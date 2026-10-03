--- A stand-in for Factorio's data stage, so data.lua can be loaded outside the game.
--
-- data.lua only reads a handful of base-game prototypes and copies them, so
-- each one is stubbed with just the fields it touches. load() runs the real
-- data.lua in a fresh environment and returns what it registered.
--
-- @module spec.support.data_stage

local data_stage = {}

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = deepcopy(v) end
    return copy
end

local function sprite() return { filename = "__base__/stub.png" } end

local function inserter(name)
    return {
        type = "inserter", name = name, icon = "__base__/" .. name .. ".png", icon_size = 64,
        minable = { result = name },
        platform_picture = { sheet = sprite() },
        hand_base_picture = sprite(),
        hand_open_picture = sprite(),
        hand_closed_picture = sprite(),
    }
end

local function cargo_bay(name)
    return {
        type = "cargo-bay", name = name, icon = "__space-age__/" .. name .. ".png", icon_size = 64,
        graphics_set = { picture = { sprite() }, connections = {} },
        platform_graphics_set = { picture = { sprite() }, connections = {} },
        hatch_definitions = { { hatch_graphics = { layers = { sprite() } } } },
    }
end

local function base_raw()
    return {
        container = { ["steel-chest"] = {
            type = "container", name = "steel-chest", inventory_size = 48,
            minable = { result = "steel-chest" },
            picture = { layers = { sprite(), sprite() } },
        } },
        roboport = { roboport = { type = "roboport", name = "roboport" } },
        ["cargo-wagon"] = { ["cargo-wagon"] = {
            type = "cargo-wagon", name = "cargo-wagon", icon = "__base__/cargo-wagon.png",
            icon_size = 64, minable = { result = "cargo-wagon" },
        } },
        inserter = {
            inserter = inserter("inserter"),
            ["fast-inserter"] = inserter("fast-inserter"),
            ["long-handed-inserter"] = inserter("long-handed-inserter"),
            ["bulk-inserter"] = inserter("bulk-inserter"),
        },
        fluid = {
            ["crude-oil"] = { type = "fluid", name = "crude-oil", icon = "__base__/crude-oil.png", icon_size = 64 },
            ["petroleum-gas"] = { type = "fluid", name = "petroleum-gas", icon = "__base__/petroleum-gas.png", icon_size = 64 },
        },
        item = { ["copper-cable"] = { type = "item", name = "copper-cable", icon = "__base__/copper-cable.png", icon_size = 64 } },
        recipe = { ["basic-oil-processing"] = {
            type = "recipe", name = "basic-oil-processing", category = "oil-processing",
            ingredients = { { type = "fluid", name = "crude-oil", amount = 100 } },
            results = { { type = "fluid", name = "petroleum-gas", amount = 45 } },
        }, ["advanced-oil-processing"] = {
            type = "recipe", name = "advanced-oil-processing", category = "oil-processing",
            ingredients = { { type = "fluid", name = "water", amount = 50 }, { type = "fluid", name = "crude-oil", amount = 100 } },
            results = { { type = "fluid", name = "heavy-oil", amount = 25 }, { type = "fluid", name = "light-oil", amount = 45 },
                        { type = "fluid", name = "petroleum-gas", amount = 55 } },
        }, ["heavy-oil-cracking"] = {
            type = "recipe", name = "heavy-oil-cracking", category = "chemistry",
            ingredients = { { type = "fluid", name = "water", amount = 30 }, { type = "fluid", name = "heavy-oil", amount = 40 } },
            results = { { type = "fluid", name = "light-oil", amount = 30 } },
        }, ["light-oil-cracking"] = {
            type = "recipe", name = "light-oil-cracking", category = "chemistry",
            ingredients = { { type = "fluid", name = "water", amount = 30 }, { type = "fluid", name = "light-oil", amount = 30 } },
            results = { { type = "fluid", name = "petroleum-gas", amount = 20 } },
        } },
    }
end

local function add_space_age(raw)
    raw.inserter["stack-inserter"] = inserter("stack-inserter")
    raw["cargo-bay"] = {
        ["cargo-bay"] = cargo_bay("cargo-bay"),
        ["landing-pad-unloading-bay"] = cargo_bay("landing-pad-unloading-bay"),
    }
    -- Like the real prototype, fluorine relies on the engine's default icon size
    raw.fluid.ammonia = { type = "fluid", name = "ammonia", icon = "__space-age__/ammonia.png" }
    raw.fluid.fluorine = {
        type = "fluid", name = "fluorine", icon = "__space-age__/fluorine.png",
        default_temperature = 25, base_color = { r = 0.6, g = 0.7, b = 0.3 }, flow_color = { r = 0.8, g = 0.9, b = 0.5 },
    }
end

local function startup_settings()
    local values = {
        ["fridge-small-chest-capacity"] = 24,
        ["fridge-large-chest-capacity"] = 200,
        ["fridge-power-consumption"] = 10,
        ["fridge-power-capacity"] = 3000,
        ["fridge-space-plantform-capacity"] = 20,
    }
    local startup = {}
    for name, value in pairs(values) do startup[name] = { value = value } end
    return { startup = startup }
end

local function new_data(raw, added)
    return {
        raw = raw,
        extend = function(_, prototypes)
            for _, prototype in pairs(prototypes) do
                raw[prototype.type] = raw[prototype.type] or {}
                raw[prototype.type][prototype.name] = prototype
                added[#added + 1] = prototype
            end
        end,
    }
end

local function environment(data, space_age)
    local env = {
        data = data,
        mods = { base = "2.1.0", ["space-age"] = space_age and "2.1.0" or nil },
        settings = startup_settings(),
        util = { by_pixel = function(x, y) return { x / 32, y / 32 } end },
        table = setmetatable({ deepcopy = deepcopy }, { __index = table }),
    }
    return setmetatable(env, { __index = _G })
end

--- Run data.lua and return what it registered.
-- @tparam table options `space_age` (boolean) loads with the Space Age mod present
-- @treturn table `raw`, the whole data.raw afterwards, and `added`, every
--   prototype data.lua passed to data:extend, in order
function data_stage.load(options)
    local raw, added = base_raw(), {}
    if options.space_age then add_space_age(raw) end
    local chunk = assert(loadfile("data.lua", "t", environment(new_data(raw, added), options.space_age)))
    chunk()
    return { raw = raw, added = added }
end

return data_stage
