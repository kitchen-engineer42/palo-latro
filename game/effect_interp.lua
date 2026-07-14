-- game/effect_interp.lua — data-driven founder ability interpreter (bridge B2).
-- A founder center carries `dsl = { hook, gate?, ops[], once? }`; this executes it into the standard
-- effect table {chips,mult,x_mult,dollars} (or {jokers={repetitions}} for retrigger) that scoring.lua
-- consumes. Covers the 6 ability shapes the deep-dive found over the engine's real helper vocabulary;
-- the snowball counters (ships_this_run / rounds_held / …) are approximated by a generic per-trigger
-- accumulator (the f_stoppelman/f_andreessen cfg pattern). Abilities with no dsl fall back (B1).

local Meters = require("game.meters")
local Coverage = require("game.coverage")
local RNG = require("game.rng")

local Interp = {}

-- helpers (count sources) -------------------------------------------------
local function coverage(ctx)
  return ctx.coverage or Coverage.analyze(ctx.scoring_hand or {})
end
local function distinct_layers(ctx)
  return coverage(ctx).distinct
end
local function others() return math.max(0, #G.jokers.cards - 1) end
local function empty_slots() return math.max(0, (G.jokers.card_limit or 5) - #G.jokers.cards) end
local function hand_size(ctx) return #(ctx.scoring_hand or {}) end
local function count_group(group)
  local n = 0
  for _, c in ipairs(G.jokers.cards) do
    local g = c.center and c.center.groups
    if c.center and (c.center.mafia and group == "paypal-mafia") then n = n + 1
    elseif g then for _, x in ipairs(g) do if x == group then n = n + 1; break end end end
  end
  return n
end
local function distinct_sub_roles(ctx)
  return coverage(ctx).subrole_count
end

local HELP = {
  distinct_layers = function(ctx) return distinct_layers(ctx) end,
  others = function(ctx) return others() end,
  empty_slots = function(ctx) return empty_slots() end,
  hand_size = function(ctx) return hand_size(ctx) end,
  distinct_sub_roles = function(ctx) return distinct_sub_roles(ctx) end,
}
-- count source for a `scale` op. Run-state helpers (E1) read G.GAME / per-founder cfg.
local function help(name, ctx, card, gate)
  if name == "count_group" then return count_group(gate and gate.group or "") end
  if name == "ante" then return (G.GAME and G.GAME.ante) or 1 end
  if name == "round_num" then return (G.GAME and G.GAME.round_num) or 0 end
  if name == "ships_this_run" then return (G.GAME and G.GAME.ships_this_run) or 0 end
  if name == "rounds_held" then
    local cf = card and card.ability and card.ability.config
    local now = (G.GAME and G.GAME.round_num) or 0
    return math.max(0, now - ((cf and cf._hire_round) or now))
  end
  if name == "overkill" then return (G.GAME and G.GAME.overkill) or 0 end
  if name == "cash" then return (G.GAME and G.GAME.cash) or 0 end
  if name == "runway" then return (G.GAME and G.GAME.runway) or 0 end
  if name == "distinct_layers_seen_run" then
    local n = 0; for _ in pairs((G.GAME and G.GAME.layers_seen_run) or {}) do n = n + 1 end; return n
  end
  if name == "distinct_app_types_shipped" then
    local n = 0; for _ in pairs((G.GAME and G.GAME.app_types_shipped_run) or {}) do n = n + 1 end; return n
  end
  if name == "maturity_rung" then return (G.GAME and G.GAME.maturity_rung) or 1 end
  -- hand-shape per-sources (A): pure functions of the scoring hand + run state
  if name == "unplayed_cards" then return math.max(0, ((G.GAME and G.GAME.hand_size) or 8) - #(ctx.scoring_hand or {})) end
  if name == "unused_layers" then return math.max(0, 5 - distinct_layers(ctx)) end
  if name == "redundant_cards" then return coverage(ctx).redundant_cards end
  if name == "cards_of_layer" then                         -- count of gate/op.layer in the scoring hand (covers ai_cards)
    local cards = ctx.scoring_hand or {}
    return Coverage.count_layer(cards, gate and gate.layer, coverage(ctx))
  end
  if name == "deck_layer_count" then                       -- count of gate/op.layer across the whole deck
    local cards = (G.deck and G.deck.cards) or {}
    return Coverage.count_layer(cards, gate and gate.layer)
  end
  if name == "new_app_types" then return (G.GAME and G.GAME._new_app_types) or 0 end   -- delta this Ship (B)
  if name == "new_layers" then return (G.GAME and G.GAME._new_layers) or 0 end          -- delta this Ship (B)
  if name == "arr_ratio" then                              -- running ARR / blind target (meaningful on `after`)
    local t = math.max(1, (G.GAME and G.GAME.blind and G.GAME.blind.target) or 1)
    return ((G.GAME and (G.GAME._running_arr or G.GAME.this_ship_arr)) or 0) / t
  end
  -- 1.5a per-sources
  if name == "running_arr" then return (G.GAME and G.GAME._running_arr) or 0 end
  if name == "run_best_arr" then return (G.GAME and G.GAME.run_best_arr) or 0 end
  if name == "founders_hired_this_run" then return (G.GAME and G.GAME.founders_hired_run) or #((G.jokers and G.jokers.cards) or {}) end
  if name == "last_hand_distinct_layers" then return (G.GAME and G.GAME._last_hand_ndl) or 0 end
  if name == "distinct_markets_seen_run" then
    local n = 0; for _ in pairs((G.GAME and G.GAME.markets_seen_run) or {}) do n = n + 1 end; return math.max(1, n)
  end
  if name == "cards_of_layer_in_hand" then                 -- held (un-played) cards of gate/op.layer
    local cards = (G.hand and G.hand.cards) or {}
    return Coverage.count_layer(cards, gate and gate.layer)
  end
  if name == "salary_due" then                             -- this round's payroll (Σ salary × target / div)
    return require("game.economy").payroll_due(G.GAME, (G.jokers and G.jokers.cards) or {})
  end
  if G.GAME and G.GAME.meters and G.GAME.meters[name] then return Meters.get(name) end   -- meter read (E4)
  local f = HELP[name]; return f and f(ctx) or 0
end

local function cfg(card) card.ability.config = card.ability.config or {}; return card.ability.config end

-- gates -------------------------------------------------------------------
local function layer_present(ctx, layer)
  return Coverage.has_layer(ctx.scoring_hand or {}, layer, coverage(ctx))
end
local CMP = { [">="]=function(a,b) return a>=b end, ["<="]=function(a,b) return a<=b end,
              ["=="]=function(a,b) return a==b end, [">"]=function(a,b) return a>b end,
              ["<"]=function(a,b) return a<b end }
local function eval_gate(g, ctx, card)
  if not g then return true end
  local k = g.g
  if k == "layer_present" then return layer_present(ctx, g.layer)
  elseif k == "card_layer" then return ctx.other_card and Coverage.card_has_layer(ctx.other_card, g.layer, coverage(ctx))
  elseif k == "app_type_in" then
    for _, n in ipairs(g.names or {}) do if ctx.scoring_name == n then return true end end
    return false
  elseif k == "count" then
    local v = (g.per == "count_group") and count_group(g.group) or help(g.per, ctx, card, g)
    return (CMP[g.op] or CMP["=="])(v, g.val or 0)
  elseif k == "ante" then
    return (CMP[g.op] or CMP[">="])((G.GAME and G.GAME.ante) or 1, g.val or 1)
  elseif k == "overkill" then
    return (CMP[g.op] or CMP[">="])((G.GAME and G.GAME.overkill) or 0, g.val or 0)
  elseif k == "is_boss_blind" then
    return (G.GAME and G.GAME.blind and G.GAME.blind.is_boss) or false
  elseif k == "market" then                                  -- E5: gate on the run's Market
    return (G.GAME and G.GAME.market and (g.attr == nil or G.GAME.market[g.attr] == g.value)) or false
  elseif k == "has_group" then
    return count_group(g.group) >= (g.val or 1)
  elseif k == "and" then
    for _, sub in ipairs(g.gs or {}) do if not eval_gate(sub, ctx, card) then return false end end
    return true
  elseif k == "or" then
    for _, sub in ipairs(g.gs or {}) do if eval_gate(sub, ctx, card) then return true end end
    return false
  elseif k == "not" then return not eval_gate(g.g1, ctx, card)
  elseif k == "arr_ratio" then                               -- F: running ARR vs blind target (use on `after`)
    local t = math.max(1, (G.GAME and G.GAME.blind and G.GAME.blind.target) or 1)
    local r = ((G.GAME and (G.GAME._running_arr or G.GAME.this_ship_arr)) or 0) / t
    return (CMP[g.op] or CMP[">="])(r, g.val or 1)
  elseif k == "all_distinct_layers" then                     -- F: every played card is a distinct Layer
    return Coverage.is_all_distinct(ctx.scoring_hand or {}, coverage(ctx))
  elseif k == "market_fit" then                              -- F: the run's Market-fit multiplier threshold
    return (CMP[g.op] or CMP[">="])((G.GAME and G.GAME.last_fit) or 1, g.val or 1)
  end
  return false
end

-- ops ---------------------------------------------------------------------
local function add_field(eff, field, value)
  if field == "x_mult" then eff.x_mult = (eff.x_mult or 1) * value
  else eff[field] = (eff[field] or 0) + value end
end

local function run_op(op, ctx, card, eff)
  local k = op.k
  if k == "scale" then
    local count = op.per and help(op.per, ctx, card, op) or 1
    local base = op.base or (op.field == "x_mult" and 1 or 0)
    add_field(eff, op.field, base + (op.coef or 0) * count)
  elseif k == "acc" then
    local c = cfg(card)
    local skey = (op.state or "n") .. (op.key == "scoring_name" and ("_" .. (ctx.scoring_name or "?")) or "")  -- 1.5a: per-key counter (per App Type)
    local key = "_acc_" .. skey
    local before = c[key] or 0
    local inc = true                                         -- C: step — trigger(default)=every eval; round/ship=once per new round/ship
    if op.step == "round" then local g = (G.GAME and G.GAME.round_num) or 0; inc = (c[key .. "_g"] ~= g); c[key .. "_g"] = g
    elseif op.step == "ship" then local g = (G.GAME and G.GAME.ships_this_run) or 0; inc = (c[key .. "_g"] ~= g); c[key .. "_g"] = g end
    local delta = op.inc_per and help(op.inc_per, ctx, card, op) or 1                          -- 1.5a: increment by a per-source (not just +1)
    local nextv = inc and before + delta or before
    if op.max then nextv = math.min(nextv, op.max) end                                         -- C: max cap
    local counter = (op.when == "post") and nextv or before
    c[key] = nextv
    local base = op.base or (op.field == "x_mult" and 1 or 0)
    add_field(eff, op.field, base + (op.coef or 0) * counter)
  elseif k == "grant" and G.GAME then                       -- P&L writes
    local amt = (op.amount or 0) + (op.per and (op.coef or 1) * help(op.per, ctx, card, op) or 0)
    if op.pct then amt = amt + op.pct * help("salary_due", ctx, card, op) end   -- 1.5a: % payroll relief
    if op.max then                                                              -- 1.5a: cumulative per-run cap
      local c = cfg(card); local gk = "_granted_" .. (op.what or "x"); local g0 = c[gk] or 0
      amt = math.max(0, math.min(amt, op.max - g0)); c[gk] = g0 + amt
    end
    if op.what == "cash" then G.GAME.cash = (G.GAME.cash or 0) + amt
    elseif op.what == "margin" then
      local Economy = require("game.economy")
      G.GAME.margin_bonus = math.min(Economy.MAX_MARGIN_BONUS,
        (G.GAME.margin_bonus or 0) + math.max(-0.1, math.min(0.1, amt)))
    elseif op.what == "salary" then G.GAME.salary_relief = (G.GAME.salary_relief or 0) + amt end
  elseif k == "clear_clash" and G.GAME then                  -- utility: dissolve compatibility clashes (E3)
    if op.amount == "all" then G.GAME._clashes_active = 0
    else
      -- Generated abilities use both the flat `amount=N` shape and a nested scalable
      -- `amount={base,coef,per}` shape. Normalize them here so the latter cannot reach math.floor as a table.
      local spec = type(op.amount) == "table" and op.amount or op
      local amt = spec.per and ((spec.base or 0) + (spec.coef or 1) * help(spec.per, ctx, card, spec))
        or (op.amount or 1)  -- 1.5a: scalable
      G.GAME._clashes_active = math.max(0, (G.GAME._clashes_active or 0) - math.floor(amt))
    end
  elseif k == "gen" and G.GENERATE then                      -- generation: create cards mid-run (E3); amount scalable (E)
    local amt = op.per and ((op.base or 0) + (op.coef or 1) * help(op.per, ctx, card, op)) or (op.amount or 1)
    if amt >= 1 then G.GENERATE(op.kind, { layer = op.layer, amount = math.floor(amt), key = op.key, which = op.which }) end
  elseif k == "meter" and G.GAME then                        -- reputation/identity meters (E4)
    Meters.add(op.name, (op.amount or 0) + (op.per and (op.coef or 1) * help(op.per, ctx, card, op) or 0))
  elseif k == "gamble" then                                  -- stake-or-spike ×mult (Rocket-Boy/Thiel)
    local c = cfg(card)
    local key = "_gfail_" .. (op.state or "g")
    local fails, n = c[key] or 0, op.n or 3
    local res
    if fails >= n then res = op.guaranteed or (op.win or 2) * 2; c[key] = 0       -- the Nth try is guaranteed (huge)
    elseif RNG.value("effect") < (op.p or 0.5) then res = op.win or 2; c[key] = 0  -- hit
    else res = op.lose or 1; c[key] = fails + 1 end                               -- whiff → build the streak
    add_field(eff, "x_mult", res)
  elseif k == "delete_card" and G.GAME then                  -- cut a Layer for Margin; over-cut → debt
    local before = #(G.GAME.master_deck or {})
    if G.GENERATE then G.GENERATE("remove_card", { which = op.which or "lowest", amount = 1 }) end
    if #(G.GAME.master_deck or {}) < before then
      local Economy = require("game.economy")
      G.GAME.margin_bonus = math.min(Economy.MAX_MARGIN_BONUS,
        (G.GAME.margin_bonus or 0) + math.min(op.margin or 0.1, 0.1))
      local c = cfg(card); c._cuts = (c._cuts or 0) + 1
      if c._cuts > (op.overcut or 3) then Meters.add("tech_debt", 1) end
    end
  elseif k == "clash_tax" then                               -- skim a fee per active clash (Dorsey Block)
    add_field(eff, op.field or "dollars", -(op.per or 1) * ((G.GAME and G.GAME._clashes_active) or 0))
  elseif k == "arm" and G.GAME then                          -- D: event-hook buff, consumed at the next scoring pass
    local val = (op.base or (op.field == "x_mult" and 1 or 0)) + (op.coef or 0) * (op.per and help(op.per, ctx, card, op) or 0)
    G.GAME._armed_buffs = G.GAME._armed_buffs or {}
    G.GAME._armed_buffs[#G.GAME._armed_buffs + 1] = { field = op.field or "mult", value = val }
  end
end

-- entry -------------------------------------------------------------------
-- returns an effect table, or nil if the dsl doesn't fire in this context.
function Interp.run(card, ctx)
  local dsl = card.center and card.center.dsl
  if not dsl then return nil end

  -- C: reset accumulators on a reset event (selling_self / blind_lost) — runs BEFORE the hook gate,
  -- independent of the founder's own hook, so the counter zeroes even though the dsl scores elsewhere.
  for _, op in ipairs(dsl.ops or {}) do
    if op.k == "acc" and op.reset_on then
      for _, rh in ipairs(op.reset_on) do
        if ctx[rh] then local c = cfg(card); c["_acc_" .. (op.state or "n")] = 0; c["_acc_" .. (op.state or "n") .. "_g"] = nil end
      end
    end
  end

  -- retrigger is special: only meaningful during the repetition pass
  if dsl.retrigger and ctx.repetition then
    if eval_gate(dsl.gate, ctx, card) then
      local rt = dsl.retrigger
      local reps = (type(rt) == "table")                                        -- 1.5a: scalable reps {base,coef,per}
        and math.floor((rt.base or 0) + (rt.coef or 1) * help(rt.per, ctx, card, rt)) or rt
      if dsl.retrigger_target == "highest" and ctx.other_card then              -- 1.5a: only the top-Users played card
        local best = ctx.other_card
        local function effective_users(subject)
          return (subject.get_users and subject:get_users()) or subject.base_users or 0
        end
        for _, oc in ipairs(ctx.scoring_hand or {}) do
          if effective_users(oc) > effective_users(best) then best = oc end
        end
        if ctx.other_card ~= best then return nil end
      end
      if reps and reps >= 1 then return { jokers = { repetitions = math.min(2, reps) } } end
    end
    return nil
  end

  local hook = dsl.hook or "joker_main"
  if not ctx[hook] then return nil end
  if not eval_gate(dsl.gate, ctx, card) then return nil end

  local c = cfg(card)
  if dsl.once then
    local scope = dsl.once_scope or "run"
    local key = "_run"
    if scope == "blind" then key = "_b" .. ((G.GAME and G.GAME._bid) or 0)
    elseif scope == "ante" then key = "_a" .. ((G.GAME and G.GAME._aid) or 0) end
    c._once = c._once or {}
    if c._once[key] then return nil end
    c._once[key] = true
  end

  local eff = {}
  for _, op in ipairs(dsl.ops or {}) do
    if not op.gate or eval_gate(op.gate, ctx, card) then run_op(op, ctx, card, eff) end   -- 1.5a: per-op gate (multi-clause)
  end
  return eff
end

-- 1.5b: passive run-modifiers — applied WHILE a founder is hired, reverted on sell. Spec lives at
-- center.dsl.passive = { what, amount }. Keyed by card.ID so apply/revert is exact + idempotent. Numeric
-- modifiers only (hand_size / founder_slots / salary-relief); the engine reads the modified base directly.
function Interp.apply_passive(card)
  local p = card and card.center and card.center.dsl and card.center.dsl.passive
  if not (p and G.GAME) then return end
  G.GAME._passives = G.GAME._passives or {}
  local id = card.ID or tostring(card)
  if G.GAME._passives[id] then return end                  -- already applied
  local requested, applied = p.amount or 0, 0
  if p.what == "hand_size" then
    local before = G.GAME.hand_size or 8
    G.GAME.hand_size = math.max(1, before + requested)
    applied = G.GAME.hand_size - before
  elseif p.what == "founder_slots" then
    local before = G.GAME.founder_slots or 5
    G.GAME.founder_slots = math.max(1, before + requested)
    applied = G.GAME.founder_slots - before
  elseif p.what == "salary" then
    G.GAME.passive_salary = (G.GAME.passive_salary or 0) + requested
    applied = requested
  end
  -- Store the actual bounded delta so removal is the exact inverse even when
  -- applying a negative modifier at the minimum hand/slot size.
  G.GAME._passives[id] = { what = p.what, amount = applied }
end
function Interp.revert_passive(card)
  local id = card and (card.ID or tostring(card))
  local rec = id and G.GAME and G.GAME._passives and G.GAME._passives[id]
  if not rec then return end
  local amt = rec.amount or 0
  if rec.what == "hand_size" then G.GAME.hand_size = math.max(1, (G.GAME.hand_size or 8) - amt)
  elseif rec.what == "founder_slots" then G.GAME.founder_slots = math.max(1, (G.GAME.founder_slots or 5) - amt)
  elseif rec.what == "salary" then G.GAME.passive_salary = (G.GAME.passive_salary or 0) - amt end
  G.GAME._passives[id] = nil
end

return Interp
