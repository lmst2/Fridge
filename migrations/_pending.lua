-- Restore the Space Freezing Warehouse (Freezing Cargo Bay) for existing saves.
--
-- Up to 0.2.x the "preservation-platform-warehouse" recipe was unlocked by the
-- base game's "space-platform" technology. In 0.3.0 that unlock moved to a new
-- dedicated "preservation-platform-warehouse" technology, without a migration.
-- When an older save is loaded, Factorio resets each recipe to its prototype
-- default (here: disabled) and only re-applies the effects of the technologies
-- that are actually researched. Players who had unlocked the cargo bay through
-- "space-platform" therefore lose it - it stays available only in the editor.
--
-- Mirror the old unlock: re-enable the recipe for any force that has already
-- researched "space-platform". Guarded throughout so it is a harmless no-op
-- without Space Age, where neither the recipe nor the technology exist.
for _, force in pairs(game.forces) do
  local recipe = force.recipes["preservation-platform-warehouse"]
  local space_platform = force.technologies["space-platform"]
  if recipe and not recipe.enabled and space_platform and space_platform.researched then
    recipe.enabled = true
  end
end
