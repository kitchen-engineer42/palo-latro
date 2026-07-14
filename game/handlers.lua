-- game/handlers.lua — per-STATE update handlers (registered into StateMachine) + the G.FUNCS
-- string-keyed button handlers (the declarative-UI bridge: ui.lua calls G.FUNCS[name]()).

local Round = require("game.round")
local Scoring = require("game.scoring")
local StateMachine = require("game.statemachine")
local Centers = require("game.centers")
local Audio = require("game.audio")
local Shop = require("game.shop")
local Interp = require("game.effect_interp")   -- 1.5b: revert passive run-modifiers on sell
local Coverage = require("game.coverage")
local Lifecycle = require("game.founder_lifecycle")
local Economy = require("game.economy")
local Pricing = require("game.pricing")
local Collection = require("game.collection")
local Guidance = require("game.guidance")
local Profile = require("game.profile")

local S = G.STATES

StateMachine.handlers[S.SELECTING_HAND] = function() end
StateMachine.handlers[S.SHIPPING] = function() end           -- unused: ship -> SCORING directly
StateMachine.handlers[S.SHOP] = function() end               -- passive; input drives buy/reroll/continue
StateMachine.handlers[S.BLIND_SELECT] = function() end       -- passive; Play button → play_blind (P2)
StateMachine.handlers[S.MARKET_SELECT] = function() end
StateMachine.handlers[S.TECH_DRAFT] = function() end
StateMachine.handlers[S.COLLECTION] = function() end

StateMachine.handlers[S.SCORING] = function()
  if not G.E_MANAGER:any_pending("base") then                -- juice finished
    StateMachine.set_state(S.ROUND_EVAL)
  end
end

StateMachine.handlers[S.ROUND_EVAL] = function()
  Round.cash_out_ship()                                       -- sets DRAW_TO_HAND or GAME_OVER
end

StateMachine.handlers[S.DRAW_TO_HAND] = function()
  Round.deal_to_full()
  StateMachine.set_state(S.SELECTING_HAND)
end

StateMachine.handlers[S.GAME_OVER] = function() end

-- buttons --------------------------------------------------------------------

G.FUNCS.ship = function()
  if G.STATE ~= S.SELECTING_HAND or G.GAME.ships_left <= 0 then return end
  local sel = G.hand:highlighted()
  if #sel < 1 then Guidance.emit("ship_rejected_no_selection"); return end
  if #sel > G.GAME.select_max then return end
  Guidance.emit("ship_committed", { count = #sel })
  Round.move_to_play(sel)
  Audio.play("ship", 0.7, 0.5)                                -- launch whoosh
  Scoring.evaluate_ship(G.play.cards)
  delay(0.5)                                                  -- let the resolved ARR linger
  StateMachine.set_state(S.SCORING)
end

G.FUNCS.pivot = function()
  if G.STATE ~= S.SELECTING_HAND or G.GAME.pivots_left <= 0 then return end
  local sel = G.hand:highlighted()
  if #sel < 1 then return end
  G.GAME.last_tech_modifier_discard = require("game.tech_modifiers").on_discard(sel)
  local full_hand_discarded = #sel == #G.hand.cards
  for _, c in ipairs(sel) do
    G.hand:remove_card(c, true)
    c:remove()
  end
  G.hand:align_cards()
  G.GAME.pivots_left = G.GAME.pivots_left - 1
  G.GAME.pivot_count = (G.GAME.pivot_count or 0) + 1
  G.GAME.pivots_round = (G.GAME.pivots_round or 0) + 1
  G.GAME.discard_count = (G.GAME.discard_count or 0) + #sel
  Scoring.fire_hook("discard", { discard_count = #sel, full_hand_discarded = full_hand_discarded,
    discarded_layers = require("game.coverage").analyze(sel).distinct })
  Round.deal_to_full()
  Guidance.emit("pivot_committed", { count = #sel })
  Guidance.emit("compatibility_changed", { count = #sel })
end

G.FUNCS.restart = function()                                  -- game-over → back to the MENU (re-pick stake)
  StateMachine.prep_stage(G.STAGES.MAIN_MENU, G.STATES.MENU)
end

-- pre-run MENU: stake-select buttons + Start
StateMachine.handlers[S.MENU] = function() end
for s = 1, 8 do G.FUNCS["stake_" .. s] = function() G.MENU = G.MENU or {}; G.MENU.stake = s end end
G.FUNCS.start_run_at = function()
  local st = (G.MENU and G.MENU.stake) or 1
  local tutorial = Guidance.first_run_options()
  G.MIMIC_HEADLESS = false
  StateMachine.prep_stage(G.STAGES.RUN, G.STATES.SELECTING_HAND)
  Round.start_run({
    stake = st,
    seed = tutorial and tutorial.seed or nil,
    tutorial_script = tutorial and tutorial.script or nil,
    tutorial_market_id = tutorial and tutorial.recommended_market_id or nil,
  })
end
G.FUNCS.collection_open = function()
  if G.STATE ~= S.MENU then return end
  Collection.reset()
  StateMachine.set_state(S.COLLECTION)
end
G.FUNCS.collection_back = function()
  if G.STATE ~= S.COLLECTION then return end
  StateMachine.set_state(S.MENU)
end
for i = 1, #Collection.CATEGORIES do
  G.FUNCS["collection_category_" .. i] = function()
    if G.STATE == S.COLLECTION then Collection.select_category(i) end
  end
end
for i = 1, 7 do
  G.FUNCS["collection_filter_" .. i] = function()
    if G.STATE == S.COLLECTION then Collection.select_filter(i) end
  end
end
G.FUNCS.collection_prev = function()
  if G.STATE == S.COLLECTION then Collection.change_page(-1) end
end
G.FUNCS.collection_next = function()
  if G.STATE == S.COLLECTION then Collection.change_page(1) end
end
for i = 1, 3 do
  G.FUNCS["market_pick_" .. i] = function()
    if G.STATE ~= S.MARKET_SELECT then return end
    local market = G.GAME.market_choices and G.GAME.market_choices[i]
    if market then Round.select_market(market) end
  end
end
for i = 1, 4 do G.FUNCS["tech_pick_" .. i] = function() if G.STATE == S.TECH_DRAFT then Round.choose_tech(i) end end end

-- Refactor trades one Pivot for bounded debt relief; debt can no longer be farmed for Cash.
G.FUNCS.refactor = function()
  if G.STATE ~= S.SELECTING_HAND then return end
  local Meters = require("game.meters")
  local debt = Meters.get("tech_debt")
  if debt <= 0 or (G.GAME.pivots_left or 0) <= 0 then return end
  Meters.add("tech_debt", -math.min(5, debt))
  G.GAME.pivots_left = G.GAME.pivots_left - 1
  Audio.play("hire")
end

-- E4 signature actions (functional; full UX/choice-overlays are a later polish pass).
local function selected_founder()
  for _, c in ipairs(G.jokers.cards) do if c.selected then return c end end
end

G.FUNCS.activate_founder = function()
  if G.STATE ~= S.SELECTING_HAND and G.STATE ~= S.SHOP then return end
  if G.STATE == S.SHOP and Shop.negotiation_pending() then return end
  local card = selected_founder()
  if not card then return end
  local ok = require("game.founder_actions").activate(card)
  if ok then Audio.play("hire") end
  return ok
end

G.FUNCS.distill = function()   -- halve a founder's Salary (pay-once → cheap recurring earner)
  if G.STATE ~= S.SELECTING_HAND then return end
  local c = selected_founder(); if not c or not c.center then return end
  if Lifecycle.distill(c) then
    local Markets = require("game.markets")
    if Markets.can_free_distill(G.GAME) then
      c.ability.config._salary = 0
      G.GAME.market_distill_used_ante = G.GAME.ante
    end
    Audio.play("hire")
  end
end

G.FUNCS.promote = function()   -- automate a founder into the harness → climb the ladder, free the slot
  if G.STATE ~= S.SELECTING_HAND then return end
  local c = selected_founder(); if not c then return end
  if not Lifecycle.can_promote(c) then return end
  require("game.meters").add("rung_progress", 8)
  if Lifecycle.remove(c, { promote = true }) then Audio.play("fire") end
end

G.FUNCS.market_pivot = function()   -- costed Market re-roll: abandon fit for a fresh demand
  if G.STATE ~= S.SELECTING_HAND then return end
  if G.GAME.last_market_pivot_ante == G.GAME.ante then return end
  local cost = Pricing.base_reroll(G.GAME, require("game.runstate").ANTE_BASE) * math.min(2, 1 + (G.GAME.market_pivots or 0))
  if (G.GAME.cash or 0) < cost then return end
  local choices = require("game.markets").offers(3, require("game.rng").fn("market"), true)
  local Markets = require("game.markets")
  local founder_count = #((G.jokers and G.jokers.cards) or {})
  local next_market
  for _, m in ipairs(choices) do
    if (not G.GAME.market or m.id ~= G.GAME.market.id) and Markets.can_queue(G.GAME, m, founder_count) then
      next_market = m
      break
    end
  end
  if not next_market then return end
  if not Markets.queue(G.GAME, next_market, founder_count) then return end
  if not require("game.founder_events").spend(G.GAME, cost, "market_pivot") then return end
  G.GAME.last_market_pivot_ante = G.GAME.ante
  G.GAME.market_pivots = (G.GAME.market_pivots or 0) + 1
  Audio.play("fire")
end

G.FUNCS.raise = function()     -- a priced round — Cash now for equity dilution
  if (G.STATE ~= S.SELECTING_HAND and G.STATE ~= S.SHOP and G.STATE ~= S.TECH_DRAFT)
    or not G.GAME.raise_available then return end
  if G.STATE == S.SHOP and Shop.negotiation_pending() then return end
  local equity_cost, cash_fraction = Economy.raise_terms(G.GAME)
  if (G.GAME.equity_pct or 0) <= equity_cost then return end
  G.GAME.valuation = G.GAME.run_best_arr or 0
  local market_economy = require("data.gameplay.market_rules").for_market(G.GAME.market).economy or {}
  G.GAME.cash = (G.GAME.cash or 0) + math.floor(G.GAME.valuation * cash_fraction
    * (market_economy.raise_cash_mult or 1))
  G.GAME.equity_pct = (G.GAME.equity_pct or 100) - equity_cost
  G.GAME.raises_taken = (G.GAME.raises_taken or 0) + 1
  G.GAME.raise_available = false
  Audio.play("hire")
end

-- Debug hire still obeys the live Market capacity, including a queued
-- destination's lower cap. This keeps a previously admitted pivot admissible.
G.FUNCS.hire = function()
  local Markets = require("game.markets")
  local cap = G.GAME.founder_slots or 5
  if G.GAME.pending_market then
    cap = math.min(cap, Markets.destination_founder_cap(G.GAME, G.GAME.pending_market) or cap)
  end
  if G.STATE ~= S.SELECTING_HAND or #G.jokers.cards >= cap then return end
  local pool = Centers.pool("Founder")
  if #pool == 0 then return end
  for _ = 1, #pool do
    G.GAME.hire_idx = ((G.GAME.hire_idx or 0) % #pool) + 1
    local center = pool[G.GAME.hire_idx]
    local present = false
    for _, c in ipairs(G.jokers.cards) do if c.center_key == center.key then present = true break end end
    local in_era = true                                       -- forms are era-soft-gated in the shop
    if center.is_form and center.era_gate then
      local ante = G.GAME.ante or 1
      in_era = ante >= (center.era_gate.min or 1) and ante <= (center.era_gate.max or 8)
    end
    if not present and in_era then
      local jk = Card({ center = center, T = { x = G.jokers.T.x, y = G.jokers.T.y } })
      G.jokers:emplace(jk)
      Lifecycle.acquire(jk, { source = "debug_hire", sell_basis = 0 })
      Audio.play("hire")
      return
    end
  end
end

-- fire (sell/remove) the SELECTED founder — Balatro-style two-step (select -> Fire button -> confirm)
G.FUNCS.fire = function()
  if G.STATE ~= S.SELECTING_HAND and G.STATE ~= S.SHOP then return end   -- sell mid-run OR in the shop (Balatro)
  if G.STATE == S.SHOP and Shop.negotiation_pending() then return end
  if G.GAME.founders_locked then return end                  -- stake 4: Vesting Cliff (founders can't be fired)
  for i = #G.jokers.cards, 1, -1 do
    local c = G.jokers.cards[i]
    if c.selected then
      if c.ability and c.ability.config and c.ability.config._unsellable then return end
      if c.center then G.GAME.cash = (G.GAME.cash or 0) + Pricing.sell_value(c) end
      Scoring.fire_hook("selling_self", { other_card = c })
      Scoring.fire_hook("selling_card", { other_card = c })
      Lifecycle.remove(c); Audio.play("fire"); return
    end
  end
end

-- shop: buy a founder offer / reroll / leave for the next blind
G.FUNCS.shop_buy_1 = function() if G.STATE == S.SHOP then Shop.buy(1) end end
G.FUNCS.shop_buy_2 = function() if G.STATE == S.SHOP then Shop.buy(2) end end
G.FUNCS.shop_buy_3 = function() if G.STATE == S.SHOP then Shop.buy(3) end end
G.FUNCS.shop_reroll = function() if G.STATE == S.SHOP then Shop.reroll() end end
G.FUNCS.shop_redeem = function() if G.STATE == S.SHOP then Shop.redeem() end end
G.FUNCS.shop_open_pack_1 = function() if G.STATE == S.SHOP then Shop.open_pack(1) end end
G.FUNCS.shop_open_pack_2 = function() if G.STATE == S.SHOP then Shop.open_pack(2) end end
G.FUNCS.shop_open_pack_3 = function() if G.STATE == S.SHOP then Shop.open_pack(3) end end
G.FUNCS.pack_pick_1 = function() if G.STATE == S.SHOP then Shop.pack_pick(1) end end
G.FUNCS.pack_pick_2 = function() if G.STATE == S.SHOP then Shop.pack_pick(2) end end
G.FUNCS.pack_pick_3 = function() if G.STATE == S.SHOP then Shop.pack_pick(3) end end
G.FUNCS.pack_pick_4 = function() if G.STATE == S.SHOP then Shop.pack_pick(4) end end
G.FUNCS.pack_pick_5 = function() if G.STATE == S.SHOP then Shop.pack_pick(5) end end
G.FUNCS.pack_adopt_1 = function() if G.STATE == S.SHOP then Shop.pack_adopt(1) end end
G.FUNCS.pack_adopt_2 = function() if G.STATE == S.SHOP then Shop.pack_adopt(2) end end
G.FUNCS.pack_adopt_3 = function() if G.STATE == S.SHOP then Shop.pack_adopt(3) end end
G.FUNCS.pack_adopt_4 = function() if G.STATE == S.SHOP then Shop.pack_adopt(4) end end
G.FUNCS.pack_adopt_5 = function() if G.STATE == S.SHOP then Shop.pack_adopt(5) end end
G.FUNCS.pack_migrate_1 = function() if G.STATE == S.SHOP then Shop.pack_migrate(1) end end
G.FUNCS.pack_migrate_2 = function() if G.STATE == S.SHOP then Shop.pack_migrate(2) end end
G.FUNCS.pack_migrate_3 = function() if G.STATE == S.SHOP then Shop.pack_migrate(3) end end
G.FUNCS.pack_migrate_4 = function() if G.STATE == S.SHOP then Shop.pack_migrate(4) end end
G.FUNCS.pack_migrate_5 = function() if G.STATE == S.SHOP then Shop.pack_migrate(5) end end
G.FUNCS.pack_target_prev = function() if G.STATE == S.SHOP then Shop.pack_cycle_migration_target(-1) end end
G.FUNCS.pack_target_next = function() if G.STATE == S.SHOP then Shop.pack_cycle_migration_target(1) end end
G.FUNCS.pack_skip = function() if G.STATE == S.SHOP then Shop.pack_skip() end end
G.FUNCS.pack_locked = function() end -- modal ceremony consumes clicks until the last card is revealed
G.FUNCS.founder_negotiation_answer_1 = function() if G.STATE == S.SHOP then Shop.negotiation_answer(1) end end
G.FUNCS.founder_negotiation_answer_2 = function() if G.STATE == S.SHOP then Shop.negotiation_answer(2) end end
G.FUNCS.founder_negotiation_answer_3 = function() if G.STATE == S.SHOP then Shop.negotiation_answer(3) end end
G.FUNCS.founder_negotiation_continue = function() if G.STATE == S.SHOP then Shop.negotiation_continue() end end
G.FUNCS.founder_negotiation_standard_terms = function() if G.STATE == S.SHOP then Shop.negotiation_standard_terms() end end
G.FUNCS.founder_negotiation_walk_away = function() if G.STATE == S.SHOP then Shop.negotiation_walk_away() end end
G.FUNCS.shop_continue = function()
  if G.STATE ~= S.SHOP then return end
  if Shop.negotiation_pending() then return end
  G.GAME.shop = nil
  StateMachine.set_state(S.BLIND_SELECT)                       -- preview the upcoming blind (P2); Play → play_blind
end

-- BLIND_SELECT (P2): commit to the previewed blind → deal + start playing
G.FUNCS.play_blind = function()
  if G.STATE ~= S.BLIND_SELECT then return end
  if G.GAME.blind and G.GAME.blind.is_boss then
    Guidance.emit("boss_entered", { boss = G.GAME.blind.event })
  end
  Round.next_blind()                                           -- rebuild deck + deal + → SELECTING_HAND
end

G.FUNCS.skip_blind = function()
  local Leads = require("game.leads")
  if G.STATE ~= S.BLIND_SELECT or not Leads.can_skip(G.GAME) then return false end
  local skipped, lead = G.GAME.blind_idx, Leads.claim_current(G.GAME)
  if not lead then return false end
  G.GAME.skips_run = (G.GAME.skips_run or 0) + 1
  Scoring.fire_hook("skip_blind", { lead = lead, skipped_blind_idx = skipped })
  require("game.runstate").advance()
  if G.GAME.blind_idx == 3 then
    Guidance.emit("boss_previewed", { boss = G.GAME.blind and G.GAME.blind.event })
  end
  StateMachine.set_state(S.BLIND_SELECT)
  return true
end

-- ── Track C B2/B4/B5: consumable (Tech Law) use / target-select / sell ────────────────────────────
local Consumables = require("game.consumables")
local Juice = require("game.juice")
StateMachine.handlers[S.USE_CARD] = function() end             -- transient (reserved)
StateMachine.handlers[S.TARGET_SELECT] = function() end        -- passive; input drives the pick

local function selected_consumable()
  if not G.consumables then return nil end
  for _, c in ipairs(G.consumables.cards) do if c.selected then return c end end
end

local function restore_target_selection(pc)
  local area = pc and pc.target_area
  if not area then area = Consumables.target_area(pc and pc.card) end
  if not area then return end
  local present = {}
  for _, card in ipairs(area.cards or {}) do present[card] = true; card.selected = false end
  for _, card in ipairs((pc and pc.prior_selection) or {}) do
    if present[card] then card.selected = true end
  end
  if area.align_cards then area:align_cards() end
end

G.FUNCS.use_consumable = function()
  if G.STATE ~= S.SELECTING_HAND and G.STATE ~= S.SHOP then return end
  if G.STATE == S.SHOP and Shop.negotiation_pending() then return end
  local return_state = G.STATE
  local c = selected_consumable(); if not c then return end
  local usable, reason = Consumables.can_use(c, G.GAME)
  if not usable then return { ok = false, key = c.center_key,
    reason = reason, consumed = false, changes = {}, generated = {} } end
  if c.center.target then                                      -- B4: two-stage — pick target card(s) first
    local target_area, target_area_name = Consumables.target_area(c)
    if not target_area then return { ok = false, key = c.center_key,
      reason = "Unknown consumable target area", consumed = false, changes = {}, generated = {} } end
    local prior = {}
    for _, target in ipairs(target_area.cards or {}) do
      if target.selected then prior[#prior + 1] = target end
      target.selected = false
    end
    G.PENDING_CONSUMABLE = { card = c, center = c.center, picks = {}, prior_selection = prior,
      return_state = return_state, target_area = target_area, target_area_name = target_area_name }
    StateMachine.set_state(S.TARGET_SELECT)
    return { ok = true, pending = true, key = c.center_key, consumed = false }
  else                                                          -- B2: instant (cash / auto-target ops)
    local result = Consumables.use(c, nil, nil)
    if result.ok then Audio.play("ship"); Juice.pulse("cash") end
    return result
  end
end

G.FUNCS.sell_consumable = function()
  if G.STATE ~= S.SELECTING_HAND and G.STATE ~= S.SHOP then return end
  if G.STATE == S.SHOP and Shop.negotiation_pending() then return end
  local c = selected_consumable(); if not c then return end
  Scoring.fire_hook("sell_consumable", { consumable = c.center })
  G.GAME.cash = (G.GAME.cash or 0) + Shop.consumable_sell_value(c)
  Consumables.remove(c)
  Audio.play("fire")
end

G.FUNCS.shop_buy_consumable = function() if G.STATE == S.SHOP then Shop.buy_consumable() end end

function G.CONSUMABLE_TARGET_PICK(card)                        -- an eligible card clicked during TARGET_SELECT
  local pc = G.PENDING_CONSUMABLE
  if not (pc and card) then return false end
  for _, picked in ipairs(pc.picks) do
    if picked == card or (picked.uid and picked.uid == card.uid) then
      pc.error = "Choose distinct targets"
      return false
    end
  end
  local eligible, reason = Consumables.can_target(pc.card, card, G.GAME)
  if not eligible then
    pc.error = reason
    return false
  end
  if #pc.picks >= ((pc.center.target and pc.center.target.n) or 1) then
    pc.error = "All required targets are already selected"
    return false
  end
  pc.error = nil
  pc.picks[#pc.picks + 1] = card
  card.selected = true
  if #pc.picks >= ((pc.center.target and pc.center.target.n) or 1) then
    if pc.center.target and pc.center.target.layer then pc.need_layer = true   -- Conway: now pick the Layer
    else return G.CONSUMABLE_RESOLVE(nil) end
  end
  return true
end

function G.CONSUMABLE_RESOLVE(layer)                           -- apply + consume + return to play
  local pc = G.PENDING_CONSUMABLE
  if not pc then return false end
  local return_state = pc.return_state or S.SELECTING_HAND
  local result = Consumables.use(pc.card, pc.picks, { layer = layer })
  if not result.ok then
    pc.error = result.reason
    if not pc.need_layer then
      for _, target in ipairs(pc.picks) do target.selected = false end
      pc.picks = {}
    end
    return result
  end
  restore_target_selection(pc)
  G.PENDING_CONSUMABLE = nil
  Audio.play("ship"); Juice.pulse("cash")
  StateMachine.set_state(return_state)
  return result
end

function G.CONSUMABLE_CANCEL()                                 -- right-click/Esc — consumable NOT spent
  local pc = G.PENDING_CONSUMABLE
  if not pc then return end
  local return_state = pc.return_state or S.SELECTING_HAND
  restore_target_selection(pc)
  G.PENDING_CONSUMABLE = nil
  StateMachine.set_state(return_state)
end

for _, L in ipairs({ "Frontend", "Backend", "Data", "Infra", "AI" }) do
  G.FUNCS["pick_layer_" .. L] = function()
    if G.STATE == S.TARGET_SELECT and G.PENDING_CONSUMABLE and G.PENDING_CONSUMABLE.need_layer then
      G.CONSUMABLE_RESOLVE(L)
    end
  end
end

-- ── Phase 4B: sort hand (bottom-mid row) + Run Info / Options / deck-view overlays ────────────────
local function effective_users(card)
  return (card and card.get_users and card:get_users()) or (card and card.base_users) or 0
end

G.FUNCS.sort_users = function()
  if not (G.STATE == S.SELECTING_HAND and G.hand) then return end
  table.sort(G.hand.cards, function(a, b)
    local au, bu = effective_users(a), effective_users(b)
    if au ~= bu then return au > bu end
    return (a.center_key or "") < (b.center_key or "")
  end)
  G.hand:align_cards(); Audio.play("select", nil, 0.4)
end
G.FUNCS.sort_layer = function()
  if not (G.STATE == S.SELECTING_HAND and G.hand) then return end
  table.sort(G.hand.cards, function(a, b)
    local ia, ib = Coverage.sort_index(a), Coverage.sort_index(b)
    if ia ~= ib then return ia < ib end
    local au, bu = effective_users(a), effective_users(b)
    if au ~= bu then return au > bu end
    return (a.center_key or "") < (b.center_key or "")
  end)
  G.hand:align_cards(); Audio.play("select", nil, 0.4)
end

G.FUNCS.run_info = function() G.SHOW_RUN_INFO = not G.SHOW_RUN_INFO; G.SHOW_OPTIONS, G.SHOW_DECK_VIEW = nil, nil end
G.FUNCS.options  = function() G.SHOW_OPTIONS = not G.SHOW_OPTIONS; G.SHOW_RUN_INFO, G.SHOW_DECK_VIEW = nil, nil end
G.FUNCS.opt_motion = function() if G.SHOW_OPTIONS then G.SETTINGS.reduced_motion = not G.SETTINGS.reduced_motion end end
G.FUNCS.opt_sound  = function() if G.SHOW_OPTIONS then G.SETTINGS.sound = (G.SETTINGS.sound == false) end end
G.FUNCS.opt_shake  = function() if G.SHOW_OPTIONS then G.SETTINGS.shake = not (G.SETTINGS.shake ~= false) end end
G.FUNCS.opt_flash  = function() if G.SHOW_OPTIONS then G.SETTINGS.flash = not (G.SETTINGS.flash ~= false) end end
G.FUNCS.opt_particles = function() if G.SHOW_OPTIONS then G.SETTINGS.particles = not (G.SETTINGS.particles ~= false) end end
G.FUNCS.opt_crt    = function() if G.SHOW_OPTIONS then G.SETTINGS.crt = not G.SETTINGS.crt end end
G.FUNCS.opt_guidance = function()
  if not G.SHOW_OPTIONS then return end
  local prefs = Guidance.preferences()
  Guidance.set_preference("guidance", not prefs.guidance)
  Profile.save()
end
G.FUNCS.opt_chatter = function()
  if not G.SHOW_OPTIONS then return end
  local prefs = Guidance.preferences()
  Guidance.set_preference("cofounder_chatter", not prefs.cofounder_chatter)
  Profile.save()
end
G.FUNCS.guidance_ack = function()
  local lesson = Guidance.current()
  if lesson and lesson.id == "welcome" then Guidance.emit("acknowledged") end
end
G.FUNCS.opt_quit   = function() if G.SHOW_OPTIONS then G.SHOW_OPTIONS = nil; G.FUNCS.restart() end end

return true
