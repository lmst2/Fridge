--- Fridge mod control script
-- This mod adds refrigerators that slow down item spoilage by extending spoil time
-- @module control

--- Initialize or update general storages of the mod
-- @function init_storages
-- @field storage.tick Counter for timing fridge updates
-- @field storage.Fridges Table storing all fridge entities
local function init_storages()
	storage.tick = storage.tick or 0
  storage.Fridges = {}
end

--- Main tick handler that extends spoil time for items in fridges
-- @function on_tick
-- @param event Event data from Factorio runtime
-- @field event.tick Current game tick
local function on_tick(event)
	if storage.tick >= 80 then 
		storage.tick = 0
	-- perform spoil time extension every 20 ticks (0.33s)
	elseif storage.tick%20 == 1 then
    -- Process each fridge
    for _, chest in pairs(storage.Fridges) do
      local inv = chest.get_inventory(defines.inventory.chest)
      -- Check each slot in the fridge
      for i=1, #inv do
        local itemStack = inv[i]
        if itemStack and itemStack.valid_for_read then
          -- Extend spoil time by 19 ticks if item can spoil
          if itemStack.spoil_tick > 0 then
            itemStack.spoil_tick = itemStack.spoil_tick + 19
          end
        end
      end
    end
	end
  storage.tick = storage.tick + 1
end

---- Runtime Events ----

--- Handler for when a fridge is created
-- @function OnChestCreated
-- @param event Event data containing the created entity
-- @field event.created_entity Entity created by player
-- @field event.entity Entity created by script
function OnChestCreated(event)
  local entity = event.created_entity or event.entity
  -- Check if entity is a valid fridge
  if entity and entity.valid and entity.name == "refrigerater" then
    table.insert(storage.Fridges, entity)
  end
end

--- Handler for when a fridge is removed
-- @function OnEntityRemoved
-- @param event Event data containing the removed entity
-- @field event.entity Entity that was removed
function OnEntityRemoved(event)
  local entity = event.entity
  -- Check if entity is a valid fridge that was removed
  if entity and entity.valid and entity.name == "refrigerater" then
    local filtered = {}
    -- Create new list excluding the removed fridge
    for _, chest in pairs(storage.Fridges) do
      if chest ~= entity then
        table.insert(filtered, chest)
      end
    end
    -- Update storage with filtered list
    storage.Fridges = filtered
  end
end

---- Initialization ----
do
  --- Find and register all existing fridges on all surfaces
  -- @function init_chests
  -- Scans all game surfaces for fridges and adds them to storage
  local function init_chests()
    for _, surface in pairs(game.surfaces) do
      local chests = surface.find_entities_filtered{ name = "refrigerater" }
      for _, chest in pairs(chests) do
        table.insert(storage.Fridges, chest)
      end
    end
  end

  --- Register all event handlers
  -- @function init_events
  -- Sets up all event handlers for fridge creation, removal and updates
  local function init_events()
    local filter = {{ filter="name", name="refrigerater" }}
    script.on_event(defines.events.on_built_entity, OnChestCreated, filter)
    script.on_event(defines.events.on_robot_built_entity, OnChestCreated, filter)
    script.on_event({defines.events.script_raised_built, defines.events.script_raised_revive}, OnChestCreated)
    script.on_event(defines.events.on_tick, on_tick)
    script.on_event(defines.events.on_player_mined_entity, OnEntityRemoved, filter)
    script.on_event(defines.events.on_robot_mined_entity, OnEntityRemoved, filter)
    script.on_event(defines.events.on_entity_died, OnEntityRemoved, filter)
    script.on_event(defines.events.script_raised_destroy, OnEntityRemoved)
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