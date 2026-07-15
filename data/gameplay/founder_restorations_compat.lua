-- Player-facing Founder restorations for persistent compatibility edges.
-- Generated centers remain immutable; this manifest contains only the public
-- gameplay contract and its executable data.

return {
  ["f_azalia-mirhoseini"] = {
    ability_text = "After each blind won, permanently suppress one outstanding clash edge among Techs in your deck. Edges are chosen in stable Tech-key order, up to 24 per run.",
    effect_brief = "Blind wins permanently suppress a deck clash edge (max 24)",
    dsl = { hook="blind_won", ops={{k="suppress_clash_edge", mode="deck_outstanding",
      select="pair_key", amount=1, cap=24}} },
  },

  ["f_chris-olah"] = {
    ability_text = "The first time each Tech card is played, immediately and permanently suppress one clash between it and an earlier card in that Ship. Stable Tech-key order breaks ties.",
    effect_brief = "Each Tech's first play permanently suppresses one prior clash",
    dsl = { hook="individual", ops={{k="suppress_clash_edge", mode="trigger_card_prior",
      select="pair_key", amount=1, once_per="tech_uid", immediate=true}} },
  },

  ["f_patrick-esser"] = {
    ability_text = "Once per run, the first Ship with a clashing cross-Layer pair immediately ignores that clash and permanently suppresses its edge. Stable Tech-key order breaks ties.",
    effect_brief = "First cross-Layer clash is bridged permanently, once per run",
    dsl = { hook="before", ops={{k="suppress_clash_edge", mode="cross_layer_hand",
      select="pair_key", amount=1, once_per="run", immediate=true}} },
  },
}
