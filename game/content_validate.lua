-- Fail-closed validation for generated runtime content.
--
-- This is intentionally kept beside the runtime vocabulary: generators may emit
-- data, but they do not get to extend the interpreter by typo.  A small set of
-- historical gate-key aliases is normalized before registration; no unknown
-- hook, gate, operation, counter source, or cross-reference is accepted.

local Validate = {}
local Deck = require("game.deck")

local LAYERS = { Frontend=true, Backend=true, Data=true, Infra=true, AI=true, Knowledge=true }
local ERAS = { E1=true, E2=true, E3=true, E4=true, E5=true }
local RARITIES = { Common=true, Uncommon=true, Rare=true, Legendary=true }
local HOOKS = {
  joker_main=true, before=true, individual=true, after=true, held=true, repetition=true,
  setting_blind=true, first_hand_drawn=true, pre_cash_out=true, end_of_round=true,
  blind_won=true, blind_lost=true, discard=true, selling_self=true, selling_card=true,
  sell_consumable=true, use_consumable=true,
}
local RESET_HOOKS = { selling_self=true, selling_card=true, blind_lost=true, discard=true }
local OPS = {
  scale=true, acc=true, grant=true, clear_clash=true, gen=true, meter=true,
  gamble=true, delete_card=true, clash_tax=true, arm=true,
}
local GATES = {
  layer_present=true, card_layer=true, app_type_in=true, count=true, ante=true, overkill=true,
  is_boss_blind=true, market=true, has_group=true, ["and"]=true, ["or"]=true, ["not"]=true,
  arr_ratio=true, all_distinct_layers=true, market_fit=true,
}
local COMPARATORS = { [">="]=true, ["<="]=true, ["=="]=true, [">"]=true, ["<"]=true }
local PER_SOURCES = {
  distinct_layers=true, others=true, empty_slots=true, hand_size=true, distinct_sub_roles=true,
  count_group=true, ante=true, round_num=true, ships_this_run=true, rounds_held=true, overkill=true,
  cash=true, runway=true, distinct_layers_seen_run=true, distinct_app_types_shipped=true,
  maturity_rung=true, unplayed_cards=true, unused_layers=true, redundant_cards=true,
  cards_of_layer=true, deck_layer_count=true, new_app_types=true, new_layers=true,
  arr_ratio=true, running_arr=true, run_best_arr=true, founders_hired_this_run=true,
  last_hand_distinct_layers=true, distinct_markets_seen_run=true, cards_of_layer_in_hand=true,
  salary_due=true,
}

local function report()
  return { errors = {}, aliases = {}, counts = {} }
end

local function add(r, path, message)
  r.errors[#r.errors + 1] = path .. ": " .. message
end

local function text(v) return type(v) == "string" and v ~= "" end
local function number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function dense_array(value)
  if type(value) ~= "table" then return false end
  local n = #value
  for key in pairs(value) do if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > n then return false end end
  return true
end

local function gate_kind(g, path, r)
  if text(g.g) then
    if (g.k and g.k ~= g.g) or (g.kind and g.kind ~= g.g) then add(r, path, "conflicting gate kind fields") end
    return g.g
  end
  local legacy = g.k or g.kind
  if text(legacy) and GATES[legacy] then
    g.g = legacy
    r.aliases[#r.aliases + 1] = path .. " normalized legacy gate key to g"
    return legacy
  end
  add(r, path, "missing gate kind g")
end

local validate_gate
local function validate_per(value, path, r, meter_names, owner)
  if not text(value) then add(r, path, "counter source must be a non-empty string"); return end
  if not PER_SOURCES[value] and not meter_names[value] then
    add(r, path, "unknown counter source " .. value .. " for " .. owner)
  end
end

validate_gate = function(g, path, r, meter_names, owner, depth)
  if type(g) ~= "table" then add(r, path, "gate must be a table"); return end
  depth = depth or 1
  if depth > 12 then add(r, path, "gate nesting exceeds limit"); return end
  local kind = gate_kind(g, path, r)
  if not kind then return end
  if not GATES[kind] then add(r, path, "unknown gate " .. tostring(kind)); return end

  if kind == "and" or kind == "or" then
    if not dense_array(g.gs) or #g.gs == 0 then add(r, path .. ".gs", "must be a non-empty array"); return end
    for i, child in ipairs(g.gs) do validate_gate(child, path .. ".gs[" .. i .. "]", r, meter_names, owner, depth + 1) end
  elseif kind == "not" then
    validate_gate(g.g1, path .. ".g1", r, meter_names, owner, depth + 1)
  elseif kind == "layer_present" or kind == "card_layer" then
    if not LAYERS[g.layer] then add(r, path .. ".layer", "unknown Layer " .. tostring(g.layer)) end
  elseif kind == "app_type_in" then
    if not dense_array(g.names) or #g.names == 0 then add(r, path .. ".names", "must be a non-empty array") end
  elseif kind == "count" then
    validate_per(g.per, path .. ".per", r, meter_names, owner)
    if not COMPARATORS[g.op] then add(r, path .. ".op", "unknown comparator " .. tostring(g.op)) end
    if not number(g.val) then add(r, path .. ".val", "must be a finite number") end
    if (g.per == "cards_of_layer" or g.per == "cards_of_layer_in_hand" or g.per == "deck_layer_count")
       and not LAYERS[g.layer] then add(r, path .. ".layer", "counter requires a valid Layer") end
    if g.per == "count_group" and not text(g.group) then add(r, path .. ".group", "count_group requires a group") end
  elseif kind == "ante" or kind == "overkill" or kind == "arr_ratio" or kind == "market_fit" then
    if not COMPARATORS[g.op] then add(r, path .. ".op", "unknown comparator " .. tostring(g.op)) end
    if not number(g.val) then add(r, path .. ".val", "must be a finite number") end
  elseif kind == "market" then
    if g.attr ~= nil and not text(g.attr) then add(r, path .. ".attr", "must be a string") end
    if g.attr ~= nil and g.value == nil then add(r, path .. ".value", "is required with attr") end
  elseif kind == "has_group" then
    if not text(g.group) then add(r, path .. ".group", "is required") end
    if g.val ~= nil and not number(g.val) then add(r, path .. ".val", "must be a number") end
  end
end

local function validate_number_fields(op, fields, path, r)
  for _, field in ipairs(fields) do
    if op[field] ~= nil and not number(op[field]) then add(r, path .. "." .. field, "must be a finite number") end
  end
end

local function validate_op(op, path, r, meter_names, owner)
  if type(op) ~= "table" then add(r, path, "operation must be a table"); return end
  if not text(op.k) or not OPS[op.k] then add(r, path .. ".k", "unknown operation " .. tostring(op.k)); return end
  if op.gate ~= nil then validate_gate(op.gate, path .. ".gate", r, meter_names, owner) end
  if op.per ~= nil and op.k ~= "clash_tax" then validate_per(op.per, path .. ".per", r, meter_names, owner) end
  if op.inc_per ~= nil then validate_per(op.inc_per, path .. ".inc_per", r, meter_names, owner) end
  validate_number_fields(op, { "base", "coef", "max", "pct" }, path, r)

  if op.k == "scale" or op.k == "acc" or op.k == "arm" then
    if not ({ chips=true, mult=true, x_mult=true, dollars=true })[op.field] then
      add(r, path .. ".field", "unknown score field " .. tostring(op.field))
    end
  end
  if op.k == "acc" then
    if op.field == "x_mult" and op.max == nil and number(op.coef) and op.coef > 0 then
      op.max = math.max(0, math.floor((5 - (op.base or 1)) / op.coef))
      r.aliases[#r.aliases + 1] = path .. " capped unbounded x_mult accumulator"
    end
    if op.step ~= nil and op.step ~= "round" and op.step ~= "ship" then add(r, path .. ".step", "must be round or ship") end
    if op.when ~= nil and op.when ~= "post" and op.when ~= "pre" then add(r, path .. ".when", "must be pre or post") end
    if op.reset_on ~= nil then
      if not dense_array(op.reset_on) then add(r, path .. ".reset_on", "must be an array")
      else for i, hook in ipairs(op.reset_on) do if not RESET_HOOKS[hook] then add(r, path .. ".reset_on[" .. i .. "]", "unknown reset hook " .. tostring(hook)) end end end
    end
  elseif op.k == "grant" then
    if not ({ cash=true, margin=true, salary=true })[op.what] then add(r, path .. ".what", "unknown grant target " .. tostring(op.what)) end
    if op.amount ~= nil and not number(op.amount) then add(r, path .. ".amount", "must be a finite number") end
  elseif op.k == "clear_clash" then
    if type(op.amount) == "table" and op.per == nil then
      local legacy = op.amount
      if legacy.per and (legacy.base == nil or number(legacy.base)) and (legacy.coef == nil or number(legacy.coef)) then
        op.per, op.base, op.coef, op.amount = legacy.per, legacy.base, legacy.coef, nil
        r.aliases[#r.aliases + 1] = path .. " normalized legacy scalable amount"
        validate_per(op.per, path .. ".per", r, meter_names, owner)
      else add(r, path .. ".amount", "invalid scalable amount") end
    end
    if op.amount ~= nil and op.amount ~= "all" and not number(op.amount) then add(r, path .. ".amount", "must be a number or all") end
  elseif op.k == "gen" then
    if not ({ tech_card=true, remove_card=true, copy_card=true, hand_size=true })[op.kind] then add(r, path .. ".kind", "unknown generation kind " .. tostring(op.kind)) end
    if op.amount ~= nil and not number(op.amount) then add(r, path .. ".amount", "must be a finite number") end
    if op.layer ~= nil and not LAYERS[op.layer] then add(r, path .. ".layer", "unknown Layer") end
  elseif op.k == "meter" then
    if not text(op.name) then add(r, path .. ".name", "meter name is required") end
    if op.amount ~= nil and not number(op.amount) then add(r, path .. ".amount", "must be a finite number") end
  elseif op.k == "gamble" then
    validate_number_fields(op, { "p", "win", "lose", "n", "guaranteed" }, path, r)
    if not number(op.p) or op.p < 0 or op.p > 1 then add(r, path .. ".p", "must be a probability") end
    if number(op.lose) and op.lose >= 1 then op.lose = 0.75; r.aliases[#r.aliases + 1] = path .. " added a real gamble downside" end
    if number(op.win) and op.win > 5 then op.win = 5; r.aliases[#r.aliases + 1] = path .. " capped gamble win multiplier" end
    if number(op.guaranteed) and op.guaranteed > 5 then op.guaranteed = 5; r.aliases[#r.aliases + 1] = path .. " capped gamble guarantee" end
  elseif op.k == "delete_card" then
    validate_number_fields(op, { "margin", "overcut" }, path, r)
  elseif op.k == "clash_tax" then
    if op.per ~= nil and not number(op.per) then add(r, path .. ".per", "must be a finite number") end
    if op.field ~= nil and not ({ chips=true, mult=true, x_mult=true, dollars=true })[op.field] then add(r, path .. ".field", "unknown field") end
  end
end

local function validate_dsl(dsl, path, r, owner)
  if type(dsl) ~= "table" then add(r, path, "DSL must be a table"); return end
  local meter_names = {}
  for _, op in ipairs(dsl.ops or {}) do if type(op) == "table" and op.k == "meter" and text(op.name) then meter_names[op.name] = true end end
  if dsl.hook ~= nil and not HOOKS[dsl.hook] then add(r, path .. ".hook", "unknown hook " .. tostring(dsl.hook)) end
  if dsl.once ~= nil and type(dsl.once) ~= "boolean" then add(r, path .. ".once", "must be boolean") end
  if dsl.once_scope ~= nil and not ({ run=true, ante=true, blind=true })[dsl.once_scope] then add(r, path .. ".once_scope", "unknown once scope") end
  if dsl.gate ~= nil then validate_gate(dsl.gate, path .. ".gate", r, meter_names, owner) end
  if dsl.ops ~= nil then
    if not dense_array(dsl.ops) then add(r, path .. ".ops", "must be an array")
    else for i, op in ipairs(dsl.ops) do validate_op(op, path .. ".ops[" .. i .. "]", r, meter_names, owner) end end
  end
  if dsl.retrigger ~= nil then
    if type(dsl.retrigger) == "table" then
      validate_number_fields(dsl.retrigger, { "base", "coef" }, path .. ".retrigger", r)
      validate_per(dsl.retrigger.per, path .. ".retrigger.per", r, meter_names, owner)
    elseif not number(dsl.retrigger) then add(r, path .. ".retrigger", "must be a number or scale table") end
  end
  if dsl.retrigger_target ~= nil and dsl.retrigger_target ~= "highest" then add(r, path .. ".retrigger_target", "unknown target") end
  if dsl.passive ~= nil then
    if type(dsl.passive) ~= "table" then add(r, path .. ".passive", "must be a table")
    else
      if not ({ hand_size=true, founder_slots=true, salary=true })[dsl.passive.what] then add(r, path .. ".passive.what", "unknown passive target") end
      if not number(dsl.passive.amount) then add(r, path .. ".passive.amount", "must be a finite number") end
    end
  end
end

local function validate_centers(list, source, r, keys)
  if not dense_array(list) then add(r, source, "must return a dense center array"); return end
  r.counts[source] = #list
  for i, center in ipairs(list) do
    local path = source .. "[" .. i .. "]"
    if type(center) ~= "table" then add(r, path, "center must be a table")
    else
      if not text(center.key) then add(r, path .. ".key", "is required")
      elseif keys[center.key] then add(r, path .. ".key", "duplicates " .. keys[center.key])
      else keys[center.key] = path end
      if not text(center.set) then add(r, path .. ".set", "is required") end
      if source == "techcards" and center.set == "TechCard" then
        if not number(center.base_users) or center.base_users < 0 then add(r, path .. ".base_users", "must be non-negative") end
        if not dense_array(center.layers) or #center.layers == 0 then add(r, path .. ".layers", "must be a non-empty array")
        else
          local primary = false
          for j, layer in ipairs(center.layers) do
            if type(layer) ~= "table" or not LAYERS[layer.layer] then add(r, path .. ".layers[" .. j .. "]", "has an unknown Layer") end
            if type(layer) == "table" and layer.layer == center.layer then primary = true end
          end
          if not primary then add(r, path .. ".layer", "primary Layer must occur in layers") end
        end
        if not dense_array(center.eras) or #center.eras == 0 then add(r, path .. ".eras", "must be a non-empty array")
        else for j, era in ipairs(center.eras) do if not ERAS[era] then add(r, path .. ".eras[" .. j .. "]", "unknown era") end end end
      elseif (source == "founders" or source == "forms") and center.set == "Founder" then
        if not RARITIES[center.rarity] then add(r, path .. ".rarity", "unknown rarity " .. tostring(center.rarity)) end
        if not number(center.salary) or center.salary < 0 then add(r, path .. ".salary", "must be non-negative") end
        if center.dsl ~= nil then validate_dsl(center.dsl, path .. ".dsl", r, center.key or path) end
      end
    end
  end
end

local function validate_compat(compat, tech_keys, r)
  if type(compat) ~= "table" then add(r, "compat", "must return a table"); return end
  for _, relation in ipairs({ "substitutes", "clashes", "complements" }) do
    local edges = compat[relation]
    if type(edges) ~= "table" then add(r, "compat." .. relation, "must be a table")
    else
      local count = 0
      for pair, enabled in pairs(edges) do
        count = count + 1
        local left, right
        if type(pair) == "string" then left, right = pair:match("^([^|]+)|([^|]+)$") end
        if not left then add(r, "compat." .. relation, "invalid pair " .. tostring(pair))
        else
          if not tech_keys[left] then add(r, "compat." .. relation .. "[" .. pair .. "]", "unknown endpoint " .. left) end
          if not tech_keys[right] then add(r, "compat." .. relation .. "[" .. pair .. "]", "unknown endpoint " .. right) end
        end
        if relation == "complements" then
          if not number(enabled) or enabled < 0 then add(r, "compat." .. relation .. "[" .. tostring(pair) .. "]", "weight must be non-negative") end
        elseif enabled ~= true then add(r, "compat." .. relation .. "[" .. tostring(pair) .. "]", "edge value must be true") end
      end
      r.counts["compat." .. relation] = count
    end
  end
end

local function validate_markets(markets, tech_keys, r)
  if type(markets) ~= "table" then add(r, "markets", "must return a table"); return end
  if not dense_array(markets.markets) then add(r, "markets.markets", "must be an array")
  else
    local ids = {}
    for i, market in ipairs(markets.markets) do
      local path = "markets.markets[" .. i .. "]"
      if type(market) ~= "table" or not text(market.id) then add(r, path, "market id is required")
      elseif ids[market.id] then add(r, path .. ".id", "duplicate market id") else ids[market.id] = true end
      if type(market) == "table" and (not dense_array(market.home_eras) or #market.home_eras == 0) then add(r, path .. ".home_eras", "must be a non-empty array") end
    end
    r.counts.markets = #markets.markets
  end
  if type(markets.scenario_fit) ~= "table" then add(r, "markets.scenario_fit", "must be a table")
  else
    local rows = 0
    for tech, fits in pairs(markets.scenario_fit) do
      rows = rows + 1
      if not tech_keys[tech] then add(r, "markets.scenario_fit[" .. tostring(tech) .. "]", "unknown Tech endpoint") end
      if type(fits) ~= "table" then add(r, "markets.scenario_fit[" .. tostring(tech) .. "]", "must be a table")
      else for scenario, rating in pairs(fits) do if not ({ great=true, ok=true, poor=true })[rating] then add(r, "markets.scenario_fit[" .. tech .. "][" .. tostring(scenario) .. "]", "unknown rating") end end end
    end
    r.counts["markets.scenario_fit"] = rows
  end
end

local function validate_gameplay(gameplay, catalog, r)
  if type(gameplay) ~= "table" then add(r, "gameplay", "must be a table"); return end
  local market_rules = gameplay.market_rules
  local rules = market_rules and market_rules.raw or {}
  local scenarios, roles = {}, {}
  for _, fits in pairs((catalog.markets and catalog.markets.scenario_fit) or {}) do
    for scenario in pairs(fits) do scenarios[scenario] = true end
  end
  for _, tech in ipairs(catalog.techcards or {}) do
    if tech.sub_role then roles[tech.sub_role] = true end
    for _, spec in ipairs(tech.layers or {}) do if spec.sub_role then roles[spec.sub_role] = true end end
  end
  local allowed_perks = { ships_per_blind=true, pivots_per_blind=true, founder_slots=true, hand_size=true,
    starting_cash_units=true, free_voucher=true }
  for _, market in ipairs((catalog.markets and catalog.markets.markets) or {}) do
    local rule, path = rules[market.id], "gameplay.market_rules." .. tostring(market.id)
    if type(rule) ~= "table" then add(r, path, "missing authored rule")
    else
      local resolved = type(market_rules.for_market) == "function" and market_rules.for_market(market) or rule
      local starter_ok, starter_error = Deck.validate_starter_recipe(
        catalog.techcards or {}, market, resolved.start_era, resolved
      )
      if not starter_ok then r.errors[#r.errors + 1] = starter_error end
      if not scenarios[rule.scenario_id] then add(r, path .. ".scenario_id", "does not exist in scenario_fit") end
      for i, op in ipairs(rule.perk_ops or {}) do
        if not allowed_perks[op.op] then add(r, path .. ".perk_ops[" .. i .. "].op", "unknown perk operation") end
        if not number(op.amount) then add(r, path .. ".perk_ops[" .. i .. "].amount", "must be a number") end
      end
    end
  end
  for i, archetype in ipairs(gameplay.archetypes or {}) do
    for j, role in ipairs(archetype.roles or {}) do if not roles[role] then add(r, "gameplay.archetypes["..i.."].roles["..j.."]", "unknown sub-role " .. tostring(role)) end end
  end
  local boss_keys = {}
  local normal_bosses, showdown_bosses = 0, 0
  for i, boss in ipairs(gameplay.bosses or {}) do
    if boss_keys[boss.key] then add(r, "gameplay.bosses["..i.."].key", "duplicate") else boss_keys[boss.key] = true end
    if not dense_array(boss.responses) or #boss.responses < 2 then add(r, "gameplay.bosses["..i.."].responses", "needs at least two response channels") end
    if boss.showdown then showdown_bosses = showdown_bosses + 1 else normal_bosses = normal_bosses + 1 end
  end
  if #(gameplay.stakes or {}) ~= 8 then add(r, "gameplay.stakes", "must define exactly eight tiers") end
  for key, pack in pairs(gameplay.packs or {}) do
    if type(pack) ~= "table" then add(r, "gameplay.packs."..tostring(key), "must be a table")
    else
      if pack.legendary_chance ~= nil then
        if not number(pack.legendary_chance) then add(r, "gameplay.packs."..key..".legendary_chance", "must be a probability")
        elseif pack.legendary_chance < 0 or pack.legendary_chance > 0.02 then add(r, "gameplay.packs."..key..".legendary_chance", "outside prototype band") end
      end
      if pack.edition_chance ~= nil then
        if not number(pack.edition_chance) then add(r, "gameplay.packs."..key..".edition_chance", "must be a probability")
        elseif pack.edition_chance < 0.04 or pack.edition_chance > 0.06 then add(r, "gameplay.packs."..key..".edition_chance", "outside prototype band") end
      end
    end
  end
end

function Validate.catalog(catalog, options)
  options = options or {}
  local r, keys, tech_keys = report(), {}, {}
  validate_centers(catalog.techcards, "techcards", r, keys)
  for _, center in ipairs(catalog.techcards or {}) do if text(center.key) then tech_keys[center.key:gsub("^t_", "")] = true end end
  validate_centers(catalog.founders, "founders", r, keys)
  validate_centers(catalog.forms, "forms", r, keys)
  validate_centers(catalog.signature_cards or {}, "signature_cards", r, keys)
  validate_centers(catalog.vouchers or {}, "vouchers", r, keys)
  validate_centers(catalog.consumables or {}, "consumables", r, keys)
  validate_compat(catalog.compat, tech_keys, r)
  validate_markets(catalog.markets, tech_keys, r)
  if catalog.gameplay then validate_gameplay(catalog.gameplay, catalog, r) end

  local minimums = options.minimums or {}
  for name, minimum in pairs(minimums) do
    if (r.counts[name] or 0) < minimum then add(r, name, "count fell below minimum " .. minimum) end
  end
  for i, form in ipairs(catalog.forms or {}) do
    if form.base_form and not keys[form.base_form] then add(r, "forms[" .. i .. "].base_form", "unknown founder " .. tostring(form.base_form)) end
  end
  return #r.errors == 0, r
end

function Validate.assert_catalog(catalog, options)
  local ok, r = Validate.catalog(catalog, options)
  if not ok then error("content validation failed:\n  - " .. table.concat(r.errors, "\n  - "), 2) end
  return r
end

return Validate
