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

-- Ticks for one complete pass over everything tracked. Because recovery is
-- derived from the time that actually elapsed since an entry was last visited
-- (see recovery_for), this is purely a granularity/UPS knob: changing it does
-- not change how fast items spoil, only how often their remaining time is
-- refreshed. 80 is the interval the warehouse sweep already used.
local UPDATE_PERIOD = 80

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
-- @return boolean Whether the stack was spoilable at all
local function preserve_stack(stack, recover, tick)
    local current = stack.spoil_tick
    if current <= 0 then return false end

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
        stack.spoil_tick = extended < limit and extended or limit
    end
    return true
end

--- Preserve every spoilable stack in an inventory.
-- @param inv LuaInventory
-- @param recover Ticks of spoilage to undo
-- @param tick Current tick
-- @param max_stacks Optional cap on how many stacks are preserved
-- @return number Slots examined - this entry's workload for the scheduler
local function preserve_inventory(inv, recover, tick, max_stacks)
    if inv.is_empty() then return 1 end

    local slots = #inv
    local scanned = slots
    local preserved = 0
    for i = 1, slots do
        local stack = inv[i]
        if stack.valid_for_read and preserve_stack(stack, recover, tick) then
            preserved = preserved + 1
            if max_stacks and preserved >= max_stacks then
                scanned = i
                break
            end
        end
    end
    return scanned
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
    storage.PlatformWarehouses = storage.PlatformWarehouses or {}
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
        set_work(entry, preserve_inventory(inv, recover, tick,
            #warehouses * platform_capacity))
    end
    return false
end

--- Run one entry's preservation pass.
-- @return boolean Whether the entry removed itself from the queue
local function preserve_entry(entry, tick)
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
            set_work(entry, 1)
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
            preserve_stack(held, recover, tick)
        end
        return false
    end

    local inv = entity.get_inventory(entry.inventory)
    if inv then
        set_work(entry, preserve_inventory(inv, recover, tick))
    else
        set_work(entry, 1)
    end
    return false
end

--- Main tick handler: drain a slice of the preservation queue.
-- Credit is carried in "slot-ticks": every tick adds the whole workload, and
-- visiting an entry costs its workload times UPDATE_PERIOD. Over UPDATE_PERIOD
-- ticks that is exactly enough to visit everything once, and because the cost
-- is the entry's own slot count the slice is balanced by real work rather than
-- by container count.
-- @param event Event data from Factorio runtime
local function on_tick(event)
    if freeze_rates == 1 then return end

    local queue = storage.queue
    local count = #queue
    if count == 0 then return end

    local total = storage.total_work
    if total <= 0 then return end

    local credit = storage.work_credit + total
    local ceiling = total * UPDATE_PERIOD
    if credit > ceiling then credit = ceiling end

    local tick = event.tick
    local cursor = storage.cursor
    local visited = 0

    while visited < count do
        if cursor > #queue then cursor = 1 end
        local entry = queue[cursor]
        if not entry then break end

        local cost = entry.work * UPDATE_PERIOD
        if cost > credit then break end
        credit = credit - cost

        -- A removed entry pulls the last one into this slot, so hold position.
        if not preserve_entry(entry, tick) then
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
            queue_add{
                key = entity.unit_number,
                kind = "warehouse",
                entity = entity,
                proxy = proxy,
                inventory = defines.inventory.chest,
                full_freeze = true,
                work = inventory_slots(entity, defines.inventory.chest)
            }
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
        queue_add{
            key = entity.unit_number,
            kind = "container",
            entity = entity,
            inventory = defines.inventory.chest,
            full_freeze = false,
            work = inventory_slots(entity, defines.inventory.chest)
        }

    elseif name == WAGON_NAME then
        queue_add{
            key = entity.unit_number,
            kind = "container",
            entity = entity,
            inventory = defines.inventory.cargo_wagon,
            full_freeze = false,
            work = inventory_slots(entity, defines.inventory.cargo_wagon)
        }

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
    queue_remove(entity.unit_number)
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
                queue_add{
                    key = fridge.unit_number,
                    kind = "container",
                    entity = fridge,
                    inventory = defines.inventory.chest,
                    full_freeze = false,
                    work = inventory_slots(fridge, defines.inventory.chest)
                }
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
                queue_add{
                    key = warehouse.unit_number,
                    kind = "warehouse",
                    entity = warehouse,
                    proxy = proxy,
                    inventory = defines.inventory.chest,
                    full_freeze = true,
                    work = inventory_slots(warehouse, defines.inventory.chest)
                }
            end
        end

        for _, wagon in pairs(surface.find_entities_filtered{ name = WAGON_NAME }) do
            queue_add{
                key = wagon.unit_number,
                kind = "container",
                entity = wagon,
                inventory = defines.inventory.cargo_wagon,
                full_freeze = false,
                work = inventory_slots(wagon, defines.inventory.cargo_wagon)
            }
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
