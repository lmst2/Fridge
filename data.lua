local small_chest_capacity = settings.startup["fridge-small-chest-capacity"].value
local large_chest_capacity = settings.startup["fridge-large-chest-capacity"].value
local power_consumption = settings.startup["fridge-power-consumption"].value
local power_capacity = settings.startup["fridge-power-capacity"].value
local bouns_capacity = settings.startup["fridge-space-plantform-capacity"].value

-- mod settings
local key_enrgy = "uranium-fuel-cell"
if mods["Factorio-Tirberium"] then
  key_enrgy = "tiberium-fuel-cell"
end


local vcp = table.deepcopy(data.raw.container["steel-chest"])
vcp.type = "container"
vcp.name = "refrigerater"
vcp.icon = "__Fridge__/graphics/icon/refrigerater.png"
vcp.icon_size = 64
vcp.minable.result = "refrigerater"
vcp.order = "a[items]-c[refrigerater]"
vcp.picture =
{
  layers =
  {
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
-- vcp.energy_source = {
--   type = "electric",
--   usage_priority = "secondary-input",
--   emissions_per_minute = 5,
-- }
-- vcp.energy_usage = "10kW"
-- vcp.gui_mode = "none" -- all, none, admins
-- vcp.erase_contents_when_mined = true
vcp.logistic_mode = nil
vcp.inventory_size = small_chest_capacity
vcp.trash_inventory_size = nil

data:extend({
  vcp,
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
  {
    type = "recipe",
    name = "refrigerater",
    enabled = false,
    ingredients =
    {
      {type = "item", name = "steel-chest", amount = 1},
      {type = "item", name = "electric-engine-unit", amount = 1},
      {type = "item", name = "processing-unit", amount = 1},
      {type = "item", name = key_enrgy, amount = 1},
      {type = "item", name = "plastic-bar", amount = 10}
    },
    results = {{type = "item", name = "refrigerater", amount = 1}}
  },
})

data:extend({
  {
    type = "technology",
    name = "refrigerater",
    icons = {
      {
        icon = "__Fridge__/graphics/icon/refrigerater.png",
        icon_size = 64
      }
    },
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
  }
})

local logistic_fridge_types = {
  {name = "logistic-refrigerater-passive-provider", color = {r=0.8, g=0.2, b=0.2}, logistic_mode = "passive-provider", type = "logistic-container", trash_inventory_size = 0},
  {name = "logistic-refrigerater-requester", color = {r=0.2, g=0.2, b=0.8}, logistic_mode = "requester", type = "logistic-container", trash_inventory_size = 10},
  {name = "logistic-refrigerater-buffer", color = {r=0.2, g=0.8, b=0.2}, logistic_mode = "buffer", type = "logistic-container", trash_inventory_size = 10}
}

for _, fridge_type in pairs(logistic_fridge_types) do
  local logistic_fridge = table.deepcopy(vcp)
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
  data:extend({
    logistic_fridge,
    {
      type = "item",
      name = fridge_type.name,
      icons = logistic_fridge.icons,
      subgroup = "storage",
      order = "a[items]-c[" .. fridge_type.name .. "]",
      place_result = fridge_type.name,
      stack_size = 50
    },
    {
      type = "recipe",
      name = fridge_type.name,
      enabled = false,
      ingredients = {
        {type = "item", name = "refrigerater", amount = 1},
        {type = "item", name = "processing-unit", amount = 1},
        {type = "item", name = "advanced-circuit", amount = 2}
      },
      results = {{type = "item", name = fridge_type.name, amount = 1}}
    }
  })
end

local ingredLR = {}
if mods["space-age"] then
  ingredLR = {
    {"automation-science-pack", 1},
    {"logistic-science-pack", 1},
    {"chemical-science-pack", 1},
    {"production-science-pack", 1},
    {"agricultural-science-pack", 1}
  }
else
  ingredLR =  {
    {"automation-science-pack", 1},
    {"logistic-science-pack", 1},
    {"chemical-science-pack", 1},
    {"production-science-pack", 1},
  }
end

data:extend({
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
  }
})

-- 创建隐藏的电力实体，使用 roboport 作为基础
local power_proxy = table.deepcopy(data.raw["roboport"]["roboport"])
power_proxy.name = "warehouse-power-proxy"
power_proxy.icon = "__Fridge__/graphics/icon/large-chest.png"
power_proxy.icon_size = 256
power_proxy.energy_source =
    {
      type = "electric",
      usage_priority = "secondary-input",
      input_flow_limit = (3 * power_consumption).."MW",
      buffer_capacity = power_capacity.."MJ"
    }
power_proxy.recharge_minimum = (power_capacity * 0.05).."MJ"
power_proxy.energy_usage = power_consumption.."MW"
power_proxy.charging_energy = "0W"  -- 禁用机器人充电
power_proxy.radar_range = 0  -- 禁用雷达范围
power_proxy.logistics_radius = 0  -- 禁用物流范围
power_proxy.construction_radius = 0  -- 禁用建设范围
power_proxy.robot_slots_count = 0  -- 禁用机器人槽
power_proxy.material_slots_count = 0  -- 禁用维修包槽
power_proxy.stationing_offset = {0, 0}  -- 机器人进出位置
power_proxy.charging_offsets = {}  -- 禁用充电点
power_proxy.base = nil
power_proxy.base_patch = nil
power_proxy.frozen_patch = nil
power_proxy.base_animation = nil  -- 移除基础动画
power_proxy.door_animation_up = nil  -- 移除门动画
power_proxy.door_animation_down = nil  -- 移除门动画
power_proxy.recharging_animation = nil  -- 移除充电动画
power_proxy.spawn_and_station_height = 0  -- 设置高度为0
power_proxy.next_upgrade = nil  -- 移除升级选项
if mods["space-age"] then
  power_proxy.surface_conditions = {}
end

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
-- 使用空白图片
power_proxy.base = {
  filename = "__core__/graphics/empty.png",
  width = 1,
  height = 1
}
power_proxy.selection_priority = 1

-- 创建大型仓库
local warehouse = table.deepcopy(data.raw.container["steel-chest"])
warehouse.name = "preservation-warehouse"
warehouse.flags = {"placeable-neutral","placeable-player", "player-creation"}
warehouse.type = "container"
warehouse.icon = "__Fridge__/graphics/icon/large-chest.png"
warehouse.icon_size = 256
warehouse.minable = {mining_time = 6, result = "preservation-warehouse"}
warehouse.inventory_size = large_chest_capacity
warehouse.picture = {
  layers = {
    {
      filename = "__Fridge__/graphics/large-chest-front.png",
      priority = "extra-high",
      width = 1024,
      height = 1024,
      shift = util.by_pixel(0, -30),
      scale = 0.25 -- 放大一倍
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
-- 修改碰撞盒和选择盒大小
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
warehouse.corpse = "big-remnants"

data:extend({
  power_proxy,
  warehouse,
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
  }
})

local ingredPW = {}
if mods["space-age"] then
  ingredPW = {
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
  }
else
  ingredPW =  {
    {"automation-science-pack", 1},
    {"logistic-science-pack", 1},
    {"chemical-science-pack", 1},
    {"production-science-pack", 1},
    {"utility-science-pack", 1},
    {"space-science-pack", 1},
  }
end
-- Add to technology tree
data:extend({
  {
    type = "technology",
    name = "preservation-warehouse-tech",
    icon = "__Fridge__/graphics/icon/large-chest.png",
    icon_size = 256,
    prerequisites = {"logistic-refrigerater", "cryogenic-science-pack"},
    unit = {
      count = 1500,
      ingredients = ingredPW,
      time = 60
    },
    effects = {
      {type = "unlock-recipe", recipe = "preservation-warehouse"}
    }
  }
})

-- Add after the preservation-warehouse definition

-- Create space platform warehouse
if mods["space-age"] then
  local space_warehouse = table.deepcopy(data.raw["cargo-bay"]["cargo-bay"])
  space_warehouse.type = "cargo-bay"
  space_warehouse.name = "preservation-platform-warehouse"
  space_warehouse.icons = {
    {
      icon = data.raw["cargo-bay"]["cargo-bay"].icon,
      icon_size = data.raw["cargo-bay"]["cargo-bay"].icon_size,
      tint = {r=0.6, g=0.8, b=1.0, a=0.8}
    }
  }
  -- space_warehouse.icon_size = 256
  -- space_warehouse.graphics_set.picture.tint = {r=0.6, g=0.8, b=1.0, a=0.8}
  -- space_warehouse.graphics_set.picture.render_layer = data.raw["cargo-bay"]["cargo-bay"].graphics_set.picture.render_layer

  space_warehouse.minable = {mining_time = 8, result = "preservation-platform-warehouse"}
  space_warehouse.inventory_size_bonus = bouns_capacity
  -- space_warehouse.inventory_type = "with_filters_and_bar"
  space_warehouse.surface_conditions = {}
  -- Add cargo bay specific properties
  -- space_warehouse.graphics_set = {
  --   animation = {
  --     filename = "__Fridge__/graphics/large-chest-front.png",
  --     priority = "extra-high",
  --     width = 1024,
  --     height = 1024,
  --     scale = 0.25
  --   }
  -- }
  -- space_warehouse.platform_graphics_set = {
  --   animation = {
  --     filename = "__Fridge__/graphics/large-chest-front.png",
  --     priority = "extra-high",
  --     width = 1024,
  --     height = 1024,
  --     scale = 0.25
  --   }
  -- }
  data:extend({
    space_warehouse,
    {
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
    },
    {
      type = "recipe",
      name = "preservation-platform-warehouse",
      enabled = false,
      ingredients = {
        {type = "item", name = "preservation-warehouse", amount = 1},
        {type = "item", name = "iron-plate", amount = 100}
      },
      results = {{type = "item", name = "preservation-platform-warehouse", amount = 1}}
    }
  })
  
  -- Add to space age technology
  table.insert(data.raw["technology"]["space-platform"].effects,
    {type = "unlock-recipe", recipe = "preservation-platform-warehouse"}
  )
end

-- -- Add after other graphics definitions
-- data:extend({
--   {
--     type = "sprite",
--     name = "frozen-overlay",
--     filename = "__Fridge__/graphics/frozen-overlay.png",
--     priority = "extra-high",
--     width = 32,
--     height = 32,
--     flags = {"icon"}
--   }
-- })
-- Create preservation wagon based on cargo wagon
local preservation_wagon = table.deepcopy(data.raw["cargo-wagon"]["cargo-wagon"])
preservation_wagon.name = "preservation-wagon"
preservation_wagon.minable.result = "preservation-wagon"

-- -- Apply freezing tint to wagon sprites
-- for _, sprite in pairs(preservation_wagon.pictures.layers) do
--   sprite.tint = {r=0.6, g=0.8, b=1.0, a=0.8}
-- end

-- for _, sprite in pairs(preservation_wagon.horizontal_doors.layers) do
--   sprite.tint = {r=0.6, g=0.8, b=1.0, a=0.8}
-- end

-- for _, sprite in pairs(preservation_wagon.vertical_doors.layers) do
--   sprite.tint = {r=0.6, g=0.8, b=1.0, a=0.8}
-- end
preservation_wagon.color = {r=0.6, g=0.8, b=1.0, a=0.8}
preservation_wagon.allow_manual_color = false

data:extend({
  preservation_wagon,
  {
    type = "item",
    name = "preservation-wagon", 
    icons = {
      {
        icon = preservation_wagon.icon,
        icon_size = preservation_wagon.icon_size,
        tint = {r=0.6, g=0.8, b=1.0, a=0.8},
      }
    },
    subgroup = "storage",
    order = "a[items]-d[preservation-wagon]",
    place_result = "preservation-wagon",
    stack_size = 5
  },
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
  {
    type = "technology",
    name = "preservation-wagon",
    icons = {
      {
        icon = preservation_wagon.icon,
        icon_size = preservation_wagon.icon_size,
        tint = {r=0.6, g=0.8, b=1.0, a=0.8},
      }
    },
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
  }
})


