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
        name = "fridge-freeze-rate",
        setting_type = "runtime-global", 
        default_value = 20,
        minimum_value = 1, 
        maximum_value = 100,
        order = "c"
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
    }
})