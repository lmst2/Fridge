--- The scheduler: entries, the due-order heap, periods and the tick budget.
--
-- Every tracked object is an *entry* with a *due tick*; a min-heap keeps them
-- in due order; each tick spends a slot budget on whatever has come due. An
-- entry's period is normally the global one, which widens as the factory grows
-- so the per-tick cost stays flat, but shortens towards PERIOD_MIN as its
-- contents approach spoiling. Urgency is a rate, not a category, so there is
-- no second queue and nothing to be in or out of.
--
-- This file is pure bookkeeping: it never touches an inventory, an item stack
-- or an entity. It reads only game.tick and game.speed. What a visit *does*
-- is the executor's business, handed in as a callback to `tick`.
--
-- entry = {
--   key          unit_number, or "surface:<name>" for a platform hub
--   kind         "container" | "warehouse" | "inserter" | "platform"
--   entity       the container, inserter or hub
--   uid          the walked entity's unit_number, keys the handle cache
--   proxy        power proxy (warehouse only)
--   bays         freezing cargo bays granting capacity (platform only)
--   surface      surface name (platform only)
--   inventory    defines.inventory.* to walk
--   from,to      slot range this entry owns (a large inventory is split)
--   full_freeze  stop spoilage rather than slow it
--   work         slots this range examines
--   last         tick this entry was last processed
--   due          tick it should next be processed
--   rate         its share of the per-tick slot budget, work/period
--   deadline     earliest tick its contents spoil (full-freeze entries only)
--   seen         its contents have been read at least once (deadline is real)
--   count        item total at the last walk, for the large-factory skip
-- }
--
-- @module script.scheduler

local config = require("script.config")

local floor = math.floor

local scheduler = {}

---- Keys ----

function scheduler.platform_key(surface_name)
    return "surface:" .. surface_name
end

--- Key for one slot range of an entity. Chunk 0 keeps the bare unit_number, so
-- an entity small enough not to split looks exactly as it did before.
function scheduler.chunk_key(unit_number, chunk)
    return chunk == 0 and unit_number or (unit_number .. "#" .. chunk)
end

function scheduler.entry_for(key)
    local position = storage.index[key]
    return position and storage.queue[position]
end

--- Every key covering this entity. Chunks are contiguous from zero, so walking
-- until one is missing finds them all with no stored list. Collected up front
-- because removing an entry swaps another into its slot.
function scheduler.chunk_keys(unit_number)
    local keys = {}
    while storage.index[scheduler.chunk_key(unit_number, #keys)] do
        keys[#keys + 1] = scheduler.chunk_key(unit_number, #keys)
    end
    return keys
end

---- State ----

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

function scheduler.reset_state()
    for field, value in pairs(default_state()) do storage[field] = value end
end

function scheduler.init_state()
    if not storage.queue then scheduler.reset_state() end
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
function scheduler.global_period()
    local work = storage.total_work
    local speed = game.speed
    local slot_budget = config.SLOT_BUDGET
    local budget = speed > 1 and slot_budget / speed or slot_budget
    local period_min, period_max = config.PERIOD_MIN, config.PERIOD_MAX

    if work <= budget * period_min then return period_min end

    local knee = budget * period_max
    local bend = config.BEND * knee
    if work <= knee - bend then return work / budget end
    if work >= knee + bend then return period_max end

    local remaining = 1 - (work - knee + bend) / (2 * bend)
    return period_max * (1 - config.BEND * remaining * remaining)
end

--- Give an entry its next due tick, and its share of the per-tick budget.
--
-- Normally the global period. A full-freeze entry promises its contents do not
-- spoil, so as its earliest deadline approaches, its period shortens to come
-- back SAFETY ticks ahead of it - continuously, not as a change of category.
--
-- A full-freeze entry that has never been read is treated as if it might be
-- urgent: it is checked within PERIOD_MIN so its real deadline is learned
-- before anything short-lived inside it can spoil. Without this, an entry
-- registered into a large factory inherited that factory's long global period
-- and its first look could come hundreds of ticks late - long enough for a
-- freshly stocked freezer of nearly-spoiled goods to rot before it was ever
-- examined. Because such entries take a short period, the herd from a rebuild
-- raises `demand` and is cleared in a handful of ticks, then settles.
function scheduler.schedule(entry, tick)
    local period_min = config.PERIOD_MIN
    local period
    if entry.full_freeze and not entry.seen then
        period = period_min
    else
        period = scheduler.global_period()
        local deadline = entry.deadline
        if deadline and entry.full_freeze then
            local slack = deadline - tick - config.SAFETY
            if slack < period then period = slack end
        end
        if period < period_min then period = period_min end
    end

    entry.due = tick + period
    storage.demand = storage.demand - (entry.rate or 0) + entry.work / period
    entry.rate = entry.work / period
    heap_push(entry.due, entry.key)
end

--- Bring an entry forward to be processed as soon as the budget allows.
function scheduler.expedite(entry, tick)
    entry.due = tick
    heap_push(tick, entry.key)
end

---- Queue membership ----

function scheduler.set_work(entry, work)
    if work < 1 then work = 1 end
    storage.total_work = storage.total_work + work - entry.work
    entry.work = work
end

function scheduler.queue_add(entry)
    if storage.index[entry.key] then return end

    entry.work = entry.to and (entry.to - entry.from + 1) or 1
    entry.last = game.tick
    entry.rate = 0

    local queue = storage.queue
    queue[#queue + 1] = entry
    storage.index[entry.key] = #queue
    storage.total_work = storage.total_work + entry.work
    scheduler.schedule(entry, game.tick)
end

--- Remove an entry in constant time by swapping the last one into its place.
-- Anything left for it in the heap is discarded when it surfaces.
function scheduler.queue_remove(key)
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

---- Tick ----

--- Spend this tick's slot budget on whatever has come due.
--
-- The grant is `demand`, the sum of every entry's work divided by its own
-- period - exactly the rate needed to keep all of them on schedule. Credit is
-- capped at one grant so an idle stretch cannot buy a burst, and a visit is
-- billed what it really cost, so an entry that turns out expensive drives the
-- credit negative and ends the tick rather than overrunning it.
--
-- @param process function(entry, tick) -> cost, the executor's visit
function scheduler.tick(tick, process)
    local credit = storage.credit + storage.demand
    if credit > storage.demand then credit = storage.demand end

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

        local entry = scheduler.entry_for(heap_pop())
        -- Anything rescheduled since it was pushed left a stale pair behind.
        if entry and entry.due <= tick then
            credit = credit - process(entry, tick)
        end
    end

    storage.credit = credit
end

return scheduler
