-- game/compat.lua — runtime tech compatibility over the played hand. Clashes feed a
-- scoring haircut + tech-debt; substitutes = redundancy/tech-debt; complement weight feeds E4 chemistry.
local C = require("data.centers.compat_gen")
local Suppression = require("game.compat_suppression")
local Compat = {}

local function bare(card)
  local k = card.center_key or card.key or (card.center and card.center.key) or ""
  return (k:gsub("^t_", ""))
end
local function pk(a, b) if a <= b then return a .. "|" .. b else return b .. "|" .. a end end

local function well_formed(card)
  return card and type(card.law_marks) == "table" and card.law_marks.well_formed == true
end

local function pairs_in(played, set, game, suppress_clashes)
  local out = {}
  for i = 1, #played do
    for j = i + 1, #played do
      local edge = pk(bare(played[i]), bare(played[j]))
      if not well_formed(played[i]) and not well_formed(played[j]) and set[edge]
          and not (suppress_clashes and Suppression.is_suppressed(game or (G and G.GAME), edge)) then
        out[#out + 1] = { played[i], played[j] }
      end
    end
  end
  return out
end

function Compat.clashes(played, game) return pairs_in(played, C.clashes, game, true) end
function Compat.substitutes(played) return pairs_in(played, C.substitutes, nil, false) end

-- sum of complement-edge weights among played pairs (E4 live-chemistry coherence)
function Compat.complement_score(played)
  local s = 0
  for i = 1, #played do
    for j = i + 1, #played do
      s = s + (C.complements[pk(bare(played[i]), bare(played[j]))] or 0)
    end
  end
  return s
end

return Compat
