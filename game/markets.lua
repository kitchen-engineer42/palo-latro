-- game/markets.lua — Market identity + Fit-as-earned-mult. A run picks a Market (audience ×
-- industry × architecture); Fit = how well the played stack serves the demanded scenario, scored via the
-- compat graph's scenario_fit. Fit is the EARNED multiplier; the perk is the unconditional given.
local M = require("data.centers.markets_gen")
local Coverage = require("game.coverage")
local Rules = require("data.gameplay.market_rules")
local RATING = { great = 1, ok = 0, poor = -1 }

local Markets = {}
Markets.list = M.markets

local function bare(card) return (((card.center and card.center.key) or ""):gsub("^t_", "")) end
function Markets.rules(m) return Rules.for_market(m) end
function Markets.scenario(m) return Rules.for_market(m).scenario_id end
function Markets.by_id(id) for _, m in ipairs(M.markets) do if m.id == id then return m end end end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

-- The one public projection used by UI, collection, and headless mimic. It is
-- deliberately sourced from authored gameplay rules, never generated perk prose.
function Markets.view(market)
  if not market then return nil end
  local rules = Rules.for_market(market)
  local fit_solution, fit_industry = tostring(rules.scenario_id or ""):match("^(.-)%-(.+)$")
  return {
    id = market.id, name = market.name,
    audience = market.audience, industry = fit_industry,
    solution = fit_solution,
    fit = { scenario_id = rules.scenario_id, label = rules.fit_label,
      solution = fit_solution, industry = fit_industry },
    perk = copy(rules.perk),
    start_era = rules.start_era, starter_size = rules.starter_size,
    score = copy(rules.score), economy = copy(rules.economy),
    constraints = copy(rules.constraints),
  }
end

function Markets.compatibility_per_point(market)
  return (Rules.for_market(market).score or {}).compatibility_per_point or 0.02
end

function Markets.margin_bonus(app, market, context)
  local bonus = (Rules.for_market(market).economy or {}).ai_margin_bonus or 0
  local key = app and app.key or ""
  local ai_app = key:find("^apt_ai_") ~= nil
  local ai_moonshot = key == "apt_moonshot" and context and context.ai_backed == true
  return (ai_app or ai_moonshot) and bonus or 0
end

function Markets.reliability_bonus(market)
  return (Rules.for_market(market).score or {}).reliability_bonus or 0
end

-- Signature score transforms happen after Fit/Boss Revenue effects and before
-- Reliability and ARR. Plasma therefore averages the fully-built lanes, as the
-- Balatro deck it echoes does, rather than averaging base values prematurely.
function Markets.apply_score_perk(score, market, limits)
  local rule = Rules.for_market(market).score or {}
  local before = { chips = score.chips, mult = score.mult }
  if rule.revenue_mult then score.mult = score.mult * rule.revenue_mult end
  if rule.balance_lanes then
    local average = (score.chips + score.mult) / 2
    if limits then average = math.min(average, limits.max_users or average, limits.max_revenue or average) end
    score.chips, score.mult = average, average
  end
  if rule.revenue_cap then score.mult = math.min(score.mult, rule.revenue_cap) end
  return before, { chips = score.chips, mult = score.mult }, rule
end

function Markets.high_fit_reward(g, ante_base)
  local economy = Rules.for_market(g and g.market).economy or {}
  if not economy.high_fit_floor or (g.market_best_fit or 0) < economy.high_fit_floor then return 0 end
  local Economy = require("game.economy")
  return (economy.high_fit_reward_units or 0) * Economy.unit(g, ante_base)
end

function Markets.earns_high_fit_lead(g)
  local economy = Rules.for_market(g and g.market).economy or {}
  return economy.high_fit_lead == true
    and (g.market_best_fit or 0) >= (economy.high_fit_floor or math.huge)
end

function Markets.can_free_distill(g)
  local count = (Rules.for_market(g and g.market).economy or {}).free_distill_per_ante or 0
  return count > 0 and g.market_distill_used_ante ~= g.ante
end

function Markets.active_state(g)
  if not g then return {} end
  local rules = Rules.for_market(g.market)
  return {
    free_distill_ready = ((rules.economy or {}).free_distill_per_ante or 0) > 0
      and Markets.can_free_distill(g) or false,
    free_distill_used_ante = g.market_distill_used_ante,
    best_fit_this_blind = g.market_best_fit or 0,
    pending_market_id = g.pending_market and g.pending_market.id or nil,
    last_reward = g.last_market_reward or 0,
    last_lead = g.last_market_lead and g.last_market_lead.key or nil,
  }
end

function Markets.fulfill_initial(g)
  if not (g and g.pending_market_assets and g.market and g.pending_market_assets == g.market.id) then return false end
  g.market_assets_granted = g.market_assets_granted or {}
  if g.market_assets_granted[g.market.id] then g.pending_market_assets = nil; return false end
  local assets = Rules.for_market(g.market).initial_assets or {}
  if assets.playbook then require("game.playbooks").upgrade(assets.playbook, assets.playbook_levels or 1) end
  if assets.consumable then require("game.consumables").grant(assets.consumable) end
  local discovered = {}
  if assets.playbook then discovered[#discovered + 1] = assets.playbook end
  if assets.consumable then discovered[#discovered + 1] = assets.consumable end
  if #discovered > 0 then require("game.profile").discover_many(discovered) end
  g.market_assets_granted[g.market.id] = true
  g.pending_market_assets = nil
  return assets.playbook ~= nil or assets.consumable ~= nil
end

-- fit multiplier in ~[0.88, 1.12]: average scenario_fit rating of played cards vs the Market's demand
function Markets.fit_mult(played, market)
  if not market then return 1 end
  local scen = Markets.scenario(market)
  local sum, n = 0, 0
  for _, c in ipairs(played) do
    local row = M.scenario_fit[bare(c)]
    local r = row and row[scen]
    if r then sum = sum + (RATING[r] or 0); n = n + 1 end
  end
  if n == 0 then return 1 end
  return 1 + 0.12 * (sum / n)
end

-- boss "market event" penalty: a telegraphed shock applied to the Ship's mult
function Markets.event_mult(played, event)
  if not event then return 1 end
  local analysis = Coverage.analyze(played)
  local function has(layer) return Coverage.has_layer(played, layer, analysis) end
  if event == "ai_winter" then return has("AI") and 0.7 or 1 end          -- AI cards lose their shine
  if event == "platform_shift" then return has("Infra") and 0.7 or 1 end  -- the infra ground moves
  if event == "dotcom_bust" then return 0.85 end                          -- broad valuation haircut
  return 1
end

function Markets.pick(rng)
  rng = rng or love.math.random
  local starts = {}
  for _, m in ipairs(M.markets) do if m.unlock == "start" then starts[#starts + 1] = m end end
  local pool = (#starts > 0) and starts or M.markets
  return pool[rng(#pool)]
end

function Markets.offers(count, rng, include_all)
  count, rng = count or 3, rng or love.math.random
  local pool = {}
  for _, m in ipairs(M.markets) do
    local rule = Rules.for_market(m)
    if include_all or rule.start_available then pool[#pool + 1] = m end
  end
  table.sort(pool, function(a, b) return a.id < b.id end)
  local out = {}
  while #out < count and #pool > 0 do
    local i = math.floor(rng() * #pool) + 1
    out[#out + 1] = table.remove(pool, math.max(1, math.min(#pool, i)))
  end
  return out
end

function Markets.apply_perk(g, market, sign, opts)
  sign = sign or 1
  opts = opts or {}
  for _, op in ipairs(Rules.for_market(market).perk_ops or {}) do
    local amount = (op.amount or 0) * sign
    if op.op == "ships_per_blind" then g.ships_bonus = (g.ships_bonus or 0) + amount
    elseif op.op == "pivots_per_blind" then g.pivots_bonus = (g.pivots_bonus or 0) + amount
    elseif op.op == "founder_slots" then g.founder_slots = math.max(1, (g.founder_slots or 5) + amount)
    elseif op.op == "hand_size" then g.hand_size = math.max(1, (g.hand_size or 8) + amount)
    elseif op.op == "starting_cash_units" and sign > 0 and opts.initial then
      local Economy = require("game.economy")
      local RunState = require("game.runstate")
      g.cash = (g.cash or 0) + amount * Economy.unit(g, RunState.ANTE_BASE)
    elseif op.op == "free_voucher" and sign > 0 and opts.initial then g.free_voucher_pending = true
    end
  end
end

local function perk_total(market, op_name)
  local total = 0
  for _, op in ipairs(Rules.for_market(market).perk_ops or {}) do
    if op.op == op_name then total = total + (op.amount or 0) end
  end
  return total
end

-- Pure admission projection: remove the active Market's slot delta, apply the
-- destination delta, and preserve every non-Market slot modifier already in g.
function Markets.destination_founder_cap(g, market)
  if not (g and market) then return nil end
  local base = (g.founder_slots or 5) - perk_total(g.market, "founder_slots")
  return math.max(1, base + perk_total(market, "founder_slots"))
end

function Markets.can_queue(g, market, owned_founders)
  local cap = Markets.destination_founder_cap(g, market)
  if not cap then return false, "Market destination is unavailable", nil end
  if owned_founders == nil and G and g == G.GAME and G.jokers and G.jokers.cards then
    owned_founders = #G.jokers.cards
  end
  if type(owned_founders) ~= "number" or owned_founders < 0 then
    return false, "owned Founder count is required", cap
  end
  if owned_founders > cap then
    return false, ("Destination supports %d Founders; fire %d first"):format(cap, owned_founders - cap), cap
  end
  return true, nil, cap
end

function Markets.select(g, market, opts)
  opts = opts or {}
  if g.market then Markets.apply_perk(g, g.market, -1) end
  g.market = market
  g.markets_seen_run = g.markets_seen_run or {}
  g.markets_seen_run[market.id] = true
  Markets.apply_perk(g, market, 1, opts)
  if opts.initial then
    g.pending_market_assets = market.id
    if not g.initial_era_path then g.initial_era_path = copy(Rules.for_market(market).era_path) end
  end
  return market
end


function Markets.queue(g, market, owned_founders)
  if not (g and market) then return false end
  local allowed, reason, cap = Markets.can_queue(g, market, owned_founders)
  if not allowed then return false, reason, cap end
  g.pending_market = market
  g.pending_market_founder_cap = cap
  return true, nil, cap
end

function Markets.commit_pending(g, owned_founders)
  local market = g and g.pending_market
  if not market then return false end
  local allowed, reason = Markets.can_queue(g, market, owned_founders)
  if not allowed then return false, reason end
  g.pending_market = nil
  g.pending_market_founder_cap = nil
  Markets.select(g, market)
  return market
end

return Markets
