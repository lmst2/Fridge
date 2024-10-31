

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
vcp.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  emissions_per_minute = 5,
}
vcp.energy_usage = "10kW"
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