-- Pure, mutation-free product preview. Founder hooks are intentionally excluded because many mutate state.

local AppTypes = require("game.apptypes")
local Playbooks = require("game.playbooks")
local Coverage = require("game.coverage")
local Archetypes = require("game.archetypes")
local Compat = require("game.compat")
local Markets = require("game.markets")
local Reliability = require("game.reliability")
local AIMaturity = require("game.ai_maturity")

local Preview = {}

function Preview.evaluate(cards)
  local app = AppTypes.classify(cards)
  local maturity = AIMaturity.evaluate(cards, app)
  local chips, mult, level = Playbooks.values(app)
  for _, card in ipairs(cards or {}) do chips = chips + (card.get_users and card:get_users({ preview = true }) or card.base_users or 0) end
  local clashes, substitutes = #Compat.clashes(cards), #Compat.substitutes(cards)
  for _, card in ipairs(cards or {}) do
    local center = card.center or card
    if center.clears_clash then clashes = 0; break end
  end
  mult = mult * (0.9 ^ clashes)
  local chemistry = 1 + math.min(Markets.compatibility_per_point(G.GAME and G.GAME.market)
    * math.floor(Compat.complement_score(cards)), 0.5)
  mult = mult * chemistry
  chips, mult = AIMaturity.apply(chips, mult, maturity)
  local stacks, best = Archetypes.evaluate(cards)
  if best and best.complete then chips, mult = chips + best.users, mult + best.rev end
  local fit = Markets.fit_mult(cards, G.GAME and G.GAME.market)
  local boss_key = G.GAME and G.GAME.blind and G.GAME.blind.event
  local boss_mult = require("game.bosses").score_multiplier(boss_key, cards, { fit = fit })
  local reliability = Reliability.evaluate(cards, { boss = G.GAME and G.GAME.blind and G.GAME.blind.event,
    mitigation = G.GAME and G.GAME.reliability_bonus or 0 })
  reliability.score = math.max(0, reliability.score + Markets.reliability_bonus(G.GAME and G.GAME.market))
  reliability.multiplier = 0.50 + 0.05 * reliability.score
  local market_score = { chips = chips, mult = mult * fit * boss_mult }
  local before_market, _, market_rule = Markets.apply_score_perk(market_score, G.GAME and G.GAME.market,
    { max_users = 10000000, max_revenue = 100000 })
  local arr = math.floor(market_score.chips * market_score.mult * reliability.multiplier + 0.5)
  return { app = app, app_level = level, app_identity = AIMaturity.identity(app, maturity),
    ai_maturity = maturity, coverage = Coverage.analyze(cards), stacks = stacks, best_stack = best,
    chips = market_score.chips, mult = market_score.mult, chemistry = chemistry, fit = fit,
    boss_mult = boss_mult, reliability = reliability,
    before_market = before_market, market_rule = market_rule,
    clashes = clashes, substitutes = substitutes, arr = arr }
end

return Preview
