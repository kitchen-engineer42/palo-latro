-- Authored gameplay rules keyed by the factual Market ids in markets_gen.lua.
-- Mutable balance belongs here; generated Market prose remains factual/display data.

local DEFAULT = {
  start_era = 1,
  era_path = { 1, 2, 3, 4, 5 },
  starter_size = 40,
  copy_cap = 2,
  anchor_copy_cap = 3,
  layer_weights = { Frontend = 1, Backend = 1, Data = 1, Infra = 1, AI = 1, Knowledge = 0.55 },
  perk_ops = {},
  constraints = {},
  founder_tags = {},
}

local RULES = {
  ["indie-saas"] = {
    start_available = true,
    scenario_id = "promptapp-enterprise",
    anchors = { "t_php", "t_python", "t_mysql", "t_postgresql", "t_linux" },
    layer_weights = { Frontend = 1.2, Backend = 1.5, Data = 1.2, Infra = 0.8, AI = 0.25, Knowledge = 0.35 },
    perk_ops = { { op = "ships_per_blind", amount = 1 } },
    founder_tags = { "bootstrap", "margin", "saas", "oss" },
  },
  ["consumer-social"] = {
    start_available = true,
    scenario_id = "promptapp-social",
    anchors = { "t_html-css", "t_javascript", "t_php", "t_mysql" },
    layer_weights = { Frontend = 1.6, Backend = 1.15, Data = 1.1, Infra = 0.65, AI = 0.4, Knowledge = 0.25 },
    perk_ops = { { op = "pivots_per_blind", amount = 1 } },
    founder_tags = { "consumer", "growth", "social", "frontend" },
  },
  ["fintech-payments"] = {
    start_available = true,
    scenario_id = "workflow-finance",
    anchors = { "t_java", "t_dotnet", "t_postgresql", "t_linux", "t_rest" },
    layer_weights = { Frontend = 0.65, Backend = 1.35, Data = 1.35, Infra = 1.25, AI = 0.2, Knowledge = 0.6 },
    perk_ops = { { op = "starting_cash_units", amount = 1 }, { op = "free_voucher", amount = 1 } },
    founder_tags = { "finance", "enterprise", "reliability", "data" },
  },
  ["devtools-pickaxe"] = { scenario_id = "harness-devtools", perk_ops = { { op = "founder_slots", amount = 1 }, { op = "hand_size", amount = -1 } }, founder_tags = { "developer", "infra", "oss" } },
  ["ecommerce-platform"] = { scenario_id = "workflow-commerce", perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "commerce", "consumer", "platform" } },
  ["bootstrap-microsaas"] = { scenario_id = "promptapp-enterprise", perk_ops = { { op = "ships_per_blind", amount = 1 } }, founder_tags = { "bootstrap", "saas", "margin" } },
  ["blitzscale-rocketship"] = { scenario_id = "promptapp-consumer", perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "blitzscale", "growth", "ai" } },
  ["healthtech-clinical"] = { scenario_id = "workflow-healthcare", perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "healthcare", "enterprise", "reliability" } },
  ["legaltech-workspace"] = { scenario_id = "rag-legal", perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "legal", "rag", "knowledge" } },
  ["enterprise-onprem"] = { scenario_id = "rag-enterprise", perk_ops = { { op = "founder_slots", amount = 1 } }, founder_tags = { "enterprise", "infra", "data" } },
  ["ai-agent-harness"] = { scenario_id = "harness-devtools", perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "developer", "ai", "harness" } },
  ["data-platform"] = { scenario_id = "rag-enterprise", perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "data", "platform", "enterprise" } },
  ["plasma-market"] = { scenario_id = "multiagent-commerce", perk_ops = { { op = "ships_per_blind", amount = 1 } }, founder_tags = { "commerce", "agents", "growth" } },
  ["open-source"] = { scenario_id = "harness-devtools", perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "oss", "developer", "community" } },
  ["vaporware-hype"] = { scenario_id = "promptapp-social", perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "hype", "growth", "ai" } },
  ["solo-indie"] = { scenario_id = "promptapp-enterprise", perk_ops = { { op = "founder_slots", amount = 1 } }, founder_tags = { "solo", "bootstrap", "margin" } },
}

local function clone(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = clone(x) end
  return out
end

local function merge(base, extra)
  local out = clone(base)
  for k, v in pairs(extra or {}) do out[k] = clone(v) end
  return out
end

local M = { raw = RULES }

function M.for_market(market)
  local id = type(market) == "table" and market.id or market
  return merge(DEFAULT, RULES[id] or {})
end

return M
