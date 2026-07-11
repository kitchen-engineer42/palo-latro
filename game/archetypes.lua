local Definitions = require("data.gameplay.archetypes")

local Archetypes = { list = Definitions }

local function roles(cards)
  local have = {}
  for _, card in ipairs(cards or {}) do
    local center = card.center or card
    if center.sub_role then have[center.sub_role] = true end
    for _, spec in ipairs(center.layers or {}) do if spec.sub_role then have[spec.sub_role] = true end end
  end
  return have
end

function Archetypes.evaluate(cards)
  local have, out, best = roles(cards), {}, nil
  for _, def in ipairs(Definitions) do
    local matched, missing = 0, {}
    for _, role in ipairs(def.roles) do
      if have[role] then matched = matched + 1 else missing[#missing + 1] = role end
    end
    local result = { key = def.key, name = def.name, matched = matched, total = #def.roles,
                     complete = matched == #def.roles, missing = missing,
                     users = def.users, rev = def.rev }
    out[#out + 1] = result
    if not best or result.matched / result.total > best.matched / best.total then best = result end
  end
  return out, best
end

return Archetypes
