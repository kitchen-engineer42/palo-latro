-- Authored identity and payoff bands for the AI-solution maturity ladder.
-- Matching is deliberately about the Techs in the shipped hand, not the run's
-- persistent maturity meter.  A higher-rung Tech is evidence of the artifact
-- the product actually ships; players do not need to play every precursor.

return {
  version = 1,
  ai_app_types = {
    apt_ai_wrapper = true,
    apt_ai_feature = true,
    apt_ai_product = true,
    apt_ai_native = true,
    -- Moonshot is dual-use; the runtime additionally requires an AI Layer so
    -- an Infra-only deep-tech hand does not acquire an AI maturity identity.
    apt_moonshot = true,
  },
  limits = { users_bonus = 20, rev_mult = 1.10 },
  rungs = {
    {
      key = "prompt_engineering", name = "Prompt Engineering", short = "Prompt",
      users_bonus = 0, rev_mult = 1.00,
      evidence = { { any_layers = { "AI" } } },
    },
    {
      key = "context_engineering", name = "Context Engineering", short = "Context",
      users_bonus = 4, rev_mult = 1.02,
      evidence = {
        { any_roles = { "rag-retrieval", "vector-db", "kg-rag-graphrag" } },
        { all_layers = { "AI", "Knowledge" } },
      },
    },
    {
      key = "workflows", name = "Building Workflows", short = "Workflows",
      users_bonus = 8, rev_mult = 1.04,
      evidence = { { any_roles = { "orchestration" } } },
    },
    {
      key = "agents", name = "Building Agents", short = "Agents",
      users_bonus = 12, rev_mult = 1.06,
      evidence = { { any_roles = { "agent-framework" } } },
    },
    {
      key = "agent_harnesses", name = "Agent Harnesses", short = "Harnesses",
      users_bonus = 16, rev_mult = 1.08,
      evidence = { { any_roles = { "agent-harness" } } },
    },
    {
      key = "meta_works", name = "Meta Works", short = "Meta",
      users_bonus = 20, rev_mult = 1.10,
      evidence = {
        { any_roles = { "meta-harness" } },
        { all_roles = { "agent-harness", "eval-observability" } },
        { all_roles = { "agent-harness" }, all_layers = { "Knowledge" } },
      },
    },
  },
}
