-- game/runstate.lua — the run-state spine (engine v2 E1). G.GAME as a 4-scope hierarchy
-- (run / ante / blind / round) + the 8-ante × 3-blind funding-stage loop + the ARR target curve.
-- This is the single serialization boundary (G.GAME is plain data; live cards re-hydrate from
-- center_key + ability.config). It owns the economy and Era seams (4 antes = 1 era).

local Meters = require("game.meters")
local Markets = require("game.markets")
local Eras = require("game.eras")
local MarketRules = require("data.gameplay.market_rules")
local Stakes = require("game.stakes")
local Economy = require("game.economy")
local Bosses = require("game.bosses")
local RNG = require("game.rng")
local Leads = require("game.leads")
local TechLaws = require("game.tech_laws")
local Consumables = require("game.consumables")

local RunState = {}

local function normalize_moonshot_state(g)
  local source = type(g.moonshot_state) == "table" and g.moonshot_state or {}
  local function bounded_counter(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then value = 0 end
    return math.max(0, math.min(2, math.floor(value)))
  end
  g.moonshot_state = {
    viral_moment_uses = bounded_counter(source.viral_moment_uses),
    blitzscale_uses = bounded_counter(source.blitzscale_uses),
  }
  return g.moonshot_state
end

-- ARR target curve. Ruleset v2 uses the scaling-1 reconstruction; difficult Stakes add offer constraints
-- and an ante-progressive late curve rather than starting every run on the old scaling-3 table.
RunState.ANTE_BASE  = { 300, 800, 2000, 5000, 11000, 20000, 35000, 50000 }
RunState.BLIND_MULT = { 1.0, 1.5, 2.0 }                 -- Small, Big, Boss
RunState.BLIND_KIND = { "Small", "Big", "Boss" }
RunState.STAGE_NAME = { "Pre-seed", "Seed", "Series A", "Series B", "Series C", "Series D", "Series E", "IPO" }
RunState.SHIPS_PER_BLIND  = 4
RunState.PIVOTS_PER_BLIND = 3
RunState.HAND_SIZE = 8
RunState.WIN_ANTE  = 8

-- P&L constants — PLACEHOLDERS, tune via the balance-sim pass (target IPO win-rate).
RunState.SALARY_DIV     = Economy.SALARY_DIV
RunState.INTEREST_DIV   = 5     -- interest = floor(cash / INTEREST_DIV), per blind cleared
RunState.BANKRUPT_FLOOR = -20   -- early-game credit floor; the LIVE line scales: min(FLOOR, -2×last_payroll) — see settle_blind
RunState.DEFAULT_MARGIN = 0.5
RunState.BLIND_REWARD_UNITS = { 3, 4, 5 }
-- (2026-07-02: vs payroll ≈13% of target, raises cover ~½–1 payroll — keeps the low-margin/blitzscale lane
--  alive on funding + overkill; Balatro-faithful in role: its blinds pay $3/$4/$5 flat in a small economy.)

function RunState.blind_target(ante, blind_idx)
  local base = RunState.ANTE_BASE[ante]
  if not base then  -- endless: steepen past ante 8
    base = RunState.ANTE_BASE[#RunState.ANTE_BASE] * (1.6 ^ (ante - #RunState.ANTE_BASE))
  end
  local stake_mult = (G.GAME and G.GAME.target_mult) or 1.0   -- Funding Stakes ladder
  local late = (G.GAME and G.GAME.late_target_mult) or 1.0
  local progress = math.max(0, math.min(1, ((ante or 1) - 1) / 7))
  stake_mult = stake_mult * (1 + (late - 1) * progress)
  local market_mult = ((MarketRules.for_market(G.GAME and G.GAME.market).economy or {}).target_mult) or 1
  return math.floor(base * (RunState.BLIND_MULT[blind_idx] or 1.0) * stake_mult * market_mult + 0.5)
end

function RunState.apply_stake(g, stake)
  Stakes.apply(g, stake)
end

function RunState.era_for_ante(g, ante)
  g = g or G.GAME
  local path = g and g.initial_era_path
  if not path then path = MarketRules.for_market(g and g.market).era_path end -- old-save fallback
  return Eras.for_ante({ era_path = path }, ante)
end

-- set the current (ante, blind_idx): target from curve, reset per-blind counters, bump scope ids.
function RunState.set_blind(ante, blind_idx)
  local g = G.GAME
  g.ante, g.blind_idx = ante, blind_idx
  g.era = RunState.era_for_ante(g, ante)
  g._bid = (g._bid or 0) + 1                             -- per-blind once-gate id
  if blind_idx == 1 then g._aid = (g._aid or 0) + 1 end  -- per-ante once-gate id (bumps each new ante)
  if blind_idx == 1 then TechLaws.on_ante_start(g, ante) end
  g.blind = {
    kind = RunState.BLIND_KIND[blind_idx], idx = blind_idx, ante = ante,
    stage = RunState.STAGE_NAME[ante] or ("Ante " .. ante),
    target = RunState.blind_target(ante, blind_idx),
    is_boss = (blind_idx == 3), modifier = nil,          -- boss modifier (E5)
  }
  Leads.ensure_ante(g, ante)
  local lead = Leads.offer_for(g, blind_idx, ante)
  if lead then
    g.blind.lead_key = lead.key
    g.blind.lead_offer = lead
  end
  if blind_idx == 3 then                                  -- telegraphed market-event boss
    local ev = { "ai_winter", "platform_shift", "dotcom_bust" }
    g.blind.event = (g.boss_sequence and g.boss_sequence[ante]) or ev[((ante - 1) % #ev) + 1]
  end
  g.cumulative_arr, g.this_blind_arr = 0, 0
  g.best_ship_arr, g.best_ship_margin, g.market_best_fit = 0, nil, 0
  g.ships_left  = RunState.SHIPS_PER_BLIND + (g.ships_bonus or 0)     -- voucher: Extra Sprint
  g.pivots_left = RunState.PIVOTS_PER_BLIND + (g.pivots_bonus or 0)   -- voucher: DevOps
end

-- advance after a blind win → "won_run" (cleared the final boss) | "next" (a new blind is set).
function RunState.advance()
  local g = G.GAME
  local founder_count = #((G.jokers and G.jokers.cards) or {})
  if g.blind_idx < 3 then
    Markets.commit_pending(g, founder_count)
    RunState.set_blind(g.ante, g.blind_idx + 1)
  elseif g.ante >= RunState.WIN_ANTE then
    return "won_run"
  else
    Markets.commit_pending(g, founder_count)
    RunState.set_blind(g.ante + 1, 1)
  end
  return "next"
end

-- payroll due this blind = Σ(founder salary) × (blind_target / SALARY_DIV) − salary_relief
function RunState.payroll_due()
  return Economy.payroll_due(G.GAME, (G.jokers and G.jokers.cards) or {})
end

-- settle the P&L at a cleared blind: drain payroll, accrue interest, set runway, flag bankruptcy.
function RunState.settle_blind()
  local g = G.GAME
  g.last_payroll = RunState.payroll_due()
  g.cash = g.cash - g.last_payroll
  g.last_interest = 0
  local market_economy = (MarketRules.for_market(g.market).economy or {})
  if g.cash > 0 and not market_economy.no_interest then
    g.last_interest = Economy.interest(g.cash, market_economy.interest_cap or 5)
    g.cash = g.cash + g.last_interest
  end
  g.runway = (g.last_payroll > 0) and math.floor(g.cash / g.last_payroll) or 99
  -- credit line SCALES with the economy (≈2 payrolls of runway) — a fixed -20 was instant death at ante-7
  -- scale (payroll ~tens of thousands). From cash 0 a single payroll can never bankrupt you (-P > -2P);
  -- bankruptcy now requires sustained deficit, and `runway` telegraphs it. (Balatro Credit-Card analogue, scaled.)
  g.credit_line = math.min(RunState.BANKRUPT_FLOOR, -2 * g.last_payroll)
  g.bankrupt = g.cash < g.credit_line
  return g.bankrupt
end

-- apply a Market's unconditional perk (E5, light — full perk system is a later pass).
function RunState.apply_perk(m)
  Markets.apply_perk(G.GAME, m, 1)
end

function RunState.new(opts)
  opts = opts or {}
  G.GAME = {
    -- RUN scope ----------------------------------------------------------------
    seed = opts.seed or tostring(os.time()), rng_streams = {}, ruleset_version = MarketRules.ruleset_version,
    ante = 1, era = 1, _bid = 0, _aid = 0,
    round_num = 0, ships_this_run = 0,
    cash = opts.cash or 4,
    margin_bonus = 0, salary_relief = 0, overkill = 0,
    last_income = 0, last_payroll = 0, last_interest = 0, runway = 99, bankrupt = false,
    won = nil, result = nil,
    meters = {},                                          -- threshold-counter primitive (meters.lua)
    layers_seen_run = {}, app_types_shipped_run = {},     -- run sets (E3)
    run_best_arr = 0,
    master_deck = {}, _deck_uid = 0, _deck_seeded = false, deck_thinned = {},   -- persistent run-owned tech deck (Track C A)
    consumables = {}, consumable_slots = 2, consumable_next_id = 0,              -- consumable inventory (Track C B)
    tech_law_state = {}, last_ship_app_key = nil, last_ship_coverage = 0,
    moonshot_state = { viral_moment_uses = 0, blitzscale_uses = 0 },
    last_shipped_app_key = nil, last_shipped_distinct_layers = 0,
    -- maturity / equity seams (E4) -------------------------------------------
    maturity_rung = 1, leverage_mult = 1,
    equity_pct = 100, valuation = 0, ipo_value = 0, automated_founders = {}, raises_taken = 0, last_raise_ante = 0,
    founder_next_id = 0,
    founder_negotiation_seen = {}, founder_negotiation_next_id = 0,
    app_levels = {}, tech_drafts_taken = 0,
    -- BLIND / ROUND scope (filled by set_blind / scoring) --------------------
    blind = nil, blind_idx = 1,
    cumulative_arr = 0, this_blind_arr = 0,
    ships_left = 0, pivots_left = 0,
    hand_size = opts.hand_size or RunState.HAND_SIZE,
    select_max = 5,
    score = { chips = 0, mult = 0, arr = 0 },
    this_ship_arr = 0, scoring_name = nil, this_app = nil,
    _new_app_types = 0, _new_layers = 0, _running_arr = 0, _armed_buffs = {},   -- ability primitives (B/A/D)
    founders_hired_run = 0, markets_seen_run = {}, _last_hand_ndl = 0, _passives = {}, passive_salary = 0,   -- ability primitives (1.5a/b)
    pending_dollars = 0,
    hire_idx = 0, pivot_count = 0, discard_count = 0,
    -- SHOP scope + voucher run-modifiers -------------
    shop = nil, shop_founder_slots = 2, shop_pack_slots = 2, founder_slots = 5,
    pending_market = nil, pending_market_founder_cap = nil, pending_market_assets = nil,
    market_assets_granted = {}, market_best_fit = 0, initial_era_path = nil,
    ships_bonus = 0, pivots_bonus = 0, reroll_discount = 0, shop_discount = 0,
    vouchers_owned = {},
    lead_offers = {}, lead_queue = {}, lead_history = {}, lead_next_id = 0,
    -- Funding Stakes ladder ---------------------------------------
    stake = opts.stake or 1, target_mult = 1.0, salary_div_override = nil,
  }
  RunState.apply_stake(G.GAME, opts.stake or 1)          -- apply stake mods BEFORE the first blind target
  G.GAME.boss_sequence = Bosses.sequence(tonumber(opts.seed) or 0)
  RunState.set_blind(1, 1)
  Meters.def("tech_debt", { thresholds = { 3, 6, 10, 15 } })          -- E3 redundancy/clash debt → drag
  Meters.def("rung_progress", { thresholds = { 4, 10, 20, 34, 52 } }) -- E4 maturity ladder (tier→rung)
  Meters.def("knowledge_charge", { thresholds = { 3, 6, 10 } })       -- E4 KE/MSG seasoning
  Meters.def("hype", { decay_per_round = 2, thresholds = { 5, 12, 25 } })          -- E4 volatile rep
  Meters.def("credibility", { monotonic = true, thresholds = { 4, 10, 20 } })      -- E4 durable rep
  Meters.def("moat", { monotonic = true, thresholds = { 3, 8, 16 } })              -- E4 defense
  Meters.def("oss_lean", { min = -50, thresholds = { 3, 8, 16 } })                 -- E4 OSS↔proprietary
  G.GAME.market_choices = Markets.offers(3, RNG.fn("market"))
  if opts.market_id then
    local market = Markets.by_id(opts.market_id)
    if market then
      Markets.select(G.GAME, market, { initial = true })
      G.GAME.era = RunState.era_for_ante(G.GAME, G.GAME.ante)
      G.GAME.blind.target = RunState.blind_target(G.GAME.ante, G.GAME.blind_idx)
    end
  end
end

-- serialization boundary (G.GAME is plain data minus transient display; cards rehydrate elsewhere).
function RunState.serialize()
  local g, out = G.GAME, {}
  require("game.founder_lifecycle").normalize_ids(g)
  require("game.founder_negotiation").normalize(g)
  TechLaws.normalize(g)
  normalize_moonshot_state(g)
  Consumables.normalize(g)
  for k, v in pairs(g) do
    if k ~= "score" and k ~= "this_app" then out[k] = v end
  end
  return out
end

function RunState.deserialize(t)
  G.GAME = t
  -- The current authored ruleset owns normalization from older plain-data run
  -- snapshots. Consumable normalization below safely drops malformed payloads.
  G.GAME.ruleset_version = MarketRules.ruleset_version
  G.GAME.master_deck = G.GAME.master_deck or {}
  G.GAME.lead_offers = G.GAME.lead_offers or {}
  G.GAME.lead_queue = G.GAME.lead_queue or {}
  G.GAME.lead_history = G.GAME.lead_history or {}
  G.GAME.lead_next_id = G.GAME.lead_next_id or 0
  Leads.normalize(G.GAME)
  Leads.ensure_ante(G.GAME, G.GAME.ante)
  if G.GAME.blind and (G.GAME.blind_idx == 1 or G.GAME.blind_idx == 2) then
    local lead = Leads.offer_for(G.GAME, G.GAME.blind_idx, G.GAME.ante)
    G.GAME.blind.lead_key = lead and lead.key or nil
    G.GAME.blind.lead_offer = lead
  end
  G.GAME.score = { chips = 0, mult = 0, arr = 0 }
  TechLaws.normalize(G.GAME)
  normalize_moonshot_state(G.GAME)
  Consumables.normalize(G.GAME)
  require("game.founder_negotiation").normalize(G.GAME)
  require("game.founder_lifecycle").normalize_ids(G.GAME)
  if G.consumables then Consumables.rehydrate(G.GAME) end
end

return RunState
