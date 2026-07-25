--- The executor: every Lua<->C++ inventory crossing the mod makes.
--
-- A visit is one fused pass: it reads each stack once and, in that same pass,
-- rewrites its spoil tick, learns the range's earliest deadline and counts the
-- real cost to bill the scheduler. Reading and writing are not split into
-- separate passes - measured, a second pass re-pays the LuaItemStack creation
-- per slot and costs ~60% more than doing both at once.
--
-- Two properties make visiting safe at any time. Recovery is derived from the
-- time actually elapsed since an entry was last visited, so the scheduler may
-- visit whenever it likes without changing how fast anything spoils. And a
-- visit is charged what it really cost rather than a prediction, so an entry
-- that turns out expensive ends the tick instead of overrunning it.
--
-- @module script.executor

local config = require("script.config")
local scheduler = require("script.scheduler")

local floor = math.floor

local FRESHNESS_MARGIN = config.FRESHNESS_MARGIN
local SKIP_DRIFT = config.SKIP_DRIFT

local executor = {}

---- Stack handle cache ----

-- Indexing an inventory (`inv[i]`) creates a fresh LuaItemStack userdata each
-- time; measured, that creation is ~40% of a fused walk and all of its GC
-- churn. A slot handle stays valid as long as its inventory does, so they are
-- built once per entity and reused across walks: 2.10 -> 1.04 us per slot.
--
-- Keyed by unit_number, which the engine never reuses, so a replaced platform
-- hub (new unit number) can never collide with its predecessor's handles.
-- alive() drops dead entities before any walk, and a valid entity implies
-- valid handles. Module-local and rebuilt lazily after every load - handles
-- must never reach `storage`.
local stack_handles = {}

--- The per-slot handles for this inventory, grown to cover slot `hi`.
local function stacks_for(uid, inv, hi)
    local stacks = stack_handles[uid]
    if not stacks then
        stacks = {}
        stack_handles[uid] = stacks
    end
    for i = #stacks + 1, hi do stacks[i] = inv[i] end
    return stacks
end

--- Drop an entity's cached handles (it was removed, or a hub was replaced).
function executor.forget(uid)
    if uid then stack_handles[uid] = nil end
end

---- Prototype cache ----

-- Rebuilt on every load and deliberately outside `storage`: prototype data
-- cannot change without one. Re-reading `stack.prototype` and calling
-- get_spoil_ticks() per stack was the largest cost in the original sweep.
local spoil_ticks = {}
local quality_changes_spoil = false
local spoilable = {}   -- name -> boolean, for the probes' contents filter

function executor.init_cache()
    spoil_ticks = {}
    stack_handles = {}
    spoilable = {}
    -- Vanilla qualities leave spoil time alone, so the cache can be keyed by
    -- item name and the stack's quality never read. A mod that does change it
    -- forces the slower, fully correct path.
    local worst_quality = 1
    local quality_varies = false
    local ok = pcall(function()
        for _, quality in pairs(prototypes.quality) do
            local multiplier = quality.spoil_ticks_multiplier
            if multiplier < worst_quality then worst_quality = multiplier end
            if multiplier ~= 1 then quality_varies = true end
        end
    end)
    quality_changes_spoil = (not ok) or quality_varies

    -- The shortest spoil life in this game, quality-adjusted: the number the
    -- config derives the discovery guarantee from. nil when nothing spoils.
    local min_spoil
    for _, proto in pairs(prototypes.item) do
        local ticks = proto.get_spoil_ticks()
        if ticks > 0 and (not min_spoil or ticks < min_spoil) then
            min_spoil = ticks
        end
    end
    if min_spoil and worst_quality < 1 then
        min_spoil = floor(min_spoil * worst_quality)
    end
    config.set_min_spoil(min_spoil)
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

--- Walk one slot range of an inventory, preserving what can spoil.
--
-- The earliest spoil tick falls out of values the pass reads anyway, so every
-- kind reports it and the scheduler shortens the period of whatever holds
-- something close to dying. For freezers that keeps the no-spoil promise; for
-- refrigerators and wagons it makes a dying item's last stretch exact - the
-- slowdown must be applied before the raw spoil tick arrives, or the item
-- dies early inside a working fridge.
--
-- @param stacks Cached per-slot handles covering [from, to]
-- @param from,to Slot range this entry owns (a large inventory is split)
-- @param cap Optional limit on how many stacks are preserved
-- @return number Slots examined - the visit's real cost
-- @return number|nil Earliest tick anything in range spoils
local function walk(inv, stacks, from, to, recover, tick, cap)
    if inv.is_empty() then return 1 end

    local scanned, preserved = to - from + 1, 0
    local deadline

    -- The body of preserve_stack, inlined. A Lua call per slot measured at 39%
    -- of this loop's total cost - the walk is the one place in the mod where
    -- that is worth eighteen duplicated lines. The quality-aware path is rare
    -- enough to stay a call.
    local cache, by_quality = spoil_ticks, quality_changes_spoil
    local ceiling = tick - FRESHNESS_MARGIN

    for i = from, to do
        local stack = stacks[i]
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
                if not deadline or spoils_at < deadline then
                    deadline = spoils_at
                end
                preserved = preserved + 1
                if cap and preserved >= cap then
                    scanned = i - from + 1
                    break
                end
            end
        end
    end
    return scanned, deadline
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
    local rates = config.freeze_rates
    local aged = floor(tick / rates) - floor((tick - elapsed) / rates)
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
            -- A replaced hub is a new entity: its predecessor's slot handles
            -- can never be valid again, so drop them with the old unit number.
            executor.forget(entry.uid)
            entry.uid = hub and hub.unit_number or nil
        end
        if not hub then return nil end
        return hub.get_inventory(defines.inventory.hub_main),
               #bays * config.platform_capacity
    end

    if kind == "warehouse" and entry.proxy.energy <= config.WAREHOUSE_ENERGY then
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
    executor.forget(entry.uid)
    scheduler.queue_remove(entry.key)
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
        entry.deadline, entry.count = nil, nil
        scheduler.schedule(entry, tick)
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
    if config.skip_unchanged and entry.count and entry.deadline then
        local drift = tick - entry.last
        if drift * SKIP_DRIFT < entry.deadline - entry.last
            and inv.get_item_count() == entry.count then
            scheduler.schedule(entry, tick)
            return 1
        end
    end

    local elapsed = tick - entry.last
    if elapsed <= 0 then
        scheduler.schedule(entry, tick)
        return 0
    end
    entry.last = tick

    local recover = recovery_for(entry, elapsed, tick)
    if recover <= 0 then
        scheduler.schedule(entry, tick)
        return 0
    end

    -- Derived lazily so entries from older saves pick it up on first visit.
    local uid = entry.uid
    if not uid then
        uid = entry.entity.unit_number
        entry.uid = uid
    end

    local to = entry.to or #inv
    local scanned, deadline = walk(inv, stacks_for(uid, inv, to),
                                   entry.from or 1, to,
                                   recover, tick, cap)
    scheduler.set_work(entry, scanned)
    entry.deadline = deadline
    entry.seen = nil  -- retired flag; clear it out of older saves
    if config.skip_unchanged then entry.count = inv.get_item_count() end

    scheduler.schedule(entry, tick)
    return scanned
end

--- Preserve an inserter's held stack. One slot, no inventory to resolve.
-- The held stack's spoil tick doubles as the entry's deadline, so a blocked
-- hand holding something short-lived is revisited before it can die there.
local function process_inserter(entry, tick)
    if not alive(entry) then return 0 end

    local elapsed = tick - entry.last
    if elapsed > 0 then
        entry.last = tick
        local recover = recovery_for(entry, elapsed, tick)
        local held = entry.entity.held_stack
        if recover > 0 and held and held.valid_for_read then
            entry.deadline = preserve_stack(held, recover, tick)
        else
            entry.deadline = nil
        end
    end
    scheduler.schedule(entry, tick)
    return 1
end

--- One cheap question per entity: has anything new arrived since last look?
--
-- Probes exist only when a mod's items spoil too fast for the ordinary
-- refresh rhythm to promise discovery (config.probes_on). A count that went
-- UP means something was inserted by an inserter, robot or script - the paths
-- no event covers - so the entity's walk entries are pulled forward to learn
-- the newcomer's deadline. Removals cannot create spoilage risk and do not
-- fire. The probe owns its baseline and refreshes it on every look, fired or
-- not, so steady feeding cannot re-trigger it forever.
local function process_probe(entry, tick)
    local count

    if entry.surface then
        -- The platform hub: plates and ore churn through it constantly, so a
        -- raw count would fire every window. One get_contents call instead,
        -- summing only names that can spoil.
        local target = scheduler.entry_for(scheduler.platform_key(entry.surface))
        if not target then
            scheduler.queue_remove(entry.key)
            return 1
        end
        local inv = contents_of(target)
        if inv then
            count = 0
            local contents = inv.get_contents()
            for i = 1, #contents do
                local item = contents[i]
                local name = item.name
                local can_spoil = spoilable[name]
                if can_spoil == nil then
                    can_spoil = prototypes.item[name].get_spoil_ticks() > 0
                    spoilable[name] = can_spoil
                end
                if can_spoil then count = count + item.count end
            end
        end
    else
        local entity = entry.entity
        if not (entity and entity.valid) then
            scheduler.queue_remove(entry.key)
            return 1
        end
        count = entity.get_inventory(entry.inventory).get_item_count()
    end

    if count and entry.baseline and count > entry.baseline then
        if entry.surface then
            local target = scheduler.entry_for(scheduler.platform_key(entry.surface))
            if target then
                target.count = nil
                scheduler.expedite(target, tick)
            end
        else
            -- Every chunk, staggered a tick apart: the newcomer could sit in
            -- any slot, and the merge that absorbed it could have shifted any
            -- stack's spoil time. Chunks already due sooner are left alone.
            local keys = scheduler.chunk_keys(entry.uid)
            for i = 1, #keys do
                local chunk = scheduler.entry_for(keys[i])
                if chunk then
                    chunk.count = nil
                    scheduler.expedite(chunk, tick + i - 1)
                end
            end
        end
    end
    entry.baseline = count

    scheduler.schedule_probe(entry, tick)
    return 1
end

--- Visit one due entry, whatever its kind. The scheduler's tick callback.
function executor.process_entry(entry, tick)
    local kind = entry.kind
    if kind == "inserter" then
        return process_inserter(entry, tick)
    elseif kind == "probe" then
        return process_probe(entry, tick)
    end
    return process(entry, tick)
end

return executor
