for i, force in pairs(game.forces) do
  if force.technologies["agricultural-science-pack"].researched then
    force.recipes["refrigerater"].enabled = true
  else
    force.recipes["refrigerater"].enabled = false
  end
end
