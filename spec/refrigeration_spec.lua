local data_stage = require("spec.support.data_stage")
local query = require("spec.support.query")

local AQUILO_SCIENCE = query.set(
    "automation-science-pack", "logistic-science-pack", "chemical-science-pack",
    "production-science-pack", "utility-science-pack",
    "space-science-pack", "metallurgic-science-pack", "agricultural-science-pack",
    "electromagnetic-science-pack", "cryogenic-science-pack")

local LOGISTIC_FRIDGE_CHESTS = {
    ["logistic-refrigerater-passive-provider"] = "passive-provider-chest",
    ["logistic-refrigerater-requester"] = "requester-chest",
    ["logistic-refrigerater-buffer"] = "buffer-chest",
    ["logistic-refrigerater-storage"] = "storage-chest",
}

local LOGISTIC_FRIDGE_MODES = {
    ["logistic-refrigerater-passive-provider"] = "passive-provider",
    ["logistic-refrigerater-requester"] = "requester",
    ["logistic-refrigerater-buffer"] = "buffer",
    ["logistic-refrigerater-storage"] = "storage",
}

for _, space_age in pairs({ true, false }) do
    describe("in every game (space_age = " .. tostring(space_age) .. ")", function()
        local raw

        before_each(function()
            raw = data_stage.load({ space_age = space_age }).raw
        end)

        it("offers passive provider, requester, buffer and storage logistic refrigerators", function()
            -- Arrange / Act: loaded in before_each

            -- Assert
            for name, mode in pairs(LOGISTIC_FRIDGE_MODES) do
                local fridge = raw["logistic-container"][name]
                assert.is_not_nil(fridge, name)
                assert.are.equal(mode, fridge.logistic_mode)
                assert.is_not_nil(raw.recipe[name], name)
            end
        end)

        it("limits the storage refrigerator to the single filter slot the engine allows a storage chest", function()
            -- Arrange
            local fridge = raw["logistic-container"]["logistic-refrigerater-storage"]

            -- Act / Assert
            assert.are.equal(1, fridge.max_logistic_slots)
        end)

        it("unlocks all four logistic refrigerators from refrigeration and the logistic system", function()
            -- Arrange
            local tech = raw.technology["logistic-refrigerater"]

            -- Act
            local unlocks = query.unlocks(tech)

            -- Assert
            for name in pairs(LOGISTIC_FRIDGE_CHESTS) do assert.is_true(unlocks[name], name) end
            assert.is_true(query.contains_all(query.set(table.unpack(tech.prerequisites)),
                query.set("refrigerater", "logistic-system")))
        end)

        it("keeps a refrigerator as the cooling ingredient of the wagon and every preservation inserter", function()
            -- Arrange
            local users = { "preservation-wagon", "preservation-fast-inserter",
                            "preservation-long-inserter", "preservation-bulk-inserter" }
            if space_age then users[#users + 1] = "preservation-stack-inserter" end

            -- Act / Assert
            for _, name in pairs(users) do
                assert.is_true(query.ingredients(raw.recipe[name])["refrigerater"], name)
            end
        end)
    end)
end

describe("with Space Age", function()
    local raw

    before_each(function()
        raw = data_stage.load({ space_age = true }).raw
    end)

    it("makes HFC from fluorine and petroleum gas, in the cryogenic plant only", function()
        -- Arrange
        local recipe = raw.recipe["hfc"]

        -- Act / Assert
        assert.is_not_nil(raw.fluid["hfc"])
        assert.are.equal("cryogenics", recipe.category)
        assert.are.same(query.set("fluid:fluorine", "fluid:petroleum-gas"), query.ingredients(recipe))
        assert.are.same(query.set("fluid:hfc"), query.results(recipe))
    end)

    it("lists HFC with the other Aquilo processes in intermediate products", function()
        -- Arrange
        local recipe = raw.recipe["hfc"]

        -- Act / Assert
        assert.are.equal("aquilo-processes", recipe.subgroup)
    end)

    it("makes petroleum gas from ammonia and crude oil in the cryogenic plant", function()
        -- Arrange
        local recipe = raw.recipe["cryogenic-oil-processing"]

        -- Act / Assert
        assert.are.equal("cryogenics", recipe.category)
        assert.are.same(query.set("fluid:ammonia", "fluid:crude-oil"), query.ingredients(recipe))
        assert.are.same(query.set("fluid:petroleum-gas"), query.results(recipe))
    end)

    it("lists cryogenic oil processing as its own recipe instead of folding it into petroleum gas", function()
        -- Arrange
        local recipe = raw.recipe["cryogenic-oil-processing"]

        -- Act / Assert
        assert.are.equal("", recipe.main_product)
    end)

    it("draws petroleum gas in front of crude oil and ammonia on the cryogenic oil processing icon", function()
        -- Arrange
        local icons = raw.recipe["cryogenic-oil-processing"].icons

        -- Act
        local background = query.set(icons[1].icon, icons[2].icon)

        -- Assert
        assert.are.equal(3, #icons)
        assert.are.same(query.set(raw.fluid["crude-oil"].icon, raw.fluid["ammonia"].icon), background)
        assert.are.equal(raw.fluid["petroleum-gas"].icon, icons[3].icon)
        for _, layer in pairs(icons) do assert.is_number(layer.icon_size) end
    end)

    it("lists cryogenic oil processing with the oil processing recipes", function()
        -- Arrange
        local recipe = raw.recipe["cryogenic-oil-processing"]

        -- Act / Assert
        assert.are.equal("fluid-recipes", recipe.subgroup)
    end)

    it("yields less petroleum gas per crude oil than fully cracked advanced oil processing", function()
        -- Arrange
        local recipe = raw.recipe["cryogenic-oil-processing"]

        -- Act
        local cryogenic = query.amount_of(recipe.results, "petroleum-gas") / query.amount_of(recipe.ingredients, "crude-oil")

        -- Assert
        assert.is_true(cryogenic < query.fully_cracked_gas_per_crude(raw))
    end)

    it("yields at least twice the petroleum gas per crude oil of basic oil processing", function()
        -- Arrange
        local function gas_per_crude(recipe)
            return query.amount_of(recipe.results, "petroleum-gas") / query.amount_of(recipe.ingredients, "crude-oil")
        end

        -- Act
        local cryogenic = gas_per_crude(raw.recipe["cryogenic-oil-processing"])
        local basic = gas_per_crude(raw.recipe["basic-oil-processing"])

        -- Assert
        assert.is_true(cryogenic >= 2 * basic)
    end)

    it("makes HFC on Aquilo and nowhere else", function()
        -- Arrange
        local recipe = raw.recipe["hfc"]
        local pressures = { nauvis = 1000, vulcanus = 4000, fulgora = 800, gleba = 2000,
                            aquilo = 300, ["space platform"] = 0 }

        -- Act / Assert
        for surface, pressure in pairs(pressures) do
            assert.are.equal(surface == "aquilo", query.craftable_on(recipe, { pressure = pressure }), surface)
        end
    end)

    it("gives every HFC icon layer an explicit size, which base's barrel recipe generator requires", function()
        -- Arrange
        local icons = raw.fluid["hfc"].icons

        -- Act / Assert
        for _, layer in pairs(icons) do
            assert.is_number(layer.icon_size)
        end
    end)

    it("makes the sealed cooling coil from HFC, copper and plastic, in an assembler or cryogenic plant", function()
        -- Arrange
        local recipe = raw.recipe["sealed-cooling-coil"]

        -- Act / Assert
        assert.is_not_nil(raw.item["sealed-cooling-coil"])
        assert.are.equal("cryogenics-or-assembling", recipe.category)
        assert.are.same(query.set("fluid:hfc", "copper-plate", "plastic-bar"), query.ingredients(recipe))
    end)

    it("builds the refrigerator from the coil, an electric engine unit and iron, by hand or in any assembler", function()
        -- Arrange
        local recipe = raw.recipe["refrigerater"]

        -- Act / Assert
        assert.is_nil(recipe.category)
        assert.are.same(query.set("sealed-cooling-coil", "electric-engine-unit", "iron-plate"),
            query.ingredients(recipe))
    end)

    it("builds each logistic refrigerator from the refrigerator's ingredients plus its matching logistic chest, by hand or in any assembler", function()
        for name, chest in pairs(LOGISTIC_FRIDGE_CHESTS) do
            -- Arrange
            local recipe = raw.recipe[name]

            -- Act / Assert
            assert.is_nil(recipe.category, name)
            assert.are.same(query.set("sealed-cooling-coil", "electric-engine-unit", "iron-plate", chest),
                query.ingredients(recipe), name)
        end
    end)

    it("gates refrigeration behind the cryogenic plant at Aquilo-tier science", function()
        -- Arrange
        local tech = raw.technology["refrigerater"]

        -- Act
        local prerequisites = query.set(table.unpack(tech.prerequisites))

        -- Assert
        assert.is_true(prerequisites["cryogenic-plant"])
        assert.are.same(AQUILO_SCIENCE, query.science(tech))
    end)

    it("unlocks HFC, the coil, the refrigerator and cryogenic oil processing together with refrigeration", function()
        -- Arrange
        local tech = raw.technology["refrigerater"]

        -- Act / Assert
        assert.are.same(query.set("hfc", "sealed-cooling-coil", "refrigerater", "cryogenic-oil-processing"),
            query.unlocks(tech))
    end)

    it("gives every refrigeration technology its own science list, so another mod can change one without the rest", function()
        -- Arrange
        local names = { "refrigerater", "logistic-refrigerater", "preservation-wagon", "preservation-fast-inserter" }
        local seen = {}

        -- Act / Assert
        for _, name in pairs(names) do
            local ingredients = raw.technology[name].unit.ingredients
            assert.is_nil(seen[ingredients], name)
            seen[ingredients] = true
        end
    end)

    it("never lets a technology built on refrigeration cost less than Aquilo-tier science", function()
        for name, tech in pairs(raw.technology) do
            if query.depends_on(raw, tech, "refrigerater") then
                -- Act / Assert
                assert.is_true(query.contains_all(query.science(tech), AQUILO_SCIENCE), name)
            end
        end
    end)
end)

describe("without Space Age", function()
    local raw

    before_each(function()
        raw = data_stage.load({ space_age = false }).raw
    end)

    it("keeps the original refrigerator recipe", function()
        -- Arrange
        local recipe = raw.recipe["refrigerater"]

        -- Act / Assert
        assert.are.same(query.set("steel-chest", "electric-engine-unit", "processing-unit",
            "uranium-fuel-cell", "plastic-bar"), query.ingredients(recipe))
    end)

    it("keeps refrigeration an early, red and green science technology", function()
        -- Arrange
        local tech = raw.technology["refrigerater"]

        -- Act / Assert
        assert.are.same(query.set("automation-science-pack", "logistic-science-pack"), query.science(tech))
        assert.are.same(query.set("electric-engine", "processing-unit", "plastics"),
            query.set(table.unpack(tech.prerequisites)))
    end)

    it("builds every logistic refrigerator from a refrigerator and circuits", function()
        for name in pairs(LOGISTIC_FRIDGE_CHESTS) do
            -- Arrange
            local recipe = raw.recipe[name]

            -- Act / Assert
            assert.are.same(query.set("refrigerater", "processing-unit", "advanced-circuit"),
                query.ingredients(recipe), name)
        end
    end)

    it("adds no HFC or cooling coil", function()
        -- Act / Assert
        assert.is_nil(raw.fluid["hfc"])
        assert.is_nil(raw.item["sealed-cooling-coil"])
        assert.is_nil(raw.recipe["hfc"])
        assert.is_nil(raw.recipe["sealed-cooling-coil"])
    end)

    it("adds no cryogenic oil processing", function()
        -- Act / Assert
        assert.is_nil(raw.recipe["cryogenic-oil-processing"])
    end)
end)
