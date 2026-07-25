data:extend({
    {
        type = "int-setting",
        name = "fridge-small-chest-capacity",
        setting_type = "startup",
        default_value = 24,
        minimum_value = 1,
        maximum_value = 96,
        order = "a"
    },
    {
        type = "int-setting",
        name = "fridge-large-chest-capacity",
        setting_type = "startup",
        default_value = 200,
        minimum_value = 1,
        maximum_value = 1024,
        order = "b"
    },
    {
        type = "int-setting",
        name = "fridge-space-plantform-capacity",
        setting_type = "startup",
        default_value = 20,
        minimum_value = 1,
        maximum_value = 200,
        order = "b"
    },
    {
        type = "int-setting",
        name = "fridge-freeze-rate",
        setting_type = "runtime-global", 
        default_value = 20,
        minimum_value = 1, 
        maximum_value = 100,
        order = "c"
    },
    {
        -- Skip re-walking a freezer whose item count has not changed since the
        -- last pass. Off by default: see the locale description for what it
        -- trades away.
        type = "bool-setting",
        name = "fridge-large-factory-optimization",
        setting_type = "startup",
        default_value = false,
        order = "c[perf]-a"
    },
    {
        -- Inventory slots the mod aims to process per tick.
        type = "int-setting",
        name = "fridge-slot-budget",
        setting_type = "runtime-global",
        default_value = 200,
        minimum_value = 20,
        maximum_value = 4000,
        order = "c[perf]-b"
    },
    {
        -- Longest gap between two passes over the same container, in ticks.
        type = "int-setting",
        name = "fridge-max-refresh-gap",
        setting_type = "runtime-global",
        default_value = 300,
        minimum_value = 60,
        maximum_value = 900,
        order = "c[perf]-c"
    },
    {
        -- How quickly machine-fed insertions are noticed, in ticks. Only
        -- consulted when a mod adds items that spoil faster than the normal
        -- refresh rhythm can guarantee; see the locale description.
        type = "int-setting",
        name = "fridge-reaction-window",
        setting_type = "runtime-global",
        default_value = 30,
        minimum_value = 10,
        maximum_value = 600,
        order = "c[perf]-d"
    },
    {
        type = "double-setting",
        name = "fridge-power-consumption",
        setting_type = "startup",
        default_value = 10.0,
        minimum_value = 0.01,
        order = "d"
    },
    {
        type = "double-setting", 
        name = "fridge-power-capacity",
        setting_type = "startup",
        default_value = 3000,
        minimum_value = 0.1,
        order = "e"
    },
    
})
