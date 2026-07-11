-- Persistent active-deck service. The global Tech catalog is not the run deck.

local Eras = require("game.eras")
local MarketRules = require("data.gameplay.market_rules")

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

local function is_anchor(center, rules)
  for _, key in ipairs(rules.anchors or {}) do if center.key == key then return true end end
  return false
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

function Deck.starter_centers(tech_pool, market, era, rng)
  local rules = MarketRules.for_market(market)
  local candidates = {}
  for _, center in ipairs(tech_pool or {}) do
    if Eras.available(center, era) then candidates[#candidates + 1] = center end
  end
  table.sort(candidates, function(a, b) return a.key < b.key end)
  assert(#candidates > 0, "no Era-eligible Tech cards for starter deck")

  rng = rng or love.math.random
  local out, copies = {}, {}
  while #out < rules.starter_size do
    local center = weighted_pick(candidates, copies, rules, rng)
    assert(center, "starter recipe cannot reach requested size within copy caps")
    out[#out + 1] = center
    copies[center.key] = (copies[center.key] or 0) + 1
  end
  return out
end

function Deck.draft_candidates(tech_pool, market, era, owned, count, rng)
  local rules = MarketRules.for_market(market)
  local copies, candidates = {}, {}
  for _, entry in ipairs(owned or {}) do copies[entry.center_key] = (copies[entry.center_key] or 0) + 1 end
  for _, center in ipairs(tech_pool or {}) do
    local cap = is_anchor(center, rules) and rules.anchor_copy_cap or rules.copy_cap
    if Eras.available(center, era) and (copies[center.key] or 0) < cap then candidates[#candidates + 1] = center end
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
  for _, e in ipairs(entries or {}) do
    if not e.uid or not e.center_key then return false, "deck entry lacks uid or center_key" end
    if seen[e.uid] then return false, "duplicate deck uid" end
    seen[e.uid] = true
  end
  if expected_size and #(entries or {}) ~= expected_size then return false, "wrong deck size" end
  return true
end

return Deck
