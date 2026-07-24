--- Fridge Mod Control Script
-- Preservation mechanics for refrigerators, warehouses and related entities:
-- everything this mod tracks slows or stops the spoilage of what it holds.
--
-- The whole runtime is one idea. Every tracked object is an *entry* with a
-- *due tick*; a min-heap keeps them in due order; each tick spends a slot
-- budget on whatever has come due. An entry's period is normally the global
-- one, which widens as the factory grows so the per-tick cost stays flat, but
-- shortens towards PERIOD_MIN as its contents approach spoiling. Urgency is a
-- rate, not a category, so there is no second queue and nothing to be in or
-- out of.
--
-- Two properties make that safe. Recovery is derived from the time actually
-- elapsed since an entry was last visited, so the scheduler may visit whenever
-- it likes without changing how fast anything spoils. And a visit is charged
-- what it really cost rather than a prediction, so an entry that turns out
-- expensive ends the tick instead of overrunning it.
--
-- @module control
-- @author LightningMaster
-- @license MIT
-- @copyright 2025

local floor = math.floor

---- Configuration ----

-- Bounds on how long one pass over everything takes. The period adapts to the
-- workload between them (see global_period); because recovery is elapsed-based
-- it is purely a granularity/UPS knob and can move freely between ticks.
local PERIOD_MIN = 20    -- fastest refresh, for small bases
local PERIOD_MAX = 300   -- slowest refresh, from settings: 5 s of game time

-- Slots per tick the mod aims to spend once past the trivial range. At roughly
-- 4.5 us per slot the default 200 is about 0.9 ms of a 16.67 ms tick.
local SLOT_BUDGET = 200

-- Half-width of the Bezier fillet, as a fraction of the workload at which the
-- flat-budget line would reach PERIOD_MAX. 0.5 lets the per-tick budget drift
-- to 1.5x SLOT_BUDGET across the bend rather than overshooting the cap.
local BEND = 0.5

-- How far ahead of spoiling an entry is brought back. Wide enough to absorb a
-- backlog, so a container that promises its contents do not spoil is revisited
-- with time in hand rather than exactly on the deadline.
local SAFETY = 3 * PERIOD_MIN

-- How many near-expiry slots an entry tracks individually before giving up and
-- walking its whole inventory. Past this, targeting costs more than the walk.
local URGENT_SLOT_CAP = 16

-- A preservation warehouse only cools while its power proxy holds this much.
local WAREHOUSE_ENERGY = 1200000

-- Items are never pushed closer than this to brand new.
local FRESHNESS_MARGIN = 3

local freeze_rates = settings.global["fridge-freeze-rate"].value
local platform_capacity = settings.startup["fridge-space-plantform-capacity"].value

-- Skip re-walking a container whose item count has not moved. Off by default;
-- the setting description spells out the trade. See `process`.
local skip_unchanged = settings.startup["fridge-large-factory-optimization"].value

-- While skipping, a container's freshness display drifts. Bound that drift to
-- 1/SKIP_DRIFT of the life its contents had left when they were last read.
local SKIP_DRIFT = 20

---- Tracked entities ----

-- One descriptor per prototype this mod preserves. Everything else derives
-- from this table: the surface scan, the event filter, and what a new entity
-- becomes when built. A name cannot be handled by one and missed by another.
--
--   kind         how the entry is processed
--   inventory    which inventory to walk
--   full_freeze  stop spoilage entirely, rather than slow it by freeze_rates
local TRACKED = {}

local function describe(names, spec)
    for _, name in pairs(names) do
        TRACKED[name] = spec
    end
end

describe({ "refrigerater",
           "logistic-refrigerater-passive-provider",
           "logistic-refrigerater-requester",
           "logistic-refrigerater-buffer" },
         { kind = "container", inventory = defines.inventory.chest })

describe({ "preservation-wagon" },
         { kind = "container", inventory = defines.inventory.cargo_wagon })

describe({ "preservation-fast-inserter",
           "preservation-long-inserter",
           "preservation-bulk-inserter",
           "preservation-stack-inserter" },
         { kind = "inserter" })

describe({ "preservation-warehouse" },
         { kind = "warehouse", inventory = defines.inventory.chest,
           full_freeze = true })

-- Freezing cargo bays and unloading bays do not hold items themselves; they
-- grant capacity to the platform hub, which is what actually gets preserved.
describe({ "preservation-platform-warehouse",
           "preservation-platform-unloading-bay" },
         { kind = "bay" })

local PROXY_NAME = "warehouse-power-proxy"

--- The tracked names that exist in this game, as a find_entities_filtered list.
-- The stack inserter needs Space Age and the unloading bay additionally needs
-- Factorio 2.1; filtering on the prototype covers both without version guards.
local function tracked_names()
    local present = {}
    for name in pairs(TRACKED) do
        if prototypes.entity[name] then present[#present + 1] = name end
    end
    table.sort(present)  -- pairs() order is not stable across saves
    return present
end

---- Prototype cache ----

-- Rebuilt on every load and deliberately outside `storage`: prototype data
-- cannot change without one. Re-reading `stack.prototype` and calling
-- get_spoil_ticks() per stack was the largest cost in the original sweep.
local spoil_ticks = {}
local quality_changes_spoil = false

local function init_cache()
    spoil_ticks = {}
    -- Vanilla qualities leave spoil time alone, so the cache can be keyed by
    -- item name and the stack's quality never read. A mod that does change it
    -- forces the slower, fully correct path.
    local ok, changed = pcall(function()
        for _, quality in pairs(prototypes.quality) do
            if quality.spoil_ticks_multiplier ~= 1 then return true end
        end
        return false
    end)
    quality_changes_spoil = (not ok) or changed
end

---- Preserving stacks ----

--- Push one stack's spoil time back, never past brand new.
-- @param stack LuaItemStack, already known to be valid_for_read
-- @return number|nil The tick it will now spoil on, or nil if it cannot spoil
local function preserve_stack(stack, recover, tick)
    local current = stack.spoil_tick
    if current <= 0 then return nil end

    local name = stack.name
    local base
    if quality_changes_spoil then
        local by_quality = spoil_ticks[name]
        if not by_quality then
            by_quality = {}
            spoil_ticks[name] = by_quality
        end
        local quality = stack.quality.name
        base = by_quality[quality]
        if not base then
            base = stack.prototype.get_spoil_ticks(quality)
            by_quality[quality] = base
        end
    else
        base = spoil_ticks[name]
        if not base then
            base = stack.prototype.get_spoil_ticks()
            spoil_ticks[name] = base
        end
    end

    local limit = tick + base - FRESHNESS_MARGIN
    if current < limit then
        local extended = current + recover
        current = extended < limit and extended or limit
        stack.spoil_tick = current
    end
    return current
end

--- Walk an inventory, preserving what can spoil.
--
-- `track` asks for the extra bookkeeping only a full-freeze entry uses: the
-- earliest spoil tick, and which slots hold something close enough to it to be
-- worth revisiting alone. Refrigerators are the most numerous entries and are
-- allowed to spoil, so they skip it.
--
-- @param cap Optional limit on how many stacks are preserved
-- @return number Slots examined - the visit's real cost
-- @return number|nil Earliest tick anything here spoils
-- @return table|nil Slots near expiry, or nil if there are none or too many
local function walk(inv, recover, tick, track, cap)
    if inv.is_empty() then return 1 end

    local slots = #inv
    local scanned, preserved = slots, 0
    local horizon = tick + PERIOD_MAX + SAFETY
    local deadline, hot, hot_n = nil, nil, 0

    -- The body of preserve_stack, inlined. A Lua call per slot measured at 39%
    -- of this loop's total cost - the walk is the one place in the mod where
    -- that is worth eighteen duplicated lines. The quality-aware path is rare
    -- enough to stay a call.
    local cache, by_quality = spoil_ticks, quality_changes_spoil
    local ceiling = tick - FRESHNESS_MARGIN

    for i = 1, slots do
        local stack = inv[i]
        if stack.valid_for_read then
            local spoils_at
            if by_quality then
                spoils_at = preserve_stack(stack, recover, tick)
            else
                spoils_at = stack.spoil_tick
                if spoils_at > 0 then
                    local name = stack.name
                    local base = cache[name]
                    if not base then
                        base = stack.prototype.get_spoil_ticks()
                        cache[name] = base
                    end
                    local limit = ceiling + base
                    if spoils_at < limit then
                        local extended = spoils_at + recover
                        spoils_at = extended < limit and extended or limit
                        stack.spoil_tick = spoils_at
                    end
                else
                    spoils_at = nil
                end
            end
            if spoils_at then
                if track then
                    if not deadline or spoils_at < deadline then
                        deadline = spoils_at
                    end
                    if hot_n <= URGENT_SLOT_CAP and spoils_at <= horizon then
                        hot_n = hot_n + 1
                        if hot_n > URGENT_SLOT_CAP then
                            hot = nil   -- too many to target; walk it all
                        else
                            hot = hot or {}
                            hot[hot_n] = i
                        end
                    end
                end
                preserved = preserved + 1
                if cap and preserved >= cap then
                    scanned = i
                    break
                end
            end
        end
    end
    return scanned, deadline, hot
end

--- Revisit only the slots last seen holding something near expiry.
--
-- Slot indices are stable in Factorio: removing items from one slot does not
-- compact the others. Anything that does invalidate them - a stack consumed,
-- or merged away - shows up as a slot that no longer reads, and the caller
-- falls back to a full walk.
--
-- @return number|nil Earliest tick anything in those slots spoils, or nil if
--   the cache is stale and the caller must walk everything
local function walk_hot(inv, hot, recover, tick)
    local slots = #inv
    local deadline
    for k = 1, #hot do
        local index = hot[k]
        if index > slots then return nil end
        local stack = inv[index]
        if not stack.valid_for_read then return nil end
        local spoils_at = preserve_stack(stack, recover, tick)
        if not spoils_at then return nil end
        if not deadline or spoils_at < deadline then deadline = spoils_at end
    end
    return deadline
end

---- Entries ----
--
-- entry = {
--   key          unit_number, or "surface:<name>" for a platform hub
--   kind         "container" | "warehouse" | "inserter" | "platform"
--   entity       the container, inserter or hub
--   proxy        power proxy (warehouse only)
--   bays         freezing cargo bays granting capacity (platform only)
--   surface      surface name (platform only)
--   inventory    defines.inventory.* to walk
--   full_freeze  stop spoilage rather than slow it
--   work         slots the last full walk examined
--   last         tick this entry was last processed
--   due          tick it should next be processed
--   rate         its share of the per-tick slot budget, work/period
--   deadline     earliest tick its contents spoil (full-freeze entries only)
--   hot          slots near expiry, for a cheap revisit
-- }

local function platform_key(surface_name)
    return "surface:" .. surface_name
end

local function entry_for(key)
    local position = storage.index[key]
    return position and storage.queue[position]
end

--- What the next visit to this entry is expected to cost, in slots. An entry
-- tracking its near-expiry slots only pays for those.
local function visit_cost(entry)
    local hot = entry.hot
    return hot and #hot or entry.work
end

local function default_state()
    return {
        queue = {},       -- array of entries
        index = {},       -- key -> position in queue
        heap_due = {},    -- min-heap of due ticks...
        heap_key = {},    -- ...and the key each belongs to
        total_work = 0,   -- sum of entry.work, drives the global period
        demand = 0,       -- sum of entry.rate, the per-tick slot grant
        credit = 0,       -- slots banked towards the next visit
    }
end

local function reset_state()
    for field, value in pairs(default_state()) do storage[field] = value end
end

local function init_state()
    if not storage.queue then reset_state() end
end

---- Due-order heap ----
--
-- Entries are pushed with the due tick they had when scheduled. Rescheduling
-- pushes a fresh pair and leaves the old one to be discarded on pop, which
-- costs one comparison and saves maintaining positions.

local function heap_push(due, key)
    local dues, keys = storage.heap_due, storage.heap_key
    local i = #dues + 1
    dues[i], keys[i] = due, key
    while i > 1 do
        local parent = floor(i / 2)
        if dues[parent] <= dues[i] then break end
        dues[parent], dues[i] = dues[i], dues[parent]
        keys[parent], keys[i] = keys[i], keys[parent]
        i = parent
    end
end

local function heap_pop()
    local dues, keys = storage.heap_due, storage.heap_key
    local n = #dues
    if n == 0 then return nil end

    local key = keys[1]
    dues[1], keys[1] = dues[n], keys[n]
    dues[n], keys[n] = nil, nil
    n = n - 1

    local i = 1
    while true do
        local left, right, best = i * 2, i * 2 + 1, i
        if left <= n and dues[left] < dues[best] then best = left end
        if right <= n and dues[right] < dues[best] then best = right end
        if best == i then break end
        dues[i], dues[best] = dues[best], dues[i]
        keys[i], keys[best] = keys[best], keys[i]
        i = best
    end
    return key
end

---- Scheduling ----

--- How long a full pass should take at this workload.
--
-- Three regimes joined smoothly: pinned at PERIOD_MIN while the cost is
-- trivial; work/SLOT_BUDGET while that holds the per-tick cost flat; pinned at
-- PERIOD_MAX beyond, after which per-tick cost necessarily grows. The join
-- between the last two is a quadratic Bezier whose control point sits where
-- the two tangents meet, making it C1-continuous with the line at one end and
-- the asymptote at the other; that construction's x-coordinate is linear in t,
-- so there is no quadratic to solve. Bending early is what lets the per-tick
-- budget drift to 1.5x SLOT_BUDGET rather than overshooting the cap.
--
-- game.speed is the only real-time quantity involved, and it is map state
-- rather than a measurement, so this stays identical on every client. Under a
-- speed mod each tick covers less real time, so spend proportionally less per
-- tick; guarded at 1 so slow motion does not shorten the period and waste CPU.
local function global_period()
    local work = storage.total_work
    local speed = game.speed
    local budget = speed > 1 and SLOT_BUDGET / speed or SLOT_BUDGET

    if work <= budget * PERIOD_MIN then return PERIOD_MIN end

    local knee = budget * PERIOD_MAX
    local bend = BEND * knee
    if work <= knee - bend then return work / budget end
    if work >= knee + bend then return PERIOD_MAX end

    local remaining = 1 - (work - knee + bend) / (2 * bend)
    return PERIOD_MAX * (1 - BEND * remaining * remaining)
end

--- Give an entry its next due tick, and its share of the per-tick budget.
--
-- Normally the global period. A full-freeze entry promises its contents do not
-- spoil, so as its earliest deadline approaches, its period shortens to come
-- back SAFETY ticks ahead of it - continuously, not as a change of category.
local function schedule(entry, tick)
    local period = global_period()

    local deadline = entry.deadline
    if deadline and entry.full_freeze then
        local slack = deadline - tick - SAFETY
        if slack < period then period = slack end
    end
    if period < PERIOD_MIN then period = PERIOD_MIN end

    entry.due = tick + period
    storage.demand = storage.demand - (entry.rate or 0) + visit_cost(entry) / period
    entry.rate = visit_cost(entry) / period
    heap_push(entry.due, entry.key)
end

--- Bring an entry forward to be processed as soon as the budget allows.
local function expedite(entry, tick)
    entry.due = tick
    heap_push(tick, entry.key)
end

---- Queue membership ----

local function set_work(entry, work)
    if work < 1 then work = 1 end
    storage.total_work = storage.total_work + work - entry.work
    entry.work = work
end

local function queue_add(entry)
    if storage.index[entry.key] then return end

    local inv = entry.inventory and entry.entity
        and entry.entity.get_inventory(entry.inventory)
    entry.work = inv and #inv or 1
    entry.last = game.tick
    entry.rate = 0

    local queue = storage.queue
    queue[#queue + 1] = entry
    storage.index[entry.key] = #queue
    storage.total_work = storage.total_work + entry.work
    schedule(entry, game.tick)
end

--- Remove an entry in constant time by swapping the last one into its place.
-- Anything left for it in the heap is discarded when it surfaces.
local function queue_remove(key)
    local position = storage.index[key]
    if not position then return end

    local queue = storage.queue
    local last = #queue
    local entry = queue[position]
    storage.total_work = storage.total_work - entry.work
    storage.demand = storage.demand - (entry.rate or 0)
    storage.index[key] = nil

    if position ~= last then
        queue[position] = queue[last]
        storage.index[queue[position].key] = position
    end
    queue[last] = nil
end

---- Processing one entry ----

--- Ticks of spoilage to undo, given how long since this entry's last visit.
--
-- Deriving recovery from elapsed time rather than a fixed per-pass constant is
-- what lets the scheduler visit whenever it has budget: visited after 60 ticks
-- an entry gets exactly twice the nudge of one visited after 30, so the
-- effective spoil rate is identical either way. Counting whole freeze_rates
-- boundaries crossed makes the slowed rate exact without carrying a remainder.
local function recovery_for(entry, elapsed, tick)
    if entry.full_freeze then return elapsed end
    local aged = floor(tick / freeze_rates) - floor((tick - elapsed) / freeze_rates)
    return elapsed - aged
end

--- Find what an entry preserves, and how much of it.
-- @return LuaInventory|nil, number|nil The inventory and any stack cap, or nil
--   if this entry has nothing to do right now
local function contents_of(entry)
    local kind = entry.kind

    if kind == "platform" then
        -- Surviving bays set the capacity, so drop dead ones as we count. The
        -- hub is cached; the list is unordered, so swap the last one down.
        local bays = entry.bays
        for i = #bays, 1, -1 do
            if not (bays[i] and bays[i].valid) then
                bays[i] = bays[#bays]
                bays[#bays] = nil
            end
        end
        if #bays == 0 then return nil end

        local hub = entry.entity
        if not (hub and hub.valid) then
            local surface = game.surfaces[entry.surface]
            hub = surface and surface.platform and surface.platform.hub
            entry.entity = hub
        end
        if not hub then return nil end
        return hub.get_inventory(defines.inventory.hub_main),
               #bays * platform_capacity
    end

    if kind == "warehouse" and entry.proxy.energy <= WAREHOUSE_ENERGY then
        return nil  -- unpowered: its contents spoil normally
    end

    return entry.entity.get_inventory(entry.inventory)
end

--- Is this entry still real? Cleans up after itself if not.
local function alive(entry)
    if entry.kind == "platform" then
        if entry.bays[1] then return true end
    else
        local entity = entry.entity
        if entity and entity.valid then
            if entry.kind ~= "warehouse" then return true end
            local proxy = entry.proxy
            if proxy and proxy.valid then return true end
        elseif entry.proxy and entry.proxy.valid then
            entry.proxy.destroy()
        end
    end
    queue_remove(entry.key)
    return false
end

--- Preserve one entry's contents. Returns the slots the visit actually cost.
local function process(entry, tick)
    if not alive(entry) then return 0 end

    local inv, cap = contents_of(entry)
    if not inv then
        -- Nothing to preserve: an unpowered warehouse, a platform without a
        -- hub. Do not bank the elapsed time - a warehouse that lost power must
        -- not retroactively freeze everything when it comes back - and forget
        -- what it held, so nothing stale keeps it looking urgent. `work` keeps
        -- the full-walk figure: it is what a visit *might* cost, and shrinking
        -- it would let a base-wide power cut collapse the whole budget.
        entry.last = tick
        entry.deadline, entry.hot, entry.count = nil, nil, nil
        schedule(entry, tick)
        return 1
    end

    -- Large factory optimisation. Asking the game how many items a container
    -- holds is one question; reading five hundred slots is five hundred. If
    -- the answer has not moved, the previous reading still stands and the walk
    -- can wait. `last` is left alone, so whichever visit does walk recovers
    -- the whole skipped interval at once and nothing is lost.
    --
    -- What is lost meanwhile is display: an untouched spoil_tick means the
    -- freshness bar really does drain until the next walk snaps it back. So
    -- skipping is bounded by that drift rather than by time - at most
    -- 1/SKIP_DRIFT of what the contents had left when they were last read.
    -- Long-lived goods coast for thousands of ticks; something with a minute
    -- to live is barely deferred at all, and anything near spoiling is not
    -- deferred, which is what keeps the freezer's promise intact.
    --
    -- The remaining hole is an equal-count swap: one item out and one in
    -- between two walks reads as unchanged, so a nearly-spoiled newcomer goes
    -- unnoticed until the next one. Off by default, spelled out in the setting.
    if skip_unchanged and entry.count and entry.deadline then
        local drift = tick - entry.last
        if drift * SKIP_DRIFT < entry.deadline - entry.last
            and inv.get_item_count() == entry.count then
            schedule(entry, tick)
            return 1
        end
    end

    local elapsed = tick - entry.last
    if elapsed <= 0 then
        schedule(entry, tick)
        return 0
    end
    entry.last = tick

    local recover = recovery_for(entry, elapsed, tick)
    if recover <= 0 then
        schedule(entry, tick)
        return 0
    end

    local cost
    if entry.hot then
        local deadline = walk_hot(inv, entry.hot, recover, tick)
        if deadline then
            cost = #entry.hot
            entry.deadline = deadline
        else
            entry.hot = nil  -- stale; rebuilt by the full walk below
        end
    end

    if not cost then
        local scanned, deadline, hot = walk(inv, recover, tick,
                                            entry.full_freeze, cap)
        set_work(entry, scanned)
        entry.deadline, entry.hot = deadline, hot
        cost = scanned
        if skip_unchanged then entry.count = inv.get_item_count() end
    end

    schedule(entry, tick)
    return cost
end

--- Preserve an inserter's held stack. One slot, no inventory to resolve.
local function process_inserter(entry, tick)
    if not alive(entry) then return 0 end

    local elapsed = tick - entry.last
    if elapsed > 0 then
        entry.last = tick
        local recover = recovery_for(entry, elapsed, tick)
        local held = entry.entity.held_stack
        if recover > 0 and held and held.valid_for_read then
            preserve_stack(held, recover, tick)
        end
    end
    schedule(entry, tick)
    return 1
end

---- Tick ----

--- Spend this tick's slot budget on whatever has come due.
--
-- The grant is `demand`, the sum of every entry's work divided by its own
-- period - exactly the rate needed to keep all of them on schedule. Credit is
-- capped at one grant so an idle stretch cannot buy a burst, and a visit is
-- billed what it really cost, so an entry that turns out expensive drives the
-- credit negative and ends the tick rather than overrunning it.
local function on_tick(event)
    if freeze_rates == 1 then return end

    local credit = storage.credit + storage.demand
    if credit > storage.demand then credit = storage.demand end

    local tick = event.tick
    local dues = storage.heap_due

    -- The schedule is the requirement; the budget only decides how smoothly it
    -- is met. So when the credit runs out one entry is still processed, and
    -- pays for it out of the following ticks. Stopping dead instead let a
    -- fully-loaded base under a speed mod spend nearly every tick repaying a
    -- single 500-slot walk, and anything close to spoiling starved behind the
    -- bulk work until it rotted. A tick still costs at most the credit it had
    -- plus one entry, which is the bound either way.
    local forced = false

    while dues[1] and dues[1] <= tick do
        if credit <= 0 then
            if forced then break end
            forced = true
        end

        local entry = entry_for(heap_pop())
        -- Anything rescheduled since it was pushed left a stale pair behind.
        if entry and entry.due <= tick then
            if entry.kind == "inserter" then
                credit = credit - process_inserter(entry, tick)
            else
                credit = credit - process(entry, tick)
            end
        end
    end

    storage.credit = credit
end

---- Runtime events ----

--- Start tracking an entity, creating whatever it needs to work.
local function track(entity)
    local spec = TRACKED[entity.name]
    if not spec then return end

    if spec.kind == "bay" then
        -- Bays feed the platform hub entry for their surface.
        local surface_name = entity.surface.name
        local key = platform_key(surface_name)
        local entry = entry_for(key)
        if entry then
            entry.bays[#entry.bays + 1] = entity
        else
            queue_add {
                key = key,
                kind = "platform",
                surface = surface_name,
                bays = { entity },
                full_freeze = true,
            }
        end
        return
    end

    local proxy
    if spec.kind == "warehouse" then
        proxy = entity.surface.create_entity {
            name = PROXY_NAME,
            position = entity.position,
            force = entity.force,
        }
        if not proxy then return end
    end

    queue_add {
        key = entity.unit_number,
        kind = spec.kind,
        entity = entity,
        proxy = proxy,
        inventory = spec.inventory,
        full_freeze = spec.full_freeze or false,
    }
end

--- @function OnEntityCreated
-- on_entity_cloned reports the new entity as `destination`; without it a
-- cloned freezer was never tracked.
local function OnEntityCreated(event)
    local entity = event.created_entity or event.entity or event.destination
    if entity and entity.valid then track(entity) end
end

--- @function OnEntityRemoved
local function OnEntityRemoved(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end

    local spec = TRACKED[entity.name]
    if not spec then return end

    if spec.kind == "bay" then
        local entry = entry_for(platform_key(entity.surface.name))
        if not entry then return end
        local bays = entry.bays
        for i = 1, #bays do
            if bays[i] == entity then
                bays[i] = bays[#bays]
                bays[#bays] = nil
                break
            end
        end
        if #bays == 0 then queue_remove(entry.key) end
        return
    end

    local entry = entry_for(entity.unit_number)
    if entry and entry.proxy and entry.proxy.valid then entry.proxy.destroy() end
    queue_remove(entity.unit_number)
end

--- Re-check a container a player just moved items in or out of.
--
-- Nothing tells a mod that an item entered a chest, so a stack put into a
-- freezer is invisible until that container's next visit. Drop one in with
-- less life left than that and it spoils inside a working freezer. Player
-- transfers are observable though, and rare enough to act on directly: one
-- player action touches one container, where priming in bulk would hand back
-- the very stall this scheduler exists to avoid.
--
-- `last` is deliberately untouched - recovery is derived from it, and winding
-- it back would grant preservation the container did not earn.
--
-- @function OnPlayerMovedItems
local function OnPlayerMovedItems(event)
    local entity = event.entity
    if not (entity and entity.valid and entity.unit_number) then return end

    local entry = entry_for(entity.unit_number)
    if not (entry and entry.full_freeze) then return end

    -- Force a full walk, so a stack dropped into any slot is found, and drop
    -- the item count so the large-factory skip cannot short-circuit it.
    entry.hot, entry.count = nil, nil
    expedite(entry, event.tick)
end

---- Initialisation ----

local function init_settings()
    freeze_rates = settings.global["fridge-freeze-rate"].value
    SLOT_BUDGET = settings.global["fridge-slot-budget"].value
    PERIOD_MAX = settings.global["fridge-max-refresh-gap"].value
    if PERIOD_MAX < PERIOD_MIN then PERIOD_MAX = PERIOD_MIN end
end

--- Rebuild the queue from scratch by scanning every surface.
local function init_entities()
    reset_state()

    local names = tracked_names()
    if #names == 0 then return end

    for _, surface in pairs(game.surfaces) do
        -- Proxies are recreated with their warehouses, so clear the old ones.
        for _, proxy in pairs(surface.find_entities_filtered { name = PROXY_NAME }) do
            proxy.destroy()
        end
        for _, entity in pairs(surface.find_entities_filtered { name = names }) do
            track(entity)
        end
    end
end

local function init_events()
    init_settings()
    init_cache()

    local filter = {}
    for _, name in pairs(tracked_names()) do
        filter[#filter + 1] = { filter = "name", name = name }
    end

    for _, event in pairs {
        defines.events.on_built_entity,                 -- player built
        defines.events.on_entity_cloned,                -- copied
        defines.events.on_robot_built_entity,           -- robot built
        defines.events.on_space_platform_built_entity,  -- space platform
        defines.events.script_raised_built,             -- script created
        defines.events.script_raised_revive,            -- revived
    } do
        script.on_event(event, OnEntityCreated, filter)
    end

    for _, event in pairs {
        defines.events.on_player_mined_entity,          -- player removed
        defines.events.on_robot_mined_entity,           -- robot removed
        defines.events.on_space_platform_mined_entity,  -- space platform
        defines.events.on_entity_died,                  -- destroyed
        defines.events.script_raised_destroy,           -- script removed
    } do
        script.on_event(event, OnEntityRemoved, filter)
    end

    -- The only item movement into a container a mod can observe. Unfiltered
    -- because both carry an arbitrary entity; the handler drops anything it is
    -- not already tracking in one lookup.
    script.on_event(defines.events.on_player_fast_transferred, OnPlayerMovedItems)
    script.on_event(defines.events.on_gui_closed, OnPlayerMovedItems)

    script.on_event(defines.events.on_tick, on_tick)
    script.on_event(defines.events.on_runtime_mod_setting_changed, init_settings)
end

---- Lifecycle ----

script.on_load(init_events)

script.on_init(function()
    init_state()
    init_events()
    init_entities()
end)

script.on_configuration_changed(function()
    init_settings()
    init_state()
    init_events()
    init_entities()
end)
