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
vcp.inventory_size = 24

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
      {type = "item", name = "uranium-fuel-cell", amount = 1},
      {type = "item", name = "plastic-bar", amount = 10}
    },
    results = {{type = "item", name = "refrigerater", amount = 1}}
  },
})

table.insert(data.raw["technology"]["agricultural-science-pack"].effects, { type = "unlock-recipe", recipe = "refrigerater" } )

local logistic_fridge_types = {
  {name = "logistic-refrigerater-passive-provider", color = {r=0.8, g=0.2, b=0.2}, logistic_mode = "passive-provider", type = "logistic-container"},
  {name = "logistic-refrigerater-requester", color = {r=0.2, g=0.2, b=0.8}, logistic_mode = "requester", type = "logistic-container"}
}

for _, fridge_type in pairs(logistic_fridge_types) do
  local logistic_fridge = table.deepcopy(vcp)
  logistic_fridge.name = fridge_type.name
  logistic_fridge.logistic_mode = fridge_type.logistic_mode
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

data:extend({
  {
    type = "technology",
    name = "logistic-refrigerater",
    icon = "__Fridge__/graphics/icon/refrigerater.png",
    icon_size = 64,
    prerequisites = {"agricultural-science-pack", "logistic-system"},
    effects = {
      {type = "unlock-recipe", recipe = "logistic-refrigerater-passive-provider"},
      {type = "unlock-recipe", recipe = "logistic-refrigerater-requester"}
    },
    unit = {
      count = 200,
      ingredients = {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
        {"production-science-pack", 1},
        {"agricultural-science-pack", 1}
      },
      time = 30
    }
  }
})

-- 创建隐藏的电力实体，使用 roboport 作为基础
local power_proxy = table.deepcopy(data.raw["roboport"]["roboport"])
power_proxy.name = "warehouse-power-proxy"
power_proxy.icon = "__Fridge__/graphics/icon/refrigerater.png"
power_proxy.icon_size = 64
power_proxy.energy_source =
    {
      type = "electric",
      usage_priority = "secondary-input",
      input_flow_limit = "40MW",
      buffer_capacity = "3GJ"
    }
power_proxy.recharge_minimum = "120MJ"
power_proxy.energy_usage = "10MW"
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
power_proxy.collision_box = {{-2.5, -2.5}, {2.5, 2.5}}
power_proxy.collision_mask = {
  layers = {
    item = true,
    object = true,
    player = true,
    water_tile = true
  }
}
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

-- 创建大型仓库
local warehouse = table.deepcopy(data.raw.container["steel-chest"])
warehouse.name = "preservation-warehouse"
warehouse.icon = "__Fridge__/graphics/icon/refrigerater.png"
warehouse.icon_size = 64
warehouse.minable.result = "preservation-warehouse"
warehouse.inventory_size = 200
warehouse.picture = {
  layers = {
    {
      filename = "__Fridge__/graphics/hr-refrigerater.png",
      priority = "extra-high",
      width = 66,
      height = 74,
      shift = util.by_pixel(0, -2),
      scale = 3 -- 放大一倍
    }
  }
}
-- 修改碰撞盒和选择盒大小
warehouse.collision_box = {{-2.8, -2.8}, {2.8, 2.8}}
warehouse.selection_box = {{-3, -3}, {3, 3}}

data:extend({
  power_proxy,
  warehouse,
  {
    type = "item",
    name = "preservation-warehouse",
    icon = "__Fridge__/graphics/icon/refrigerater.png",
    icon_size = 64,
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

-- Add to technology tree
data:extend({
  {
    type = "technology",
    name = "preservation-warehouse-tech",
    icon = "__Fridge__/graphics/icon/refrigerater.png",
    icon_size = 64,
    prerequisites = {"logistic-refrigerater", "cryogenic-science-pack"},
    unit = {
      count = 1500,
      ingredients = {
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
      },
      time = 60
    },
    effects = {
      {type = "unlock-recipe", recipe = "preservation-warehouse"}
    }
  }
})
