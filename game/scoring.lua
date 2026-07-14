-- game/scoring.lua — the scoring engine. evaluate_ship() computes ARR instantly and enqueues
-- the count-up juice via the EventManager. The FULL context vocabulary + return-effect protocol
-- are defined now (only some populated in the slice) so founders/editions/seals slot in later
-- without changing the core traversal contract.

local AppTypes = require("game.apptypes")
local Juice = require("game.juice")
local Audio = require("game.audio")
local Particles = require("game.particles")
local Compat = require("game.compat")
local Meters = require("game.meters")
local Markets = require("game.markets")
local Coverage = require("game.coverage")
local Playbooks = require("game.playbooks")
local Archetypes = require("game.archetypes")
local Reliability = require("game.reliability")
local Profile = require("game.profile")
local Guidance = require("game.guidance")
local ScoreTrace = require("game.score_trace")
local Centers = require("game.centers")
local Bosses = require("game.bosses")
local AIMaturity = require("game.ai_maturity")

local Scoring = {}
local MAX_USERS, MAX_REVENUE = 10000000, 100000

-- The complete scoring context vocabulary (keys defined; founders/blinds populate the rest later):
--   cardarea, full_hand, scoring_hand, scoring_name, poker_hands,
--   before, repetition, repetition_only, individual, other_card,
--   joker_main, other_joker, edition, after, debuffed_hand,
--   destroying_card, removed, blueprint, blueprint_card
local function ctx(base, over)
  local c = {}
  for k, v in pairs(base) do c[k] = v end
  if over then for k, v in pairs(over) do c[k] = v end end
  return c
end

-- The single context-driven seam. Every card/founder is asked the same way; the engine never
-- knows what any specific one does. Tech cards return nil; founders return an effect table.
local function eval_card(card, context)
  if not card or not card.calculate then return {} end
  return card:calculate(context) or {}
end
Scoring.eval_card = eval_card

local function eval_automated(record, context)
  local center = record and Centers.get(record.center_key)
  if not (center and G.FOUNDER_CALC) then return {} end
  record.config = record.config or { _effect_scale = record.effect_scale or 0.5 }
  return G.FOUNDER_CALC({ center = center, center_key = center.key, ability = { config = record.config } }, context) or {}
end

local function each_automated(context, fn)
  for _, record in ipairs((G.GAME and G.GAME.automated_founders) or {}) do fn(eval_automated(record, context)) end
end

-- Apply a return-effect table to the running score S. Full protocol (populate-what's-used):
-- chips, mult, x_mult, h_mult, h_x_mult, dollars, p_dollars,
-- edition{chip_mod,mult_mod,x_mult_mod}, seals{repetitions,...},
-- jokers{chip_mod,mult_mod,Xmult_mod,repetitions,...}, extra{...}
local function apply_effect(S, eff)
  if not eff then return end
  if eff.chips  then S.chips = math.min(MAX_USERS, S.chips + eff.chips) end
  if eff.mult   then S.mult  = math.min(MAX_REVENUE, S.mult + eff.mult) end
  if eff.x_mult then S.mult  = math.min(MAX_REVENUE, S.mult * math.max(0, math.min(5, eff.x_mult))) end
  if eff.dollars   then G.GAME.pending_dollars = G.GAME.pending_dollars + eff.dollars end
  if eff.p_dollars then G.GAME.pending_dollars = G.GAME.pending_dollars + eff.p_dollars end
  local e = eff.edition
  if e then
    if e.chip_mod   then S.chips = S.chips + e.chip_mod end
    if e.mult_mod   then S.mult  = S.mult  + e.mult_mod end
    if e.x_mult_mod then S.mult  = S.mult  * e.x_mult_mod end
  end
  local j = eff.jokers
  if j then
    if j.chip_mod  then S.chips = S.chips + j.chip_mod end
    if j.mult_mod  then S.mult  = S.mult  + j.mult_mod end
    if j.Xmult_mod then S.mult  = S.mult  * j.Xmult_mod end
  end
  local x = eff.extra
  if x then
    if x.chip_mod then S.chips = S.chips + x.chip_mod end
    if x.mult_mod then S.mult  = S.mult  + x.mult_mod end
  end
end

local function score_snap(S) return { chips = S.chips, mult = S.mult } end

local function score_delta(before, after)
  local parts = {}
  local dc, dm = after.chips - before.chips, after.mult - before.mult
  if math.abs(dc) >= .01 then parts[#parts + 1] = (dc >= 0 and "+" or "") .. format_number(math.floor(dc + .5)) .. " Users" end
  if math.abs(dm) >= .01 then
    local ratio = before.mult ~= 0 and after.mult / before.mult or 1
    if ratio >= 1.18 or ratio <= .82 then parts[#parts + 1] = "x" .. tostring(round_to(ratio, 2)) .. " Rev"
    else parts[#parts + 1] = (dm >= 0 and "+" or "") .. tostring(round_to(dm, 2)) .. " Rev" end
  end
  return table.concat(parts, "  "), dc, dm
end

-- Presentation is queued alongside the score tween, never used to compute it. That keeps simulation and
-- headless behavior deterministic while making every material Founder/system contribution attributable.
local function queue_score_feedback(card, source, before, after, preset, color)
  local detail, dc, dm = score_delta(before, after)
  if detail == "" then return end
  local x = card and card.VT and (card.VT.x + card.VT.w / 2) or G.WINDOW.w / 2
  local y = card and card.VT and (card.VT.y - 8) or 500
  local base = math.max(1, math.abs(before.chips) + math.abs(before.mult) * 5)
  local intensity = clamp(.65 + (math.abs(dc) + math.abs(dm) * 5) / base, .55, 2.2)
  local ratio = before.mult ~= 0 and after.mult / before.mult or 1
  local semantic = preset or ((dm < 0 or dc < 0) and "score_penalty"
    or (ratio >= 1.18 and "score_xmult") or (math.abs(dm) > 0 and "score_mult" or "score_users"))
  G.E_MANAGER:add_event(Event({ trigger = "immediate", blocking = true, func = function()
    if card and not card.REMOVED then card:juice_up(.48, .08) end
    Juice.cue(x, y, source, detail, color or ((dm < 0 or dc < 0) and G.C.lose or (math.abs(dm) > 0 and G.C.mult or G.C.users)))
    Particles.emit((semantic == "score_penalty" and "penalty") or (semantic == "score_users" and "score")
      or (semantic == "score_system" and "system") or "mult",
      x, y + 24, color or ((dm < 0 or dc < 0) and G.C.lose or (math.abs(dm) > 0 and G.C.mult or G.C.users)), intensity)
    Audio.event(semantic, { intensity = intensity })
    Juice.shake(semantic == "score_penalty" and .45 or .3 * intensity)
    return true
  end }))
end

local function founder_name(card)
  return card and card.center and (card.center.short or card.center.name) or "Founder"
end

-- repetitions for a card = 1 + seal retriggers + joker `repetition` retriggers (0 in the slice)
local function collect_reps(card, base)
  local reps = 1
  local seal = card.seal and Card.SEALS and Card.SEALS[card.seal]
  if seal and seal.retrigger then reps = reps + math.min(1, seal.retrigger) end
  if seal and seal.cash then G.GAME.pending_dollars = G.GAME.pending_dollars + seal.cash end
  local seal_eff = eval_card(card, ctx(base, { repetition = true, repetition_only = true, other_card = card }))
  if seal_eff.seals and seal_eff.seals.repetitions then reps = reps + seal_eff.seals.repetitions end
  for _, jk in ipairs(G.jokers.cards) do
    local e = eval_card(jk, ctx(base, { repetition = true, other_card = card }))
    if e.jokers and e.jokers.repetitions then reps = reps + e.jokers.repetitions end
  end
  return reps
end

-- enqueue a blocking count-up of a display field toward `to`, with a short beat after
local function juice(field, to, dur, beat)
  ease_value(G.GAME.score, field, to, dur or 0.16, { blocking = true })
  if beat then delay(beat) end
end

-- Fixed traversal (mirrors the runtime contract). Logical chips/mult are computed in S; the display
-- (G.GAME.score.*) is tweened to follow, serialized by the blocking event queue.
function Scoring.evaluate_ship(played)
  local coverage = Coverage.analyze(played)
  local app = AppTypes.classify(played)
  local ai_maturity = AIMaturity.evaluate(played, app)
  Profile.discover(app.key)
  local base = {
    cardarea = G.play, full_hand = played, scoring_hand = played,
    scoring_name = app.name, poker_hands = { [app.key] = true }, coverage = coverage,
  }
  G.GAME.scoring_name = app.name
  G.GAME.this_app = app
  G.GAME.this_ship_ai_backed = Coverage.has_layer(played, "AI", coverage)
  G.GAME.last_ai_maturity = ai_maturity
  G.GAME.product_identity = AIMaturity.identity(app, ai_maturity)
  G.GAME.this_ship_arr = 0
  -- delta tracking (B): count distinct App Types / Layers FIRST-seen this Ship (the "per NEW X" per-sources)
  G.GAME._new_app_types = 0
  if G.GAME.app_types_shipped_run and not G.GAME.app_types_shipped_run[app.key] then
    G.GAME._new_app_types = 1; G.GAME.app_types_shipped_run[app.key] = true
  end
  G.GAME._new_layers = 0
  for _, c in ipairs(played) do
    for _, L in ipairs(Coverage.layers_for(c, coverage)) do
      if G.GAME.layers_seen_run and not G.GAME.layers_seen_run[L] then
        G.GAME._new_layers = G.GAME._new_layers + 1; G.GAME.layers_seen_run[L] = true
      end
    end
  end

  G.GAME.score_trace = ScoreTrace.new()
  local base_chips, base_mult, app_level = Playbooks.values(app)
  local S = { chips = base_chips, mult = base_mult }
  ScoreTrace.capture(G.GAME.score_trace, "app_base", { chips = S.chips, mult = S.mult, app = app.key, level = app_level })

  -- reset + reveal base chips/mult
  G.GAME.score.chips, G.GAME.score.mult, G.GAME.score.arr = 0, 0, 0
  juice("chips", S.chips, 0.20)
  juice("mult", S.mult, 0.20, 0.10)

  -- compatibility (E3): count clashes (utility founders clear them in the `before` pass) + accrue tech-debt
  G.GAME._clashes_active = #Compat.clashes(played)
  for _, c in ipairs(played) do                                  -- the signature JIT schema clears ALL clashes
    if c.center and c.center.clears_clash then G.GAME._clashes_active = 0; break end
  end
  local subs = #Compat.substitutes(played)
  if subs > 0 then
    Meters.add("tech_debt", (G.GAME.tech_debt_accel and subs * 2 or subs)) -- stake 7
    if Meters.get("tech_debt") >= 3 then Guidance.emit("high_tech_debt", { debt = Meters.get("tech_debt") }) end
  end

  -- "before" jokers (clear_clash ops decrement G.GAME._clashes_active)
  for _, jk in ipairs(G.jokers.cards) do
    local b = score_snap(S); apply_effect(S, eval_card(jk, ctx(base, { before = true })))
    queue_score_feedback(jk, founder_name(jk), b, score_snap(S))
  end
  each_automated(ctx(base, { before = true }), function(e)
    local b = score_snap(S); apply_effect(S, e); queue_score_feedback(nil, "Automated", b, score_snap(S), "score_system", G.C.arr)
  end)

  -- each scoring card, left -> right
  local step = 0
  for _, c in ipairs(played) do
    local reps = collect_reps(c, base)
    for _ = 1, reps do
      step = step + 1
      local users = c:get_users(ctx(base, { individual = true, other_card = c }))
      S.chips = S.chips + users
      local card, idx, total = c, step, #played
      -- pop / floating text / shake / rising-pitch tick, fired in sync with this card's count-up
      G.E_MANAGER:add_event(Event({ trigger = "immediate", blocking = true, func = function()
        if not card.REMOVED then
          card:juice_up(0.6, 0.1)
          Particles.burst(card.VT.x + card.VT.w / 2, card.VT.y + card.VT.h / 2, G.C.users, 5)
        end
        Juice.text(card.VT.x + card.VT.w / 2, card.VT.y - 4, "+" .. users .. " Users", G.C.users)
        Juice.shake(0.6); Juice.pulse("score")
        Audio.chip(idx, total)
        return true
      end }))
      juice("chips", S.chips, 0.14, 0.05)
      -- per-card joker synergy (individual)
      for _, jk in ipairs(G.jokers.cards) do
        local bm, bc = S.mult, S.chips
        apply_effect(S, eval_card(jk, ctx(base, { individual = true, other_card = c })))
        queue_score_feedback(jk, founder_name(jk), { chips = bc, mult = bm }, score_snap(S))
        if S.mult ~= bm then juice("mult", S.mult, 0.12, 0.03) end
        if S.chips ~= bc then juice("chips", S.chips, 0.10, 0.02) end
      end
      each_automated(ctx(base, { individual = true, other_card = c }), function(e) apply_effect(S, e) end)
      -- card edition (after individual, before joker_main) — seam
      apply_effect(S, eval_card(c, ctx(base, { edition = true, other_card = c })))
      -- Track C: per-card Rev sticker (card_stat_sticker field=rev) folds into the hand mult (override→add→mul)
      local rs = c.rev_sticker and c:rev_sticker()
      if rs then
        if rs.override then S.mult = rs.override end
        S.mult = (S.mult + (rs.add or 0)) * (rs.mul or 1)
        juice("mult", S.mult, 0.12, 0.03)
      end
    end
  end
  ScoreTrace.capture(G.GAME.score_trace, "tech", { chips = S.chips, mult = S.mult })

  -- held-card pass (h_mult/h_x_mult) — seam (G.hand), no-op now
  -- joker main + after
  for _, jk in ipairs(G.jokers.cards) do
    local b = score_snap(S); apply_effect(S, eval_card(jk, ctx(base, { joker_main = true })))
    queue_score_feedback(jk, founder_name(jk), b, score_snap(S))
  end
  each_automated(ctx(base, { joker_main = true }), function(e)
    local b = score_snap(S); apply_effect(S, e); queue_score_feedback(nil, "Automated", b, score_snap(S), "score_system", G.C.arr)
  end)
  G.GAME._pre_after_arr = math.floor(S.chips * S.mult + 0.5)
  G.GAME._running_arr = G.GAME._pre_after_arr
  for _, jk in ipairs(G.jokers.cards) do
    local b = score_snap(S); apply_effect(S, eval_card(jk, ctx(base, { after = true })))
    queue_score_feedback(jk, founder_name(jk), b, score_snap(S))
  end
  each_automated(ctx(base, { after = true }), function(e)
    local b = score_snap(S); apply_effect(S, e); queue_score_feedback(nil, "Automated", b, score_snap(S), "score_system", G.C.arr)
  end)
  -- D: apply armed buffs (event hooks → scoring), consumed once at the next scoring pass
  if G.GAME._armed_buffs and #G.GAME._armed_buffs > 0 then
    for _, ab in ipairs(G.GAME._armed_buffs) do apply_effect(S, { [ab.field] = ab.value }) end
    G.GAME._armed_buffs = {}
  end
  -- founder Editions + Seals: passive card modifiers folded into the score
  for _, jk in ipairs(G.jokers.cards) do
    local e = jk.edition and Card.EDITIONS and Card.EDITIONS[jk.edition]
    if e then
      if e.chips then S.chips = S.chips + e.chips end
      if e.mult then S.mult = S.mult + e.mult end
      if e.x_mult then S.mult = S.mult * e.x_mult end
    end
  end
  ScoreTrace.capture(G.GAME.score_trace, "founders", { chips = S.chips, mult = S.mult })
  if S.mult ~= G.GAME.score.mult then juice("mult", S.mult, 0.14) end

  -- Jo-harness-burg — when in the built hand it grows with its paired Founder, but
  -- ADDITIVELY (never a 2nd ×engine), plus Hamster flat +rev/user. Polynomial, not exponential.
  local signature_tech
  for _, c in ipairs(played) do if c.center_key == "t_joharness-burg" then signature_tech = c; break end end
  if signature_tech then
    local signature_before = score_snap(S)
    local add = signature_tech.center.hamster_mult or 0        -- Hamster flat +mult
    for _, jk in ipairs(G.jokers.cards) do
      if jk.center_key == "f_kitchen-engineer42" then
        local k = math.max(0, (G.GAME.ante or 1) - ((jk.ability.config or {})._hire_ante or G.GAME.ante or 1))
        add = add + math.floor(0.8 + 0.1 * 2 ^ k)             -- additive coupling: tracks her current level
        break
      end
    end
    if add > 0 then
      S.mult = S.mult + add; queue_score_feedback(signature_tech, "Jo-harness-burg", signature_before, score_snap(S), "score_system", G.C.arr)
      juice("mult", S.mult, 0.12)
    end
  end

  -- compatibility penalty (clashes left after utility clears) + tech-debt drag (E3)
  local clashes_left = G.GAME._clashes_active or 0
  local td = Meters.tier("tech_debt")
  if clashes_left > 0 or td > 0 then
    local penalty_before = score_snap(S)
    S.mult = S.mult * (0.9 ^ clashes_left) * (1 - 0.03 * td)
    queue_score_feedback(nil, clashes_left > 0 and "Compatibility" or "Tech debt", penalty_before, score_snap(S), "score_penalty", G.C.lose)
    juice("mult", S.mult, 0.14)
  end

  -- E4 signature multipliers: maturity rung · Knowledge MSG · chemistry
  local ndl = coverage.distinct
  local ke = 0
  for _, jk in ipairs(G.jokers.cards) do
    if jk.center and jk.center.effect and jk.center.effect.ke_complement then ke = ke + 1 end
  end
  ke = ke + coverage.knowledge_count
  -- Company maturity is earned by explicit automation effects (for example
  -- Promote) and first-time Layer discoveries. Replaying the same broad hand
  -- cannot farm this persistent meter.
  Meters.add("rung_progress", G.GAME._new_layers or 0)
  G.GAME.maturity_rung = 1 + Meters.tier("rung_progress")
  if ke > 0 then Meters.add("knowledge_charge", ke) end
  local rung_lev = 1 + 0.08 * (G.GAME.maturity_rung - 1)
  local msg = (Meters.tier("knowledge_charge") >= 1) and (1 + 0.1 * Meters.tier("knowledge_charge")) or 1
  local chem = 1 + math.min(Markets.compatibility_per_point(G.GAME.market)
    * math.floor(Compat.complement_score(played)), 0.5)
  G.GAME._ndl = ndl
  if rung_lev ~= 1 or msg ~= 1 or chem ~= 1 then
    local systems_before = score_snap(S)
    S.mult = S.mult * rung_lev * msg * chem
    queue_score_feedback(nil, "Startup systems", systems_before, score_snap(S), "score_system", G.C.arr)
    juice("mult", S.mult, 0.14)
  end
  local systems_trace = ScoreTrace.capture(G.GAME.score_trace, "systems", { chips = S.chips, mult = S.mult, chemistry = chem,
    maturity = rung_lev, msg = msg })

  -- AI maturity is a product-architecture refinement of an already-classified
  -- AI App Type. It is evaluated from this hand's Tech evidence and never
  -- changes `app`, `scoring_name`, or the persistent company maturity meter.
  local maturity_before = score_snap(S)
  S.chips, S.mult = AIMaturity.apply(S.chips, S.mult, ai_maturity)
  if ai_maturity then
    queue_score_feedback(nil, ai_maturity.name, maturity_before, score_snap(S), "score_system", G.C.arr)
    if S.chips ~= maturity_before.chips then juice("chips", S.chips, 0.12) end
    if S.mult ~= maturity_before.mult then juice("mult", S.mult, 0.12) end
  end
  local maturity_trace = { chips = S.chips, mult = S.mult, active = ai_maturity ~= nil }
  if ai_maturity then
    maturity_trace.key = ai_maturity.key
    maturity_trace.name = ai_maturity.name
    maturity_trace.rung = ai_maturity.rung
    maturity_trace.users_bonus = ai_maturity.users_bonus
    maturity_trace.rev_mult = ai_maturity.rev_mult
    maturity_trace.identity = G.GAME.product_identity
    maturity_trace.roles = ai_maturity.roles
    maturity_trace.layers = ai_maturity.layers
  end
  ScoreTrace.capture(G.GAME.score_trace, "ai_maturity", maturity_trace)

  local stacks, best_stack = Archetypes.evaluate(played)
  G.GAME.last_stack_progress, G.GAME.last_named_stack = stacks, nil
  if best_stack and best_stack.complete then
    local stack_before = score_snap(S)
    S.chips = math.min(MAX_USERS, S.chips + best_stack.users)
    S.mult = math.min(MAX_REVENUE, S.mult + best_stack.rev)
    G.GAME.last_named_stack = best_stack.key
    queue_score_feedback(nil, best_stack.name or "Named stack", stack_before, score_snap(S), "score_system", G.C.arr)
  end
  ScoreTrace.capture(G.GAME.score_trace, "named_stack", { chips = S.chips, mult = S.mult,
    active = G.GAME.last_named_stack ~= nil, stack = G.GAME.last_named_stack })
  systems_trace.stack = G.GAME.last_named_stack -- compatibility alias for older trace readers

  -- E5 Market fit (earned mult) + telegraphed boss event penalty
  local fit = Markets.fit_mult(played, G.GAME.market)
  local boss_key = G.GAME.blind and G.GAME.blind.event
  local evm = Bosses.score_multiplier(boss_key, played, { fit = fit })
  G.GAME.current_boss_margin_delta = Bosses.margin_delta(boss_key)
  G.GAME.last_fit = fit
  G.GAME.market_best_fit = math.max(G.GAME.market_best_fit or 0, fit)
  if fit ~= 1 or evm ~= 1 then
    local fit_before = score_snap(S)
    S.mult = S.mult * fit * evm
    queue_score_feedback(nil, evm < 1 and "Market event" or "Market fit", fit_before, score_snap(S),
      (fit * evm < 1) and "score_penalty" or "score_system", (fit * evm < 1) and G.C.lose or G.C.arr)
    juice("mult", S.mult, 0.14)
  end

  local market_before, market_after, market_score_rule = Markets.apply_score_perk(S, G.GAME.market,
    { max_users = MAX_USERS, max_revenue = MAX_REVENUE })
  if market_before.chips ~= market_after.chips or market_before.mult ~= market_after.mult then
    local perk = require("data.gameplay.market_rules").for_market(G.GAME.market).perk or {}
    queue_score_feedback(nil, perk.name or "Market perk", market_before, market_after,
      "score_system", G.C.arr)
    juice("chips", S.chips, 0.14)
    juice("mult", S.mult, 0.14)
  end
  ScoreTrace.capture(G.GAME.score_trace, "market_perk", {
    before_chips = market_before.chips, before_mult = market_before.mult,
    chips = S.chips, mult = S.mult,
    balance_lanes = market_score_rule.balance_lanes == true,
    revenue_mult = market_score_rule.revenue_mult, revenue_cap = market_score_rule.revenue_cap })

  -- blind modify_hand vs debuff_hand branch — identity stubs now (the branch exists)
  -- if G.GAME.blind and G.GAME.blind:debuff_hand(...) then ... else ... end

  -- resolve ARR = chips x mult
  delay(0.18)
  local reliability = Reliability.evaluate(played, { boss = G.GAME.blind and G.GAME.blind.event,
    mitigation = G.GAME.reliability_bonus or 0 })
  reliability.score = math.max(0, reliability.score + (G.GAME.reliability_stake_delta or 0)
    + Markets.reliability_bonus(G.GAME.market))
  reliability.multiplier = 0.50 + 0.05 * reliability.score
  S.chips, S.mult = math.min(MAX_USERS, S.chips), math.min(MAX_REVENUE, S.mult)
  local final_arr = math.floor(S.chips * S.mult * reliability.multiplier + 0.5)
  G.GAME.last_reliability, G.GAME.last_misfire = reliability, false
  G.GAME._final_arr = final_arr
  ScoreTrace.finalize(G.GAME.score_trace, { chips = S.chips, mult = S.mult, fit = fit, boss_mult = evm,
    market = G.GAME.market and G.GAME.market.id,
    reliability = reliability.score, reliability_mult = reliability.multiplier, arr = final_arr })
  G.E_MANAGER:add_event(Event({ trigger = "immediate", blocking = true, func = function()
    local target = math.max(1, (G.GAME.blind and G.GAME.blind.target) or final_arr)
    local intensity = clamp(.7 + math.log(1 + final_arr / target) / math.log(2), .7, 2.5)
    Juice.shake(1.25 + .8 * intensity); Juice.pulse("score"); Juice.flash(.12 + .04 * intensity, G.C.arr)
    Audio.event("score_final", { pitch = .94 + .12 * intensity, intensity = intensity })
    Particles.emit("final", G.WINDOW.w / 2, 533, G.C.arr, intensity)
    return true
  end }))
  ease_value(G.GAME.score, "arr", final_arr, 0.55, {
    blocking = true,
    func = function()
      G.GAME.this_ship_arr = final_arr
      G.GAME._last_hand_ndl = G.GAME._ndl or 0                                  -- 1.5a: snapshot just-shipped hand's distinct Layers
      G.GAME.run_best_arr = math.max(G.GAME.run_best_arr or 0, final_arr)       -- 1.5a: run high-water ARR
      Juice.pulse("score")
    end,
  })
end

-- Fire a run-loop hook (engine v2): every founder is asked with ctx[name]=true. Non-scoring — chips/mult
-- on the scratch score are discarded; economy (dollars) routes to pending_dollars; state-write op kinds
-- (meter/gen/grant/clear_clash, added in later phases) mutate G.GAME directly. Founder DSLs listen to
-- run-loop events (ante_start, setting_blind, blind_won/lost, end_of_round, discard, selling_*, …) with
-- ZERO new interpreter code, because effect_interp keys purely on ctx[hook].
function Scoring.fire_hook(name, over)
  if not (G.jokers and G.jokers.cards) then return end
  local base = { cardarea = G.jokers, scoring_name = G.GAME and G.GAME.scoring_name }
  local scratch = { chips = 0, mult = 0 }
  for _, jk in ipairs(G.jokers.cards) do
    local c = ctx(base, over); c[name] = true
    apply_effect(scratch, eval_card(jk, c))
  end
end

return Scoring
