-- game/effect_interp.lua — data-driven founder ability interpreter (bridge B2).
-- A founder center carries `dsl = { hook, gate?, ops[], once? }`; this executes it into the standard
-- effect table {chips,mult,x_mult,dollars} (or {jokers={repetitions}} for retrigger) that scoring.lua
-- consumes. Covers the 6 ability shapes the deep-dive found over the engine's real helper vocabulary;
-- the snowball counters (ships_this_run / rounds_held / …) are approximated by a generic per-trigger
-- accumulator (the f_stoppelman/f_andreessen cfg pattern). Abilities with no dsl fall back (B1).

local Meters = require("game.meters")
local Coverage = require("game.coverage")
local RNG = require("game.rng")
local DeckTransactions = require("game.deck_transactions")
local TechMutation = require("game.tech_mutation")
local ShopDirectives = require("game.shop_directives")
local Centers = require("game.centers")

local Interp = {}

-- helpers (count sources) -------------------------------------------------
local function coverage(ctx)
  return ctx.coverage or Coverage.analyze(ctx.scoring_hand or {})
end
local function distinct_layers(ctx)
  return coverage(ctx).distinct
end
local function in_live_row(card)
  for _, live in ipairs((G.jokers and G.jokers.cards) or {}) do if live == card then return true end end
  return false
end
local function others(card)
  return math.max(0, #((G.jokers and G.jokers.cards) or {}) - (in_live_row(card) and 1 or 0))
end
local function empty_slots() return math.max(0, (G.jokers.card_limit or 5) - #G.jokers.cards) end
local function hand_size(ctx) return #(ctx.scoring_hand or {}) end
local function center_has_group(center, group)
  if center and center.mafia and group == "paypal-mafia" then return true end
  for _, value in ipairs((center and center.groups) or {}) do if value == group then return true end end
  return false
end
local function count_group(group, card)
  local n = 0
  for _, c in ipairs(G.jokers.cards) do
    if center_has_group(c.center, group) then n = n + 1 end
  end
  if card and not in_live_row(card) and center_has_group(card.center, group) then n = n + 1 end
  return n
end
local function distinct_sub_roles(ctx)
  return coverage(ctx).subrole_count
end

local function effective_users(card)
  return (card and card.get_users and card:get_users()) or (card and card.base_users) or 0
end

local function same_layer_count(ctx)
  local subject = ctx.other_card
  if not subject then return 0 end
  local analysis, wanted = coverage(ctx), {}
  for _, layer in ipairs(Coverage.layers_for(subject, analysis)) do wanted[layer] = true end
  local count = 0
  for _, card in ipairs(ctx.scoring_hand or {}) do
    for _, layer in ipairs(Coverage.layers_for(card, analysis)) do
      if wanted[layer] then count = count + 1; break end
    end
  end
  return count
end

local function repeated_layer_shape(ctx)
  local analysis = coverage(ctx)
  local repeated, singleton = 0, 0
  for _, card in ipairs(ctx.scoring_hand or {}) do
    local is_repeated = false
    for _, layer in ipairs(Coverage.layers_for(card, analysis)) do
      if (analysis.counts[layer] or 0) >= 2 then is_repeated = true; break end
    end
    if is_repeated then repeated = repeated + 1 else singleton = singleton + 1 end
  end
  return repeated, singleton
end

local HELP = {
  distinct_layers = function(ctx) return distinct_layers(ctx) end,
  others = function(ctx) return others() end,
  empty_slots = function(ctx) return empty_slots() end,
  hand_size = function(ctx) return hand_size(ctx) end,
  distinct_sub_roles = function(ctx) return distinct_sub_roles(ctx) end,
}
local cfg
-- count source for a `scale` op. Run-state helpers (E1) read G.GAME / per-founder cfg.
local function help(name, ctx, card, gate)
  if name == "count_group" then return count_group(gate and gate.group or "", card) end
  if name == "others" then return others(card) end
  if name == "ante" then return (G.GAME and G.GAME.ante) or 1 end
  if name == "round_num" then return (G.GAME and G.GAME.round_num) or 0 end
  if name == "ships_this_run" then return (G.GAME and G.GAME.ships_this_run) or 0 end
  if name == "rounds_held" then
    local cf = card and card.ability and card.ability.config
    local now = (G.GAME and G.GAME.round_num) or 0
    return math.max(0, now - ((cf and cf._hire_round) or now))
  end
  if name == "overkill" then
    if ctx.final_arr ~= nil then
      local target = (G.GAME and G.GAME.blind and G.GAME.blind.target) or 0
      return math.max(0, ctx.final_arr - target)
    end
    return (G.GAME and G.GAME.overkill) or 0
  end
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
  if name == "arr_ratio" then                              -- named score snapshot / blind target
    local t = math.max(1, (G.GAME and G.GAME.blind and G.GAME.blind.target) or 1)
    return help("running_arr", ctx, card, gate) / t
  end
  -- 1.5a per-sources
  if name == "running_arr" then
    local stage = gate and gate.stage or "pre_after"
    if stage == "final" then return ctx.final_arr or (G.GAME and (G.GAME._final_arr or G.GAME.last_ship_arr or G.GAME.this_ship_arr)) or 0 end
    if stage == "pre_market" then return ctx.pre_market_arr or (G.GAME and G.GAME._pre_market_arr) or 0 end
    return ctx.pre_after_arr or (G.GAME and (G.GAME._running_arr or G.GAME._pre_after_arr)) or 0
  end
  if name == "run_best_arr" then return (G.GAME and G.GAME.run_best_arr) or 0 end
  if name == "founders_hired_this_run" then return (G.GAME and G.GAME.founders_hired_run) or #((G.jokers and G.jokers.cards) or {}) end
  if name == "founder_count" then return #((G.jokers and G.jokers.cards) or {}) end
  if name == "same_layer_count" then return same_layer_count(ctx) end
  if name == "other_card_users" then return effective_users(ctx.other_card) end
  if name == "cards_in_repeated_layers" then return repeated_layer_shape(ctx) end
  if name == "singleton_cards" then local _, n = repeated_layer_shape(ctx); return n end
  if name == "card_mark_age" then
    local _, mark = TechMutation.marked_entry(G.GAME, card, gate and gate.target)
    return mark and math.max(0, tonumber(mark.age) or 0) or 0
  end
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
  if name == "blind_target" then return (G.GAME and G.GAME.blind and G.GAME.blind.target) or 0 end
  if name == "target_shortfall" then
    local target = (G.GAME and G.GAME.blind and G.GAME.blind.target) or 0
    local current = ctx.final_arr or (G.GAME and (G.GAME._running_arr or G.GAME.this_ship_arr)) or 0
    return math.max(0, target - current)
  end
  if name == "final_arr" then return ctx.final_arr or (G.GAME and (G.GAME._final_arr or G.GAME.last_ship_arr)) or 0 end
  if name == "cash_spent_round" then return (G.GAME and G.GAME.cash_spent_round) or 0 end
  if name == "founders_hired_round" then return (G.GAME and G.GAME.founders_hired_round) or 0 end
  if name == "pivots_round" then return (G.GAME and G.GAME.pivots_round) or 0 end
  if name == "counter" then
    local state = gate and gate.state
    return state and (cfg(card)["_state_" .. state] or 0) or 0
  end
  if G.GAME and G.GAME.meters and G.GAME.meters[name] then return Meters.get(name) end   -- meter read (E4)
  local f = HELP[name]; return f and f(ctx) or 0
end

cfg = function(card) card.ability.config = card.ability.config or {}; return card.ability.config end

local function effect_scale(card)
  local value = tonumber(cfg(card)._effect_scale) or 1
  return math.max(0, math.min(1, value))
end

-- gates -------------------------------------------------------------------
local function layer_present(ctx, layer)
  return Coverage.has_layer(ctx.scoring_hand or {}, layer, coverage(ctx))
end
local CMP = { [">="]=function(a,b) return a>=b end, ["<="]=function(a,b) return a<=b end,
              ["=="]=function(a,b) return a==b end, [">"]=function(a,b) return a>b end,
              ["<"]=function(a,b) return a<b end }
local function compare(op, a, b)
  local fn = CMP[op]
  if not fn or type(a) ~= "number" or type(b) ~= "number" then return nil end
  return fn(a, b)
end
local function eval_gate(g, ctx, card)
  if not g then return true end
  local k = g.g
  if k == "layer_present" then return layer_present(ctx, g.layer)
  elseif k == "card_layer" then return ctx.other_card and Coverage.card_has_layer(ctx.other_card, g.layer, coverage(ctx))
  elseif k == "app_type_in" then
    for _, n in ipairs(g.names or {}) do if ctx.scoring_name == n then return true end end
    return false
  elseif k == "count" then
    local v = (g.per == "count_group") and count_group(g.group, card) or help(g.per, ctx, card, g)
    return compare(g.op, v, g.val)
  elseif k == "ante" then
    return compare(g.op, (G.GAME and G.GAME.ante) or 1, g.val)
  elseif k == "overkill" then
    return compare(g.op, (G.GAME and G.GAME.overkill) or 0, g.val)
  elseif k == "is_boss_blind" then
    return (G.GAME and G.GAME.blind and G.GAME.blind.is_boss) or false
  elseif k == "market" then                                  -- E5: gate on the run's Market
    return (G.GAME and G.GAME.market and (g.attr == nil or G.GAME.market[g.attr] == g.value)) or false
  elseif k == "has_group" then
    return count_group(g.group, card) >= (g.val or 1)
  elseif k == "and" then
    for _, sub in ipairs(g.gs or {}) do local result = eval_gate(sub, ctx, card); if result == nil then return nil elseif not result then return false end end
    return true
  elseif k == "or" then
    local matched = false
    for _, sub in ipairs(g.gs or {}) do local result = eval_gate(sub, ctx, card); if result == nil then return nil elseif result then matched = true end end
    if matched then return true end
    return false
  elseif k == "not" then
    local result = eval_gate(g.g1, ctx, card)
    if result == nil then return nil end
    return not result
  elseif k == "arr_ratio" then                               -- F: running ARR vs blind target (use on `after`)
    local t = math.max(1, (G.GAME and G.GAME.blind and G.GAME.blind.target) or 1)
    local r = help("running_arr", ctx, card, g) / t
    return compare(g.op, r, g.val)
  elseif k == "previous_arr_ratio" then
    local previous = G.GAME and G.GAME.previous_ship_arr
    if previous == nil then return false end
    local target = math.max(1, (G.GAME.blind and G.GAME.blind.target) or 1)
    return compare(g.op, previous / target, g.val)
  elseif k == "all_distinct_layers" then                     -- F: every played card is a distinct Layer
    return Coverage.is_all_distinct(ctx.scoring_hand or {}, coverage(ctx))
  elseif k == "market_fit" then                              -- F: the run's Market-fit multiplier threshold
    return compare(g.op, ctx.market_fit or 1, g.val)
  elseif k == "state" then
    local value = cfg(card)["_state_" .. tostring(g.state or "")]
    return compare(g.op, value or 0, g.val)
  elseif k == "event" then
    local value = ctx[g.field]
    if g.op then return compare(g.op, tonumber(value), g.val) end
    return value == g.value
  elseif k == "played_covers_deck_layers" then
    local required = {}
    for _, entry in ipairs((G.GAME and G.GAME.master_deck) or {}) do
      local center = Centers.get(entry.center_key)
      if center then
        local proxy = {
          center=center, layer=center.layer, layer_override=entry.layer_override,
          enhancement=entry.enhancement or entry.enh, modifier_state=entry.modifier_state,
          stickers=entry.stickers, config=entry.config,
        }
        for _, layer in ipairs(Coverage.card_options(proxy)) do required[layer] = true end
      end
    end
    local analysis = coverage(ctx)
    local any = false
    for layer in pairs(required) do
      any = true
      if not analysis.counts[layer] then return false end
    end
    return any
  elseif k == "marked_card_played" then
    local entry = TechMutation.marked_entry(G.GAME, card, g.target)
    if not entry then return false end
    for _, played in ipairs(ctx.scoring_hand or {}) do if played.uid == entry.uid then return true end end
    return false
  elseif k == "card_mark" then
    return TechMutation.card_has_mark(ctx.other_card, card, g.target)
  end
  -- Unknown gates are invalid data. Preserve an explicit indeterminate result
  -- so compositional gates (especially `not`) fail closed instead of turning a
  -- misspelling into a truthy gameplay condition.
  return nil
end

-- ops ---------------------------------------------------------------------
local function add_field(eff, field, value)
  if field == "x_mult" or field == "x_chips" then eff[field] = (eff[field] or 1) * value
  else eff[field] = (eff[field] or 0) + value end
end

local function op_value(op, ctx, card)
  local value = op.amount or op.base or 0
  if op.per then value = value + (op.coef or 1) * help(op.per, ctx, card, op) end
  if op.floor ~= nil then value = math.max(op.floor, value) end
  if op.cap ~= nil then value = math.min(op.cap, value) end
  return value
end

local function scalable_value(value, ctx, card, default)
  local spec = type(value) == "table" and value or nil
  local result
  if spec then result = (spec.base or 0) + (spec.coef or 0) * (spec.per and help(spec.per, ctx, card, spec) or 0)
  elseif value ~= nil then result = value
  else result = default or 0 end
  if spec and spec.floor ~= nil then result = math.max(spec.floor, result) end
  if spec and spec.cap ~= nil then result = math.min(spec.cap, result) end
  if spec and spec.round == "floor" then result = math.floor(result)
  elseif spec and spec.round == "ceil" then result = math.ceil(result) end
  return result
end

local DECK_GENERATION = {
  tech_card = true,
  specific_tech_card = true,
  remove_tech_card = true,
  remove_card = true,
  copy_card = true,
}

-- Resolve every deck-generating operation in a Founder clause before any of
-- that clause's dependent score/economy/state operations run. Fractional
-- Distill carry is also staged and only published after a successful commit.
local function prepare_deck_generation(spec, ctx, card)
  local operations, carry_updates, pending_carry = {}, {}, {}
  local has_deck_generation = false
  for _, op in ipairs(spec.ops or {}) do
    local gate = not op.gate or eval_gate(op.gate, ctx, card)
    if op.k == "gen" and DECK_GENERATION[op.kind] and gate == true then
      has_deck_generation = true
      local amount = op.per and ((op.base or 0) + (op.coef or 1) * help(op.per, ctx, card, op))
        or (op.amount or 1)
      if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
        return nil, "Founder generation amount must be finite"
      end
      local scale = effect_scale(card)
      if scale < 1 then
        local carry_key = "_scaled_gen_" .. table.concat({ op.kind or "x", op.layer or "", op.which or "" }, "_")
        local current = pending_carry[carry_key]
        if current == nil then current = cfg(card)[carry_key] or 0 end
        amount = amount * scale + current
        local whole = math.floor(amount)
        pending_carry[carry_key] = amount - whole
        carry_updates[carry_key] = pending_carry[carry_key]
        amount = whole
      else
        amount = math.floor(amount)
      end
      if amount >= 1 then
        local layer, layers = op.layer, nil
        if layer == "random_seen" then
          layer, layers = nil, {}
          for _, candidate in ipairs(Coverage.CORE_ORDER) do
            if G.GAME.layers_seen_run and G.GAME.layers_seen_run[candidate] then
              layers[#layers + 1] = candidate
            end
          end
          if #layers == 0 then return nil, "Founder generation has no previously used Layer" end
        end
        local operation, reason = DeckTransactions.operation_from_generate(op.kind, {
          layer = layer, layers = layers, amount = amount, key = op.key, which = op.which,
        })
        if not operation then return nil, reason end
        operations[#operations + 1] = operation
      end
    end
  end
  return {
    has_deck_generation = has_deck_generation,
    operations = operations,
    carry_updates = carry_updates,
  }
end

local function prepare_mutation(spec, ctx, card)
  local found
  for index, op in ipairs(spec.ops or {}) do
    if op.k == "mutate" and (not op.gate or eval_gate(op.gate, ctx, card) == true) then
      if found then return nil, "Founder clauses support one atomic Tech mutation" end
      local amount = scalable_value(op.amount, ctx, card, 1)
      if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
        return nil, "Founder mutation amount must be finite"
      end
      local prepared, reason = TechMutation.prepare(op, ctx, card, math.max(0, math.floor(amount)))
      if not prepared then return nil, reason end
      found = { index=index, prepared=prepared }
    end
  end
  return found or false
end

local function run_op(op, ctx, card, eff, deck_generation_committed, mutation_result)
  local k = op.k
  if k == "scale" then
    local count = op.per and help(op.per, ctx, card, op) or 1
    local base = op.base or ((op.field == "x_mult" or op.field == "x_chips") and 1 or 0)
    add_field(eff, op.field, base + (op.coef or 0) * count)
  elseif k == "x_add" then
    local field = op.field == "chips" and "x_chips_add" or "x_mult_add"
    eff[field] = (eff[field] or 0) + op_value(op, ctx, card)
  elseif k == "score_floor" then
    local field = ({ users="chips_floor", rev="mult_floor", arr="arr_floor" })[op.what]
    if field then eff[field] = math.max(eff[field] or 0, op_value(op, ctx, card)) end
  elseif k == "state" then
    local c, key = cfg(card), "_state_" .. tostring(op.state or "")
    local before, amount = c[key] or 0, op_value(op, ctx, card)
    local next_value
    if op.mode == "set" then next_value = amount
    elseif op.mode == "clear" then next_value = nil
    elseif op.mode == "max" then next_value = math.max(before, amount)
    elseif op.mode == "min" then next_value = math.min(before, amount)
    else next_value = before + amount end
    if next_value ~= nil then
      if op.floor ~= nil then next_value = math.max(op.floor, next_value) end
      if op.cap ~= nil then next_value = math.min(op.cap, next_value) end
    end
    c[key] = next_value
  elseif k == "acc" then
    local c = cfg(card)
    local skey = (op.state or "n") .. (op.key == "scoring_name" and ("_" .. (ctx.scoring_name or "?")) or "")  -- 1.5a: per-key counter (per App Type)
    local key = "_acc_" .. skey
    if op.key == "scoring_name" then
      local keys = c["_acc_keys_" .. (op.state or "n")] or {}
      keys[skey] = true
      c["_acc_keys_" .. (op.state or "n")] = keys
    end
    local before = c[key] or 0
    local inc = true                                         -- C: step — trigger(default)=every eval; round/ship=once per new round/ship
    if op.step == "round" then local g = (G.GAME and G.GAME.round_num) or 0; inc = (c[key .. "_g"] ~= g); c[key .. "_g"] = g
    elseif op.step == "ship" then local g = (G.GAME and G.GAME.ships_this_run) or 0; inc = (c[key .. "_g"] ~= g); c[key .. "_g"] = g end
    local delta = op.inc_per and help(op.inc_per, ctx, card, op) or 1                          -- 1.5a: increment by a per-source (not just +1)
    local nextv = inc and before + delta or before
    if op.max then nextv = math.min(nextv, op.max) end                                         -- C: max cap
    local counter = (op.when == "post") and nextv or before
    c[key] = nextv
    local base = op.base or ((op.field == "x_mult" or op.field == "x_chips") and 1 or 0)
    add_field(eff, op.field, base + (op.coef or 0) * counter)
  elseif k == "grant" and G.GAME then                       -- P&L writes
    local amt = (op.amount or 0) + (op.per and (op.coef or 1) * help(op.per, ctx, card, op) or 0)
    if op.pct then amt = amt + op.pct * help("salary_due", ctx, card, op) end   -- 1.5a: % payroll relief
    amt = amt * effect_scale(card)
    if op.what == "margin" then
      local event_cap = op.cap or 0.1
      amt = math.max(-event_cap, math.min(event_cap, amt))
    end
    local grant_max = op.max and op.max * effect_scale(card)
    if grant_max then                                                            -- 1.5a: cumulative per-run cap
      local c = cfg(card); local gk = "_granted_" .. (op.what or "x"); local g0 = c[gk] or 0
      amt = math.max(0, math.min(amt, grant_max - g0)); c[gk] = g0 + amt
    end
    if op.what == "cash" then G.GAME.cash = (G.GAME.cash or 0) + amt
    elseif op.what == "margin" then
      local Economy = require("game.economy")
      G.GAME.margin_bonus = math.min(Economy.MAX_MARGIN_BONUS,
        (G.GAME.margin_bonus or 0) + amt)
    elseif op.what == "salary" then G.GAME.salary_relief = (G.GAME.salary_relief or 0) + amt end
  elseif k == "spend" and G.GAME then
    local amount = math.max(0, op_value(op, ctx, card))
    require("game.founder_events").spend(G.GAME, amount, "founder_action", {
      founder_key = card.center_key or (card.center and card.center.key),
    })
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
  elseif k == "gen" and G.GENERATE and not (deck_generation_committed and DECK_GENERATION[op.kind]) then
                                                                  -- generation: create cards mid-run (E3); amount scalable (E)
    local amt = op.per and ((op.base or 0) + (op.coef or 1) * help(op.per, ctx, card, op)) or (op.amount or 1)
    local scale = effect_scale(card)
    if scale < 1 then
      local c = cfg(card)
      local carry_key = "_scaled_gen_" .. table.concat({ op.kind or "x", op.layer or "", op.which or "" }, "_")
      amt = amt * scale + (c[carry_key] or 0)
      c[carry_key] = amt - math.floor(amt)
    end
    if amt >= 1 then G.GENERATE(op.kind, { layer = op.layer, amount = math.floor(amt), key = op.key, which = op.which }) end
  elseif k == "mutate" then
    if mutation_result and mutation_result.chips then add_field(eff, "chips", mutation_result.chips) end
  elseif k == "offer" and G.GAME then
    local options = op.options and scalable_value(op.options, ctx, card)
    if options then options = math.max(2, math.min(6, math.floor(options))) end
    local row, reason = ShopDirectives.enqueue(G.GAME, {
      kind=op.kind, timing=op.timing, duration=op.duration, count=op.count or 1,
      rarity=op.rarity, free=op.free, pinned=op.pinned, discount=op.discount,
      pack_key=op.pack_key, options=options,
      source_key=card.center_key or (card.center and card.center.key),
      source_id=cfg(card)._founder_id or card.ID,
      label=op.label,
    })
    if row and row.timing == "current_or_next" and G.GAME.shop then
      require("game.shop").apply_directives("current")
    end
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
    local val = (op.base or ((op.field == "x_mult" or op.field == "x_chips") and 1 or 0))
      + (op.coef or 0) * (op.per and help(op.per, ctx, card, op) or 0)
    local scale = effect_scale(card)
    if op.field == "x_mult" or op.field == "x_chips" then val = 1 + (val - 1) * scale
    else val = val * scale end
    G.GAME._armed_buffs = G.GAME._armed_buffs or {}
    G.GAME._armed_buffs[#G.GAME._armed_buffs + 1] = { field = op.field or "mult", value = val }
  end
end

-- entry -------------------------------------------------------------------
-- returns an effect table, or nil if the dsl doesn't fire in this context.
local function merge_effect(out, effect)
  if not effect then return out end
  out = out or {}
  for key, value in pairs(effect) do
    if type(value) == "number" then
      if key == "x_mult" or key == "x_chips" then out[key] = (out[key] or 1) * value
      elseif key:match("_floor$") then out[key] = math.max(out[key] or 0, value)
      else out[key] = (out[key] or 0) + value end
    elseif type(value) == "table" then out[key] = merge_effect(out[key], value)
    else out[key] = value end
  end
  return out
end

local function reset_ops(spec, card, ctx)
  for _, op in ipairs(spec.ops or {}) do
    if (op.k == "acc" or op.k == "state") and op.reset_on then
      for _, rh in ipairs(op.reset_on) do
        if ctx[rh] then
          local c = cfg(card)
          if op.k == "state" then c["_state_" .. tostring(op.state or "")] = nil
          else
            local state = op.state or "n"
            if op.key == "scoring_name" then
              for skey in pairs(c["_acc_keys_" .. state] or {}) do
                c["_acc_" .. skey] = 0
                c["_acc_" .. skey .. "_g"] = nil
              end
              c["_acc_keys_" .. state] = {}
            else
              c["_acc_" .. state] = 0
              c["_acc_" .. state .. "_g"] = nil
            end
          end
        end
      end
    end
  end
end

local function once_key(spec, spec_id)
  local scope = spec.once_scope or "run"
  local key = "_run"
  if scope == "blind" then key = "_b" .. ((G.GAME and G.GAME._bid) or 0)
  elseif scope == "ante" then key = "_a" .. ((G.GAME and G.GAME._aid) or 0) end
  return tostring(spec.once_id or spec.id or spec_id or "root") .. key
end

local function run_spec(card, ctx, spec, spec_id)
  reset_ops(spec, card, ctx)

  -- C: reset accumulators on a reset event (selling_self / blind_lost) — runs BEFORE the hook gate,
  -- independent of the founder's own hook, so the counter zeroes even though the dsl scores elsewhere.
  -- retrigger is special: only meaningful during the repetition pass
  if spec.retrigger and ctx.repetition then
    if eval_gate(spec.gate, ctx, card) then
      local rt = spec.retrigger
      local reps = (type(rt) == "table")                                        -- 1.5a: scalable reps {base,coef,per}
        and math.floor((rt.base or 0) + (rt.coef or 1) * help(rt.per, ctx, card, rt)) or rt
      if spec.retrigger_target == "highest" and ctx.other_card then              -- 1.5a: only the top-Users played card
        local best = ctx.other_card
        local function effective_users(subject)
          return (subject.get_users and subject:get_users()) or subject.base_users or 0
        end
        for _, oc in ipairs(ctx.scoring_hand or {}) do
          if effective_users(oc) > effective_users(best) then best = oc end
        end
        if ctx.other_card ~= best then return nil end
      elseif spec.retrigger_target == "marked" and not TechMutation.card_has_mark(ctx.other_card, card,
          spec.gate and spec.gate.target) then
        return nil
      end
      if reps and reps >= 1 then return { jokers = { repetitions = math.min(2, reps) } } end
    end
    return nil
  end

  local hook = spec.hook or "joker_main"
  if not ctx[hook] then return nil end
  if not eval_gate(spec.gate, ctx, card) then return nil end

  local c = cfg(card)
  local once_token
  if spec.once then
    once_token = once_key(spec, spec_id)
    c._once = c._once or {}
    if c._once[once_token] then return nil end
  end

  local prepared = prepare_deck_generation(spec, ctx, card)
  if not prepared then return nil end
  local prepared_mutation = prepare_mutation(spec, ctx, card)
  if prepared_mutation == nil then return nil end
  local deck_result
  if #prepared.operations > 0 then
    local plan = DeckTransactions.plan(G.GAME, { ops = prepared.operations })
    if not plan then return nil end
    deck_result = DeckTransactions.commit(G.GAME, plan)
    if not deck_result.ok then return nil end
  elseif prepared.has_deck_generation then
    deck_result = { ok=true, requested=0, applied=0, changes={}, added_uids={}, removed_uids={} }
  end
  local mutation_result
  if prepared_mutation then
    mutation_result = TechMutation.commit(prepared_mutation.prepared)
    if not mutation_result.ok then return nil end
    if mutation_result.mutation_upgraded ~= nil then
      ctx.mutation_upgraded = mutation_result.mutation_upgraded
    end
  end
  for key, value in pairs(prepared.carry_updates) do c[key] = value end
  if once_token then c._once[once_token] = true end

  local eff = {}
  for index, op in ipairs(spec.ops or {}) do
    if not op.gate or eval_gate(op.gate, ctx, card) then
      local result = prepared_mutation and prepared_mutation.index == index and mutation_result or nil
      run_op(op, ctx, card, eff, deck_result ~= nil, result)
    end
  end
  return eff
end

function Interp.run(card, ctx)
  local dsl = card.center and card.center.dsl
  if not dsl then return nil end
  local out
  if dsl.clauses then
    -- Clauses are independent abilities sharing one card-local state bag. Each
    -- owns its hook, gate and once token; this is the backward-compatible seam
    -- for biographies whose effects happen at different moments.
    for i, clause in ipairs(dsl.clauses) do out = merge_effect(out, run_spec(card, ctx, clause, i)) end
  else out = run_spec(card, ctx, dsl, "root") end
  return out
end

local function spec_available(card, ctx, spec, spec_id)
  local hook = spec.hook or "joker_main"
  if not ctx[hook] or eval_gate(spec.gate, ctx, card) ~= true then return false end
  if spec.once then
    local used = cfg(card)._once
    if used and used[once_key(spec, spec_id)] then return false end
  end
  return true
end

-- Pure readiness probe for optional UI/agent actions. It does not reset state,
-- consume once tokens, or execute operations.
function Interp.can_run(card, ctx)
  local dsl = card and card.center and card.center.dsl
  if not dsl then return false end
  if dsl.clauses then
    for index, clause in ipairs(dsl.clauses) do
      if spec_available(card, ctx, clause, index) then return true end
    end
    return false
  end
  return spec_available(card, ctx, dsl, "root")
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
  elseif p.what == "pack_option_bonus" then
    G.GAME.pack_option_passives = G.GAME.pack_option_passives or {}
    G.GAME.pack_option_passives[id] = {
      family=p.family, base=p.base, coef=p.coef, per=p.per, round=p.round, cap=p.cap,
    }
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
  elseif rec.what == "salary" then G.GAME.passive_salary = (G.GAME.passive_salary or 0) - amt
  elseif rec.what == "pack_option_bonus" and G.GAME.pack_option_passives then
    G.GAME.pack_option_passives[id] = nil
  end
  G.GAME._passives[id] = nil
end

return Interp
