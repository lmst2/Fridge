--- Read-only questions about a loaded data.raw, phrased the way the specs ask them.
--
-- Each returns a set ({name = true}) so specs compare contents, not order or amounts.
--
-- @module spec.support.query

local query = {}

local function set_of(list, key_of)
    local set = {}
    for _, value in pairs(list or {}) do set[key_of(value)] = true end
    return set
end

--- Ingredient names of a recipe, prefixed "fluid:" for fluids.
function query.ingredients(recipe)
    return set_of(recipe.ingredients, function(i)
        return (i.type == "fluid" and "fluid:" or "") .. i.name
    end)
end

--- Result names of a recipe, prefixed "fluid:" for fluids.
function query.results(recipe)
    return set_of(recipe.results, function(r)
        return (r.type == "fluid" and "fluid:" or "") .. r.name
    end)
end

--- Total amount of `name` among a recipe's ingredients or results.
function query.amount_of(entries, name)
    local total = 0
    for _, entry in pairs(entries or {}) do
        if entry.name == name then total = total + entry.amount end
    end
    return total
end

--- Petroleum gas per crude oil from advanced oil processing with all of its
--- heavy oil cracked to light oil and all of that cracked to petroleum gas.
function query.fully_cracked_gas_per_crude(raw)
    local refinery = raw.recipe["advanced-oil-processing"]
    local function ratio(recipe, from, to)
        return query.amount_of(recipe.results, to) / query.amount_of(recipe.ingredients, from)
    end
    local light_per_heavy = ratio(raw.recipe["heavy-oil-cracking"], "heavy-oil", "light-oil")
    local gas_per_light = ratio(raw.recipe["light-oil-cracking"], "light-oil", "petroleum-gas")
    local light = query.amount_of(refinery.results, "light-oil")
        + query.amount_of(refinery.results, "heavy-oil") * light_per_heavy
    local gas = query.amount_of(refinery.results, "petroleum-gas") + light * gas_per_light
    return gas / query.amount_of(refinery.ingredients, "crude-oil")
end

--- Science packs a technology costs.
function query.science(technology)
    return set_of(technology.unit.ingredients, function(pack) return pack[1] end)
end

--- Recipes a technology unlocks.
function query.unlocks(technology)
    return set_of(technology.effects, function(effect) return effect.recipe end)
end

--- Whether `technology` has `ancestor` anywhere among its prerequisites.
function query.depends_on(raw, technology, ancestor)
    for _, name in pairs(technology.prerequisites or {}) do
        if name == ancestor then return true end
        local parent = raw.technology[name]
        if parent and query.depends_on(raw, parent, ancestor) then return true end
    end
    return false
end

--- Whether a recipe's surface conditions let it be crafted on a surface with
--- the given properties, e.g. {pressure = 300}.
function query.craftable_on(recipe, surface_properties)
    for _, condition in pairs(recipe.surface_conditions or {}) do
        local value = surface_properties[condition.property]
        if value < (condition.min or -math.huge) or value > (condition.max or math.huge) then
            return false
        end
    end
    return true
end

--- Whether every member of `subset` is in `set`.
function query.contains_all(set, subset)
    for name in pairs(subset) do
        if not set[name] then return false end
    end
    return true
end

--- Set of the given names.
function query.set(...)
    return set_of({ ... }, function(name) return name end)
end

return query
