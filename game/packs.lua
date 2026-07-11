local Definitions = require("data.gameplay.packs")
local Packs = { definitions = Definitions }

function Packs.get(key) return Definitions[key] end

function Packs.roll_modifier(rng)
  rng = rng or love.math.random
  local x = rng()
  if x >= 0.05 then return nil end
  if x < 0.003 then return "viral" end
  if x < 0.018 then return "battle_tested" end
  return "open_source"
end

return Packs
