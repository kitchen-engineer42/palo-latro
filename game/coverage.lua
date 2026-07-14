-- game/coverage.lua -- canonical Layer Coverage contract.
--
-- Coverage is exactly the five product layers in data.layers. Knowledge is an
-- optional overlay, and role labels such as agent-harness are tags,
-- never additional Coverage slots.  All hand-level consumers should use the
-- analysis returned here so multi-layer assignment and run-time overrides agree.

local LayerData = require("data.layers")
local TechModifiers = require("game.tech_modifiers")

local Coverage = {
  CORE_ORDER = LayerData.order,
  KNOWLEDGE = "Knowledge",
}

local core_set, core_index = {}, {}
for i, layer in ipairs(Coverage.CORE_ORDER) do
  core_set[layer], core_index[layer] = true, i
end

local function canonical_layer(layer)
  -- Older signature-card data represented the harness maturity/role as a
  -- layer. Harness cards are AI cards; agent-harness remains a sub-role.
  if layer == "agent-harness" then return "AI" end
  return layer
end

function Coverage.normalize_layer(layer)
  return canonical_layer(layer)
end

function Coverage.is_core(layer)
  return core_set[canonical_layer(layer)] == true
end

local function add_unique(out, seen, value)
  if value and not seen[value] then
    seen[value] = true
    out[#out + 1] = value
  end
end

-- Core layers this card may fill before hand-level assignment. A layer override
-- replaces the card's native layer set; it does not add another identity.
function Coverage.card_options(card)
  if not card then return {} end
  local modifier_options = TechModifiers.coverage_options(card)
  if modifier_options ~= nil then return modifier_options end
  if card.layer_override ~= nil then
    local layer = canonical_layer(card.layer_override)
    return core_set[layer] and { layer } or {}
  end

  local out, seen = {}, {}
  local center = card.center
  if center and center.layers then
    for _, entry in ipairs(center.layers) do
      local layer = canonical_layer(entry.layer)
      if core_set[layer] then add_unique(out, seen, layer) end
    end
  end
  if #out == 0 then
    local layer = canonical_layer(card.layer or (center and center.layer))
    if core_set[layer] then add_unique(out, seen, layer) end
  end
  return out
end

function Coverage.card_has_knowledge(card)
  if not card then return false end
  if TechModifiers.coverage_options(card) ~= nil then return false end
  if card.layer_override ~= nil then return card.layer_override == Coverage.KNOWLEDGE end
  local center = card.center
  if card.layer == Coverage.KNOWLEDGE or (center and center.layer == Coverage.KNOWLEDGE) then return true end
  for _, entry in ipairs((center and center.layers) or {}) do
    if entry.layer == Coverage.KNOWLEDGE then return true end
  end
  return false
end

function Coverage.card_subroles(card)
  local out, seen = {}, {}
  if not card then return out end
  local center = card.center
  local function add_entry(layer, sub_role)
    if layer == "agent-harness" then add_unique(out, seen, "agent-harness") end
    add_unique(out, seen, sub_role)
  end
  if center and center.layers then
    for _, entry in ipairs(center.layers) do add_entry(entry.layer, entry.sub_role) end
  end
  add_entry(card.layer or (center and center.layer), card.sub_role or (center and center.sub_role))
  return out
end

-- Deterministic hand analysis. Fixed cards are placed first, then flexible
-- cards greedily fill the first uncovered core layer in their declared order.
-- The assignment is intentionally the same policy App Types historically used.
function Coverage.analyze(cards)
  cards = cards or {}
  local result = {
    cards = cards,
    counts = {},
    assignments = {},
    distinct = 0,
    knowledge_count = 0,
    subroles = {},
    subrole_count = 0,
  }
  local covered, flexible = {}, {}

  local function assign(card, layer)
    if not layer then return end
    local assigned = result.assignments[card]
    if not assigned then assigned = {}; result.assignments[card] = assigned end
    for _, existing in ipairs(assigned) do if existing == layer then return end end
    assigned[#assigned + 1] = layer
    result.counts[layer] = (result.counts[layer] or 0) + 1
    covered[layer] = true
  end

  for _, card in ipairs(cards) do
    local options = Coverage.card_options(card)
    if Coverage.card_has_knowledge(card) then result.knowledge_count = result.knowledge_count + 1 end
    for _, role in ipairs(Coverage.card_subroles(card)) do
      if not result.subroles[role] then
        result.subroles[role] = true
        result.subrole_count = result.subrole_count + 1
      end
    end

    if #options == 1 then
      assign(card, options[1])
    elseif #options > 1 and card.center and card.center.double_layer then
      for _, layer in ipairs(options) do assign(card, layer) end
    elseif #options > 1 then
      flexible[#flexible + 1] = { card = card, options = options }
    else
      result.assignments[card] = {}
    end
  end

  for _, item in ipairs(flexible) do
    local pick = item.options[1]
    for _, layer in ipairs(item.options) do
      if not covered[layer] then pick = layer; break end
    end
    assign(item.card, pick)
  end

  for _, layer in ipairs(Coverage.CORE_ORDER) do
    if result.counts[layer] then result.distinct = result.distinct + 1 end
  end
  result.redundant_cards = math.max(0, #cards - result.distinct)
  return result
end

function Coverage.layers_for(card, analysis)
  if analysis and analysis.assignments and analysis.assignments[card] ~= nil then
    return analysis.assignments[card]
  end
  local options = Coverage.card_options(card)
  return options[1] and { options[1] } or {}
end

function Coverage.card_has_layer(card, layer, analysis)
  if layer == Coverage.KNOWLEDGE then return Coverage.card_has_knowledge(card) end
  layer = canonical_layer(layer)
  if not core_set[layer] then return false end
  for _, assigned in ipairs(Coverage.layers_for(card, analysis)) do
    if assigned == layer then return true end
  end
  return false
end

function Coverage.has_layer(cards, layer, analysis)
  analysis = analysis or Coverage.analyze(cards)
  if layer == Coverage.KNOWLEDGE then return analysis.knowledge_count > 0 end
  layer = canonical_layer(layer)
  return core_set[layer] and analysis.counts[layer] ~= nil or false
end

function Coverage.count_layer(cards, layer, analysis)
  analysis = analysis or Coverage.analyze(cards)
  if layer == Coverage.KNOWLEDGE then return analysis.knowledge_count end
  layer = canonical_layer(layer)
  return (core_set[layer] and analysis.counts[layer]) or 0
end

function Coverage.is_all_distinct(cards, analysis)
  cards = cards or {}
  if #cards == 0 then return false end
  analysis = analysis or Coverage.analyze(cards)
  if analysis.distinct ~= #cards then return false end
  for _, card in ipairs(cards) do
    if #(analysis.assignments[card] or {}) ~= 1 then return false end
  end
  return true
end

-- Stable visual identity for card faces, tooltips, deck grouping, and sorting.
function Coverage.display_layer(card)
  if not card then return nil end
  if card.layer_override ~= nil then
    local layer = canonical_layer(card.layer_override)
    if core_set[layer] or layer == Coverage.KNOWLEDGE then return layer end
    return nil
  end
  local options = Coverage.card_options(card)
  if options[1] then return options[1] end
  if Coverage.card_has_knowledge(card) then return Coverage.KNOWLEDGE end
  return nil
end

function Coverage.sort_index(card)
  local layer = Coverage.display_layer(card)
  if core_index[layer] then return core_index[layer] end
  if layer == Coverage.KNOWLEDGE then return #Coverage.CORE_ORDER + 1 end
  return #Coverage.CORE_ORDER + 2
end

return Coverage
