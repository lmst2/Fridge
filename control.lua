--- Fridge Mod Control Script
-- Implements preservation mechanics for refrigerators, warehouses, and related entities
-- that extend item spoilage time through various cooling mechanisms.
--
-- @module control
-- @author LightningMaster
-- @license MIT
-- @copyright 2025

---- Configuration ----

-- Load mod settings
local freeze_rates = settings.global["fridge-freeze-rate"].value

---- Helper Functions ----

--- Removes an item from a table or dictionary while preserving structure
-- @function remove_item
-- @param tbl The input table or dictionary to modify
-- @param item The key or value to remove
-- @return table A new table with the specified item removed
local function remove_item(tbl, item)
    local new_tbl = {}
    if type(tbl) == "table" then
        -- If input is array-like table
        if #tbl > 0 then
            for _, v in ipairs(tbl) do
                if v ~= item then
                    table.insert(new_tbl, v)
                end
            end
        -- If input is dictionary-like table
        else
            for k, v in pairs(tbl) do
                if k ~= item then
                    new_tbl[k] = v
                end
            end
        end
    end
    return new_tbl
end


--- Initialize or update general storages of the mod
-- @function init_storages
-- @field storage.tick Counter for timing fridge updates
-- @field storage.Fridges Table storing all fridge entities
-- @field storage.Warehouses Table storing all warehouse entities
-- @field storage.PlatformWarehouses Table storing all platform warehouse entities
local function init_storages()
  storage.Fridges = storage.Fridges or {}
  storage.Warehouses = storage.Warehouses or {}
  storage.PlatformWarehouses = storage.PlatformWarehouses or {}
  storage.Wagons = storage.Wagons or {}
  storage.PreservationInserters = storage.PreservationInserters or {}
end

--- Check warehouse power and extend spoil time if necessary
-- @function check_warehouse_power
-- @field storage.Warehouses Table storing all warehouse entities
local function check_warehouse_power()
  for unit_number,  warehouse_dict in pairs(storage.Warehouses) do
    local warehouse = warehouse_dict.warehouse
    local proxy = warehouse_dict.proxy
    if warehouse and warehouse.valid and proxy and proxy.valid then
      -- game.print("warehouse energy: " .. serpent.block(proxy.energy))
      -- game.print("warehouse electric_buffer_size: " .. serpent.block(proxy.electric_buffer_size))
      
      if proxy.energy > 1200000 then
        local inv = warehouse.get_inventory(defines.inventory.chest)
        for i=1, #inv do
          local itemStack = inv[i]
          if itemStack and itemStack.valid_for_read and itemStack.spoil_tick > 0 then
            itemStack.spoil_tick = math.min(itemStack.spoil_tick + 80, game.tick + itemStack.prototype.get_spoil_ticks(itemStack.quality) - 3)
          end
        end
      end
    else
      proxy.destroy()
      storage.Warehouses = remove_item(storage.Warehouses, unit_number)
      -- game.print("warehouse is removed unexpectedly, removing it from watch list, id: "..unit_number)
    end
  end
end

--- Process refrigerators to extend item spoilage time
-- Checks each refrigerator (both basic and logistic variants) and extends
-- the spoilage time for items inside based on the provided recovery rate.
-- Removes invalid refrigerators from storage.
--
-- @function check_fridges
-- @param recover_number Amount to extend spoilage time by
local function check_fridges(recover_number)
    -- Process each refrigerator in storage
    for unit_number, fridge in pairs(storage.Fridges) do
        -- Verify refrigerator is still valid
        if fridge and fridge.valid then
            -- Get refrigerator inventory
            local inv = fridge.get_inventory(defines.inventory.chest)
            
            -- Process each item in the inventory
            for i = 1, #inv do
                local itemStack = inv[i]
                -- Check if item exists and can spoil
                if itemStack and itemStack.valid_for_read and itemStack.spoil_tick > 0 then
                    -- Extend spoilage time while respecting maximum duration
                    local max_spoil_time = game.tick + itemStack.prototype.get_spoil_ticks(itemStack.quality) - 3
                    itemStack.spoil_tick = math.min(
                        itemStack.spoil_tick + recover_number,
                        max_spoil_time
                    )
                end
            end
        else
            -- Remove invalid refrigerator from storage
            storage.Fridges = remove_item(storage.Fridges, unit_number)
        end
    end
end



--- Process space platform warehouses to extend item spoilage time
-- Only runs if Space Age mod is active. Finds all platform hubs and extends
-- spoilage time for items up to the configured bonus slot capacity.
-- Tracks which slots are being preserved for visual feedback.
--
-- @function check_platform_warehouse
local function check_platform_warehouse()
    -- Skip if Space Age mod is not active
    if not script.active_mods["space-age"] then return end
    
    -- Process each surface with platform warehouses
    for surface_name, warehouses in pairs(storage.PlatformWarehouses) do
        local surface = game.surfaces[surface_name]
        if not surface then goto continue end
        
        -- Calculate preservation capacity for this surface
        local bonus_slots = #warehouses * settings.startup["fridge-space-plantform-capacity"].value
        
        -- Find and process all platform hubs
        local platform_hubs = surface.find_entities_filtered{
            name = "space-platform-hub"
        }
        
        -- Process each hub's inventory
        for _, hub in pairs(platform_hubs) do
            local platform_inv = hub.get_inventory(defines.inventory.hub_main)
            if not platform_inv then goto next_hub end
            
            -- Track preserved slots for this hub
            local items_frozen = 0
            
            -- Process inventory slots up to capacity
            for i = 1, #platform_inv do
                -- Stop if we've reached preservation limit
                if items_frozen >= bonus_slots then break end
                
                local itemStack = platform_inv[i]
                if itemStack and itemStack.valid_for_read and itemStack.spoil_tick > 0 then
                    local max_spoil_time = game.tick + itemStack.prototype.get_spoil_ticks(itemStack.quality) - 3
                    itemStack.spoil_tick = math.min(
                        itemStack.spoil_tick + 80,
                        max_spoil_time
                    )
                    items_frozen = items_frozen + 1
                end
            end
            
            ::next_hub::
        end
        
        ::continue::
    end
end


--- Process preservation wagons to extend item spoilage time
-- Checks each preservation wagon's cargo inventory and extends the spoilage time
-- for items inside based on the provided recovery rate. This allows items to be
-- preserved while being transported by rail.
--
-- @function check_wagons
-- @param recover_number Amount to extend spoilage time by
local function check_wagons(recover_number)
  -- Process each wagon's inventory
  for _, wagon in pairs(storage.Wagons) do
    local wagon_inv = wagon.get_inventory(defines.inventory.cargo_wagon)
    if wagon_inv then
      for i = 1, #wagon_inv do
        local itemStack = wagon_inv[i]
        if itemStack and itemStack.valid_for_read and itemStack.spoil_tick > 0 then
          -- Extend spoil time by freeze rate
          itemStack.spoil_tick = math.min(
            itemStack.spoil_tick + recover_number,
            game.tick + itemStack.prototype.get_spoil_ticks(itemStack.quality) - 3
          )
        end
      end
    end
  end
end


--- Check preservation inserters and extend spoil time for held items
-- @function check_preservation_inserters
local function check_preservation_inserters(recover_number)
  for unit_number, inserter in pairs(storage.PreservationInserters) do
    if inserter and inserter.valid then
      local held_stack = inserter.held_stack
      if held_stack and held_stack.valid_for_read and held_stack.spoil_tick > 0 then
        held_stack.spoil_tick = math.min(
          held_stack.spoil_tick + recover_number,
          game.tick + held_stack.prototype.get_spoil_ticks(held_stack.quality) - 3
        )
      end
    else
      storage.PreservationInserters = remove_item(storage.PreservationInserters, unit_number)
    end
  end
end


--- Main tick handler that extends spoil time for items in fridges
-- @function on_tick
-- @param event Event data from Factorio runtime
-- @field event.tick Current game tick
-- @field storage.tick Counter for timing fridge updates
local function on_tick(event)
  
  
  if freeze_rates == 1 then return end

  if freeze_rates < 10 then -- avoiding hurt too much of ups
    if game.tick%(10 * freeze_rates) == 0 then
      check_fridges((freeze_rates - 1) * 10)
      check_wagons((freeze_rates - 1) * 10)
      check_preservation_inserters((freeze_rates - 1) * 10)
    end
	elseif game.tick%freeze_rates == 0 then
    check_fridges(freeze_rates - 1)
    check_wagons(freeze_rates - 1)
    check_preservation_inserters(freeze_rates - 1)
  end

  if game.tick%80 == 0 then
    check_warehouse_power()
    check_platform_warehouse()
  end
end

---- Runtime Events ----

--- Handle creation of preservation entities
-- Registers newly created entities in the appropriate storage tables
-- and performs any necessary setup (like creating power proxies for warehouses).
--
-- @function OnEntityCreated
-- @param event Event data containing the created entity
-- @field event.created_entity Entity created by player
-- @field event.entity Entity created by script
local function OnEntityCreated(event)
    -- Get entity from either player or script creation
    local entity = event.created_entity or event.entity
    if not (entity and entity.valid) then return end
    
    -- Handle entity based on type
    if entity.name == "preservation-warehouse" then
        -- Create power proxy for warehouse
        local proxy = entity.surface.create_entity{
            name = "warehouse-power-proxy",
            position = entity.position,
            force = entity.force
        }
        
        -- Register warehouse with its power proxy
        if proxy then
            storage.Warehouses[entity.unit_number] = {
                warehouse = entity,
                proxy = proxy
            }
        end
        
    elseif entity.name == "preservation-platform-warehouse" then
        -- Initialize surface storage if needed
        local surface_name = entity.surface.name
        storage.PlatformWarehouses[surface_name] = storage.PlatformWarehouses[surface_name] or {}
        
        -- Add warehouse to surface storage
        table.insert(storage.PlatformWarehouses[surface_name], entity)
        
    elseif entity.name:find("refrigerater") then
        -- Register basic or logistic refrigerator
        storage.Fridges[entity.unit_number] = entity
        
    elseif entity.name == "preservation-wagon" then
        -- Register preservation wagon
        storage.Wagons[entity.unit_number] = entity
        
    elseif entity.name:find("preservation%-inserter") then
        -- Register preservation inserter
        storage.PreservationInserters[entity.unit_number] = entity
    end
end

--- Handle removal of preservation entities
-- Cleans up entity references from storage tables and performs any necessary
-- cleanup operations (like destroying power proxies for warehouses).
--
-- @function OnEntityRemoved
-- @param event Event data containing the removed entity
-- @field event.entity Entity being removed
local function OnEntityRemoved(event)
    -- Verify entity is valid
    local entity = event.entity
    if not (entity and entity.valid) then return end
    
    -- Handle entity based on type
    if entity.name == "preservation-warehouse" then
        -- Clean up warehouse and its power proxy
        local filtered_warehouses = {}
        for unit_number, warehouse_dict in pairs(storage.Warehouses) do
            local warehouse = warehouse_dict.warehouse
            local proxy = warehouse_dict.proxy
            
            if warehouse == entity then
                -- Destroy associated power proxy
                if proxy and proxy.valid then
                    proxy.destroy()
                end
            else
                -- Keep other warehouses
                filtered_warehouses[unit_number] = warehouse_dict
            end
        end
        storage.Warehouses = filtered_warehouses
        
    elseif entity.name == "preservation-platform-warehouse" then
        -- Remove from surface-specific storage
        local surface_name = entity.surface.name
        if storage.PlatformWarehouses[surface_name] then
            for i, warehouse in ipairs(storage.PlatformWarehouses[surface_name]) do
                if warehouse == entity then
                    table.remove(storage.PlatformWarehouses[surface_name], i)
                    break
                end
            end
        end
        
    elseif entity.name:find("refrigerater") then
        -- Remove refrigerator from storage
        storage.Fridges = remove_item(storage.Fridges, entity.unit_number)
        
    elseif entity.name == "preservation-wagon" then
        -- Remove wagon from storage
        storage.Wagons = remove_item(storage.Wagons, entity.unit_number)
        
    elseif entity.name:find("inserter") then
        -- Remove inserter from storage
        storage.PreservationInserters = remove_item(storage.PreservationInserters, entity.unit_number)
    end
end

---- Initialization Functions ----

--- Initialize or update mod settings
-- Updates global variables with current mod settings
--
-- @function init_settings
local function init_settings()
    freeze_rates = settings.global["fridge-freeze-rate"].value
end

--- Find and register all preservation entities across all surfaces
-- Scans all game surfaces for preservation entities (refrigerators, warehouses,
-- wagons, etc.) and registers them in the appropriate storage tables. Also
-- handles cleanup of old power proxies and initialization of new ones.
--
-- @function init_entities
local function init_entities()
    -- Reset all storage tables
    storage.Fridges = {}
    storage.Warehouses = {}
    storage.PlatformWarehouses = {}
    storage.Wagons = {}
    storage.PreservationInserters = {}

    -- Process each game surface
    for _, surface in pairs(game.surfaces) do
        -- Clean up old power proxies first
        local old_proxies = surface.find_entities_filtered{
            name = "warehouse-power-proxy"
        }
        for _, proxy in pairs(old_proxies) do
            proxy.destroy()
        end
        
        -- Find and register basic and logistic refrigerators
        local refrigerators = surface.find_entities_filtered{
            name = {
                "refrigerater",
                "logistic-refrigerater-passive-provider",
                "logistic-refrigerater-requester",
                "logistic-refrigerater-buffer"
            }
        }
        for _, fridge in pairs(refrigerators) do
            storage.Fridges[fridge.unit_number] = fridge
        end
        
        -- Find and register preservation inserters
        local inserters = script.active_mods["space-age"] and {
          "preservation-inserter",
          "preservation-long-inserter",
          "preservation-stack-inserter",
          "preservation-bulk-inserter"
        } or {
          "preservation-inserter",
          "preservation-long-inserter",
          "preservation-stack-inserter"
        }
        local inserters = surface.find_entities_filtered{ name = inserters }
        for _, inserter in pairs(inserters) do
            storage.PreservationInserters[inserter.unit_number] = inserter
        end
        
        -- Find and register warehouses with power proxies
        local warehouses = surface.find_entities_filtered{
            name = "preservation-warehouse"
        }
        for _, warehouse in pairs(warehouses) do
            -- Create new power proxy for warehouse
            local proxy = surface.create_entity{
                name = "warehouse-power-proxy",
                position = warehouse.position,
                force = warehouse.force
            }
            
            -- Register warehouse with its proxy
            if proxy then
                storage.Warehouses[warehouse.unit_number] = {
                    warehouse = warehouse,
                    proxy = proxy
                }
            end
        end
        
        if script.active_mods["space-age"] then
          -- Find and register platform warehouses
          local platform_warehouses = surface.find_entities_filtered{
              name = "preservation-platform-warehouse"
          }
          if #platform_warehouses > 0 then
              storage.PlatformWarehouses[surface.name] = platform_warehouses
          end
        end
        
        -- Find and register preservation wagons
        local wagons = surface.find_entities_filtered{
            name = "preservation-wagon"
        }
        for _, wagon in pairs(wagons) do
            storage.Wagons[wagon.unit_number] = wagon
        end
    end
end


---- Event Registration ----

--- Register all event handlers for preservation entities
-- Sets up event handlers for entity creation, removal, and periodic updates.
-- Also handles mod settings changes.
--
-- @function init_events
local function init_events()
    -- Define entity filter for all preservation-related entities
    local entity_filter = {
        { filter = "name", name = "refrigerater" },
        { filter = "name", name = "logistic-refrigerater-passive-provider" },
        { filter = "name", name = "logistic-refrigerater-requester" },
        { filter = "name", name = "logistic-refrigerater-buffer" },
        { filter = "name", name = "preservation-warehouse" },
        { filter = "name", name = "preservation-wagon" },
        { filter = "name", name = "preservation-inserter" },
        { filter = "name", name = "preservation-long-inserter" },
        { filter = "name", name = "preservation-stack-inserter" }
    }

    if script.active_mods["space-age"] then
      table.insert(entity_filter, { filter = "name", name = "preservation-platform-warehouse" })
      table.insert(entity_filter, { filter = "name", name = "preservation-bulk-inserter" })
    end
    
    -- Register entity creation events
    local creation_events = {
        defines.events.on_built_entity,              -- Player built
        defines.events.on_entity_cloned,             -- Entity copied
        defines.events.on_robot_built_entity,        -- Robot built
        defines.events.on_space_platform_built_entity, -- Space platform
        defines.events.script_raised_built,          -- Script created
        defines.events.script_raised_revive          -- Entity revived
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
    init_entities()
    init_events()
end)

-- Handle mod configuration changes
script.on_configuration_changed(function(data)
    init_settings()
    init_entities()
    init_events()
end)
