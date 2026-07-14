-- Persistent active-deck service. The global Tech catalog is not the run deck.

local Eras = require("game.eras")
local MarketRules = require("data.gameplay.market_rules")
local AppTypes = require("game.apptypes")
local Coverage = require("game.coverage")
local TechModifiers = require("game.tech_modifiers")

local Deck = {}

local function center_layers(center)
  local out = {}
  if center.layers then
    for _, spec in ipairs(center.layers) do out[#out + 1] = spec.layer end
  elseif center.layer then out[1] = center.layer end
  return out
end

local function weight(center, rules)
  local total, n = 0, 0
  for _, layer in ipairs(center_layers(center)) do
    total = total + ((rules.layer_weights and rules.layer_weights[layer]) or 1)
    n = n + 1
  end
  return n > 0 and total / n or 0.1
end

local function is_anchor(center_or_key, rules)
  local wanted = type(center_or_key) == "table" and center_or_key.key or center_or_key
  for _, key in ipairs(rules.anchors or {}) do if wanted == key then return true end end
  return false
end

function Deck.copy_cap(center_or_key, market)
  local rules = MarketRules.for_market(market)
  return is_anchor(center_or_key, rules) and rules.anchor_copy_cap or rules.copy_cap
end

function Deck.count_owned(owned, center_or_key)
  local wanted = type(center_or_key) == "table" and center_or_key.key or center_or_key
  local count = 0
  for _, entry in ipairs(owned or {}) do
    local key = entry.center_key or (entry.center and entry.center.key) or entry.key
    if key == wanted then count = count + 1 end
  end
  return count
end

function Deck.can_add(owned, center_or_key, market, amount)
  local count = Deck.count_owned(owned, center_or_key)
  local cap = Deck.copy_cap(center_or_key, market)
  return count + (amount or 1) <= cap, cap, count
end

-- Market constraints are authored once and consumed by every acquisition path.
-- Starter recipes are explicit historical givens; this filter governs future
-- drafts/evaluations only, so a Market can begin with a legacy dependency and
-- still refuse to offer it again.
function Deck.candidate_allowed(center_or_key, market)
  local center = type(center_or_key) == "table" and center_or_key
    or (G and G.P_CENTERS and G.P_CENTERS[center_or_key])
  if not center then return false, "Unknown Tech candidate" end
  local constraints = MarketRules.for_market(market).constraints or {}
  for _, key in ipairs(constraints.allowed_tech_keys or {}) do
    if center.key == key then return true end
  end
  for _, key in ipairs(constraints.excluded_tech_keys or {}) do
    if center.key == key then return false, "Tech is excluded by the current Market" end
  end
  local roles = {}
  if center.sub_role then roles[center.sub_role] = true end
  for _, layer in ipairs(center.layers or {}) do if layer.sub_role then roles[layer.sub_role] = true end end
  for _, role in ipairs(constraints.excluded_sub_roles or {}) do
    if roles[role] then return false, "Tech role is excluded by the current Market" end
  end
  return true
end

local function weighted_pick(candidates, copies, rules, rng)
  local total = 0
  local weights = {}
  for i, c in ipairs(candidates) do
    local cap = is_anchor(c, rules) and rules.anchor_copy_cap or rules.copy_cap
    local room = math.max(0, cap - (copies[c.key] or 0))
    local w = room > 0 and weight(c, rules) * (is_anchor(c, rules) and 1.75 or 1) or 0
    weights[i], total = w, total + w
  end
  if total <= 0 then return nil end
  local roll = rng() * total
  local last_available
  for i, c in ipairs(candidates) do
    if weights[i] > 0 then
      last_available = c
      roll = roll - weights[i]
      if roll <= 0 then return c end
    end
  end
  return last_available
end

local function dense_array(value)
  if type(value) ~= "table" then return false end
  local n = #value
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > n then return false end
  end
  return true
end

local function starter_path(market)
  local id = type(market) == "table" and market.id or market
  return "gameplay.market_rules." .. tostring(id or "<missing-market>")
end

local function invalid(path, message)
  return false, path .. ": " .. message
end

-- Validate and compile one authored Market/Era recipe. Keeping this seam
-- public lets content validation and balance tools enforce the same contract
-- that runtime deck construction enforces.
function Deck.validate_starter_recipe(tech_pool, market, era, rules_override)
  local rules = rules_override or MarketRules.for_market(market)
  local path = starter_path(market)
  if type(rules) ~= "table" then return invalid(path, "must be a table") end
  if type(rules.start_era) ~= "number" or rules.start_era % 1 ~= 0
      or rules.start_era < 1 or rules.start_era > 5 then
    return invalid(path .. ".start_era", "must be an integer from 1 to 5")
  end
  local requested_era = Eras.number(era or rules.start_era)
  if requested_era ~= rules.start_era then
    return invalid(path .. ".start_era", "authored for E" .. rules.start_era
      .. " but requested for E" .. tostring(requested_era))
  end
  if rules.starter_size ~= 24 then
    return invalid(path .. ".starter_size", "must be exactly 24")
  end
  if type(rules.copy_cap) ~= "number" or rules.copy_cap % 1 ~= 0
      or rules.copy_cap < 1 or rules.copy_cap > 2 then
    return invalid(path .. ".copy_cap", "must be an integer no greater than 2")
  end
  if type(rules.anchor_copy_cap) ~= "number" or rules.anchor_copy_cap % 1 ~= 0
      or rules.anchor_copy_cap < 1 or rules.anchor_copy_cap > 2 then
    return invalid(path .. ".anchor_copy_cap", "must be an integer no greater than 2")
  end

  if not dense_array(tech_pool) then return invalid("tech_pool", "must be a dense array") end
  local by_key = {}
  for i, center in ipairs(tech_pool) do
    if type(center) ~= "table" or type(center.key) ~= "string" or center.key == "" then
      return invalid("tech_pool[" .. i .. "].key", "must be a non-empty string")
    end
    if by_key[center.key] then
      return invalid("tech_pool[" .. i .. "].key", "duplicates " .. center.key)
    end
    by_key[center.key] = center
  end

  if not dense_array(rules.anchors) then return invalid(path .. ".anchors", "must be a dense array") end
  for i, key in ipairs(rules.anchors) do
    local field = path .. ".anchors[" .. i .. "]"
    if type(key) ~= "string" or key == "" then return invalid(field, "must be a Tech key") end
    local center = by_key[key]
    if not center then return invalid(field, "unknown Tech key " .. key) end
    if not Eras.available(center, rules.start_era) then
      return invalid(field, key .. " is not eligible in E" .. rules.start_era)
    end
  end

  local recipe = rules.starter_recipe
  if not dense_array(recipe) then return invalid(path .. ".starter_recipe", "must be a dense array") end
  if #recipe ~= 24 then
    return invalid(path .. ".starter_recipe", "must contain exactly 24 instances")
  end
  local out, copies, recipe_keys, recipe_layers = {}, {}, {}, {}
  for i, key in ipairs(recipe) do
    local field = path .. ".starter_recipe[" .. i .. "]"
    if type(key) ~= "string" or key == "" then return invalid(field, "must be a Tech key") end
    local center = by_key[key]
    if not center then return invalid(field, "unknown Tech key " .. key) end
    if not Eras.available(center, rules.start_era) then
      return invalid(field, key .. " is not eligible in E" .. rules.start_era)
    end
    local cap = is_anchor(key, rules) and rules.anchor_copy_cap or rules.copy_cap
    copies[key] = (copies[key] or 0) + 1
    if copies[key] > cap then
      return invalid(field, key .. " exceeds its copy cap of " .. cap)
    end
    recipe_keys[key] = true
    out[#out + 1] = center
    for _, layer in ipairs(center_layers(center)) do
      if Coverage.is_core(layer) then recipe_layers[Coverage.normalize_layer(layer)] = true end
    end
  end

  local eligible_layers = {}
  for _, center in ipairs(tech_pool) do
    if Eras.available(center, rules.start_era) then
      for _, layer in ipairs(center_layers(center)) do
        if Coverage.is_core(layer) then eligible_layers[Coverage.normalize_layer(layer)] = true end
      end
    end
  end
  for _, layer in ipairs(Coverage.CORE_ORDER) do
    if eligible_layers[layer] and not recipe_layers[layer] then
      return invalid(path .. ".starter_recipe", "does not represent available core Layer " .. layer)
    end
  end

  local witness = rules.starter_witness
  if type(witness) ~= "table" then return invalid(path .. ".starter_witness", "must be a table") end
  if type(witness.app_type) ~= "string" or not AppTypes.by_key[witness.app_type] then
    return invalid(path .. ".starter_witness.app_type", "must name a known App Type")
  end
  if not dense_array(witness.cards) or #witness.cards ~= 3 then
    return invalid(path .. ".starter_witness.cards", "must contain exactly three Tech keys")
  end
  local witness_cards, witness_seen = {}, {}
  for i, key in ipairs(witness.cards) do
    local field = path .. ".starter_witness.cards[" .. i .. "]"
    if type(key) ~= "string" or key == "" then return invalid(field, "must be a Tech key") end
    if witness_seen[key] then return invalid(field, "duplicates " .. key) end
    witness_seen[key] = true
    local center = by_key[key]
    if not center then return invalid(field, "unknown Tech key " .. key) end
    if not Eras.available(center, rules.start_era) then
      return invalid(field, key .. " is not eligible in E" .. rules.start_era)
    end
    if not recipe_keys[key] then return invalid(field, key .. " is not present in starter_recipe") end
    witness_cards[#witness_cards + 1] = { center = center }
  end
  local analysis = Coverage.analyze(witness_cards)
  if analysis.distinct < 2 then
    return invalid(path .. ".starter_witness.cards", "must cover at least two core Layers")
  end
  local classified = AppTypes.classify(witness_cards)
  if not classified or classified.key ~= witness.app_type then
    return invalid(path .. ".starter_witness.app_type", "expected " .. witness.app_type
      .. " but witness classifies as " .. tostring(classified and classified.key))
  end
  return true, nil, out
end

function Deck.starter_centers(tech_pool, market, era, rng)
  -- `rng` remains in the public signature for callers, but composition is
  -- deliberately independent of run seed. The completed deck is shuffled by
  -- the normal deck RNG after these authored instances are materialized.
  local ok, reason, out = Deck.validate_starter_recipe(tech_pool, market, era)
  assert(ok, reason)
  return out
end

function Deck.draft_candidates(tech_pool, market, era, owned, count, rng)
  local rules = MarketRules.for_market(market)
  local copies, candidates = {}, {}
  for _, entry in ipairs(owned or {}) do copies[entry.center_key] = (copies[entry.center_key] or 0) + 1 end
  for _, center in ipairs(tech_pool or {}) do
    local cap = is_anchor(center, rules) and rules.anchor_copy_cap or rules.copy_cap
    if Eras.available(center, era) and Deck.candidate_allowed(center, market)
        and (copies[center.key] or 0) < cap then candidates[#candidates + 1] = center end
  end
  table.sort(candidates, function(a, b) return a.key < b.key end)
  local out, seen = {}, {}
  rng, count = rng or love.math.random, count or 3
  while #out < count and #out < #candidates do
    local c = weighted_pick(candidates, copies, rules, rng)
    if not c then break end
    copies[c.key] = (copies[c.key] or 0) + 1
    if not seen[c.key] then out[#out + 1], seen[c.key] = c, true end
  end
  return out
end

function Deck.validate(entries, expected_size)
  local seen = {}
  for i, e in ipairs(entries or {}) do
    if not e.uid or not e.center_key then return false, "deck entry lacks uid or center_key" end
    if seen[e.uid] then return false, "duplicate deck uid" end
    local valid, reason = TechModifiers.validate(e, "master_deck[" .. i .. "]")
    if not valid then return false, reason end
    seen[e.uid] = true
  end
  if expected_size and #(entries or {}) ~= expected_size then return false, "wrong deck size" end
  return true
end

return Deck
