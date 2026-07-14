-- Pure, mutation-free product preview. Founder hooks are intentionally excluded because many mutate state.

local AppTypes = require("game.apptypes")
local Playbooks = require("game.playbooks")
local Coverage = require("game.coverage")
local Archetypes = require("game.archetypes")
local Compat = require("game.compat")
local Markets = require("game.markets")
local Reliability = require("game.reliability")
local AIMaturity = require("game.ai_maturity")
local CardModel = require("game.card")
local TechModifiers = require("game.tech_modifiers")

local Preview = {}

function Preview.evaluate(cards, opts)
  opts = opts or {}
  local app = AppTypes.classify(cards)
  local maturity = AIMaturity.evaluate(cards, app)
  local chips, mult, level = Playbooks.values(app)
  local modifier_budget = {}
  local modifier_effects = { repetitions = 0, played_rev = 0, played_cash = 0, held_rev_mult = 1 }
  for _, card in ipairs(cards or {}) do
    local repetitions = TechModifiers.repetitions(card)
    modifier_effects.repetitions = modifier_effects.repetitions + math.max(0, repetitions - 1)
    for _ = 1, repetitions do
      chips = chips + (card.get_users and card:get_users({ preview = true }) or card.base_users or 0)
      local played = TechModifiers.played_effect(card, modifier_budget)
      mult = mult + (played.mult or 0)
      modifier_effects.played_rev = modifier_effects.played_rev + (played.mult or 0)
      modifier_effects.played_cash = modifier_effects.played_cash + (played.dollars or 0)
      local rs = card.rev_sticker and card:rev_sticker()
      if rs then
        if rs.override ~= nil then mult = rs.override end
        mult = (mult + (rs.add or 0)) * (rs.mul or 1)
      end
    end
  end
  local held_effect = TechModifiers.held_effect(opts.held_cards or {})
  mult = mult * (held_effect.x_mult or 1)
  modifier_effects.held_rev_mult = held_effect.x_mult or 1
  local cash_cow = TechModifiers.ENHANCEMENTS.cash_cow
  modifier_effects.blind_clear_cash = math.min(cash_cow.max_cash_per_blind,
    math.min(held_effect.cash_cow_count or 0, cash_cow.held_cap) * cash_cow.held_cash)
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
  local modifier_items, modifier_index, modified_cards = {}, {}, 0
  for _, card in ipairs(cards or {}) do
    local rows = CardModel.tech_modifier_rows(card)
    if #rows > 0 then modified_cards = modified_cards + 1 end
    for _, row in ipairs(rows) do
      local id = row.kind .. ":" .. tostring(row.key)
      local item = modifier_index[id]
      if not item then
        item = { kind = row.kind, key = row.key, label = row.label, desc = row.desc, count = 0 }
        modifier_index[id], modifier_items[#modifier_items + 1] = item, item
      end
      item.count = item.count + 1
    end
  end
  -- Held modifiers that affect the pending decision belong in the forecast,
  -- even though those cards are not part of the shipped hand.
  for _, card in ipairs(opts.held_cards or {}) do
    for _, row in ipairs(CardModel.tech_modifier_rows(card)) do
      local relevant = row.key == "load_bearing" or row.key == "cash_cow"
      if relevant then
        local id = "held:" .. row.kind .. ":" .. tostring(row.key)
        local item = modifier_index[id]
        if not item then
          item = { kind = row.kind, key = row.key, label = row.label .. " (held)",
            desc = row.desc, count = 0, held = true }
          modifier_index[id], modifier_items[#modifier_items + 1] = item, item
        end
        item.count = item.count + 1
      end
    end
  end
  local modifier_labels = {}
  for _, item in ipairs(modifier_items) do
    modifier_labels[#modifier_labels + 1] = item.label .. (item.count > 1 and (" ×" .. item.count) or "")
  end
  return { app = app, app_level = level, app_identity = AIMaturity.identity(app, maturity),
    ai_maturity = maturity, coverage = Coverage.analyze(cards), stacks = stacks, best_stack = best,
    chips = market_score.chips, mult = market_score.mult, chemistry = chemistry, fit = fit,
    boss_mult = boss_mult, reliability = reliability,
    before_market = before_market, market_rule = market_rule,
    clashes = clashes, substitutes = substitutes, arr = arr,
    tech_modifiers = { modified_cards = modified_cards, items = modifier_items, effects = modifier_effects },
    tech_modifier_summary = table.concat(modifier_labels, " · ") }
end

return Preview
