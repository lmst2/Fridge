for i, force in pairs(game.forces) do
  if force.technologies["agricultural-science-pack"].researched then
    force.recipes["refrigerator"].enabled = true
  else
    force.recipes["refrigerator"].enabled = false
  end
end
