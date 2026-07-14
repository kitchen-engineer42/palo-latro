-- game/data/centers/vouchers.lua — Investment vouchers (Balatro Voucher analogue, re-themed
-- from the runtime contract). Run-PERSISTENT perks, 1 offered per shop, buyable once each. Declarative `mod`
-- {field, delta} is applied generically by Shop.redeem onto a G.GAME run-field (no per-voucher code).
-- cost_frac = fraction of the ante's economic scale (Cash = Margin×ARR); sim-tuned drafts.
return {
  { key = "v_bigger-office",     set = "Voucher", name = "Bigger Office",     cost_frac = 0.55,
    desc = "+1 Founder slot — run a 6th founder.",            mod = { field = "founder_slots",   delta = 1   } },
  { key = "v_extra-sprint",      set = "Voucher", name = "Extra Sprint",      cost_frac = 0.50,
    desc = "+1 Ship every blind.",                            mod = { field = "ships_bonus",     delta = 1   } },
  { key = "v_devops-pipeline",   set = "Voucher", name = "DevOps Pipeline",   cost_frac = 0.40,
    desc = "+1 Pivot every blind.",                           mod = { field = "pivots_bonus",    delta = 1   } },
  { key = "v_cloud-credits",     set = "Voucher", name = "Cloud Credits",     cost_frac = 0.40,
    desc = "Rerolls cost 30% less.",                          mod = { field = "reroll_discount", delta = 0.3 } },
  { key = "v_better-recruiting", set = "Voucher", name = "Better Recruiting", cost_frac = 0.50,
    desc = "Hiring founders costs 20% less.",                 mod = { field = "shop_discount",   delta = 0.2 } },
  { key = "v_bigger-roadmap",    set = "Voucher", name = "Bigger Roadmap",    cost_frac = 0.50,
    desc = "+1 hand size — draw one more tech card.",         mod = { field = "hand_size",       delta = 1   } },
}
