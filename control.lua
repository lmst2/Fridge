--- Fridge Mod Control Script
-- Implements preservation mechanics for refrigerators, warehouses, and related entities
-- that extend item spoilage time through various cooling mechanisms.
--
-- Preservation used to run as a periodic sweep: every N ticks, walk every stack
-- in every tracked container and rewrite its spoil_tick. That put the entire
-- factory's cost on a single tick, which is what players saw as a recurring
-- freeze. It is now a continuously drained work queue instead - see the
-- "Preservation work queue" and "Scheduler" sections.
--
-- @module control
-- @author LightningMaster
-- @license MIT
-- @copyright 2025

---- Configuration ----

-- How long one complete pass over everything tracked takes, in ticks. The
-- period adapts to how much there is to preserve (see update_period): a handful
-- of refrigerators refresh every PERIOD_MIN ticks, a late-game base stretches
-- out towards PERIOD_MAX so the per-tick cost stays bounded.
--
-- Because recovery is derived from the time that actually elapsed since an
-- entry was last visited (see recovery_for), the period is purely a
-- granularity/UPS knob: it can move freely between ticks without changing how
-- fast anything spoils.
local PERIOD_MIN = 20    -- fastest refresh, for small bases
local PERIOD_MAX = 300   -- slowest refresh: 5 seconds of game time

-- Slots per tick the mod aims to spend once it is past the trivial range.
-- At roughly 4.5 us per slot this is about 0.9 ms of a 16.67 ms tick.
local SLOT_BUDGET = 200

-- Half-width of the Bezier fillet, as a fraction of the workload at which the
-- flat-budget line would hit PERIOD_MAX. 0.5 lets the per-tick budget drift to
-- 1.5x SLOT_BUDGET across the bend rather than letting the period overshoot.
local BEND = 0.5

-- A stack this close to spoiling gets its container watched by the fast lane.
--
-- Sized so that a main-queue pass alone is enough to notice one: a pass happens
-- at least every PERIOD_MAX ticks, and an entry outside the horizon at one pass
-- still has 3*PERIOD_MIN left at the next. That margin is what lets the watch
-- list be maintained as passes happen, with no separate sweep looking for
-- entries whose deadline has drifted closer.
local URGENT_HORIZON = PERIOD_MAX + 3 * PERIOD_MIN

-- ...but being watched is not the same as being refreshed. An entry is only
-- actually served once it is this close to expiring, so a stack with 150 ticks
-- of life waits instead of being rewritten every window for no reason. Wide
-- enough to absorb both the scan granularity and a full window of drain delay.
local URGENT_SERVE_WITHIN = 3 * PERIOD_MIN

-- How many near-expiry slots an entry may track individually before the fast
-- lane gives up and just walks its whole inventory. Past this, targeting
-- separate slots costs more than the walk it is trying to avoid.
local URGENT_SLOT_CAP = 16

-- Largest slot range a single entry covers. An inventory bigger than this is
-- tracked as several entries, one per range, so no single pass can cost more
-- than this however big the container - a modded ten-thousand-slot chest is
-- fifty entries, not one stall. A normal container is one entry and unchanged.
local MAX_ENTRY_SLOTS = 200

-- The warmup window (see prime_entries), and how many slots it primes per tick.
-- A warehouse's power proxy is created empty and only powers up a tick or two
-- later, so priming spreads across this window rather than firing once. Sized
-- so a large base is fully primed well within a short-lived item's life without
-- any single tick paying for the whole thing.
local WARMUP_TICKS = 60
local WARMUP_BUDGET = 3 * SLOT_BUDGET

-- Stand-in for "nothing is close to spoiling". Finite so it serialises.
local NEVER = 2 ^ 40

-- A preservation warehouse only cools while its power proxy holds this much.
local WAREHOUSE_ENERGY_THRESHOLD = 1200000

-- Items are never pushed closer than this to brand new.
local FRESHNESS_MARGIN = 3

-- Load mod settings
local freeze_rates = settings.global["fridge-freeze-rate"].value
local platform_capacity = settings.startup["fridge-space-plantform-capacity"].value

--- Entities this mod tracks, grouped by how they preserve.
-- These lists are the single source of truth: the surface scan, the event
-- filter and the build/remove handlers all derive from them, so a name can no
-- longer be handled by one and missed by another.
local FRIDGE_NAMES = {
    "refrigerater",
    "logistic-refrigerater-passive-provider",
    "logistic-refrigerater-requester",
    "logistic-refrigerater-buffer"
}
local INSERTER_NAMES = {
    "preservation-fast-inserter",
    "preservation-long-inserter",
    "preservation-bulk-inserter",
    "preservation-stack-inserter"
}
local PLATFORM_NAMES = {
    "preservation-platform-warehouse",
    "preservation-platform-unloading-bay"
}
local WAREHOUSE_NAME = "preservation-warehouse"
local WAGON_NAME = "preservation-wagon"

--- Turn a name list into a lookup set.
local function name_set(names)
    local set = {}
    for _, name in pairs(names) do
        set[name] = true
    end
    return set
end

local IS_FRIDGE = name_set(FRIDGE_NAMES)
local IS_INSERTER = name_set(INSERTER_NAMES)
local IS_PLATFORM = name_set(PLATFORM_NAMES)

--- Keep only the names that exist in this game.
-- The stack inserter needs Space Age, and the unloading bay additionally needs
-- Factorio 2.1, where Space Age ships the cargo bay it is built from. Filtering
-- on the prototype covers both without version guards at every use site.
local function existing_names(names)
    local present = {}
    for _, name in pairs(names) do
        if prototypes.entity[name] then
            present[#present + 1] = name
        end
    end
    return present
end

---- Prototype caches ----

-- Rebuilt on every load and deliberately kept out of `storage`: prototype data
-- cannot change without a reload. Re-reading `stack.prototype` and calling
-- get_spoil_ticks() for every stack on every pass was the single largest cost
-- in the old sweep.
local spoil_ticks = {}
local quality_changes_spoil = false

local function init_caches()
    spoil_ticks = {}
    -- Vanilla qualities all leave spoil time alone, so the cache can be keyed
    -- by item name only and the stack's quality never has to be read. Any mod
    -- that does change it forces the slower, fully correct path.
    local ok, changed = pcall(function()
        for _, quality in pairs(prototypes.quality) do
            if quality.spoil_ticks_multiplier ~= 1 then
                return true
            end
        end
        return false
    end)
    quality_changes_spoil = (not ok) or changed
end

---- Preservation ----

--- Push one stack's spoil time back, without letting it become fresher than new.
-- @param stack LuaItemStack, already known to be valid_for_read
-- @param recover Ticks of spoilage to undo
-- @param tick Current tick
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

--- Preserve every spoilable stack in an inventory.
-- @param inv LuaInventory
-- @param recover Ticks of spoilage to undo
-- @param tick Current tick
-- @param max_stacks Optional cap on how many stacks are preserved
-- @return number Slots examined - this entry's workload for the scheduler
-- @return number|nil Earliest tick anything in here spoils, for the fast lane
-- @return table|false|nil Slots holding something near expiry, so the fast lane
--   can revisit those alone instead of the whole inventory; false means there
--   are too many to be worth tracking and it should walk everything
-- @param from,to Slot range this entry owns; a large inventory is split across
--   several entries so no single pass walks more than MAX_ENTRY_SLOTS slots.
local function preserve_inventory(inv, recover, tick, max_stacks, from, to)
    if inv.is_empty() then return 1, nil, nil end

    from = from or 1
    to = to or #inv
    local horizon = tick + URGENT_HORIZON
    local scanned = to - from + 1
    local preserved = 0
    local deadline, hot
    for i = from, to do
        local stack = inv[i]
        if stack.valid_for_read then
            local spoils_at = preserve_stack(stack, recover, tick)
            if spoils_at then
                if not deadline or spoils_at < deadline then
                    deadline = spoils_at
                end
                if hot ~= false and spoils_at <= horizon then
                    hot = hot or {}
                    hot[#hot + 1] = i
                    if #hot > URGENT_SLOT_CAP then hot = false end
                end
                preserved = preserved + 1
                if max_stacks and preserved >= max_stacks then
                    scanned = i - from + 1
                    break
                end
            end
        end
    end
    return scanned, deadline, hot
end

--- Refresh only the slots already known to hold something near expiry.
--
-- The whole point of the fast lane is one dying stack, but a legendary
-- warehouse is 500 slots and the other 499 have hours left. Walking all of them
-- to save one made a single dying stack cost as much as the entire rest of the
-- base. Slot indices are stable in Factorio - removing from one slot does not
-- compact the others - so the indices found on the last full pass stay valid,
-- and anything that does invalidate them (a stack consumed, or merged away)
-- shows up as a slot that no longer reads, which sends us back to a full walk.
--
-- @return number|nil Slots touched, or nil if the cache is stale
-- @return number|nil Earliest tick anything in those slots spoils
local function preserve_hot_slots(inv, hot, recover, tick)
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
    return #hot, deadline
end

---- Preservation work queue ----
--
-- Everything tracked is one entry in `storage.queue`, and each entry caches
-- `work`: how many inventory slots its last pass had to walk. The scheduler
-- spends a fixed share of the *total* workload per tick, so a packed legendary
-- warehouse and an empty refrigerator no longer cost the same slice, and no
-- single tick ever pays for the whole factory.
--
-- entry = {
--   key          unit_number, or "surface:<name>" for a platform
--   kind         "container" | "warehouse" | "inserter" | "platform"
--   entity       container / inserter / platform hub
--   proxy        power proxy (warehouse only)
--   inventory    defines.inventory.* to walk (containers only)
--   from,to      slot range this entry owns (a large inventory is split)
--   surface      surface name (platform only)
--   full_freeze  true stops spoilage outright, false slows it by freeze_rates
--   work         cached slot count, at least 1
--   last         tick this entry was last processed
--   acc          leftover fractional aging in ticks, see recovery_for
-- }

local function init_storages()
    storage.queue = storage.queue or {}
    storage.index = storage.index or {}
    storage.cursor = storage.cursor or 1
    storage.total_work = storage.total_work or 0
    storage.work_credit = storage.work_credit or 0
    storage.urgent = storage.urgent or {}
    storage.urgent_work = storage.urgent_work or 0
    storage.urgent_largest = storage.urgent_largest or 1
    storage.urgent_cursor = storage.urgent_cursor or 1
    storage.urgent_credit = storage.urgent_credit or 0
    storage.urgent_accum = storage.urgent_accum or 0
    storage.urgent_accum_largest = storage.urgent_accum_largest or 1
    storage.warmup = storage.warmup or 0
    storage.warmup_cursor = storage.warmup_cursor or 1
    storage.PlatformWarehouses = storage.PlatformWarehouses or {}
end

--- What one fast-lane visit to this entry costs, in slots. An entry tracking
-- its near-expiry slots individually only pays for those; one that gave up on
-- tracking them pays for the whole inventory.
local function urgent_cost(entry)
    local hot = entry.hot
    if hot and #hot > 0 then return #hot end
    return entry.work
end

--- Put an entry on the fast lane's watch list, if it is not on it already.
local function watch(entry)
    if entry.watched then return end
    entry.watched = true

    local urgent = storage.urgent
    urgent[#urgent + 1] = entry.key

    -- Count it towards the current cycle straight away, so a set that grows
    -- mid-cycle is still funded rather than waiting for the next wrap.
    local cost = urgent_cost(entry)
    storage.urgent_work = storage.urgent_work + cost
    if cost > storage.urgent_largest then storage.urgent_largest = cost end
end

--- Record when an entry's contents will next spoil, and start watching it if
-- that is soon.
--
-- Only full-freeze entries take part: they promise items do not spoil at all,
-- so the scheduler must never let a queue delay break that. A refrigerator only
-- promises *slower* spoilage, which the queue already delivers exactly, so
-- tracking those here would just drag the fast lane down for no gain.
--
-- Membership is decided here, as passes happen, rather than by a separate sweep
-- hunting for entries whose deadline has drifted closer. URGENT_HORIZON is wide
-- enough that a pass always catches one with time to spare, which is what makes
-- that sweep unnecessary.
local function set_deadline(entry, deadline, tick)
    if not entry.full_freeze then return end
    entry.deadline = deadline
    if deadline and deadline - tick <= URGENT_HORIZON then
        watch(entry)
    end
end

--- Update an entry's cached workload, keeping the running total in step.
local function set_work(entry, work)
    if work < 1 then work = 1 end
    if work ~= entry.work then
        storage.total_work = storage.total_work + work - entry.work
        entry.work = work
    end
end

local function queue_add(entry)
    if storage.index[entry.key] then return end
    if not entry.work or entry.work < 1 then entry.work = 1 end
    entry.last = game.tick
    entry.acc = 0
    -- Deliberately no deadline yet: it is learned on the first pass. Priming
    -- new entries as due-now would make a blueprint drop, or the rescan after a
    -- mod update, mark every freezer urgent at once and hand back exactly the
    -- one-big-tick spike this scheduler exists to avoid.

    local queue = storage.queue
    queue[#queue + 1] = entry
    storage.index[entry.key] = #queue
    storage.total_work = storage.total_work + entry.work
end

--- Remove an entry in constant time by swapping the last one into its place.
local function queue_remove(key)
    local position = storage.index[key]
    if not position then return end

    local queue = storage.queue
    local last = #queue
    storage.total_work = storage.total_work - queue[position].work
    storage.index[key] = nil
    if position ~= last then
        queue[position] = queue[last]
        storage.index[queue[position].key] = position
    end
    queue[last] = nil
end

--- Slots in an entity's tracked inventory, for the initial workload estimate.
local function inventory_slots(entity, inventory)
    local inv = entity.get_inventory(inventory)
    return inv and #inv or 1
end

--- Key for one slot range of an entity. Chunk 0 keeps the bare unit_number, so
-- an entity small enough not to split looks exactly as it did before.
local function chunk_key(unit_number, chunk)
    return chunk == 0 and unit_number or (unit_number .. "#" .. chunk)
end

--- Every key covering this entity. Chunks are contiguous from zero, so walking
-- until one is missing finds them all with no stored list.
local function chunk_keys(unit_number)
    local keys = {}
    while storage.index[chunk_key(unit_number, #keys)] do
        keys[#keys + 1] = chunk_key(unit_number, #keys)
    end
    return keys
end

--- Register a container, splitting a large inventory into one entry per range.
-- Every entry shares the entity (and the warehouse's power proxy); each walks
-- only its own slots.
local function register_container(entity, kind, inventory, full_freeze, proxy)
    local slots = inventory_slots(entity, inventory)
    for chunk = 0, math.floor((slots - 1) / MAX_ENTRY_SLOTS) do
        local from = chunk * MAX_ENTRY_SLOTS + 1
        local to = from + MAX_ENTRY_SLOTS - 1
        if to > slots then to = slots end
        queue_add{
            key = chunk_key(entity.unit_number, chunk),
            kind = kind,
            entity = entity,
            proxy = proxy,
            inventory = inventory,
            full_freeze = full_freeze,
            from = from,
            to = to,
            work = to - from + 1
        }
    end
end

---- Scheduler ----

--- Ticks of spoilage to undo, given how long since this entry's last pass.
-- Deriving recovery from elapsed time rather than a fixed per-sweep constant is
-- what lets the scheduler visit an entry whenever it has budget: visited after
-- 60 ticks it gets exactly twice the nudge of one visited after 30, so the
-- effective spoil rate is identical either way. `acc` carries the remainder
-- below one full freeze_rates step so nothing is lost to rounding.
local function recovery_for(entry, elapsed)
    if entry.full_freeze then return elapsed end
    local accumulated = entry.acc + elapsed
    local aged = math.floor(accumulated / freeze_rates)
    entry.acc = accumulated - aged * freeze_rates
    return elapsed - aged
end

--- How many ticks a full pass should take, for the current workload.
--
-- Three regimes joined into one smooth curve:
--
--   tiny workload   period pinned at PERIOD_MIN; the cost is negligible either
--                   way, so refresh as promptly as is useful
--   growing         period = work / budget, holding the per-tick cost flat at
--                   SLOT_BUDGET while the base grows
--   large           period pinned at PERIOD_MAX, after which the per-tick cost
--                   necessarily grows with the workload
--
-- The join between the last two is a quadratic Bezier whose control point sits
-- where the two tangents meet, which makes it C1-continuous with the straight
-- line at one end and with the PERIOD_MAX asymptote at the other. Because the
-- x-coordinate of that construction is linear in t, there is no quadratic to
-- solve. Letting the period bend over early is what lets the per-tick budget
-- drift up to 1.5x SLOT_BUDGET (1.14x a third of the way in, 1.29x two thirds)
-- instead of blowing straight through the 5 second cap.
--
-- Note the only real-time quantity in the whole controller is game.speed, and
-- it is map state rather than a measurement, so this stays deterministic and
-- identical on every client. Wall-clock lag is deliberately not consulted: it
-- is unreadable from a mod, and using it would make spoil_tick depend on how
-- fast a given machine is, which desyncs multiplayer.
local function update_period(work)
    -- Under a speed mod each tick covers less real time, so spend
    -- proportionally less per tick and let the fast-forward actually go fast.
    -- Guarded at 1 so slow motion does not shorten the period and waste CPU.
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

--- Preserve a platform's hub inventory, up to the capacity its freezing cargo
-- bays provide. The hub is cached on the entry; the old code searched the whole
-- surface for it on every sweep.
-- @return boolean Whether the entry removed itself
local function preserve_platform(entry, tick)
    local surface = game.surfaces[entry.surface]
    local warehouses = storage.PlatformWarehouses[entry.surface]
    if not (surface and warehouses) then
        queue_remove(entry.key)
        return true
    end

    -- Surviving bays set the capacity, so drop dead ones as we count.
    for i = #warehouses, 1, -1 do
        local warehouse = warehouses[i]
        if not (warehouse and warehouse.valid) then
            table.remove(warehouses, i)
        end
    end
    if #warehouses == 0 then
        storage.PlatformWarehouses[entry.surface] = nil
        queue_remove(entry.key)
        return true
    end

    local hub = entry.entity
    if not (hub and hub.valid) then
        hub = surface.find_entities_filtered{ name = "space-platform-hub" }[1]
        entry.entity = hub
    end

    local inv = hub and hub.get_inventory(defines.inventory.hub_main)
    if not inv then
        entry.last = tick
        set_work(entry, 1)
        return false
    end

    local elapsed = tick - entry.last
    if elapsed <= 0 then return false end
    entry.last = tick

    local recover = recovery_for(entry, elapsed)
    if recover > 0 then
        local scanned, deadline = preserve_inventory(inv, recover, tick,
            #warehouses * platform_capacity)
        set_work(entry, scanned)
        set_deadline(entry, deadline, tick)
        -- A hub's walk is already bounded by the bays' capacity, and its slot
        -- indices shift as cargo pods load and unload, so it always walks.
        entry.hot = false
    end
    return false
end

--- Run one entry's preservation pass.
-- @param hot_only Refresh just the slots near expiry, if that is known to be
--   enough. Falls back to a full walk by itself when the cache is stale.
-- @return boolean Whether the entry removed itself from the queue
local function preserve_entry(entry, tick, hot_only)
    local kind = entry.kind
    if kind == "platform" then
        return preserve_platform(entry, tick)
    end

    local entity = entry.entity
    if not (entity and entity.valid) then
        if entry.proxy and entry.proxy.valid then
            entry.proxy.destroy()
        end
        queue_remove(entry.key)
        return true
    end

    if kind == "warehouse" then
        local proxy = entry.proxy
        if not (proxy and proxy.valid) then
            queue_remove(entry.key)
            return true
        end
        if proxy.energy <= WAREHOUSE_ENERGY_THRESHOLD then
            -- Unpowered: items spoil normally. Skip the walk, and just as
            -- importantly do not bank the elapsed time - a warehouse that lost
            -- power must not retroactively freeze everything when it returns.
            entry.last = tick
            entry.acc = 0
            -- `work` deliberately left at the full-walk figure. It is the
            -- scheduler's estimate of what a visit *might* cost, not what this
            -- one did, and collapsing it to 1 made a base-wide power cut shrink
            -- total_work to nothing - so when power returned every warehouse
            -- was charged 1 and walked 500, all on one tick.
            -- Its contents spoil normally now, so drop it out of the fast lane
            -- rather than letting a stale deadline keep waking it.
            set_deadline(entry, nil, tick)
            entry.hot = nil
            return false
        end
    end

    local elapsed = tick - entry.last
    if elapsed <= 0 then return false end
    entry.last = tick

    local recover = recovery_for(entry, elapsed)
    if recover <= 0 then return false end

    if kind == "inserter" then
        local held = entity.held_stack
        if held and held.valid_for_read then
            set_deadline(entry, preserve_stack(held, recover, tick), tick)
        end
        return false
    end

    local inv = entity.get_inventory(entry.inventory)
    if not inv then
        set_work(entry, 1)
        set_deadline(entry, nil, tick)
        entry.hot = nil
        return false
    end

    if hot_only and entry.hot then
        local _, deadline = preserve_hot_slots(inv, entry.hot, recover, tick)
        if deadline then
            set_deadline(entry, deadline, tick)
            return false
        end
        -- Cache went stale, so fall through and rebuild it from a full walk.
    end

    local scanned, deadline, hot = preserve_inventory(inv, recover, tick, nil,
        entry.from, entry.to)
    set_work(entry, scanned)
    set_deadline(entry, deadline, tick)
    entry.hot = hot
    return false
end

---- Near-expiry fast lane ----
--
-- A full-freeze container promises its contents do not spoil, but the main
-- queue only guarantees a visit once per period, which can be as long as
-- PERIOD_MAX. A stack with less life left than that would spoil while waiting
-- its turn. This lane revisits those containers every PERIOD_MIN ticks instead.
--
-- It is a second queue, not a bypass. Serving every urgent container the
-- instant it qualifies would put the whole urgent set on one tick - the exact
-- shape of stall this scheduler exists to remove, just reached through a
-- different door. A Gleba base buffering nutrients through fifty freezing
-- warehouses is enough to trigger it. So the lane carries its own credit and
-- spreads its work across the same PERIOD_MIN ticks it has to finish within.

--- Rebuild the urgent set. O(n) in integer compares, no API calls, and gated on
-- the tracked lower bound, so in a working freezer it almost never runs.
-- Recomputes that bound exactly while it is here.
--- Work through the watch list, covering it every PERIOD_MIN ticks.
--
-- A continuous round robin: entries join via watch() as passes discover them,
-- and drop out here once their deadline is no longer near. Walking a slice per
-- tick keeps a large watch list from costing a whole-list pass on one tick, the
-- same way the main queue is spread.
--
-- Entries are held by key rather than position because a queue removal swaps
-- the last entry into the freed slot.
local function urgent_drain(tick)
    local urgent = storage.urgent
    local count = #urgent
    if count == 0 then return end

    -- Ceiling is one tick's grant plus the largest single entry: enough to
    -- always afford the biggest warehouse in the set even when the grant alone
    -- would not cover it, but never enough to bank a crowd. Credit carries
    -- across a wrap - zeroing it starves any entry costing more than one
    -- cycle's grant, which silently let a whole warehouse spoil once already.
    local grant = storage.urgent_work / PERIOD_MIN
    local credit = storage.urgent_credit + grant
    local ceiling = grant + storage.urgent_largest
    if credit > ceiling then credit = ceiling end

    local cursor = storage.urgent_cursor
    local accum = storage.urgent_accum
    local accum_largest = storage.urgent_accum_largest
    local slice = math.ceil(count / PERIOD_MIN)
    local examined = 0

    while examined < slice and count > 0 do
        if cursor > count then
            -- Wrapped: publish the workload actually observed this cycle.
            storage.urgent_work = accum
            storage.urgent_largest = accum_largest
            accum, accum_largest, cursor = 0, 1, 1
        end

        local position = storage.index[urgent[cursor]]
        local entry = position and storage.queue[position]

        if not entry or not entry.deadline
            or entry.deadline - tick > URGENT_HORIZON then
            -- Gone, or no longer close enough to be worth watching. Swap the
            -- last key into this slot and re-examine without advancing.
            if entry then entry.watched = nil end
            urgent[cursor] = urgent[count]
            urgent[count] = nil
            count = count - 1
            -- Counts against the slice even though the cursor holds position:
            -- a base-wide power cut unwatches every warehouse at once, and
            -- without this the whole list would be cleared on a single tick.
            examined = examined + 1
        else
            local cost = urgent_cost(entry)
            accum = accum + cost
            if cost > accum_largest then accum_largest = cost end

            -- Serving on urgency rather than on membership is what keeps a
            -- crowd of merely-nearby deadlines from costing a full refresh
            -- every cycle: a stack with 150 ticks left is touched about every
            -- 110 ticks, not every 20, and still never gets within PERIOD_MIN
            -- of spoiling.
            if entry.deadline - tick <= URGENT_SERVE_WITHIN
                and tick - entry.last >= PERIOD_MIN then
                if cost > credit then break end
                credit = credit - cost
                preserve_entry(entry, tick, true)
            end
            cursor = cursor + 1
            examined = examined + 1
        end
    end

    storage.urgent_cursor = cursor
    storage.urgent_credit = credit
    storage.urgent_accum = accum
    storage.urgent_accum_largest = accum_largest
end

--- Main tick handler: drain a slice of the preservation queue.
-- Credit is carried in slots: every tick grants one period's worth of the total
-- workload, and visiting an entry costs the slots it last had to walk. Because
-- the cost is the entry's own slot count, the slice is balanced by real work
-- rather than by container count, and because the grant is derived from the
-- adaptive period the per-tick cost stays near SLOT_BUDGET as a base grows.
-- @param event Event data from Factorio runtime
--- Learn every entry's deadline the moment the queue is (re)built.
--
-- Without this a freshly built queue has no deadlines, so the fast lane cannot
-- see which containers hold something close to spoiling until the main cursor
-- reaches each one - up to a full period later. On a large base that is long
-- enough for short-lived goods that were near expiry at load to rot first. One
-- read-only pass (recover = 0 preserves nothing, it only records the earliest
-- spoil tick and the near-expiry slots) closes that window: the fast lane can
-- protect anything urgent from the very first tick. Repeated over WARMUP_TICKS
-- because a warehouse's proxy is created empty and only powers up a tick later.
--
-- Spread across the warmup window a slot budget at a time, from a cursor that
-- wraps, so no single tick pays for the whole base - priming everything at once
-- on the tick the proxies powered up was a 140 ms stall on a large factory.
local function prime_entries()
    local queue = storage.queue
    local n = #queue
    if n == 0 then return end

    local tick = game.tick
    local cursor = storage.warmup_cursor or 1
    local budget = WARMUP_BUDGET
    local checked = 0
    while checked < n and budget > 0 do
        if cursor > n then cursor = 1 end
        local entry = queue[cursor]
        if entry and not entry.primed and entry.inventory
            and entry.entity and entry.entity.valid then
            local powered = entry.kind ~= "warehouse"
                or (entry.proxy and entry.proxy.valid
                    and entry.proxy.energy > WAREHOUSE_ENERGY_THRESHOLD)
            if powered then
                local inv = entry.entity.get_inventory(entry.inventory)
                if inv then
                    local scanned, deadline, hot = preserve_inventory(
                        inv, 0, tick, nil, entry.from, entry.to)
                    set_work(entry, scanned)
                    set_deadline(entry, deadline, tick)
                    entry.hot = hot
                    entry.primed = true
                    budget = budget - entry.work
                end
            end
        end
        cursor = cursor + 1
        checked = checked + 1
    end
    storage.warmup_cursor = cursor
end

local function on_tick(event)
    if freeze_rates == 1 then return end

    local queue = storage.queue
    if #queue == 0 then return end
    local tick = event.tick

    -- Keep priming until every entry has come online, so a warehouse whose
    -- proxy was still charging at the rebuild still gets its deadline learned.
    if storage.warmup and tick <= storage.warmup then
        prime_entries()
    end

    urgent_drain(tick)

    local count = #queue
    if count == 0 then return end
    local total = storage.total_work
    if total <= 0 then return end

    -- Never bank more than one full cycle, so an idle stretch cannot buy a
    -- burst that undoes the whole point of spreading the work out.
    local credit = storage.work_credit + total / update_period(total)
    if credit > total then credit = total end

    local cursor = storage.cursor
    local visited = 0

    while visited < count do
        if cursor > #queue then cursor = 1 end
        local entry = queue[cursor]
        if not entry then break end

        local estimate = entry.work
        if estimate > credit then break end
        credit = credit - estimate

        -- A removed entry pulls the last one into this slot, so hold position.
        if not preserve_entry(entry, tick) then
            -- The estimate comes from the previous visit and can undershoot
            -- badly: an unpowered warehouse is recorded as a single slot, and
            -- the pass after power returns walks five hundred. Charging only
            -- the estimate let a base-wide power cut collapse total_work, and
            -- restoring power then walked every warehouse on one tick. Bill the
            -- difference so a surprise ends the tick instead of landing on it.
            local actual = entry.work
            if actual > estimate then
                credit = credit - (actual - estimate)
            end
            cursor = cursor + 1
        end
        visited = visited + 1
    end

    storage.cursor = cursor
    storage.work_credit = credit
end

---- Runtime Events ----

--- Start tracking a platform surface, if it is not tracked already.
local function register_platform(surface_name)
    if storage.index["surface:" .. surface_name] then return end
    queue_add{
        key = "surface:" .. surface_name,
        kind = "platform",
        surface = surface_name,
        full_freeze = true,
        work = platform_capacity
    }
end

--- Handle creation of preservation entities
-- Registers newly created entities in the work queue and performs any necessary
-- setup (like creating power proxies for warehouses).
--
-- @function OnEntityCreated
-- @param event Event data containing the created entity
local function OnEntityCreated(event)
    -- on_entity_cloned reports the new entity as `destination`; without it a
    -- cloned freezer was never tracked.
    local entity = event.created_entity or event.entity or event.destination
    if not (entity and entity.valid) then return end
    local name = entity.name

    if name == WAREHOUSE_NAME then
        -- Create power proxy for warehouse
        local proxy = entity.surface.create_entity{
            name = "warehouse-power-proxy",
            position = entity.position,
            force = entity.force
        }
        if proxy then
            register_container(entity, "warehouse", defines.inventory.chest, true, proxy)
        end

    elseif IS_PLATFORM[name] then
        local surface_name = entity.surface.name
        local warehouses = storage.PlatformWarehouses[surface_name]
        if not warehouses then
            warehouses = {}
            storage.PlatformWarehouses[surface_name] = warehouses
        end
        warehouses[#warehouses + 1] = entity
        register_platform(surface_name)

    elseif IS_FRIDGE[name] then
        register_container(entity, "container", defines.inventory.chest, false)

    elseif name == WAGON_NAME then
        register_container(entity, "container", defines.inventory.cargo_wagon, false)

    elseif IS_INSERTER[name] then
        queue_add{
            key = entity.unit_number,
            kind = "inserter",
            entity = entity,
            full_freeze = false,
            work = 1
        }
    end
end

--- Re-check a container a player just moved items in or out of.
--
-- Nothing tells a mod that an item entered a chest, so a stack put into a
-- freezer is invisible until that container's next pass - up to PERIOD_MAX
-- ticks away. Drop one in with less life left than that and it spoils inside a
-- working freezer. The watch list cannot help, because it is keyed on the
-- deadline recorded at the last pass, which knows nothing about the new stack.
--
-- Player transfers are observable though, and rare enough to act on directly.
-- Marking the entry due-now gets it served within PERIOD_MIN instead of
-- PERIOD_MAX, and clearing `hot` forces that pass to be a full walk, so a stack
-- dropped into any slot is found. The deadline is a placeholder that the walk
-- immediately replaces with the truth.
--
-- `last` is deliberately left alone: recovery is derived from it, so winding it
-- back would hand the container extra preservation it did not earn.
--
-- Priming is safe here in a way it is not for bulk registration - one player
-- action touches one container, where a blueprint drop would mark every freezer
-- urgent at once and hand back the very stall this scheduler exists to remove.
--
-- @function OnPlayerMovedItems
local function OnPlayerMovedItems(event)
    local entity = event.entity
    if not (entity and entity.valid and entity.unit_number) then return end

    -- Every chunk, since the stack could have landed in any slot range.
    for _, key in pairs(chunk_keys(entity.unit_number)) do
        local entry = storage.queue[storage.index[key]]
        if entry and entry.full_freeze then
            entry.hot = nil
            entry.deadline = event.tick
            watch(entry)
        end
    end
end

--- Handle removal of preservation entities
-- Drops the entity from the work queue and performs any necessary cleanup
-- (like destroying power proxies for warehouses).
--
-- @function OnEntityRemoved
-- @param event Event data containing the removed entity
local function OnEntityRemoved(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    local name = entity.name

    if IS_PLATFORM[name] then
        local surface_name = entity.surface.name
        local warehouses = storage.PlatformWarehouses[surface_name]
        if warehouses then
            for i = #warehouses, 1, -1 do
                if warehouses[i] == entity then
                    table.remove(warehouses, i)
                    break
                end
            end
            if #warehouses == 0 then
                storage.PlatformWarehouses[surface_name] = nil
                queue_remove("surface:" .. surface_name)
            end
        end
        return
    end

    if name == WAREHOUSE_NAME then
        local position = storage.index[entity.unit_number]
        local entry = position and storage.queue[position]
        if entry and entry.proxy and entry.proxy.valid then
            entry.proxy.destroy()
        end
    end
    -- Remove every chunk of the entity, not just chunk 0.
    for _, key in pairs(chunk_keys(entity.unit_number)) do
        queue_remove(key)
    end
end

---- Initialization Functions ----

--- Initialize or update mod settings
-- @function init_settings
local function init_settings()
    freeze_rates = settings.global["fridge-freeze-rate"].value
end

--- Find and register all preservation entities across all surfaces
-- Rebuilds the work queue from scratch by scanning every surface. Also cleans
-- up old power proxies and creates fresh ones.
--
-- @function init_entities
local function init_entities()
    storage.queue = {}
    storage.index = {}
    storage.cursor = 1
    storage.total_work = 0
    storage.work_credit = 0
    storage.urgent = {}
    storage.urgent_work = 0
    storage.urgent_largest = 1
    storage.urgent_cursor = 1
    storage.urgent_credit = 0
    storage.urgent_accum = 0
    storage.urgent_accum_largest = 1
    storage.PlatformWarehouses = {}

    local fridge_names = existing_names(FRIDGE_NAMES)
    local inserter_names = existing_names(INSERTER_NAMES)
    local platform_names = existing_names(PLATFORM_NAMES)

    for _, surface in pairs(game.surfaces) do
        -- Clean up old power proxies first
        for _, proxy in pairs(surface.find_entities_filtered{ name = "warehouse-power-proxy" }) do
            proxy.destroy()
        end

        -- An empty name list would make find_entities_filtered match everything,
        -- so every scan below is guarded on having something to look for.
        if #fridge_names > 0 then
            for _, fridge in pairs(surface.find_entities_filtered{ name = fridge_names }) do
                register_container(fridge, "container", defines.inventory.chest, false)
            end
        end

        if #inserter_names > 0 then
            for _, inserter in pairs(surface.find_entities_filtered{ name = inserter_names }) do
                queue_add{
                    key = inserter.unit_number,
                    kind = "inserter",
                    entity = inserter,
                    full_freeze = false,
                    work = 1
                }
            end
        end

        for _, warehouse in pairs(surface.find_entities_filtered{ name = WAREHOUSE_NAME }) do
            local proxy = surface.create_entity{
                name = "warehouse-power-proxy",
                position = warehouse.position,
                force = warehouse.force
            }
            if proxy then
                register_container(warehouse, "warehouse", defines.inventory.chest, true, proxy)
            end
        end

        for _, wagon in pairs(surface.find_entities_filtered{ name = WAGON_NAME }) do
            register_container(wagon, "container", defines.inventory.cargo_wagon, false)
        end

        -- Freezing cargo bays and unloading bays share one budget per platform.
        if #platform_names > 0 then
            local bays = surface.find_entities_filtered{ name = platform_names }
            if #bays > 0 then
                storage.PlatformWarehouses[surface.name] = bays
                register_platform(surface.name)
            end
        end
    end

    storage.warmup_cursor = 1
    prime_entries()
    storage.warmup = game.tick + WARMUP_TICKS
end

---- Event Registration ----

--- Register all event handlers for preservation entities
-- @function init_events
local function init_events()
    init_caches()

    -- Only filter on prototypes that exist, so the same registration works with
    -- and without Space Age and on both 2.0 and 2.1.
    local tracked = { WAREHOUSE_NAME, WAGON_NAME }
    for _, names in pairs({ FRIDGE_NAMES, INSERTER_NAMES, PLATFORM_NAMES }) do
        for _, name in pairs(names) do
            tracked[#tracked + 1] = name
        end
    end

    local entity_filter = {}
    for _, name in pairs(existing_names(tracked)) do
        entity_filter[#entity_filter + 1] = { filter = "name", name = name }
    end

    -- Register entity creation events
    local creation_events = {
        defines.events.on_built_entity,               -- Player built
        defines.events.on_entity_cloned,              -- Entity copied
        defines.events.on_robot_built_entity,         -- Robot built
        defines.events.on_space_platform_built_entity,-- Space platform
        defines.events.script_raised_built,           -- Script created
        defines.events.script_raised_revive           -- Entity revived
    }
    for _, event in pairs(creation_events) do
        script.on_event(event, OnEntityCreated, entity_filter)
    end

    -- Register entity removal events
    local removal_events = {
        defines.events.on_player_mined_entity,         -- Player removed
        defines.events.on_robot_mined_entity,          -- Robot removed
        defines.events.on_space_platform_mined_entity, -- Space platform
        defines.events.on_entity_died,                 -- Entity destroyed
        defines.events.script_raised_destroy           -- Script removed
    }
    for _, event in pairs(removal_events) do
        script.on_event(event, OnEntityRemoved, entity_filter)
    end

    -- Player item movement: the only insertions into a container this mod can
    -- observe at all. Unfiltered because both events carry an arbitrary entity;
    -- the handler drops anything it is not already tracking in two lookups.
    script.on_event(defines.events.on_player_fast_transferred, OnPlayerMovedItems)
    script.on_event(defines.events.on_gui_closed, OnPlayerMovedItems)

    -- Register update events
    script.on_event(defines.events.on_tick, on_tick)
    script.on_event(defines.events.on_runtime_mod_setting_changed, init_settings)
end

---- Script Lifecycle Handlers ----

-- Handle mod loading (called when save is loaded)
script.on_load(function()
    init_events()
end)

-- Handle initial mod setup (called when mod is first added to save)
script.on_init(function()
    init_storages()
    init_events()
    init_entities()
end)

-- Handle mod configuration changes
script.on_configuration_changed(function(data)
    init_settings()
    init_storages()
    init_events()
    init_entities()
end)
