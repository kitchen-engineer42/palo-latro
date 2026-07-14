local Definitions = require("data.gameplay.bosses")
local Coverage = require("game.coverage")

local Bosses = { list = Definitions }
local by_key = {}
for _, b in ipairs(Definitions) do by_key[b.key] = b end
Bosses.by_key = by_key

function Bosses.sequence(seed_offset)
  local normal, showdown = {}, {}
  for _, b in ipairs(Definitions) do (b.showdown and showdown or normal)[#(b.showdown and showdown or normal) + 1] = b end
  local out, offset = {}, (seed_offset or 0) % #normal
  for ante = 1, 7 do out[ante] = normal[((ante + offset - 1) % #normal) + 1].key end
  out[8] = showdown[((seed_offset or 0) % #showdown) + 1].key
  return out
end

function Bosses.rule(key) return by_key[key] end

local function pct(value) return tostring(math.floor(math.abs(value or 0) * 100 + 0.5)) .. "%" end

function Bosses.describe(key)
  local b = by_key[key]
  if not b then return "Unknown market shock" end
  if b.kind == "reliability" then
    return (b.layer or "Affected") .. " cards lose " .. tostring(b.reliability or 0) .. " Reliability each"
  elseif b.kind == "role" then
    return (b.role or "Affected") .. " cards lose " .. tostring(b.reliability or 0) .. " Reliability each"
  elseif b.kind == "margin" then
    return "Operating Margin " .. ((b.margin_delta or 0) < 0 and "−" or "+") .. pct(b.margin_delta)
  elseif b.kind == "payroll" then
    return "Payroll ×" .. string.format("%.2f", b.payroll_mult or 1)
  elseif b.kind == "depth" then
    return "Each duplicate Layer loses " .. tostring(b.reliability_per_duplicate or 0) .. " Reliability"
  elseif b.kind == "knowledge" then
    return "Ship " .. tostring(b.required_knowledge or 1) .. "+ Knowledge or lose 2 Reliability"
  elseif b.kind == "layer" then
    return (b.layer or "Affected") .. " Ships score Revenue ×" .. string.format("%.2f", b.revenue_mult or 1)
  elseif b.kind == "clashes" then
    return "Lose " .. tostring(b.reliability_per_clash or 0) .. " Reliability per compatibility clash"
  elseif b.kind == "fit" then
    return "Below ×" .. string.format("%.2f", b.fit_floor or 1) .. " Fit scores Revenue ×0.80"
  elseif b.kind == "showdown" then
    return "Below " .. tostring(b.min_equity or 0) .. "% equity loses Reliability and ×0.85 Revenue"
  end
  return b.name or key
end

function Bosses.reliability_penalty(key, cards, context)
  local b = by_key[key]
  if not b then return 0 end
  local penalty = 0
  if b.kind == "reliability" and b.layer then
    for _, c in ipairs(cards or {}) do if Coverage.card_has_layer(c, b.layer) then penalty = penalty + (b.reliability or 0) end end
  elseif b.kind == "role" then
    for _, c in ipairs(cards or {}) do
      for _, role in ipairs(Coverage.card_subroles(c)) do
        if role == b.role then penalty = penalty + (b.reliability or 0); break end
      end
    end
  elseif b.kind == "clashes" then penalty = ((context and context.clashes) or 0) * (b.reliability_per_clash or 0)
  elseif b.kind == "depth" then
    local analysis = Coverage.analyze(cards or {})
    penalty = math.max(0, #(cards or {}) - analysis.distinct) * (b.reliability_per_duplicate or 0)
  elseif b.kind == "knowledge" then
    local analysis = Coverage.analyze(cards or {})
    if analysis.knowledge_count < (b.required_knowledge or 1) then penalty = 2 end
  elseif b.kind == "showdown" and ((G.GAME and G.GAME.equity_pct) or 100) < (b.min_equity or 50) then penalty = 3
  end
  return penalty
end

function Bosses.score_multiplier(key, cards, context)
  local b = by_key[key]
  if not b then return 1 end
  if b.kind == "layer" and b.layer then
    for _, card in ipairs(cards or {}) do if Coverage.card_has_layer(card, b.layer) then return b.revenue_mult or 1 end end
  elseif b.kind == "fit" and ((context and context.fit) or 1) < (b.fit_floor or 1) then return 0.8
  elseif b.kind == "showdown" and ((G.GAME and G.GAME.equity_pct) or 100) < (b.min_equity or 50) then return 0.85 end
  return 1
end

function Bosses.margin_delta(key)
  local b = by_key[key]
  return (b and b.kind == "margin" and b.margin_delta) or 0
end

function Bosses.payroll_multiplier(key)
  local b = by_key[key]
  return (b and b.kind == "payroll" and b.payroll_mult) or 1
end

return Bosses
