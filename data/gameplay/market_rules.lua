-- Authored gameplay rules keyed by the factual Market ids in markets_gen.lua.
-- Mutable balance belongs here; generated Market prose remains factual/display data.

local function doubled(keys)
  local out = {}
  for _, key in ipairs(keys) do
    out[#out + 1] = key
    out[#out + 1] = key
  end
  return out
end

-- Starter recipes are authored instances, not weighted requests. Every recipe
-- contains twelve Techs at two copies each. The witness is a guaranteed useful
-- three-card App Type already present in that exact recipe.
local STARTERS = {
  indie_e1 = doubled({
    "t_html-css", "t_javascript", "t_jquery", "t_php", "t_python", "t_rest",
    "t_mysql", "t_postgresql", "t_memcached", "t_java", "t_lucene-solr", "t_prolog",
  }),
  consumer_e2 = doubled({
    "t_html-css", "t_javascript", "t_jquery", "t_angularjs", "t_bootstrap", "t_nodejs",
    "t_express", "t_mongodb", "t_redis", "t_aws", "t_heroku", "t_scikit-learn",
  }),
  fintech_e2 = doubled({
    "t_html-css", "t_jquery", "t_java", "t_dotnet", "t_spring-boot", "t_rest",
    "t_oracle-db", "t_sql-server", "t_postgresql", "t_bare-metal", "t_azure", "t_scikit-learn",
  }),
  devtools_e2 = doubled({
    "t_javascript", "t_backbone-js", "t_nodejs", "t_express", "t_rest", "t_postgresql",
    "t_mongodb", "t_redis", "t_aws", "t_heroku", "t_jenkins", "t_scikit-learn",
  }),
  commerce_e2 = doubled({
    "t_html-css", "t_javascript", "t_jquery", "t_bootstrap", "t_php", "t_laravel",
    "t_mysql", "t_redis", "t_aws", "t_cloudflare", "t_heroku", "t_scikit-learn",
  }),
  microsaas_e3 = doubled({
    "t_html-css", "t_javascript", "t_react", "t_nextjs", "t_python", "t_django",
    "t_rest", "t_postgresql", "t_redis", "t_digitalocean", "t_github-actions", "t_scikit-learn",
  }),
  blitzscale_e3 = doubled({
    "t_javascript", "t_react", "t_nextjs", "t_nodejs", "t_nestjs", "t_graphql",
    "t_mongodb", "t_redis", "t_aws", "t_docker", "t_kubernetes", "t_pytorch",
  }),
  health_e3 = doubled({
    "t_html-css", "t_react", "t_java", "t_spring-boot", "t_rest", "t_oauth2",
    "t_postgresql", "t_neo4j", "t_aws", "t_docker", "t_datadog", "t_tensorflow",
  }),
  legal_e4 = doubled({
    "t_react", "t_nextjs", "t_python", "t_fastapi", "t_oauth2", "t_postgresql",
    "t_elasticsearch", "t_aws", "t_docker", "t_openai-api", "t_pinecone", "t_protege",
  }),
  enterprise_e4 = doubled({
    "t_angular", "t_typescript", "t_java", "t_spring-boot", "t_rest", "t_oauth2",
    "t_sql-server", "t_postgresql", "t_azure", "t_kubernetes", "t_datadog", "t_pytorch",
  }),
  harness_e4 = doubled({
    "t_react", "t_typescript", "t_python", "t_fastapi", "t_postgresql", "t_redis",
    "t_aws", "t_docker", "t_openai-api", "t_langchain", "t_autogpt", "t_langfuse",
  }),
  data_e3 = doubled({
    "t_react", "t_typescript", "t_nodejs", "t_rest", "t_postgresql", "t_snowflake",
    "t_databricks", "t_airflow", "t_aws", "t_docker", "t_prometheus", "t_tensorflow",
  }),
  plasma_e1 = doubled({
    "t_html-css", "t_javascript", "t_jquery", "t_java", "t_dotnet", "t_python",
    "t_rest", "t_oracle-db", "t_mysql", "t_postgresql", "t_cyc", "t_prolog",
  }),
  oss_e2 = doubled({
    "t_html-css", "t_javascript", "t_angularjs", "t_php", "t_python", "t_django",
    "t_postgresql", "t_mysql", "t_digitalocean", "t_heroku", "t_jenkins", "t_scikit-learn",
  }),
  vaporware_e1 = doubled({
    "t_html-css", "t_javascript", "t_jquery", "t_php", "t_python", "t_soap",
    "t_mysql", "t_memcached", "t_lucene-solr", "t_cyc", "t_clips", "t_prolog",
  }),
  solo_e2 = doubled({
    "t_html-css", "t_javascript", "t_jquery", "t_bootstrap", "t_php", "t_laravel",
    "t_mysql", "t_postgresql", "t_digitalocean", "t_heroku", "t_cloudflare", "t_scikit-learn",
  }),
}

local DEFAULT = {
  start_era = 1,
  era_path = { 1, 2, 3, 4, 5 },
  starter_size = 24,
  copy_cap = 2,
  anchor_copy_cap = 2,
  anchors = {},
  layer_weights = { Frontend = 1, Backend = 1, Data = 1, Infra = 1, AI = 1, Knowledge = 0.55 },
  perk_ops = {},
  constraints = {},
  founder_tags = {},
}

local RULES = {
  ["indie-saas"] = {
    start_available = true,
    scenario_id = "promptapp-enterprise",
    starter_recipe = STARTERS.indie_e1,
    starter_witness = { app_type = "apt_saas", cards = { "t_html-css", "t_php", "t_mysql" } },
    anchors = { "t_php", "t_python", "t_mysql", "t_postgresql", "t_html-css" },
    layer_weights = { Frontend = 1.2, Backend = 1.5, Data = 1.2, Infra = 0.8, AI = 0.25, Knowledge = 0.35 },
    perk_ops = { { op = "ships_per_blind", amount = 1 } },
    founder_tags = { "bootstrap", "margin", "saas", "oss" },
  },
  ["consumer-social"] = {
    start_available = true,
    start_era = 2,
    era_path = { 2, 2, 3, 4, 5 },
    scenario_id = "promptapp-social",
    starter_recipe = STARTERS.consumer_e2,
    starter_witness = { app_type = "apt_webapp", cards = { "t_angularjs", "t_nodejs", "t_mongodb" } },
    anchors = { "t_html-css", "t_javascript", "t_nodejs", "t_mongodb", "t_aws" },
    layer_weights = { Frontend = 1.6, Backend = 1.15, Data = 1.1, Infra = 0.65, AI = 0.4, Knowledge = 0.25 },
    perk_ops = { { op = "pivots_per_blind", amount = 1 } },
    founder_tags = { "consumer", "growth", "social", "frontend" },
  },
  ["fintech-payments"] = {
    start_available = true,
    start_era = 2,
    era_path = { 2, 2, 3, 4, 5 },
    scenario_id = "workflow-finance",
    starter_recipe = STARTERS.fintech_e2,
    starter_witness = { app_type = "apt_saas", cards = { "t_html-css", "t_java", "t_oracle-db" } },
    anchors = { "t_java", "t_dotnet", "t_postgresql", "t_bare-metal", "t_rest" },
    layer_weights = { Frontend = 0.65, Backend = 1.35, Data = 1.35, Infra = 1.25, AI = 0.2, Knowledge = 0.6 },
    perk_ops = { { op = "starting_cash_units", amount = 1 }, { op = "free_voucher", amount = 1 } },
    founder_tags = { "finance", "enterprise", "reliability", "data" },
  },
  ["devtools-pickaxe"] = {
    start_era = 2, era_path = { 2, 2, 3, 4, 5 }, scenario_id = "harness-devtools",
    starter_recipe = STARTERS.devtools_e2,
    starter_witness = { app_type = "apt_saas", cards = { "t_javascript", "t_nodejs", "t_postgresql" } },
    anchors = { "t_nodejs", "t_postgresql", "t_aws", "t_jenkins" },
    perk_ops = { { op = "founder_slots", amount = 1 }, { op = "hand_size", amount = -1 } }, founder_tags = { "developer", "infra", "oss" },
  },
  ["ecommerce-platform"] = {
    start_era = 2, era_path = { 2, 2, 3, 4, 5 }, scenario_id = "workflow-commerce",
    starter_recipe = STARTERS.commerce_e2,
    starter_witness = { app_type = "apt_webapp", cards = { "t_jquery", "t_php", "t_mysql" } },
    anchors = { "t_jquery", "t_php", "t_mysql", "t_aws" },
    perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "commerce", "consumer", "platform" },
  },
  ["bootstrap-microsaas"] = {
    start_era = 3, era_path = { 3, 3, 3, 4, 5 }, scenario_id = "promptapp-enterprise",
    starter_recipe = STARTERS.microsaas_e3,
    starter_witness = { app_type = "apt_webapp", cards = { "t_react", "t_python", "t_postgresql" } },
    anchors = { "t_react", "t_python", "t_postgresql", "t_digitalocean" },
    perk_ops = { { op = "ships_per_blind", amount = 1 } }, founder_tags = { "bootstrap", "saas", "margin" },
  },
  ["blitzscale-rocketship"] = {
    start_era = 3, era_path = { 3, 3, 3, 4, 5 }, scenario_id = "promptapp-consumer",
    starter_recipe = STARTERS.blitzscale_e3,
    starter_witness = { app_type = "apt_webapp", cards = { "t_react", "t_nodejs", "t_mongodb" } },
    anchors = { "t_react", "t_nodejs", "t_mongodb", "t_aws", "t_pytorch" },
    perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "blitzscale", "growth", "ai" },
  },
  ["healthtech-clinical"] = {
    start_era = 3, era_path = { 3, 3, 3, 4, 5 }, scenario_id = "workflow-healthcare",
    starter_recipe = STARTERS.health_e3,
    starter_witness = { app_type = "apt_webapp", cards = { "t_react", "t_java", "t_postgresql" } },
    anchors = { "t_java", "t_postgresql", "t_oauth2", "t_tensorflow" },
    perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "healthcare", "enterprise", "reliability" },
  },
  ["legaltech-workspace"] = {
    start_era = 4, era_path = { 4, 4, 4, 4, 5 }, scenario_id = "rag-legal",
    starter_recipe = STARTERS.legal_e4,
    starter_witness = { app_type = "apt_webapp", cards = { "t_react", "t_python", "t_postgresql" } },
    anchors = { "t_python", "t_postgresql", "t_openai-api", "t_pinecone", "t_protege" },
    perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "legal", "rag", "knowledge" },
  },
  ["enterprise-onprem"] = {
    start_era = 4, era_path = { 4, 4, 4, 4, 5 }, scenario_id = "rag-enterprise",
    starter_recipe = STARTERS.enterprise_e4,
    starter_witness = { app_type = "apt_webapp", cards = { "t_angular", "t_java", "t_sql-server" } },
    anchors = { "t_java", "t_sql-server", "t_azure", "t_kubernetes" },
    perk_ops = { { op = "founder_slots", amount = 1 } }, founder_tags = { "enterprise", "infra", "data" },
  },
  ["ai-agent-harness"] = {
    start_era = 4, era_path = { 4, 4, 4, 4, 5 }, scenario_id = "harness-devtools",
    starter_recipe = STARTERS.harness_e4,
    starter_witness = { app_type = "apt_ai_feature", cards = { "t_react", "t_python", "t_openai-api" } },
    anchors = { "t_python", "t_openai-api", "t_langchain", "t_autogpt", "t_langfuse" },
    perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "developer", "ai", "harness" },
  },
  ["data-platform"] = {
    start_era = 3, era_path = { 3, 3, 3, 4, 5 }, scenario_id = "rag-enterprise",
    starter_recipe = STARTERS.data_e3,
    starter_witness = { app_type = "apt_webapp", cards = { "t_react", "t_nodejs", "t_postgresql" } },
    anchors = { "t_postgresql", "t_snowflake", "t_databricks", "t_airflow", "t_aws" },
    perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "data", "platform", "enterprise" },
  },
  ["plasma-market"] = {
    scenario_id = "multiagent-commerce", starter_recipe = STARTERS.plasma_e1,
    starter_witness = { app_type = "apt_webapp", cards = { "t_jquery", "t_java", "t_oracle-db" } },
    anchors = { "t_jquery", "t_java", "t_oracle-db", "t_prolog" },
    perk_ops = { { op = "ships_per_blind", amount = 1 } }, founder_tags = { "commerce", "agents", "growth" },
  },
  ["open-source"] = {
    start_era = 2, era_path = { 2, 2, 3, 4, 5 }, scenario_id = "harness-devtools",
    starter_recipe = STARTERS.oss_e2,
    starter_witness = { app_type = "apt_webapp", cards = { "t_angularjs", "t_python", "t_postgresql" } },
    anchors = { "t_python", "t_postgresql", "t_heroku", "t_jenkins" },
    perk_ops = { { op = "pivots_per_blind", amount = 1 } }, founder_tags = { "oss", "developer", "community" },
  },
  ["vaporware-hype"] = {
    scenario_id = "promptapp-social", starter_recipe = STARTERS.vaporware_e1,
    starter_witness = { app_type = "apt_webapp", cards = { "t_jquery", "t_php", "t_mysql" } },
    anchors = { "t_jquery", "t_php", "t_mysql", "t_cyc" },
    perk_ops = { { op = "hand_size", amount = 1 } }, founder_tags = { "hype", "growth", "ai" },
  },
  ["solo-indie"] = {
    start_era = 2, era_path = { 2, 2, 3, 4, 5 }, scenario_id = "promptapp-enterprise",
    starter_recipe = STARTERS.solo_e2,
    starter_witness = { app_type = "apt_webapp", cards = { "t_jquery", "t_php", "t_mysql" } },
    anchors = { "t_php", "t_mysql", "t_digitalocean", "t_heroku" },
    perk_ops = { { op = "founder_slots", amount = 1 } }, founder_tags = { "solo", "bootstrap", "margin" },
  },
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

local M = { raw = RULES, ruleset_version = 3 }

function M.for_market(market)
  local id = type(market) == "table" and market.id or market
  return merge(DEFAULT, RULES[id] or {})
end

return M
