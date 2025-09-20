--[[ ============================================================================
   Settings and Helper Functions
============================================================================ ]]--

-- Load mod settings
local settings = {
  small_chest_capacity = settings.startup["fridge-small-chest-capacity"].value,
  large_chest_capacity = settings.startup["fridge-large-chest-capacity"].value,
  power_consumption = settings.startup["fridge-power-consumption"].value,
  power_capacity = settings.startup["fridge-power-capacity"].value,
  platform_bonus_capacity = settings.startup["fridge-space-plantform-capacity"].value
}

-- Determine energy cell type based on available mods
local energy_cell = mods["Factorio-Tirberium"] and "tiberium-fuel-cell" or "uranium-fuel-cell"

-- Helper function to recursively apply preservation tint to sprite structures
local function apply_preservation_tint(obj)
  local tint = {r=0.6, g=0.8, b=1.0, a=1.0}
  
  if type(obj) ~= "table" then return end
  
  -- Handle sprite-like objects (with filename/tint properties)
  if obj.filename then
      obj.tint = tint
      return
  end
  
  -- Handle layers property specifically
  if obj.layers then
      for _, layer in pairs(obj.layers) do
          apply_preservation_tint(layer)
      end
  end
  
  -- Recursively process all table values
  for _, value in pairs(obj) do
      if type(value) == "table" then
          apply_preservation_tint(value)
      end
  end
end


--[[ ============================================================================
 Entity Definitions
============================================================================ ]]--

--[[ ------------------------- Basic Refrigerator ------------------------- ]]--

local refrigerator = table.deepcopy(data.raw.container["steel-chest"])
refrigerator.type = "container"
refrigerator.name = "refrigerater"
refrigerator.icon = "__Fridge__/graphics/icon/refrigerater.png"
refrigerator.icon_size = 64
refrigerator.minable.result = "refrigerater"
refrigerator.order = "a[items]-c[refrigerater]"
refrigerator.picture = {
  layers = {
      {
          filename = "__Fridge__/graphics/hr-refrigerater.png",
          priority = "extra-high",
          width = 66,
          height = 74,
          shift = util.by_pixel(0, -2),
          scale = 0.5
      },
      {
          filename = "__Fridge__/graphics/hr-refrigerater-shadow.png",
          priority = "extra-high",
          width = 112,
          height = 46,
          shift = util.by_pixel(12, 4.5),
          draw_as_shadow = true,
          scale = 0.5
      }
  }
}
refrigerator.logistic_mode = nil
refrigerator.inventory_size = settings.small_chest_capacity
refrigerator.trash_inventory_size = nil


--[[ ------------------------- Logistic Fridges ------------------------- ]]--

local logistic_fridge_types = {
{name = "logistic-refrigerater-passive-provider", color = {r=0.8, g=0.2, b=0.2}, logistic_mode = "passive-provider", type = "logistic-container", trash_inventory_size = 0},
{name = "logistic-refrigerater-requester", color = {r=0.2, g=0.2, b=0.8}, logistic_mode = "requester", type = "logistic-container", trash_inventory_size = 10},
{name = "logistic-refrigerater-buffer", color = {r=0.2, g=0.8, b=0.2}, logistic_mode = "buffer", type = "logistic-container", trash_inventory_size = 10}
}

local logistic_fridges = {}
for _, fridge_type in pairs(logistic_fridge_types) do
local logistic_fridge = table.deepcopy(refrigerator)
logistic_fridge.name = fridge_type.name
logistic_fridge.logistic_mode = fridge_type.logistic_mode
logistic_fridge.trash_inventory_size = fridge_type.trash_inventory_size
logistic_fridge.minable.result = fridge_type.name
logistic_fridge.icons = {
  {
    icon = "__Fridge__/graphics/icon/refrigerater.png",
    icon_size = 64,
    tint = fridge_type.color
  }
}
-- Apply tint to entity sprite
for _, sprite in pairs(logistic_fridge.picture.layers) do
  sprite.tint = fridge_type.color
end
logistic_fridge.type = fridge_type.type
table.insert(logistic_fridges, logistic_fridge)
end


--[[ ------------------------- Power Proxy ------------------------- ]]--

-- Create hidden power entity for warehouse power consumption
local power_proxy = table.deepcopy(data.raw["roboport"]["roboport"])
power_proxy.name = "warehouse-power-proxy"
power_proxy.icon = "__Fridge__/graphics/icon/large-chest.png"
power_proxy.icon_size = 256

-- Configure power settings
power_proxy.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  input_flow_limit = (3 * settings.power_consumption).."MW",
  buffer_capacity = settings.power_capacity.."MJ"
}
power_proxy.recharge_minimum = (settings.power_capacity * 0.05).."MJ"
power_proxy.energy_usage = settings.power_consumption.."MW"

-- Disable all roboport functionality
power_proxy.charging_energy = "0W"
power_proxy.radar_range = 0
power_proxy.logistics_radius = 0
power_proxy.construction_radius = 0
power_proxy.robot_slots_count = 0
power_proxy.material_slots_count = 0
power_proxy.stationing_offset = {0, 0}
power_proxy.charging_offsets = {}

-- Remove all animations and visual elements
power_proxy.base = {
  filename = "__core__/graphics/empty.png",
  width = 1,
  height = 1
}
power_proxy.base_patch = nil
power_proxy.base_animation = nil
power_proxy.door_animation_up = nil
power_proxy.door_animation_down = nil
power_proxy.recharging_animation = nil
power_proxy.spawn_and_station_height = 0

-- Configure entity placement and interaction
power_proxy.selection_box = {{-0.3, -0.3}, {0.3, 0.3}}
power_proxy.collision_box = {{-0.3, -0.3}, {0.3, 0.3}}
power_proxy.collision_mask = {layers = {}}
power_proxy.flags = {
  "not-blueprintable",
  "not-deconstructable",
  "placeable-off-grid",
  "not-on-map",
  "not-repairable",
  "not-upgradable"
}
power_proxy.selection_priority = 1

-- Space Age mod compatibility
if mods["space-age"] then
  power_proxy.surface_conditions = {}
end


--[[ ------------------------- Preservation Warehouse ------------------------- ]]--

local warehouse = table.deepcopy(data.raw.container["steel-chest"])
warehouse.name = "preservation-warehouse"
warehouse.type = "container"

-- Basic properties
warehouse.flags = {"placeable-neutral", "placeable-player", "player-creation"}
warehouse.icon = "__Fridge__/graphics/icon/large-chest.png"
warehouse.icon_size = 256
warehouse.minable = {mining_time = 6, result = "preservation-warehouse"}
warehouse.inventory_size = settings.large_chest_capacity
warehouse.corpse = "big-remnants"

-- Visual appearance
warehouse.picture = {
  layers = {
      {
          filename = "__Fridge__/graphics/large-chest-front.png",
          priority = "extra-high",
          width = 1024,
          height = 1024,
          shift = util.by_pixel(0, -30),
          scale = 0.25
      },
      {
          filename = "__Fridge__/graphics/large-chest-shadow.png",
          priority = "extra-high",
          width = 1024,
          height = 600,
          shift = util.by_pixel(64, 1.5),
          draw_as_shadow = true,
          scale = 0.31
      }
  }
}

-- Collision and selection properties
warehouse.collision_box = {{-2.8, -2.8}, {2.8, 2.8}}
warehouse.selection_box = {{-3, -2.8}, {3, 3}}
warehouse.collision_mask = {
  layers = {
      item = true,
      object = true,
      player = true,
      water_tile = true
  }
}


--[[ ------------------------- Space Platform Warehouse ------------------------- ]]--

-- Create space platform warehouse (Space Age mod compatibility)
local space_warehouse = nil
if mods["space-age"] then
  -- Create entity from cargo bay base
  space_warehouse = table.deepcopy(data.raw["cargo-bay"]["cargo-bay"])
  space_warehouse.type = "cargo-bay"
  space_warehouse.name = "preservation-platform-warehouse"
  
  -- Apply preservation tint to all graphics
  apply_preservation_tint(space_warehouse.graphics_set.picture)
  apply_preservation_tint(space_warehouse.graphics_set.connections)
  apply_preservation_tint(space_warehouse.platform_graphics_set.picture)
  apply_preservation_tint(space_warehouse.platform_graphics_set.connections)
  
  for _, hatch_def in pairs(space_warehouse.hatch_definitions) do
      apply_preservation_tint(hatch_def.hatch_graphics.layers)
  end
  
  -- Configure basic properties
  space_warehouse.minable = {mining_time = 8, result = "preservation-platform-warehouse"}
  space_warehouse.inventory_size_bonus = settings.platform_bonus_capacity
  space_warehouse.surface_conditions = {}
end


--[[ ------------------------- Preservation Wagon ------------------------- ]]--

local preservation_wagon = table.deepcopy(data.raw["cargo-wagon"]["cargo-wagon"])
preservation_wagon.name = "preservation-wagon"
preservation_wagon.minable.result = "preservation-wagon"
preservation_wagon.color = {r=0.6, g=0.8, b=1.0, a=0.8}
preservation_wagon.allow_manual_color = false


--[[ ------------------------- Preservation Inserters ------------------------- ]]--

-- Base preservation inserter (based on fast inserter)
local preservation_inserter = table.deepcopy(data.raw["inserter"]["fast-inserter"])
preservation_inserter.name = "preservation-inserter"
preservation_inserter.minable.result = "preservation-inserter"

-- Configure energy usage
preservation_inserter.energy_per_movement = "10kJ"
preservation_inserter.energy_per_rotation = "10kJ"
preservation_inserter.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  drain = "0.5kW"
}

-- Apply preservation tint
apply_preservation_tint(preservation_inserter.platform_picture.sheet)
apply_preservation_tint(preservation_inserter.hand_base_picture)
apply_preservation_tint(preservation_inserter.hand_open_picture)
apply_preservation_tint(preservation_inserter.hand_closed_picture)
preservation_inserter.next_upgrade = "preservation-stack-inserter"

-- Long-range preservation inserter (based on long-handed inserter)
local preservation_long_inserter = table.deepcopy(data.raw["inserter"]["long-handed-inserter"])
preservation_long_inserter.name = "preservation-long-inserter"
preservation_long_inserter.minable.result = "preservation-long-inserter"

-- Configure energy usage
preservation_long_inserter.energy_per_movement = "15kJ"
preservation_long_inserter.energy_per_rotation = "15kJ"
preservation_long_inserter.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  drain = "0.7kW"
}

-- Apply preservation tint
apply_preservation_tint(preservation_long_inserter.platform_picture.sheet)
apply_preservation_tint(preservation_long_inserter.hand_base_picture)
apply_preservation_tint(preservation_long_inserter.hand_open_picture)
apply_preservation_tint(preservation_long_inserter.hand_closed_picture)

-- Stack preservation inserter (based on stack inserter)
local preservation_stack_inserter = table.deepcopy(data.raw["inserter"]["bulk-inserter"])
preservation_stack_inserter.name = "preservation-stack-inserter"
preservation_stack_inserter.minable.result = "preservation-stack-inserter"

-- Configure energy usage
preservation_stack_inserter.energy_per_movement = "25kJ"
preservation_stack_inserter.energy_per_rotation = "25kJ"
preservation_stack_inserter.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  drain = "1kW"
}

-- Apply preservation tint
apply_preservation_tint(preservation_stack_inserter.platform_picture.sheet)
apply_preservation_tint(preservation_stack_inserter.hand_base_picture)
apply_preservation_tint(preservation_stack_inserter.hand_open_picture)
apply_preservation_tint(preservation_stack_inserter.hand_closed_picture)

if mods["space-age"] then
  preservation_stack_inserter.next_upgrade = "preservation-bulk-inserter"
end

-- Bulk preservation inserter (based on stack inserter)
local preservation_bulk_inserter = nil
if mods["space-age"] then
  preservation_bulk_inserter = table.deepcopy(data.raw["inserter"]["stack-inserter"])
  preservation_bulk_inserter.name = "preservation-bulk-inserter"
  preservation_bulk_inserter.minable.result = "preservation-bulk-inserter"

  -- Configure energy usage
  preservation_bulk_inserter.energy_per_movement = "40kJ"
  preservation_bulk_inserter.energy_per_rotation = "40kJ"
  preservation_bulk_inserter.energy_source = {
    type = "electric",
    usage_priority = "secondary-input",
    drain = "2kW"
  }

  -- Apply preservation tint
  apply_preservation_tint(preservation_bulk_inserter.platform_picture.sheet)
  apply_preservation_tint(preservation_bulk_inserter.hand_base_picture)
  apply_preservation_tint(preservation_bulk_inserter.hand_open_picture)
  apply_preservation_tint(preservation_bulk_inserter.hand_closed_picture)
end


--[[ ============================================================================
 Item Definitions
============================================================================ ]]--

local items = {
  -- Basic refrigerator
  {
      type = "item",
      name = "refrigerater",
      icon = "__Fridge__/graphics/icon/refrigerater.png",
      icon_size = 64,    
      subgroup = "storage",
      order = "a[items]-c[refrigerater]",
      place_result = "refrigerater",
      stack_size = 50
  },

  -- Preservation warehouse
  {
      type = "item",
      name = "preservation-warehouse",
      icon = "__Fridge__/graphics/icon/large-chest.png",
      icon_size = 256,
      subgroup = "storage",
      order = "a[items]-d[preservation-warehouse]",
      place_result = "preservation-warehouse",
      stack_size = 10
  },

  -- Preservation wagon
  {
      type = "item",
      name = "preservation-wagon", 
      icons = {{
          icon = preservation_wagon.icon,
          icon_size = preservation_wagon.icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8},
      }},
      subgroup = "storage",
      order = "a[items]-d[preservation-wagon]",
      place_result = "preservation-wagon",
      stack_size = 5
  },

  -- Basic preservation inserter
  {
      type = "item",
      name = "preservation-inserter",
      icons = {{
          icon = data.raw["inserter"]["fast-inserter"].icon,
          icon_size = data.raw["inserter"]["fast-inserter"].icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8}
      }},
      subgroup = "inserter",
      order = "d[preservation]-a[preservation-inserter]",
      place_result = "preservation-inserter",
      stack_size = 50
  },

  -- Long-range preservation inserter
  {
      type = "item", 
      name = "preservation-long-inserter",
      icons = {{
          icon = data.raw["inserter"]["long-handed-inserter"].icon,
          icon_size = data.raw["inserter"]["long-handed-inserter"].icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8}
      }},
      subgroup = "inserter",
      order = "d[preservation]-b[preservation-long-inserter]",
      place_result = "preservation-long-inserter",
      stack_size = 50
  },

  -- Stack preservation inserter
  {
      type = "item",
      name = "preservation-stack-inserter",
      icons = {{
          icon = data.raw["inserter"]["bulk-inserter"].icon,
          icon_size = data.raw["inserter"]["bulk-inserter"].icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8}
      }},
      subgroup = "inserter",
      order = "d[preservation]-c[preservation-stack-inserter]",
      place_result = "preservation-stack-inserter", 
      stack_size = 50
  },
}

-- Add logistic fridge items
for _, fridge_type in pairs(logistic_fridge_types) do
  table.insert(items, {
      type = "item",
      name = fridge_type.name,
      icons = {
          {
              icon = "__Fridge__/graphics/icon/refrigerater.png",
              icon_size = 64,
              tint = fridge_type.color
          }
      },
      subgroup = "storage",
      order = "a[items]-c[" .. fridge_type.name .. "]",
      place_result = fridge_type.name,
      stack_size = 50
  })
end

-- Add space platform warehouse item if mod is present
if mods["space-age"] then
  table.insert(items, {
      type = "item",
      name = "preservation-platform-warehouse",
      icons = {
          {
              icon = data.raw["cargo-bay"]["cargo-bay"].icon, 
              icon_size = data.raw["cargo-bay"]["cargo-bay"].icon_size,
              tint = {r=0.6, g=0.8, b=1.0, a=0.8},
          }
      },
      subgroup = "storage",
      order = "a[items]-e[preservation-platform-warehouse]",
      place_result = "preservation-platform-warehouse",
      stack_size = 10
  })
  table.insert(items, {
      type = "item",
      name = "preservation-bulk-inserter",
      icons = {{
          icon = data.raw["inserter"]["stack-inserter"].icon,
          icon_size = data.raw["inserter"]["stack-inserter"].icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8}
      }},
      subgroup = "inserter",
      order = "d[preservation]-d[preservation-bulk-inserter]",
      place_result = "preservation-bulk-inserter",
      stack_size = 50
  })
end


--[[ ============================================================================
 Recipe Definitions
============================================================================ ]]--

local recipes = {
  -- Basic refrigerator
  {
      type = "recipe",
      name = "refrigerater",
      enabled = false,
      ingredients = {
          {type = "item", name = "steel-chest", amount = 1},
          {type = "item", name = "electric-engine-unit", amount = 1},
          {type = "item", name = "processing-unit", amount = 1},
          {type = "item", name = energy_cell, amount = 1},
          {type = "item", name = "plastic-bar", amount = 10}
      },
      results = {{type = "item", name = "refrigerater", amount = 1}}
  },

  -- Preservation warehouse
  {
      type = "recipe",
      name = "preservation-warehouse",
      enabled = false,
      ingredients = {
          {type = "item", name = "concrete", amount = 200},
          {type = "item", name = "plastic-bar", amount = 100},
          {type = "item", name = "steel-plate", amount = 50},
          {type = "item", name = "battery", amount = 50},
          {type = "item", name = "processing-unit", amount = 10},
          {type = "item", name = "electric-engine-unit", amount = 5}
      },
      results = {{type = "item", name = "preservation-warehouse", amount = 1}}
  },

  -- Preservation wagon
  {
      type = "recipe",
      name = "preservation-wagon",
      enabled = false,
      ingredients = {
          {type = "item", name = "cargo-wagon", amount = 1},
          {type = "item", name = "refrigerater", amount = 2},
          {type = "item", name = "advanced-circuit", amount = 5}
      },
      results = {{type = "item", name = "preservation-wagon", amount = 1}}
  },

  -- Basic preservation inserter
  {
      type = "recipe",
      name = "preservation-inserter",
      enabled = false,
      ingredients = {
          {type = "item", name = "fast-inserter", amount = 1},
          {type = "item", name = "electronic-circuit", amount = 2},
          {type = "item", name = "refrigerater", amount = 1}
      },
      results = {{type = "item", name = "preservation-inserter", amount = 1}}
  },

  -- Long-range preservation inserter
  {
      type = "recipe",
      name = "preservation-long-inserter", 
      enabled = false,
      ingredients = {
          {type = "item", name = "long-handed-inserter", amount = 1},
          {type = "item", name = "electronic-circuit", amount = 3},
          {type = "item", name = "refrigerater", amount = 1}
      },
      results = {{type = "item", name = "preservation-long-inserter", amount = 1}}
  },

  -- Stack preservation inserter
  {
      type = "recipe",
      name = "preservation-stack-inserter",
      enabled = false,
      ingredients = {
          {type = "item", name = "bulk-inserter", amount = 1},
          {type = "item", name = "advanced-circuit", amount = 2},
          {type = "item", name = "refrigerater", amount = 1}
      },
      results = {{type = "item", name = "preservation-stack-inserter", amount = 1}}
  },

}

-- Add logistic fridge recipes
for _, fridge_type in pairs(logistic_fridge_types) do
  table.insert(recipes, {
      type = "recipe",
      name = fridge_type.name,
      enabled = false,
      ingredients = {
          {type = "item", name = "refrigerater", amount = 1},
          {type = "item", name = "processing-unit", amount = 1},
          {type = "item", name = "advanced-circuit", amount = 2}
      },
      results = {{type = "item", name = fridge_type.name, amount = 1}}
  })
end

-- Add space platform warehouse recipe if mod is present
if mods["space-age"] then
  table.insert(recipes, {
      type = "recipe",
      name = "preservation-platform-warehouse",
      enabled = false,
      ingredients = {
          {type = "item", name = "preservation-warehouse", amount = 1},
          {type = "item", name = "iron-plate", amount = 100}
      },
      results = {{type = "item", name = "preservation-platform-warehouse", amount = 1}}
  })
  table.insert(recipes, {
      type = "recipe",
      name = "preservation-bulk-inserter",
      enabled = false,
      ingredients = {
          {type = "item", name = "stack-inserter", amount = 1},
          {type = "item", name = "advanced-circuit", amount = 4},
          {type = "item", name = "processing-unit", amount = 1},
          {type = "item", name = "refrigerater", amount = 1}
      },
      results = {{type = "item", name = "preservation-bulk-inserter", amount = 1}}
  })
end


--[[ ============================================================================
 Technology Definitions
============================================================================ ]]--

local ingredLR = mods["space-age"] and {
  {"automation-science-pack", 1},
  {"logistic-science-pack", 1},
  {"chemical-science-pack", 1},
  {"production-science-pack", 1},
  {"agricultural-science-pack", 1}
} or {
  {"automation-science-pack", 1},
  {"logistic-science-pack", 1},
  {"chemical-science-pack", 1},
  {"production-science-pack", 1},
}

local ingredPW = mods["space-age"] and {
  {"automation-science-pack", 1},
  {"logistic-science-pack", 1},
  {"chemical-science-pack", 1},
  {"production-science-pack", 1},
  {"utility-science-pack", 1},
  {"space-science-pack", 1},
  {"metallurgic-science-pack", 1},
  {"agricultural-science-pack", 1},
  {"electromagnetic-science-pack", 1},
  {"cryogenic-science-pack", 1}
} or {
  {"automation-science-pack", 1},
  {"logistic-science-pack", 1},
  {"chemical-science-pack", 1},
  {"production-science-pack", 1},
  {"utility-science-pack", 1},
  {"space-science-pack", 1},
}

local technologies = {
  -- Basic refrigerator
  {
      type = "technology",
      name = "refrigerater",
      icons = {{
          icon = "__Fridge__/graphics/icon/refrigerater.png",
          icon_size = 64
      }},
      prerequisites = {"electric-engine", "processing-unit", "plastics"},
      effects = {
          {type = "unlock-recipe", recipe = "refrigerater"}
      },
      unit = {
          count = 50,
          ingredients = {
              {"automation-science-pack", 1},
              {"logistic-science-pack", 1}
          },
          time = 30
      }
  },

  -- Logistic refrigerator
  {
      type = "technology",
      name = "logistic-refrigerater",
      icon = "__Fridge__/graphics/icon/refrigerater.png",
      icon_size = 64,
      prerequisites = {"refrigerater", "logistic-system"},
      effects = {
          {type = "unlock-recipe", recipe = "logistic-refrigerater-passive-provider"},
          {type = "unlock-recipe", recipe = "logistic-refrigerater-requester"},
          {type = "unlock-recipe", recipe = "logistic-refrigerater-buffer"}
      },
      unit = {
          count = 200,
          ingredients = ingredLR,
          time = 30
      }
  },

  -- Preservation warehouse
  {
      type = "technology",
      name = "preservation-warehouse-tech",
      icon = "__Fridge__/graphics/icon/large-chest.png",
      icon_size = 256,
      prerequisites = {"logistic-refrigerater"},
      unit = {
          count = 1500,
          ingredients = ingredPW,
          time = 60
      },
      effects = {
          {type = "unlock-recipe", recipe = "preservation-warehouse"}
      }
  },

  -- Preservation wagon
  {
      type = "technology",
      name = "preservation-wagon",
      icons = {{
          icon = preservation_wagon.icon,
          icon_size = preservation_wagon.icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8},
      }},
      prerequisites = {"railway", "refrigerater"},
      effects = {
          {type = "unlock-recipe", recipe = "preservation-wagon"}
      },
      unit = {
          count = 100,
          ingredients = {
              {"automation-science-pack", 1},
              {"logistic-science-pack", 1}, 
              {"chemical-science-pack", 1},
              {"production-science-pack", 1}
          },
          time = 30
      }
  },

  -- Preservation inserters
  {
      type = "technology",
      name = "preservation-inserter",
      icon_size = 256,
      icon_mipmaps = 4,
      icons = {{
          icon = data.raw["inserter"]["inserter"].icon,
          icon_size = data.raw["inserter"]["inserter"].icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8}
      }},
      prerequisites = {"logistics", "refrigerater"},
      unit = {
          count = 50,
          ingredients = {
              {"automation-science-pack", 1},
              {"logistic-science-pack", 1}
          },
          time = 30
      },
      effects = {
          {type = "unlock-recipe", recipe = "preservation-inserter"},
          {type = "unlock-recipe", recipe = "preservation-long-inserter"},
          {type = "unlock-recipe", recipe = "preservation-stack-inserter"},
          {type = "unlock-recipe", recipe = "preservation-bulk-inserter"}
      },
      order = "a-d-a"
  }
}

-- Preservation platform-cargo-bay
if mods["space-age"] then
  table.insert(technologies, {
      type = "technology",
      name = "preservation-platform-warehouse",
      icons = {{
          icon = data.raw["cargo-bay"]["cargo-bay"].icon,
          icon_size = data.raw["cargo-bay"]["cargo-bay"].icon_size,
          tint = {r=0.6, g=0.8, b=1.0, a=0.8},
      }},
      icon_size = 256,
      prerequisites = {"preservation-warehouse-tech"},
      unit = {
          count = 1500,
          ingredients = ingredPW,
          time = 60
      },
      effects = {
          {type = "unlock-recipe", recipe = "preservation-platform-warehouse"}
      }
  })
end


--[[ ============================================================================
 Register Prototypes
============================================================================ ]]--

-- Register entities
data:extend({
  refrigerator,
  power_proxy,
  warehouse,
  preservation_wagon,
  preservation_inserter,
  preservation_long_inserter,
  preservation_stack_inserter,
  preservation_bulk_inserter
})

-- Register logistic fridge entities
for _, logistic_fridge in pairs(logistic_fridges) do
  data:extend({logistic_fridge})
end

-- Register space platform warehouse if mod is present
if space_warehouse then
  data:extend({space_warehouse})
end

-- Register items
data:extend(items)

-- Register recipes
data:extend(recipes)

-- Register technologies
data:extend(technologies)

