--- Fridge Mod Control Script
-- Preservation mechanics for refrigerators, warehouses and related entities:
-- everything this mod tracks slows or stops the spoilage of what it holds.
--
-- Three files share the work. `script/scheduler.lua` owns *when*: the entry
-- queue, the due-order heap, adaptive periods and the per-tick slot budget.
-- `script/executor.lua` owns *what*: every inventory read and write, one fused
-- pass per visit. `script/config.lua` owns every constant and setting. This
-- file only wires them to the game: which prototypes are tracked, and what
-- each event does to the queue.
--
-- @module control
-- @author LightningMaster
-- @license MIT
-- @copyright 2025

local config = require("script.config")
local scheduler = require("script.scheduler")
local executor = require("script.executor")

local floor = math.floor

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

---- Runtime events ----

--- Start tracking an entity, creating whatever it needs to work.
local function track(entity)
    local spec = TRACKED[entity.name]
    if not spec then return end

    if spec.kind == "bay" then
        -- Bays feed the platform hub entry for their surface.
        local surface_name = entity.surface.name
        local key = scheduler.platform_key(surface_name)
        local entry = scheduler.entry_for(key)
        if entry then
            entry.bays[#entry.bays + 1] = entity
            -- A new bay raises the hub's capacity and adds slots holding items
            -- that may be near expiry. Bring the entry forward so its next walk
            -- reads them, and its work (hence the scheduler's total) tracks the
            -- new bay at once instead of lagging until the entry's next due tick.
            -- expedite() leaves `last` alone, so recovery stays elapsed-correct.
            scheduler.expedite(entry, game.tick)
        else
            scheduler.queue_add {
                key = key,
                kind = "platform",
                surface = surface_name,
                bays = { entity },
                full_freeze = true,
            }
        end
        if config.probes_on then
            executor.probe_add { surface = surface_name }
        end
        return
    end

    if not spec.inventory then
        scheduler.queue_add {
            key = entity.unit_number,
            kind = spec.kind,
            entity = entity,
            full_freeze = spec.full_freeze or false,
        }
        return
    end

    local proxy
    if spec.kind == "warehouse" then
        proxy = entity.surface.create_entity {
            name = config.PROXY_NAME,
            position = entity.position,
            force = entity.force,
        }
        if not proxy then return end
    end

    -- Split a large inventory into one entry per slot range, so no single visit
    -- can cost more than MAX_ENTRY_SLOTS however big the container is.
    local inv = entity.get_inventory(spec.inventory)
    local slots = inv and #inv or 1
    local max_slots = config.MAX_ENTRY_SLOTS
    for chunk = 0, floor((slots - 1) / max_slots) do
        local from = chunk * max_slots + 1
        local to = from + max_slots - 1
        scheduler.queue_add {
            key = scheduler.chunk_key(entity.unit_number, chunk),
            kind = spec.kind,
            entity = entity,
            uid = entity.unit_number,
            proxy = proxy,
            inventory = spec.inventory,
            full_freeze = spec.full_freeze or false,
            from = from,
            to = to < slots and to or slots,
        }
    end

    if config.probes_on then
        executor.probe_add {
            entity = entity,
            inventory = spec.inventory,
            uid = entity.unit_number,
        }
    end
end

--- @function OnEntityCreated
-- on_entity_cloned reports the new entity as `destination`; without it a
-- cloned freezer was never tracked.
local function OnEntityCreated(event)
    local entity = event.created_entity or event.entity or event.destination
    if entity and entity.valid then track(entity) end
end

--- @function OnTrainCreated
-- Rolling stock can appear without any build event. Subsurface carries a train
-- through a tunnel by create_entity-ing a copy of each carriage on the far
-- surface and destroy()-ing the original, and neither half raises one, so a
-- preservation wagon came out the other end untracked and silently stopped
-- preserving its cargo from its first transit onwards.
local function OnTrainCreated(event)
    local train = event.train
    if not (train and train.valid) then return end
    for _, carriage in pairs(train.carriages) do
        -- Chunk 0 keeps the bare unit_number, so that is what to test for.
        if carriage.valid and TRACKED[carriage.name]
            and not scheduler.entry_for(carriage.unit_number) then
            track(carriage)
        end
    end
end

--- @function OnEntityRemoved
local function OnEntityRemoved(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end

    local spec = TRACKED[entity.name]
    if not spec then return end

    if spec.kind == "bay" then
        local entry = scheduler.entry_for(scheduler.platform_key(entity.surface.name))
        if not entry then return end
        local bays = entry.bays
        for i = 1, #bays do
            if bays[i] == entity then
                bays[i] = bays[#bays]
                bays[#bays] = nil
                break
            end
        end
        if #bays == 0 then
            executor.probe_remove(entity.surface.name)
            executor.forget(entry.key)
            scheduler.queue_remove(entry.key)
        else
            -- One fewer bay: re-walk so the entry's work drops to the smaller
            -- capacity now rather than staying inflated until its next due tick.
            scheduler.expedite(entry, event.tick)
        end
        return
    end

    local entry = scheduler.entry_for(entity.unit_number)
    if entry and entry.proxy and entry.proxy.valid then entry.proxy.destroy() end
    executor.probe_remove(entity.unit_number)
    for _, key in pairs(scheduler.chunk_keys(entity.unit_number)) do
        executor.forget(key)
        scheduler.queue_remove(key)
    end
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

    -- Every chunk, since the stack could have landed in any slot, and every
    -- kind - a nearly-spoiled stack dropped into a refrigerator needs its
    -- deadline learned just as urgently as one dropped into a freezer.
    -- Dropping the item count also stops the large-factory skip
    -- short-circuiting the very visit that was asked for.
    for _, key in pairs(scheduler.chunk_keys(entity.unit_number)) do
        local entry = scheduler.entry_for(key)
        if entry then
            entry.count = nil
            scheduler.expedite(entry, event.tick)
        end
    end
end

--- @function OnTick
local function OnTick(event)
    if config.freeze_rates == 1 then return end
    scheduler.tick(event.tick, executor.process_entry)
    if config.probes_on then executor.run_probes(event.tick) end
end

--- @function OnSurfaceRenamed
-- Platform entries and their probes are keyed by surface name; follow it.
local function OnSurfaceRenamed(event)
    scheduler.rename_surface(event.old_name, event.new_name)
    executor.probe_rename_surface(event.old_name, event.new_name)
    -- The hub's handles were cached under the old entry key - still valid but
    -- unreachable there - and whatever DIED holding the new name may have
    -- left its handles under the key we are about to occupy: stale handles
    -- read valid_for_read=false and silently skip every slot. Drop both
    -- sides; the next walk rebuilds the small array.
    executor.forget(scheduler.platform_key(event.old_name))
    executor.forget(scheduler.platform_key(event.new_name))
end

--- Match the probe ring to config.probes_on.
--
-- probes_on only changes at load boundaries in practice (it depends on which
-- prototypes can spoil), but a save from before the ring existed needs its
-- tables created, and probe_add is idempotent, so re-syncing is always safe.
local function sync_probes()
    storage.probes = storage.probes or {}
    storage.probe_index = storage.probe_index or {}
    if not config.probes_on then
        storage.probes, storage.probe_index = {}, {}
        storage.probe_acc, storage.probe_cursor = 0, 1
        return
    end

    for _, entry in pairs(storage.queue) do
        if entry.kind == "platform" then
            executor.probe_add { surface = entry.surface }
        elseif entry.inventory and entry.entity and entry.entity.valid then
            executor.probe_add {
                entity = entry.entity,
                inventory = entry.inventory,
                uid = entry.uid or entry.entity.unit_number,
            }
        end
    end
end

--- @function OnSettingsChanged
local function OnSettingsChanged()
    config.refresh()
    sync_probes()
end

---- Initialisation ----

--- Rebuild the queue from scratch by scanning every surface.
--
-- Knowledge already paid for is not destroyed with the queue. Deadlines and
-- last-visit ticks are harvested by key before the reset and seeded back
-- afterwards: an item that survived an old power outage may sit at a few
-- dozen ticks of remaining life, held there by deadline scheduling, forever -
-- rebuild amnesia plus the bulk-arrival stagger would let exactly that item
-- rot before its first staggered look. Seeded entries whose deadline is near
-- are expedited ahead of the stagger (expedite's guard skips the rest), and
-- seeding `last` keeps recovery continuous across the update instead of
-- silently dropping up to one period of it.
local function init_entities()
    local memory = {}
    if storage.queue then
        for _, entry in pairs(storage.queue) do
            if entry.kind ~= "probe" then
                memory[entry.key] = { deadline = entry.deadline, last = entry.last }
            end
        end
    end

    scheduler.reset_state()

    local names = tracked_names()
    if #names == 0 then return end

    for _, surface in pairs(game.surfaces) do
        -- Proxies are recreated with their warehouses, so clear the old ones.
        for _, proxy in pairs(surface.find_entities_filtered { name = config.PROXY_NAME }) do
            proxy.destroy()
        end
        for _, entity in pairs(surface.find_entities_filtered { name = names }) do
            track(entity)
        end
    end

    local now = game.tick
    for _, entry in pairs(storage.queue) do
        local known = memory[entry.key]
        if known then
            entry.deadline = known.deadline
            if known.last and known.last < entry.last then
                entry.last = known.last
            end
            if known.deadline then
                local when = known.deadline - config.SAFETY
                if when < now then when = now end
                scheduler.expedite(entry, when)
            end
        end
    end
end

local function init_events()
    config.refresh()
    executor.init_cache()

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

    script.on_event(defines.events.on_tick, OnTick)
    -- The only notice a mod gets that rolling stock exists when whatever built
    -- it raised no build event. Unfiltered: the event carries no entity to
    -- filter on, and the handler drops a train of untracked carriages in one
    -- lookup each.
    script.on_event(defines.events.on_train_created, OnTrainCreated)
    script.on_event(defines.events.on_surface_renamed, OnSurfaceRenamed)
    script.on_event(defines.events.on_runtime_mod_setting_changed, OnSettingsChanged)
end

---- Lifecycle ----

script.on_load(init_events)

script.on_init(function()
    scheduler.init_state()
    init_events()
    init_entities()
end)

script.on_configuration_changed(function()
    config.refresh()
    scheduler.init_state()
    init_events()
    init_entities()
end)
