-- game/data/centers/signature_cards.lua — the two hand-authored signature cards.
-- Kept separate from generated catalogs so content regeneration cannot clobber them.
-- Behaviour: kitchen-engineer42's per-ante doubling lives in game/founders.lua FX; Jo-harness-burg's
-- clash-clear / signature Coverage / additive coupling are handled by explicit runtime behavior.
local signature_cards = {
  {
    key = "f_kitchen-engineer42", set = "Founder",
    name = "kitchen-engineer42",                 -- codename = display name (matches the GitHub handle)
    short = "KE42",
    ability_name = "The Late Bloomer",
    ability_text = "Starts a ×0.9 drag (unproven youth). Each ante you SURVIVE with her employed, her ×Mult " ..
                   "increment DOUBLES (+0.1, +0.2, +0.4 …) → about ×26 by IPO. Firing her resets the curve " ..
                   "to ×0.9 and deletes Jo-harness-burg. The only founder whose value is mostly in the future.",
    hint = "xMult doubles per ante (x0.9 -> x26)",
    rarity = "Legendary", salary = 6, signature = true,
    identity = { era = "AI", game_era = "E4", product = "Agent",
      ai_maturity = "agent_harnesses", tech_layer = "Knowledge", role = "agent-harness" },
    era_affinity = { "E4" }, product_identity = "Agent",
    ai_maturity_key = "agent_harnesses", tech_layer_affinity = "Knowledge",
    role_affinity = "agent-harness",
    effect = { type = "xmult", scaling = "scaling_persistent", hook = "joker_main",
               primitive_hint = "x_mult", engine_status = "executable",
               magnitude = "0.8 + 0.1*2^antes_survived", ke_complement = false },
  },
  {
    key = "t_joharness-burg", set = "TechCard",
    name = "Jo-harness-burg",
    layers = { { layer = "Knowledge", sub_role = "agent-harness" } },
    layer = "Knowledge", sub_role = "agent-harness", role = "agent-harness",
    base_users = 12,
    signature_behavior = { double_layer = true, coverage_slots = 2,
      coverage_mode = "wildcard_core", anchor_layer = "AI" },
    clears_clash = true,        -- JIT schema: removes ALL compatibility clashes when in the built hand
    hamster_mult = 8,           -- Hamster: flat +rev/user (+mult)
    signature = true,           -- excluded from the normal deck build; only present while she's employed
    eras = { "E4" },
    identity = { era = "AI", game_era = "E4", product = "Agent",
      ai_maturity = "agent_harnesses", tech_layer = "Knowledge", role = "agent-harness" },
    product_identity = "Agent", ai_maturity_key = "agent_harnesses",
    tech_layer_affinity = "Knowledge",
    desc = "The harness writes the JIT schema: clears all clashes, fills 2 layers, grows with its paired Founder.",
  },
}
return require("game.founder_presentation").apply(signature_cards, signature_cards)
