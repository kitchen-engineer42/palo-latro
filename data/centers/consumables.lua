-- game/data/centers/consumables.lua — Tech Law (Tarot analogue) consumables, wave 1.
-- One-shot cards applied via Consumables.apply (game/consumables.lua) using the 5 MVP ops:
--   sticker(field=users|rev, mode=add|mul|override) · cash · destroy(+refund) · mint · set_layer.
-- `target` = nil (no target) or {area, n[, layer]}. Additional operation types can extend this catalog.
return {
  -- card-stat stickers (persistent per-card modifiers, read at scoring) -------------------------
  { key = "tl_moores_law", set = "Consumable", kind = "TechLaw", name = "Moore's Law", rarity = "common", cost_frac = 0.15,
    desc = "Double a selected tech card's Users, permanently.",
    target = { area = "hand", n = 1 }, ops = { { k = "sticker", field = "users", mode = "mul", amount = 2, label = "Vital" } } },
  { key = "tl_pareto_principle", set = "Consumable", kind = "TechLaw", name = "The Pareto Principle", rarity = "common", cost_frac = 0.15,
    desc = "A selected tech card's Revenue x1.8, permanently.",
    target = { area = "hand", n = 1 }, ops = { { k = "sticker", field = "rev", mode = "mul", amount = 1.8, label = "Vital" } } },
  { key = "tl_scalable", set = "Consumable", kind = "TechLaw", name = "Scalable", rarity = "common", cost_frac = 0.15,
    desc = "+30 Users to a selected tech card, permanently.",
    target = { area = "hand", n = 1 }, ops = { { k = "sticker", field = "users", mode = "add", amount = 30, label = "Scalable" } } },
  { key = "tl_monetizable", set = "Consumable", kind = "TechLaw", name = "Monetizable", rarity = "common", cost_frac = 0.15,
    desc = "+2 Revenue to a selected tech card, permanently.",
    target = { area = "hand", n = 1 }, ops = { { k = "sticker", field = "rev", mode = "add", amount = 2, label = "Monetizable" } } },
  { key = "tl_goodharts_law", set = "Consumable", kind = "TechLaw", name = "Goodhart's Law", rarity = "uncommon", cost_frac = 0.25,
    desc = "CURSE a card: Users x3, but its Revenue drops to 1.",
    target = { area = "hand", n = 1 }, ops = {
      { k = "sticker", field = "users", mode = "mul", amount = 3, label = "gamed" },
      { k = "sticker", field = "rev", mode = "override", amount = 1, label = "gamed" } } },
  -- economy -------------------------------------------------------------------------------------
  { key = "tl_seed_round", set = "Consumable", kind = "TechLaw", name = "Seed Round", rarity = "common", cost_frac = 0.05,  -- flat +$8 payout: keep it cheap (its value does not scale with ante)
    desc = "Close a seed round: gain +$8 Cash.",
    ops = { { k = "cash", amount = 8, cap = 8 } } },
  -- destroy + refund ----------------------------------------------------------------------------
  { key = "tl_occams_razor", set = "Consumable", kind = "TechLaw", name = "Occam's Razor", rarity = "common", cost_frac = 0.15,
    desc = "Destroy 1 chosen tech card. Refund $3.",
    target = { area = "hand", n = 1 }, ops = { { k = "destroy", select = "player", refund = { amount = 3, cap = 3 } } } },
  { key = "tl_worse_is_better", set = "Consumable", kind = "TechLaw", name = "Worse Is Better", rarity = "uncommon", cost_frac = 0.25,
    desc = "Destroy your highest-Users card; gain Cash = 10% of its Users (min $4).",
    ops = { { k = "destroy", select = "max_users", refund = { frac = 0.1, floor = 4 } } } },
  -- mint ----------------------------------------------------------------------------------------
  { key = "tl_galls_law", set = "Consumable", kind = "TechLaw", name = "Gall's Law", rarity = "uncommon", cost_frac = 0.25,
    desc = "Clone your lowest-Users tech card; the copy starts fresh.",
    ops = { { k = "mint", source = "min_users" } } },
  -- set layer -----------------------------------------------------------------------------------
  { key = "tl_conways_law", set = "Consumable", kind = "TechLaw", name = "Conway's Law", rarity = "uncommon", cost_frac = 0.25,
    desc = "Re-Layer 1 selected tech card to any Layer you choose.",
    target = { area = "hand", n = 1, layer = true }, ops = { { k = "set_layer" } } },
}
