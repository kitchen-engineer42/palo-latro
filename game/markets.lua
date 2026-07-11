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

function Markets.apply_perk(g, market, sign)
  sign = sign or 1
  for _, op in ipairs(Rules.for_market(market).perk_ops or {}) do
    local amount = (op.amount or 0) * sign
    if op.op == "ships_per_blind" then g.ships_bonus = (g.ships_bonus or 0) + amount
    elseif op.op == "pivots_per_blind" then g.pivots_bonus = (g.pivots_bonus or 0) + amount
    elseif op.op == "founder_slots" then g.founder_slots = math.max(1, (g.founder_slots or 5) + amount)
    elseif op.op == "hand_size" then g.hand_size = math.max(1, (g.hand_size or 8) + amount)
    elseif op.op == "starting_cash_units" and sign > 0 then
      local Economy = require("game.economy")
      local RunState = require("game.runstate")
      g.cash = (g.cash or 0) + amount * Economy.unit(g, RunState.ANTE_BASE)
    elseif op.op == "free_voucher" and sign > 0 then g.free_voucher_pending = true
    end
  end
end

function Markets.select(g, market)
  if g.market then Markets.apply_perk(g, g.market, -1) end
  g.market = market
  g.markets_seen_run = g.markets_seen_run or {}
  g.markets_seen_run[market.id] = true
  Markets.apply_perk(g, market, 1)
  return market
end

return Markets
