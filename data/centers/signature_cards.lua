-- game/data/centers/signature_cards.lua — the two hand-authored signature cards.
-- Kept separate from generated catalogs so content regeneration cannot clobber them.
-- Behaviour: kitchen-engineer42's per-ante doubling lives in game/founders.lua FX; Jo-harness-burg's
-- clash-clear / double-layer / additive coupling are handled as the lone special case in scoring.lua.
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
    effect = { type = "xmult", scaling = "scaling_persistent", hook = "joker_main",
               primitive_hint = "x_mult", engine_status = "executable",
               magnitude = "0.8 + 0.1*2^antes_survived", ke_complement = false },
  },
  {
    key = "t_joharness-burg", set = "TechCard",
    name = "Jo-harness-burg",
    layers = { { layer = "agent-harness", sub_role = "meta-harness" },
               { layer = "Knowledge",     sub_role = "jit-schema" } },
    layer = "agent-harness", sub_role = "meta-harness",
    base_users = 12,
    double_layer = true,        -- the LONE card that fills BOTH Coverage slots (exception)
    clears_clash = true,        -- JIT schema: removes ALL compatibility clashes when in the built hand
    hamster_mult = 8,           -- Hamster: flat +rev/user (+mult)
    signature = true,           -- excluded from the normal deck build; only present while she's employed
    eras = { "E1", "E2", "E3", "E4", "E5" },
    desc = "The harness writes the JIT schema: clears all clashes, fills 2 layers, grows with its paired Founder.",
  },
}
return require("game.founder_presentation").apply(signature_cards, signature_cards)
