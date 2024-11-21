--- Fridge mod control script
-- This mod adds refrigeraters that slow down item spoilage by extending spoil time
-- @module control
local freeze_rates = settings.global["fridge-freeze-rate"].value
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
  storage.Fridges = storage.Fridges or {}
  storage.Warehouses = storage.Warehouses or {}
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

--- Check fridges and extend spoil time for items inside
-- @function check_fridges
local function check_fridges(recover_number)
    -- Process each fridge
    for unit_number, chest in pairs(storage.Fridges) do
        if chest and chest.valid then
            local inv = chest.get_inventory(defines.inventory.chest)
            -- Check each slot in the fridge
            for i=1, #inv do
                local itemStack = inv[i]
                if itemStack and itemStack.valid_for_read and itemStack.spoil_tick > 0 then
                    itemStack.spoil_tick = math.min(itemStack.spoil_tick + recover_number, game.tick + itemStack.prototype.get_spoil_ticks(itemStack.quality) - 3)
                end
            end
        else
            storage.Fridges = remove_item(storage.Fridges, unit_number)
            -- game.print("fridge is removed unexpectedly, removing it from watch list, id: "..unit_number)
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
    end
	elseif game.tick%freeze_rates == 0 then
    check_fridges(freeze_rates - 1)
  end

  if game.tick%80 == 0 then
    freeze_rates = settings.global["fridge-freeze-rate"].value
    check_warehouse_power()
  end
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
        storage.Warehouses[entity.unit_number] = {warehouse = entity, proxy = proxy}
      end
    else
      -- 普通冰箱，使用 unit_number 作为键
      storage.Fridges[entity.unit_number] = entity
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
      for unit_number, warehouse_dict in pairs(storage.Warehouses) do
        local warehouse = warehouse_dict.warehouse
        local proxy = warehouse_dict.proxy
        if warehouse == entity then
          proxy.destroy()
        else
          filtered_warehouses[unit_number] = warehouse_dict
        end
      end
      storage.Warehouses = filtered_warehouses
    else
      -- remove fridge from storage
      storage.Fridges = remove_item(storage.Fridges, entity.unit_number)
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
        "logistic-refrigerater-requester",
        "logistic-refrigerater-buffer"
      } }
      for _, chest in pairs(chests) do
        storage.Fridges[chest.unit_number] = chest
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
          storage.Warehouses[warehouse.unit_number] = {warehouse = warehouse, proxy = proxy}
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
      { filter="name", name="logistic-refrigerater-buffer"},
      { filter="name", name="preservation-warehouse"}
    }
    script.on_event(defines.events.on_built_entity, OnEntityCreated, filter)
    script.on_event(defines.events.on_entity_cloned, OnEntityCreated, filter)
    script.on_event(defines.events.on_robot_built_entity, OnEntityCreated, filter)
    script.on_event(defines.events.on_space_platform_built_entity, OnEntityCreated, filter)
    script.on_event(defines.events.script_raised_built, OnEntityCreated, filter)
    script.on_event(defines.events.script_raised_revive, OnEntityCreated, filter)
    script.on_event(defines.events.on_tick, on_tick)
    script.on_event(defines.events.on_player_mined_entity, OnEntityRemoved, filter)
    script.on_event(defines.events.on_robot_mined_entity, OnEntityRemoved, filter)
    script.on_event(defines.events.on_space_platform_mined_entity, OnEntityRemoved, filter)
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