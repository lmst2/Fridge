local data_stage = require("spec.support.data_stage")
local control_stage = require("spec.support.control_stage")

-- An entity the player can place from one of this mod's items.
local function placeable_entities(added)
    local placed, entities = {}, {}
    for _, prototype in pairs(added) do
        if prototype.place_result then placed[prototype.place_result] = true end
    end
    for _, prototype in pairs(added) do
        if placed[prototype.name] and prototype.type ~= "item" then entities[#entities + 1] = prototype end
    end
    return entities
end

for _, space_age in pairs({ true, false }) do
    describe("preservation tracking (space_age = " .. tostring(space_age) .. ")", function()
        it("preserves every entity a player can place from this mod", function()
            -- Arrange
            local added = data_stage.load({ space_age = space_age }).added
            local entities = placeable_entities(added)

            -- Act
            local tracked = control_stage.tracked_on_build(entities)

            -- Assert
            for _, entity in pairs(entities) do
                assert.is_true(tracked[entity.name], entity.name)
            end
        end)
    end)
end
