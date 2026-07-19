-- game/round.lua — the single-blind run: build the run state + card areas, deal, and cash out a
-- ship into cumulative ARR with win/lose. Economy (Income=Margin×ARR/Cash/Salary), shop, and
-- antes are seams here (pending_dollars collected; ROUND_EVAL is the payout point).

local Centers = require("game.centers")
local StateMachine = require("game.statemachine")
local Audio = require("game.audio")
local RunState = require("game.runstate")
local Scoring = require("game.scoring")
local Shop = require("game.shop")
local Juice = require("game.juice")
local Deck = require("game.deck")
local Economy = require("game.economy")
local Eras = require("game.eras")
local RNG = require("game.rng")
local Profile = require("game.profile")
local Guidance = require("game.guidance")
local TechLifecycle = require("game.tech_lifecycle")
local TechModifiers = require("game.tech_modifiers")
local Leads = require("game.leads")
local DeckTransactions = require("game.deck_transactions")

local Round = {}

function Round.start_run(opts)
  opts = opts or {}
  local W, H = G.WINDOW.w, G.WINDOW.h
  RunState.new(opts)                                     -- the 4-scope run state + ante/blind loop
  G.GAME.tutorial_script = opts.tutorial_script
  G.GAME.tutorial_market_id = opts.tutorial_market_id
  Guidance.emit("run_started", { script = opts.tutorial_script })

  -- Balatro layout (P3): LEFT = counter column (drawn by ui.lua, x 0..328); RIGHT = play area.
  -- jokers top-left of the play zone, played cards centre, hand bottom, deck bottom-right corner.
  local PX = 352                                          -- left edge of the play zone (right of the panel)
  -- the hand gets the full bottom width (Ship/Pivot live in a right column above the deck, not beside the hand)
  -- so 8 big cards overlap less (more of each visible) and the spacing stays adaptive (fewer cards → spread out)
  G.jokers = CardArea({ type = "jokers", card_limit = 5, T = { x = PX, y = 30,  w = 800, h = Card.FH } })  -- fits the bigger founder card (full-bleed)
  G.play   = CardArea({ type = "play",   card_limit = 5, T = { x = PX, y = 300, w = 760, h = Card.H } })
  G.hand   = CardArea({ type = "hand",   card_limit = 8, T = { x = PX - 8, y = H - Card.H - 62, w = 880, h = Card.H } })  -- lifted: Ship·Sort·Pivot row sits under it (Balatro bottom-mid)
  G.deck   = CardArea({ type = "deck",   T = { x = W - Card.W - 16, y = H - Card.H - 18, w = Card.W, h = Card.H } })
  G.consumables = CardArea({ type = "consumables", card_limit = G.GAME.consumable_slots or 2,
                             T = { x = W - 244, y = 24, w = 220, h = Card.H } })   -- Track C B1 (the reserved top-right region)
  require("game.markets").fulfill_initial(G.GAME)

  if G.GAME.market then
    Profile.discover(G.GAME.market.id, false)
    Round.seed_master_deck()
    StateMachine.set_state(G.STATES.BLIND_SELECT)
  else
    local market_ids = {}
    for _, market in ipairs(G.GAME.market_choices or {}) do market_ids[#market_ids + 1] = market.id end
    Profile.discover_many(market_ids)
    StateMachine.set_state(G.STATES.MARKET_SELECT)
    Guidance.emit("market_choices_shown", { choices = market_ids })
  end
end

-- between blinds: materialize the persistent deck, redraw, and fire blind hooks (post-boss drafts
-- are handled by the TECH_DRAFT state rather than inside this transition)
function Round.next_blind()
  for i = #G.hand.cards, 1, -1 do local c = G.hand.cards[i]; G.hand:remove_card(c, true); c:remove() end
  for i = #G.deck.cards, 1, -1 do local c = G.deck.cards[i]; G.deck:remove_card(c, true); c:remove() end
  Round.build_deck()
  G.GAME.cash_spent_round, G.GAME.founders_hired_round, G.GAME.pivots_round = 0, 0, 0
  Scoring.fire_hook("setting_blind")
  Round.deal_to_full()
  Scoring.fire_hook("first_hand_drawn")
  StateMachine.set_state(G.STATES.SELECTING_HAND)
  Guidance.emit("blind_started", {
    ante = G.GAME.ante, blind_idx = G.GAME.blind_idx, boss = G.GAME.blind and G.GAME.blind.event,
  })
end

function Round.restart()
  G.MIMIC_HEADLESS = false
  StateMachine.prep_stage(G.STAGES.RUN, G.STATES.SELECTING_HAND)
  Round.start_run()
end

-- generation API (E3): a founder `gen` op creates cards / modifies hand size mid-run.
function G.GENERATE(kind, opts)
  opts = opts or {}
  if kind == "hand_size" then
    local amount = tonumber(opts.amount == nil and 1 or opts.amount)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
      return { ok=false, reason="Hand-size generation amount must be finite", requested=0,
        applied=0, changes={}, added_uids={}, removed_uids={} }
    end
    amount = math.floor(amount)
    local before = G.GAME.hand_size or 8
    G.GAME.hand_size = math.max(1, before + amount)
    local applied = G.GAME.hand_size - before
    return { ok=true, requested=amount, applied=applied, added_uids={}, removed_uids={},
      changes={{ kind="hand_size", amount=applied }} }
  end

  -- Backward-compatible public adapter: callers keep the historical generation
  -- vocabulary while the authoritative mutation is now one planned transaction.
  local tx_opts = {}; for key, value in pairs(opts) do tx_opts[key] = value end
  return DeckTransactions.generate(kind, tx_opts, G.GAME)
end

-- Track C A1: the run owns a persistent deck-of-record (master_deck). Seed it once from the TechCard pool
-- (signature Tech is injected by its owning effect), assigning a stable uid per entry. Plain data → serializable.
function Round.next_uid(game)
  local g = game or G.GAME
  g._deck_uid = (g._deck_uid or 0) + 1
  return g._deck_uid
end

function Round.seed_master_deck()
  local g = G.GAME
  if not g then return end
  g.master_deck = {}
  local starters = Deck.starter_centers(Centers.pool("TechCard"), g.market, g.era, RNG.fn("deck_build"))
  for _, center in ipairs(starters) do
    if not center.signature then
      local entry = {
        uid = Round.next_uid(), center_key = center.key,
        edition = nil, enhancement = nil, seal = nil, modifier_state = nil, config = {},
      }
      TechLifecycle.acquire(entry, { source = "starter", acquired_ante = g.ante })
      g.master_deck[#g.master_deck + 1] = entry
    end
  end
  g._deck_seeded = true
  local rules = require("data.gameplay.market_rules").for_market(g.market)
  local valid, reason = Deck.validate(g.master_deck, rules.starter_size)
  assert(valid, reason)
  local discovered = {}
  for _, entry in ipairs(g.master_deck) do discovered[#discovered + 1] = entry.center_key end
  Profile.discover_many(discovered)
end

function Round.select_market(market)
  if G.GAME._deck_seeded then return false end
  if G.GAME.tutorial_market_id and market.id ~= G.GAME.tutorial_market_id then return false end
  local lesson = Guidance.current()
  if lesson and lesson.id == "welcome" then return false end
  require("game.markets").select(G.GAME, market, { initial = true })
  require("game.markets").fulfill_initial(G.GAME)
  Profile.discover(market.id)
  Guidance.emit("market_selected", { market_id = market.id })
  G.GAME.era = RunState.era_for_ante(G.GAME, G.GAME.ante)
  G.GAME.blind.target = RunState.blind_target(G.GAME.ante, G.GAME.blind_idx)
  -- RunState creates the opening blind before the player chooses a Market. Refresh the
  -- still-unused action counters now that its perk is known (notably Indie SaaS's +1 Ship).
  RunState.refresh_blind_actions(G.GAME)
  Round.seed_master_deck()
  StateMachine.set_state(G.STATES.BLIND_SELECT)
  return true
end

function Round.prepare_tech_draft()
  local count = 3 + (G.GAME.draft_choice_bonus or 0)
  G.GAME.draft_choice_bonus = 0
  local choices = Deck.draft_candidates(Centers.pool("TechCard"), G.GAME.market, G.GAME.era,
    G.GAME.master_deck, count, RNG.fn("draft"))
  G.GAME.tech_draft = { choices = {}, offers = {} }
  local modifier_rng = RNG.fn("tech_modifier_offer")
  for _, center in ipairs(choices) do
    G.GAME.tech_draft.choices[#G.GAME.tech_draft.choices + 1] = center.key
    local offer = TechModifiers.make_offer(center, modifier_rng)
    offer.center = nil -- run-state offers remain plain serializable data
    G.GAME.tech_draft.offers[#G.GAME.tech_draft.offers + 1] = offer
  end
  Profile.discover_many(G.GAME.tech_draft.choices)
  return #choices > 0
end

function Round.choose_tech(index)
  local draft = G.GAME.tech_draft
  local key = draft and draft.choices and draft.choices[index]
  if not key then return false end
  local offer = draft.offers and draft.offers[index] or { key = key, center_key = key }
  local entry = Round.master_add(key, {
    enhancement = offer.enhancement, seal = offer.seal,
    modifier_state = offer.modifier_state, source = "boss_draft",
  })
  if not entry then return false end
  Profile.discover(key)
  G.GAME.tech_drafts_taken = (G.GAME.tech_drafts_taken or 0) + 1
  G.GAME.tech_draft = nil
  Shop.enter()
  StateMachine.set_state(G.STATES.SHOP)
  return true
end

-- Track C A3: the SINGLE mutation path into master_deck (so deck changes persist across blinds). All deck
-- adds/removes funnel through these; no direct table.insert into master_deck elsewhere. No-op headless.
function Round.master_add(center_key, props, game)
  local g = game or G.GAME
  if not (g and g.master_deck) then return nil end
  props = props or {}
  local center = Centers.get(center_key)
  if not center or center.set ~= "TechCard" then return nil, "Unknown Tech candidate" end
  if center.signature then
    local Pair = require("game.signature_pair")
    if not (center.key == Pair.JO_KEY and props.signature_injection == Pair.INJECTION_TOKEN
        and props.source == "signature_pair") then
      return nil, "Signature Tech requires explicit injection"
    end
  else
    local allowed, reason = Deck.candidate_allowed(center, g.market)
    if not allowed then return nil, reason end
  end
  local modifier_props = {
    enhancement = props.enhancement,
    enh = props.enh,
    seal = props.seal,
    modifier_state = props.modifier_state,
  }
  local modifier_valid, modifier_reason = TechModifiers.validate(modifier_props, "Tech acquisition")
  if not modifier_valid then return nil, modifier_reason end
  TechModifiers.normalize(modifier_props)
  local e = { uid = Round.next_uid(g), center_key = center_key,
              edition = props.edition, enhancement = modifier_props.enhancement, seal = modifier_props.seal,
              modifier_state = modifier_props.modifier_state and deep_copy(modifier_props.modifier_state) or nil,
              stickers = props.stickers, layer_override = props.layer_override,
              config = props.config or {} }
  TechLifecycle.acquire(e, {
    source = props.source or "generated",
    acquired_ante = props.acquired_ante or g.ante,
    migrated_from = props.migrated_from,
  })
  g.master_deck[#g.master_deck + 1] = e
  return e
end

function Round.master_remove_uid(uid)
  local g = G.GAME
  if not (g and g.master_deck and uid) then return end
  for i = #g.master_deck, 1, -1 do
    if g.master_deck[i].uid == uid then table.remove(g.master_deck, i) end
  end
end

function Round.master_remove_key(key)            -- remove ALL entries of a center (e.g. a fired signature Tech)
  local g = G.GAME
  if not (g and g.master_deck) then return end
  for i = #g.master_deck, 1, -1 do
    if g.master_deck[i].center_key == key then table.remove(g.master_deck, i) end
  end
end

-- Materialize the live G.deck CardArea as a VIEW of master_deck (was: rebuild from the full pool each blind).
-- Lazy-seeds on first build so both start_run and the headless smoke get a populated deck. Behavior-identical
-- to the old pool rebuild on day one (same cards, same shuffle) — now the composition persists across blinds.
function Round.build_deck()
  if not G.deck then return end
  if G.GAME and not G.GAME._deck_seeded then Round.seed_master_deck() end
  local cards = {}
  for _, entry in ipairs((G.GAME and G.GAME.master_deck) or {}) do
    TechModifiers.normalize(entry)
    local center = Centers.get(entry.center_key)
    if center then
      local c = Card({ center = center, face_down = true, uid = entry.uid,
        source = entry.source, acquired_ante = entry.acquired_ante, migrated_from = entry.migrated_from,
        edition = entry.edition, enhancement = entry.enhancement, seal = entry.seal,
        modifier_state = entry.modifier_state, stickers = entry.stickers,
        layer_override = entry.layer_override, layer_locked = entry.layer_locked,
        law_marks = entry.law_marks,
        T = { x = G.deck.T.x, y = G.deck.T.y } })
      if entry.config and next(entry.config) then c.ability.config = deep_copy(entry.config) end
      cards[#cards + 1] = c
    end
  end
  for i = #cards, 2, -1 do                      -- Fisher–Yates
    local j = RNG.int("deck_shuffle", i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  for _, c in ipairs(cards) do G.deck:emplace(c, true) end
  if G.deck.align_cards then G.deck:align_cards() end
end

function Round.deal_to_full()
  while #G.hand.cards < G.GAME.hand_size and #G.deck.cards > 0 do
    local c
    local queued = G.GAME.next_hand_uids or {}
    while #queued > 0 and not c do
      local uid = table.remove(queued, 1)
      for _, candidate in ipairs(G.deck.cards) do
        if candidate.uid == uid then c = candidate; break end
      end
    end
    G.GAME.next_hand_uids = queued
    c = c or G.deck.cards[#G.deck.cards]
    G.deck:remove_card(c, true)
    c.face_down = false                              -- flip face-up when drawn into hand
    G.hand:emplace(c)
  end
end

-- A blind can end before its Ship counter reaches zero when every physical Tech
-- card has already been played, Pivoted, or destroyed.  Keep this on the same
-- terminal path as an ordinary failed blind so GUI and headless play cannot sit
-- in SELECTING_HAND with no legal Ship.
function Round.fail_blind(reason)
  local g = G.GAME
  if not g or g.result ~= nil then return false end
  Scoring.fire_hook("blind_lost")
  g.won, g.result = false, "failed_blind"
  g.loss_reason = reason or "ships_exhausted"
  Audio.play("lose"); Juice.flash(0.4, G.C.lose)
  Guidance.emit("run_lost", { result = g.result, reason = g.loss_reason })
  Profile.record_run(Centers)
  StateMachine.set_state(G.STATES.GAME_OVER)
  return true
end

function Round.fail_if_tech_exhausted()
  local g = G.GAME
  if not (g and g.blind and G.hand and G.deck) then return false end
  if (g.cumulative_arr or 0) >= (g.blind.target or math.huge) then return false end
  if (g.ships_left or 0) <= 0 then return false end
  if #(G.hand.cards or {}) > 0 or #(G.deck.cards or {}) > 0 then return false end
  return Round.fail_blind("tech_exhausted")
end

-- play the highlighted cards into the play area (called by the ship handler)
function Round.move_to_play(cards)
  for _, c in ipairs(cards) do
    c.selected = false
    G.hand:remove_card(c, true)
    G.play:emplace(c)
  end
  G.hand:align_cards()
end

-- tally one resolved ship -> cumulative ARR vs the per-blind target, then advance the ante/blind
-- loop: blind won (next blind / IPO win) / blind failed (run over) / continue this blind.
function Round.cash_out_ship()
  local g = G.GAME
  Guidance.emit("ship_scored", { arr = g.this_ship_arr or 0 })
  Scoring.fire_hook("pre_cash_out")
  g.cumulative_arr = g.cumulative_arr + (g.this_ship_arr or 0)
  g.this_blind_arr = g.cumulative_arr
  if (g.this_ship_arr or 0) > (g.run_best_arr or 0) then g.run_best_arr = g.this_ship_arr end
  g.overkill = math.max(0, (g.this_ship_arr or 0) - ((g.blind and g.blind.target) or 0))
  if (g.this_ship_arr or 0) >= (g.best_ship_arr or 0) then
    g.best_ship_arr = g.this_ship_arr or 0
    g.best_ship_margin = ((g.this_app and g.this_app.margin) or RunState.DEFAULT_MARGIN)
      + (g.current_boss_margin_delta or 0)
      + require("game.markets").margin_bonus(g.this_app, g.market,
        { ai_backed = g.this_ship_ai_backed == true })
  end
  g.last_income = 0
  g.cash = g.cash + (g.pending_dollars or 0)
  g.pending_dollars = 0
  g.ships_left   = g.ships_left - 1
  g.round_num    = g.round_num + 1
  g.ships_this_run = g.ships_this_run + 1
  g.valuation = g.run_best_arr or 0
  Scoring.fire_hook("end_of_round")
  require("game.meters").decay_all()                           -- E4: hype decays per round

  for i = #G.play.cards, 1, -1 do                              -- clear the played cards
    local c = G.play.cards[i]
    G.play:remove_card(c, true)
    c:remove()
  end
  g.score.chips, g.score.mult, g.score.arr = 0, 0, 0

  if g.cumulative_arr >= g.blind.target then                  -- BLIND WON
    local cleared_boss = g.blind_idx == 3
    g.last_tech_modifier_rewards = TechModifiers.on_blind_won(G.hand.cards)
    Scoring.fire_hook("blind_won")
    g.last_lead_rewards = Leads.on_blind_won(g)
    g.last_income = Economy.operating_income(g, g.best_ship_arr, g.best_ship_margin)
    g.last_efficiency = Economy.early_close_reward(g, RunState.ANTE_BASE)
    g.last_market_reward = require("game.markets").high_fit_reward(g, RunState.ANTE_BASE)
    g.last_market_lead = nil
    if require("game.markets").earns_high_fit_lead(g) then
      g.last_market_lead = Leads.grant_random(g, "healthtech_high_fit")
    end
    g.last_blind_reward = (RunState.BLIND_REWARD_UNITS[g.blind_idx] or 0) * Economy.unit(g, RunState.ANTE_BASE)
    g.cash = g.cash + g.last_income + g.last_efficiency + g.last_market_reward + g.last_blind_reward
    g.best_ship_arr, g.best_ship_margin = 0, nil
    local bankrupt = RunState.settle_blind()
    Guidance.emit("blind_settled", { payroll = g.last_payroll, cash = g.cash, bankrupt = bankrupt })
    if cleared_boss and not bankrupt then Guidance.emit("boss_won", { boss = g.blind and g.blind.event }) end
    if bankrupt then                                           -- couldn't make payroll → bankruptcy
      g.won, g.result = false, "bankrupt"
      Audio.play("lose"); Juice.flash(0.4, G.C.lose)
      Guidance.emit("run_lost", { result = g.result })
      require("game.profile").record_run(Centers)             -- persist career/discovery/unlocks
      StateMachine.set_state(G.STATES.GAME_OVER)
    elseif RunState.advance() == "won_run" then               -- cleared the ante-8 boss → IPO
      g.won, g.result = true, "IPO"
      g.ipo_value = Economy.ipo_value(g)
      Audio.win(); Juice.flash(0.5, G.C.win)
      Guidance.emit("run_won", { ipo_value = g.ipo_value })
      require("game.profile").record_run(Centers)             -- win → unlock forms + beat stake
      StateMachine.set_state(G.STATES.GAME_OVER)
    else
      if g.blind_idx == 3 then
        Guidance.emit("boss_previewed", { boss = g.blind and g.blind.event })
      end
      local Lifecycle = require("game.founder_lifecycle")
      for i = #G.jokers.cards, 1, -1 do
        local founder = G.jokers.cards[i]
        if Lifecycle.tick_blind(founder) then Lifecycle.remove(founder) end
      end
      if cleared_boss then g.raise_available = true end
      if cleared_boss and Round.prepare_tech_draft() then
        StateMachine.set_state(G.STATES.TECH_DRAFT)
      else
        Shop.enter()
        StateMachine.set_state(G.STATES.SHOP)
      end
    end
  elseif g.ships_left <= 0 then                               -- BLIND FAILED → run over
    Round.fail_blind("ships_exhausted")
  elseif not Round.fail_if_tech_exhausted() then              -- otherwise continue this blind
    Guidance.emit("ship_failed", { remaining = g.blind.target - g.cumulative_arr })
    StateMachine.set_state(G.STATES.DRAW_TO_HAND)             -- continue this blind
  end
end

return Round
