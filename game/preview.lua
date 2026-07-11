-- Pure, mutation-free product preview. Founder hooks are intentionally excluded because many mutate state.

local AppTypes = require("game.apptypes")
local Playbooks = require("game.playbooks")
local Coverage = require("game.coverage")
local Archetypes = require("game.archetypes")
local Compat = require("game.compat")
local Markets = require("game.markets")
local Reliability = require("game.reliability")

local Preview = {}

function Preview.evaluate(cards)
  local app = AppTypes.classify(cards)
  local chips, mult, level = Playbooks.values(app)
  for _, card in ipairs(cards or {}) do chips = chips + (card.get_users and card:get_users({ preview = true }) or card.base_users or 0) end
  local stacks, best = Archetypes.evaluate(cards)
  if best and best.complete then chips, mult = chips + best.users, mult + best.rev end
  local clashes, substitutes = #Compat.clashes(cards), #Compat.substitutes(cards)
  mult = mult * (0.9 ^ clashes)
  local chemistry = 1 + math.min(0.02 * math.floor(Compat.complement_score(cards)), 0.5)
  local fit = Markets.fit_mult(cards, G.GAME and G.GAME.market)
  local reliability = Reliability.evaluate(cards, { boss = G.GAME and G.GAME.blind and G.GAME.blind.event,
    mitigation = G.GAME and G.GAME.reliability_bonus or 0 })
  local arr = math.floor(chips * mult * chemistry * fit * reliability.multiplier + 0.5)
  return { app = app, app_level = level, coverage = Coverage.analyze(cards), stacks = stacks, best_stack = best,
    chips = chips, mult = mult, chemistry = chemistry, fit = fit, reliability = reliability,
    clashes = clashes, substitutes = substitutes, arr = arr }
end

return Preview
