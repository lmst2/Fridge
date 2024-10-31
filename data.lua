

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
