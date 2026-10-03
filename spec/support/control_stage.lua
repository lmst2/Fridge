--- A stand-in for Factorio's control stage, just far enough to see what control.lua tracks.
--
-- control.lua keeps its list of preserved prototypes private, but it hands
-- that list to the game as the filter on every build event. Loading it with a
-- recording `script` and reading that filter back is the same view the game
-- has of which entities get preserved.
--
-- @module spec.support.control_stage

local control_stage = {}

-- defines.<group>.<name> becomes the string "<group>.<name>": unique per
-- define, which is all control.lua relies on at load time.
local function stub_defines()
    return setmetatable({}, { __index = function(defines, group)
        local values = setmetatable({}, { __index = function(_, name) return group .. "." .. name end })
        rawset(defines, group, values)
        return values
    end })
end

local function recording_script(handlers)
    local function ignore() end
    return {
        on_event = function(event, _, filter) handlers.filters[event] = filter end,
        on_load = function(handler) handlers.on_load = handler end,
        on_init = ignore,
        on_configuration_changed = ignore,
        on_nth_tick = ignore,
    }
end

local function stub_modules()
    local function ignore() end
    return {
        ["script.config"] = { refresh = ignore },
        ["script.executor"] = { init_cache = ignore },
        ["script.scheduler"] = {},
    }
end

local function entity_names(raw_entities)
    local names = {}
    for _, prototype in pairs(raw_entities) do names[prototype.name] = prototype end
    return names
end

local function environment(handlers, entities)
    local modules = stub_modules()
    local env = {
        script = recording_script(handlers),
        defines = stub_defines(),
        prototypes = { entity = entities },
        require = function(name) return assert(modules[name], "unstubbed module " .. name) end,
    }
    return setmetatable(env, { __index = _G })
end

--- Load control.lua in a game whose entity prototypes are `entities`.
-- @tparam table entities every entity prototype that exists, as a list
-- @treturn table set of entity names control.lua asks to hear about when built
function control_stage.tracked_on_build(entities)
    local handlers = { filters = {} }
    local chunk = assert(loadfile("control.lua", "t", environment(handlers, entity_names(entities))))
    chunk()
    handlers.on_load()
    local tracked = {}
    for _, entry in pairs(handlers.filters["events.on_built_entity"]) do tracked[entry.name] = true end
    return tracked
end

return control_stage
