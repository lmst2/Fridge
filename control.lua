--- Fridge mod control script
-- This mod adds refrigeraters that slow down item spoilage by extending spoil time
-- @module control

--- Helper function to remove an item from a table or dictionary
-- @function remove_item
-- @param tbl The input table or dictionary
-- @param item The item to be removed
-- @return A new table or dictionary without the specified item
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
local function init_storages()
	storage.tick = storage.tick or 0
  storage.Fridges = storage.Fridges or {}
  storage.Warehouses = storage.Warehouses or {}
end

--- Check warehouse power and extend spoil time if necessary
-- @function check_warehouse_power
-- @field storage.Warehouses Table storing all warehouse entities
local function check_warehouse_power()
  for warehouse, proxy in pairs(storage.Warehouses) do
    if warehouse.valid and proxy.valid then
      -- game.print("warehouse energy: " .. serpent.block(proxy.energy))
      -- game.print("warehouse electric_buffer_size: " .. serpent.block(proxy.electric_buffer_size))
      
      if proxy.energy > 0 then
        local inv = warehouse.get_inventory(defines.inventory.chest)
        for i=1, #inv do
          local itemStack = inv[i]
          if itemStack and itemStack.valid_for_read and itemStack.spoil_tick > 0 and itemStack.spoil_percent > 0.01 then
            itemStack.spoil_tick = itemStack.spoil_tick + 80
          end
        end
      end
    else
      storage.Warehouses = remove_item(storage.Warehouses, warehouse)
    end
  end
end

--- Check fridges and extend spoil time for items inside
-- @function check_fridges
local function check_fridges()
  -- Process each fridge
  for _, chest in pairs(storage.Fridges) do
    local inv = chest.get_inventory(defines.inventory.chest)
    -- Check each slot in the fridge
    for i=1, #inv do
      local itemStack = inv[i]
      if itemStack and itemStack.valid_for_read and itemStack.spoil_tick > 0 and itemStack.spoil_percent > 0.005 then
        -- Extend spoil time by 19 ticks if item can spoil
        itemStack.spoil_tick = itemStack.spoil_tick + 19
        -- game.print("-------------------")
        -- game.print("fridge working")
        -- game.print("item name " ..itemStack.name)
        -- game.print("spoil percent " ..itemStack.spoil_percent)
      elseif itemStack and itemStack.valid_for_read then
        -- game.print("-------------------")
        -- game.print("fridge stopping")
        -- game.print("item name " ..itemStack.name)
        -- game.print("spoil percent " ..itemStack.spoil_percent)
      end
    end
  end
end

--- Main tick handler that extends spoil time for items in fridges
-- @function on_tick
-- @param event Event data from Factorio runtime
-- @field event.tick Current game tick
-- @field storage.tick Counter for timing fridge updates
local function on_tick(event)
	if storage.tick >= 81 then 
		storage.tick = 1
		-- 每80 ticks检查一次仓库电力
		check_warehouse_power()
	-- perform spoil time extension every 20 ticks (0.33s)
	elseif storage.tick%20 == 0 then
    check_fridges()
	end
  storage.tick = storage.tick + 1
end

---- Runtime Events ----

--- Handler for when an entity is created
-- @function OnEntityCreated
-- @param event Event data containing the created entity
-- @field event.created_entity Entity created by player
-- @field event.entity Entity created by script
local function OnEntityCreated(event)
  local entity = event.created_entity or event.entity
  if entity and entity.valid then
    if entity.name == "preservation-warehouse" then
      -- 创建隐藏的电力实体
      local proxy = entity.surface.create_entity{
        name = "warehouse-power-proxy",
        position = entity.position,
        force = entity.force
      }
      if proxy then
        storage.Warehouses[entity] = proxy
      end
    else
      -- 普通冰箱
      table.insert(storage.Fridges, entity)
    end
  end
end

--- Handler for when an entity is removed
-- @function OnEntityRemoved
-- @param event Event data containing the removed entity
-- @field event.entity Entity that was removed
local function OnEntityRemoved(event)
  local entity = event.entity
  if entity and entity.valid then
    if entity.name == "preservation-warehouse" then
      -- remove warehouse from storage
      local filtered_warehouses = {}
      for warehouse, proxy in pairs(storage.Warehouses) do
        if warehouse == entity then
          proxy.destroy()
        else
          filtered_warehouses[warehouse] = proxy
        end
      end
      storage.Warehouses = filtered_warehouses
    else
      -- remove fridge from storage
      storage.Fridges = remove_item(storage.Fridges, entity)
    end
  end
end

---- Initialization ----
do
  --- Find and register all existing fridges on all surfaces
  -- @function init_chests
  -- Scans all game surfaces for fridges and adds them to storage
  local function init_chests()
    -- Clear existing storage
    storage.Fridges = {}
    -- Clean up old warehouse proxies
    for _, surface in pairs(game.surfaces) do
      local old_proxies = surface.find_entities_filtered{ name = "warehouse-power-proxy" }
      for _, proxy in pairs(old_proxies) do
        proxy.destroy()
      end
    end
    storage.Warehouses = {}

    -- Initialize fridges and warehouses
    for _, surface in pairs(game.surfaces) do
      -- Find and register fridges
      local chests = surface.find_entities_filtered{ name = {
        "refrigerater", 
        "logistic-refrigerater-passive-provider", 
        "logistic-refrigerater-requester"
      } }
      for _, chest in pairs(chests) do
        table.insert(storage.Fridges, chest)
      end

      -- Find and register warehouses
      local warehouses = surface.find_entities_filtered{ name = "preservation-warehouse" }
      for _, warehouse in pairs(warehouses) do
        local proxy = warehouse.surface.create_entity{
          name = "warehouse-power-proxy",
          position = warehouse.position,
          force = warehouse.force
        }
        if proxy then
          storage.Warehouses[warehouse] = proxy
        end
      end
    end
  end

  --- Register all event handlers
  -- @function init_events
  -- Sets up all event handlers for fridge creation, removal and updates
  local function init_events()
    local filter = {
      { filter="name", name="refrigerater" },
      { filter="name", name="logistic-refrigerater-passive-provider"},
      { filter="name", name="logistic-refrigerater-requester"},
      { filter="name", name="preservation-warehouse"}
    }
    script.on_event(defines.events.on_built_entity, OnEntityCreated, filter)
    script.on_event(defines.events.on_robot_built_entity, OnEntityCreated, filter)
    script.on_event(defines.events.script_raised_built, OnEntityCreated, filter)
    script.on_event(defines.events.script_raised_revive, OnEntityCreated, filter)
    script.on_event(defines.events.on_tick, on_tick)
    script.on_event(defines.events.on_player_mined_entity, OnEntityRemoved, filter)
    script.on_event(defines.events.on_robot_mined_entity, OnEntityRemoved, filter)
    script.on_event(defines.events.on_entity_died, OnEntityRemoved, filter)
    script.on_event(defines.events.script_raised_destroy, OnEntityRemoved, filter)
  end

  -- Register load handler
  script.on_load(function()
    init_events()
  end)

  -- Register init handler
  script.on_init(function()
    init_storages()
    init_chests()
    init_events()
  end)

  -- Register configuration changed handler
  script.on_configuration_changed(function(data)
    init_chests()
    init_events()
  end)

end