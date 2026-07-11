local Compat = require("game.compat")
local Bosses = require("game.bosses")

local Reliability = { BASE = 10 }

function Reliability.evaluate(cards, context)
  context = context or {}
  local clashes = #Compat.clashes(cards or {})
  local substitutes = #Compat.substitutes(cards or {})
  local debt = ((G.GAME and G.GAME.meters and G.GAME.meters.tech_debt) or {}).value or 0
  local breadth = math.max(0, #(cards or {}) - 3) * 5
  local penalty = breadth + clashes * 2 + substitutes + math.floor(debt / 3)
  penalty = penalty + Bosses.reliability_penalty(context.boss, cards, { clashes = clashes })
  local mitigation = context.mitigation or 0
  local score = math.max(0, math.min(Reliability.BASE, Reliability.BASE - penalty + mitigation))
  return { score = score, max = Reliability.BASE, penalty = penalty, mitigation = mitigation,
           multiplier = 0.50 + 0.05 * score, clashes = clashes, substitutes = substitutes, breadth = breadth }
end

return Reliability
