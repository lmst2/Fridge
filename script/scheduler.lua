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
--   deadline     earliest tick anything it holds spoils
--   primed       has completed a real read since it was (re)created
--   count        item total at the last walk, for the large-factory skip
-- }
--
-- @module script.scheduler

local config = require("script.config")

local floor = math.floor

local scheduler = {}

---- Keys ----
--
-- Four key namespaces, disjoint by construction: container chunks are the
-- bare unit_number (chunk 0) or "N#k"; platform entries are "surface:<name>";
-- probes are "probe:" followed by one of the former. Surface names are user
-- input, so nothing may be appended AFTER them - a suffix scheme would let a
-- surface literally named "X!p" forge another surface's probe key.

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
        probe_count = 0,  -- entries of kind "probe", for their budget share
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

    -- Probes spend a fixed share of the budget (capped at a quarter by
    -- probe_window); the walks adapt their period to what remains, so adding
    -- watchers genuinely widens the rhythm instead of silently overspending.
    local probes = storage.probe_count or 0
    if probes > 0 then
        budget = budget - probes / scheduler.probe_window()
    end

    local period_min, period_max = config.PERIOD_MIN, config.PERIOD_MAX

    if work <= budget * period_min then return period_min end

    local knee = budget * period_max
    local bend = config.BEND * knee
    if work <= knee - bend then return work / budget end
    if work >= knee + bend then return period_max end

    local remaining = 1 - (work - knee + bend) / (2 * bend)
    return period_max * (1 - config.BEND * remaining * remaining)
end

--- Set an entry's next due tick from an explicit period, keeping the
-- demand invariant: `demand` is always the sum of every entry's rate. Every
-- path that assigns a due goes through here, so no path can corrupt the grant.
local function schedule_at(entry, tick, period)
    entry.due = tick + period
    storage.demand = storage.demand - (entry.rate or 0) + entry.work / period
    entry.rate = entry.work / period
    heap_push(entry.due, entry.key)
end
scheduler.schedule_at = schedule_at

--- Give an entry its next due tick, and its share of the per-tick budget.
--
-- Normally the global period. As an entry's earliest deadline approaches, its
-- period shortens to come back SAFETY ticks ahead of it - continuously, not as
-- a change of category, and for every kind alike. A freezer is revisited in
-- time to keep its no-spoil promise; a refrigerator or wagon in time to apply
-- the slowdown a dying item is owed, so it dies on the slowed schedule instead
-- of the raw one; an inserter in time to preserve a blocked hand.
function scheduler.schedule(entry, tick)
    local period_min = config.PERIOD_MIN
    local period = scheduler.global_period()
    local deadline = entry.deadline
    if deadline then
        local slack = deadline - tick - config.SAFETY
        if slack < period then period = slack end
    end
    if period < period_min then period = period_min end

    schedule_at(entry, tick, period)
end

--- Bring an entry forward, to `when`, if it is not already due sooner.
-- The guard means storms of expedites - GUI open/close spam, a row of bays
-- built in one paste, a probe firing on chunks about to be visited anyway -
-- cannot flood the heap with duplicate pairs or steal work that is already
-- scheduled. `last` is never touched: recovery derives from it.
function scheduler.expedite(entry, when)
    if entry.due <= when then return end
    entry.due = when
    heap_push(when, entry.key)
end

---- Probes ----

--- How often each probe asks its one cheap question. The user's reaction
-- window, widened so that all probes together never spend more than a quarter
-- of the slot budget - the closed loop that keeps ten thousand containers
-- from starving the walks that do the real preserving.
function scheduler.probe_window()
    local window = config.reaction_window
    local by_budget = (storage.probe_count or 0) / (0.25 * config.SLOT_BUDGET)
    if by_budget > window then window = by_budget end
    return math.ceil(window)
end

--- Reschedule a probe on the current probe window.
function scheduler.schedule_probe(entry, tick)
    schedule_at(entry, tick, scheduler.probe_window())
end

---- Queue membership ----

function scheduler.set_work(entry, work)
    if work < 1 then work = 1 end
    storage.total_work = storage.total_work + work - entry.work
    entry.work = work
end

-- Work that arrived on the current tick, for spreading bulk arrivals. Module
-- state, not storage: it is rebuilt identically on every client from the same
-- deterministic event stream, and never needs to survive a tick boundary.
local arrivals_tick, arrivals_work = -1, 0

function scheduler.queue_add(entry)
    if storage.index[entry.key] then return end

    entry.work = entry.to and (entry.to - entry.from + 1) or 1
    entry.last = game.tick
    entry.rate = 0

    local queue = storage.queue
    queue[#queue + 1] = entry
    storage.index[entry.key] = #queue
    storage.total_work = storage.total_work + entry.work

    -- First visit within PERIOD_MIN, so a freshly stocked container's real
    -- deadline is learned before anything short-lived inside it can spoil -
    -- inheriting a large factory's long global period here could let a
    -- freezer-load of nearly-spoiled goods rot before it was ever examined.
    --
    -- Everything that arrives on one tick shares a cursor and each entry is
    -- pushed back by the work queued before it, so any bulk arrival - a
    -- blueprint paste, a script spawning a base, the rebuild after a mod
    -- update - drains at about twice SLOT_BUDGET per tick instead of herding
    -- onto one due tick. A single build adds nearly nothing to the cursor and
    -- keeps the prompt first look.
    local now = game.tick
    if arrivals_tick ~= now then
        arrivals_tick, arrivals_work = now, 0
    end
    arrivals_work = arrivals_work + entry.work
    local stagger = floor(arrivals_work / (2 * config.SLOT_BUDGET))
    -- With very short-lived modded items even a drain queue can be too slow;
    -- past this point arrivals herd onto one due tick and the credit loop
    -- degrades to as-fast-as-budget-allows, trading smoothness for the
    -- guarantee, which is the right way round.
    if stagger > config.STAGGER_MAX then stagger = config.STAGGER_MAX end
    schedule_at(entry, now, config.PERIOD_MIN + stagger)

    if entry.kind == "probe" then
        storage.probe_count = (storage.probe_count or 0) + 1
    end
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
    if entry.kind == "probe" then
        storage.probe_count = (storage.probe_count or 1) - 1
    end

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
