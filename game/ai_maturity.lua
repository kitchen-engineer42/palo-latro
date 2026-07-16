-- Per-Ship AI solution maturity.  This refines the identity of an AI App Type;
-- it never replaces Coverage classification and never mutates run state.

local Rules = require("data.gameplay.ai_maturity")
local Coverage = require("game.coverage")

local AIMaturity = { rules = Rules, list = Rules.rungs }

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function has_all(have, wanted)
  for _, value in ipairs(wanted or {}) do if not have[value] then return false end end
  return true
end

local function has_any(have, wanted)
  for _, value in ipairs(wanted or {}) do if have[value] then return true end end
  return false
end

local function signals(cards)
  local roles, layers, explicit, evidence_cards = {}, {}, {}, {}
  for _, card in ipairs(cards or {}) do
    local center = card.center or card
    local card_roles, card_layers = {}, {}

    local function role(value)
      if value then roles[value], card_roles[value] = true, true end
    end
    local function layer(value)
      value = Coverage.normalize_layer(value)
      if value then layers[value], card_layers[value] = true, true end
    end

    if card.layer_override ~= nil then
      layer(card.layer_override)
    else
      layer(center.layer or card.layer)
      for _, spec in ipairs(center.layers or {}) do layer(spec.layer) end
    end
    for _, spec in ipairs(center.layers or {}) do
      role(spec.sub_role)
      -- Older signature data expresses the harness as a Layer.  It remains a
      -- role signal even though Coverage correctly normalizes it to AI.
      if spec.layer == "agent-harness" then role("agent-harness") end
    end
    role(center.sub_role or card.sub_role)
    if (center.layer or card.layer) == "agent-harness" then role("agent-harness") end
    local identity = center.identity
    if type(identity) == "table" then
      if identity.role then role(identity.role) end
      if identity.era == "AI" then layer("AI") end
      if identity.tech_layer then layer(identity.tech_layer) end
      if identity.ai_maturity then explicit[identity.ai_maturity] = true end
    end
    if center.ai_maturity_key then explicit[center.ai_maturity_key] = true end

    evidence_cards[#evidence_cards + 1] = {
      key = card.center_key or center.key,
      roles = card_roles,
      layers = card_layers,
    }
  end
  return roles, layers, explicit, evidence_cards
end

local function matches(requirement, roles, layers)
  if requirement.any_roles and not has_any(roles, requirement.any_roles) then return false end
  if requirement.all_roles and not has_all(roles, requirement.all_roles) then return false end
  if requirement.any_layers and not has_any(layers, requirement.any_layers) then return false end
  if requirement.all_layers and not has_all(layers, requirement.all_layers) then return false end
  return true
end

local EVIDENCE_PREDICATES = {
  any_roles = true, all_roles = true, any_layers = true, all_layers = true,
}

local function dense_nonempty_strings(values)
  if type(values) ~= "table" or #values == 0 then return false end
  local count = 0
  for key in pairs(values) do
    if type(key) ~= "number" or key < 1 or key > #values or key % 1 ~= 0 then return false end
    count = count + 1
  end
  if count ~= #values then return false end
  for index = 1, #values do
    local value = values[index]
    if type(value) ~= "string" or value == "" then return false end
  end
  return true
end

local function validate(rules)
  rules = rules or Rules
  assert(type(rules.version) == "number", "AI maturity rules require a version")
  assert(type(rules.ai_app_types) == "table", "AI maturity requires App-Type scope")
  assert(type(rules.rungs) == "table" and #rules.rungs == 6, "AI maturity requires exactly six rungs")
  assert(type(rules.limits) == "table" and finite(rules.limits.users_bonus)
    and finite(rules.limits.rev_mult), "AI maturity requires finite payoff caps")
  local seen, last_users, last_rev = {}, -math.huge, -math.huge
  for index, rung in ipairs(rules.rungs) do
    assert(type(rung.key) == "string" and rung.key ~= "" and not seen[rung.key], "invalid AI maturity key")
    assert(type(rung.name) == "string" and rung.name ~= "", "AI maturity name required")
    assert(finite(rung.users_bonus) and rung.users_bonus >= last_users, "AI maturity Users must be monotonic")
    assert(finite(rung.rev_mult) and rung.rev_mult >= 1 and rung.rev_mult >= last_rev, "AI maturity Rev must be monotonic")
    assert(type(rung.evidence) == "table" and #rung.evidence > 0, "AI maturity evidence required")
    for evidence_index, requirement in ipairs(rung.evidence) do
      assert(type(requirement) == "table", "AI maturity evidence must be a table")
      local predicate_count = 0
      for predicate, values in pairs(requirement) do
        assert(EVIDENCE_PREDICATES[predicate], "unknown AI maturity evidence predicate " .. tostring(predicate))
        assert(dense_nonempty_strings(values), "AI maturity evidence predicate cannot be empty")
        predicate_count = predicate_count + 1
      end
      assert(predicate_count > 0, ("AI maturity rung %d evidence %d is empty"):format(index, evidence_index))
    end
    assert(rung.users_bonus <= rules.limits.users_bonus, "AI maturity Users exceeds authored cap")
    assert(rung.rev_mult <= rules.limits.rev_mult, "AI maturity Rev exceeds authored cap")
    seen[rung.key], last_users, last_rev = index, rung.users_bonus, rung.rev_mult
  end
  return true
end
validate()
AIMaturity.validate = validate

function AIMaturity.is_ai_app(app)
  local key = type(app) == "table" and app.key or app
  return Rules.ai_app_types[key] == true
end

-- Highest matching artifact wins.  This is an identity classifier over an
-- already-classified AI App Type, so a Harness card need not also include a
-- Workflow card merely to prove that the shipped product is harness-grade.
function AIMaturity.evaluate(cards, app)
  if not AIMaturity.is_ai_app(app) then return nil end
  local roles, layers, explicit, evidence_cards = signals(cards)
  if not layers.AI then return nil end
  local best, matched_by
  for index, rung in ipairs(Rules.rungs) do
    if explicit[rung.key] then best, matched_by = { rung = rung, index = index }, 0 end
  end
  if not best then
    for index, rung in ipairs(Rules.rungs) do
      for evidence_index, requirement in ipairs(rung.evidence) do
        if matches(requirement, roles, layers) then
          best, matched_by = { rung = rung, index = index }, evidence_index
          break
        end
      end
    end
  end
  -- AI App-Type classification guarantees an AI assignment.  Keep the fallback
  -- explicit so synthetic cards and future overrides still receive rung one.
  best = best or { rung = Rules.rungs[1], index = 1 }
  return {
    key = best.rung.key,
    name = best.rung.name,
    short = best.rung.short,
    rung = best.index,
    users_bonus = best.rung.users_bonus,
    rev_mult = best.rung.rev_mult,
    matched_evidence = matched_by or 1,
    explicit_identity = matched_by == 0,
    roles = roles,
    layers = layers,
    evidence_cards = evidence_cards,
  }
end

function AIMaturity.identity(app, maturity)
  if not app then return nil end
  return maturity and ((app.name or app.key) .. " / " .. maturity.name) or (app.name or app.key)
end

function AIMaturity.apply(chips, mult, maturity)
  if not maturity then return chips, mult end
  local users = math.max(0, math.min(maturity.users_bonus or 0, Rules.limits.users_bonus))
  local rev = math.max(1, math.min(maturity.rev_mult or 1, Rules.limits.rev_mult))
  return chips + users, mult * rev
end

return AIMaturity
