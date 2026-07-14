local Definitions = require("data.gameplay.packs")
local Packs = { definitions = Definitions }

function Packs.get(key) return Definitions[key] end

function Packs.all()
  local out = {}
  for _, p in pairs(Definitions) do out[#out + 1] = p end
  table.sort(out, function(a, b) return a.order < b.order end)
  return out
end

-- Weighted, deterministic shop poll. `excluded` prevents the two visible slots
-- from ever being the exact same cover; families may still repeat naturally.
function Packs.roll_shop(rng, excluded)
  rng = rng or love.math.random
  local pool, total = {}, 0
  for _, p in ipairs(Packs.all()) do
    if not (excluded and excluded[p.key]) then
      total = total + (p.weight or 1)
      pool[#pool + 1] = p
    end
  end
  if total <= 0 then return nil end
  local roll = rng() * total
  for _, p in ipairs(pool) do
    roll = roll - (p.weight or 1)
    if roll <= 0 then return p end
  end
  return pool[#pool]
end

function Packs.roll_modifier(rng)
  rng = rng or love.math.random
  local x = rng()
  if x >= 0.05 then return nil end
  if x < 0.003 then return "viral" end
  if x < 0.018 then return "battle_tested" end
  return "open_source"
end

return Packs
