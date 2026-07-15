-- Player-facing Founder restorations for Tech-card and shop-offer mechanics.
-- Generated centers remain immutable; this manifest contains only the public
-- gameplay contract and its executable data.

return {
  ["f_abubakar-abid"] = {
    ability_text = "Once per blind, activate and choose a Tech in hand to swap with the top card of the deck. If the replacement has more Users, the next Ship gains +1 Rev.",
    effect_brief = "Demo a Tech; a stronger top-deck swap arms +1 Rev",
    dsl = { action={label="Demo", description="Swap a chosen Tech with the top of the deck.", target="tech_uid"},
      hook="activated", once=true, once_scope="blind", ops={
        {k="mutate", mode="swap_top", from="hand", select="target", to="hand",
          target="tech_uid", compare="higher_users"},
        {k="arm", field="mult", base=1, gate={g="event", field="mutation_upgraded", value=true}},
      } },
  },

  ["f_amnon-shashua"] = {
    ability_text = "Each blind won adds one random Tech from a Layer you have already used to the deck.",
    effect_brief = "Blind wins add a Tech from a previously used Layer",
    dsl = { hook="blind_won", ops={{k="gen", kind="tech_card", layer="random_seen"}} },
  },

  ["f_andy-konwinski"] = {
    ability_text = "Each blind won copies a random Tech from the last Ship into the deck. If it had no Enhancement, the copy gains one.",
    effect_brief = "Blind wins graduate a played Tech into an enhanced copy",
    dsl = { hook="blind_won", ops={{k="mutate", mode="copy", from="last_ship", select="random",
      to="deck", amount=1, preserve=true, enhancement="fresh_if_empty"}} },
  },

  ["f_arthur-mensch"] = {
    ability_text = "Below 0.7x target, gain xRev equal to 2 minus the target ratio. From Stage 3, the first on-target Ship each Ante copies the highest-Users Tech from your latest Pivot into hand.",
    effect_brief = "Efficient misses gain xRev; later Antes reclaim a Pivoted Tech",
    dsl = { clauses={
      { id="efficient_weights", hook="after", gate={g="arr_ratio", stage="pre_after", op="<", val=0.7},
        ops={{k="scale", field="x_mult", base=2, coef=-1, per="arr_ratio"}} },
      { id="open_weights", hook="post_resolution", gate={g="and", gs={
          {g="ante", op=">=", val=3}, {g="arr_ratio", stage="final", op=">=", val=1},
        }}, once=true, once_scope="ante", ops={{k="mutate", mode="copy", from="last_pivot",
          select="highest_users", to="hand", amount=1, preserve=true}} },
    } },
  },

  ["f_clayton-christensen"] = {
    ability_text = "The first Ship of each new App Type copies that hand's lowest-base-Users Tech into the deck.",
    effect_brief = "New App Types seed a copy of their cheapest played Tech",
    dsl = { hook="after", gate={g="count", per="new_app_types", op=">=", val=1},
      ops={{k="mutate", mode="copy", from="scoring_hand", select="lowest_base_users",
        to="deck", amount=1, preserve=true}} },
  },

  ["f_drew-houston"] = {
    ability_text = "Winning a blind after no Founder hires and no Cash spending grows a referral streak, adds a random Tech to the next hand, and gives the next Ship xUsers starting at x2, then +0.2 per streak. Hiring or spending resets it.",
    effect_brief = "No-hire, no-spend wins grow Tech and xUsers referrals",
    dsl = { clauses={
      { id="referral_score", hook="joker_main", gate={g="state", state="referrals_armed", op=">=", val=1},
        ops={{k="scale", field="x_chips", base=1.8, coef=0.2, per="counter", state="referrals"},
          {k="state", state="referrals_armed", mode="clear"}} },
      { id="referral_win", hook="blind_won", gate={g="and", gs={
          {g="count", per="founders_hired_round", op="==", val=0},
          {g="count", per="cash_spent_round", op="==", val=0},
        }}, ops={{k="state", state="referrals", mode="add", amount=1, cap=8},
          {k="state", state="referrals_armed", mode="set", amount=1},
          {k="mutate", mode="generate", from="tech_pool", select="random_non_signature",
            to="next_hand", amount=1}} },
      { id="hire_reset", hook="founder_hired", ops={{k="state", state="referrals", mode="clear"},
        {k="state", state="referrals_armed", mode="clear"}} },
      { id="spend_reset", hook="cash_spent", ops={{k="state", state="referrals", mode="clear"},
        {k="state", state="referrals_armed", mode="clear"}} },
    } },
  },

  ["f_guillaume-lample"] = {
    ability_text = "Each AI-backed Ship queues one free Common Founder for the next Shop and builds 1 Exodus. At 3+ Exodus, it also adds a Tech from a Layer in that Ship.",
    effect_brief = "AI Ships queue Common Founders; 3+ also generate Tech",
    dsl = { hook="after", gate={g="layer_present", layer="AI"}, ops={
      {k="state", state="exodus", mode="add", amount=1, cap=12},
      {k="offer", kind="founder", timing="next_shop", count=1, rarity="Common", free=true, pinned=true},
      {k="mutate", mode="generate", from="tech_pool", select="random_scoring_layer", to="deck", amount=1,
        gate={g="state", state="exodus", op=">=", val=2}},
    } },
  },

  ["f_herbert-boyer"] = {
    ability_text = "The first Ship each blind that covers every Layer currently in your deck copies its highest-Users Tech twice into the deck.",
    effect_brief = "Cover the deck's Layers to splice two top-Tech copies",
    dsl = { hook="after", gate={g="played_covers_deck_layers"}, once=true, once_scope="blind",
      ops={{k="mutate", mode="copy", from="scoring_hand", select="highest_users",
        to="deck", amount=2, preserve=true}} },
  },

  ["f_jerry-yang"] = {
    ability_text = "Once per run, activate and tag one Tech as a Relationship Bet. Each round it stays unplayed banks +1 Rev. Its first play gains the banked Rev and retriggers twice, then clears the Bet.",
    effect_brief = "Tag a Tech; patience banks Rev for its first double retrigger",
    dsl = { action={label="Place Bet", description="Tag one Tech as the Relationship Bet.", target="tech_uid"}, clauses={
      { id="place_bet", hook="activated", once=true, once_scope="run",
        ops={{k="mutate", mode="mark", from="master_deck", select="target",
          target="tech_uid", compare="relationship_bet"}} },
      { id="patience", hook="post_resolution", gate={g="not", g1={g="marked_card_played", target="relationship_bet"}},
        ops={{k="mutate", mode="age_mark", from="master_deck", select="marked",
          target="relationship_bet", amount=1}} },
      { id="payoff", hook="individual", gate={g="card_mark", target="relationship_bet"},
        ops={{k="scale", field="mult", base=0, coef=1, per="card_mark_age", target="relationship_bet"}} },
      { id="retrigger", hook="repetition", gate={g="card_mark", target="relationship_bet"},
        retrigger=2, retrigger_target="marked" },
      { id="clear_bet", hook="post_resolution", gate={g="marked_card_played", target="relationship_bet"},
        ops={{k="mutate", mode="clear_mark", from="master_deck", select="marked", target="relationship_bet"}} },
    } },
  },

  ["f_julien-chaumond"] = {
    ability_text = "Each blind won adds one random Tech from every Layer you have used this run.",
    effect_brief = "Blind wins add one Tech per previously used Layer",
    dsl = { hook="blind_won", ops={{k="mutate", mode="generate", from="tech_pool",
      select="each_seen_layer", to="deck", amount=1}} },
  },

  ["f_matei-zaharia"] = {
    ability_text = "After each Ship, one random unplayed Tech permanently gains +2 Users. With 3+ distinct Layers, the highest-Users played Tech retriggers once.",
    effect_brief = "Unplayed Tech gains Users; broad Ships retrigger the strongest",
    dsl = { clauses={
      { id="memory", hook="post_resolution", ops={{k="mutate", mode="buff", from="hand",
        select="random", to="master_deck", amount=1, users=2}} },
      { id="replay", hook="repetition", gate={g="count", per="distinct_layers", op=">=", val=3},
        retrigger=1, retrigger_target="highest" },
    } },
  },

  ["f_michael-ovitz"] = {
    ability_text = "The first Ship each blind covering 3 or more Layers queues one free Founder for the next Shop.",
    effect_brief = "3+ Layers queue a free Founder for the next Shop",
    dsl = { hook="after", gate={g="count", per="distinct_layers", op=">=", val=3},
      once=true, once_scope="blind", ops={{k="offer", kind="founder", timing="next_shop",
        count=1, free=true, pinned=true}} },
  },

  ["f_paul-graham"] = {
    ability_text = "The first blind won each Ante queues a free Hiring Round for the next Shop. Pick 1 from up to 6 options, growing by 1 option each Ante.",
    effect_brief = "First win/Ante queues a growing free Hiring Round",
    dsl = { hook="blind_won", once=true, once_scope="ante", ops={{k="offer", kind="pack",
      timing="next_shop", pack_key="hiring", free=true, pinned=true,
      options={base=1, coef=1, per="ante", cap=6}}} },
  },

  ["f_pierre-omidyar"] = {
    ability_text = "Each scoring hand gains +10 Users per distinct App Type you have shipped this run.",
    effect_brief = "+10 Users per distinct App Type shipped",
    dsl = { hook="joker_main", ops={{k="scale", field="chips", base=0, coef=10,
      per="distinct_app_types_shipped"}} },
  },

  ["f_pieter-abbeel"] = {
    ability_text = "With 3 or more AI Techs in a Ship, its highest-Users Tech retriggers once plus once per round this Founder has been held.",
    effect_brief = "3+ AI: strongest Tech retriggers with tenure",
    dsl = { gate={g="count", per="cards_of_layer", layer="AI", op=">=", val=3},
      retrigger={base=1, coef=1, per="rounds_held"}, retrigger_target="highest" },
  },

  ["f_reid-hoffman"] = {
    ability_text = "Each blind won queues a Founder for the next Shop and builds 1 Introduction. From 3 Introductions, the Founder is half-price and a Hiring Round is also queued.",
    effect_brief = "Blind wins grow a Founder-and-pack introduction network",
    dsl = { hook="blind_won", ops={
      {k="state", state="introductions", mode="add", amount=1, cap=24},
      {k="offer", kind="founder", timing="next_shop", count=1, pinned=true,
        gate={g="state", state="introductions", op="<", val=3}},
      {k="offer", kind="founder", timing="next_shop", count=1, discount=0.5, pinned=true,
        gate={g="state", state="introductions", op=">=", val=3}},
      {k="offer", kind="pack", timing="next_shop", pack_key="hiring", count=1, pinned=true,
        gate={g="state", state="introductions", op=">=", val=3}},
    } },
  },

  ["f_robert-morris"] = {
    ability_text = "Singleton-Layer Techs contribute 0 Users. Gain +2 Rev per Tech in a repeated Layer, and +15 Users when every played Tech shares its Layer.",
    effect_brief = "Repeated Layers score; loose singletons are zeroed",
    dsl = { clauses={
      { id="zero_outliers", hook="individual", gate={g="count", per="same_layer_count", op="==", val=1},
        ops={{k="scale", field="chips", base=0, coef=-1, per="other_card_users"}} },
      { id="matched_depth", hook="joker_main", ops={{k="scale", field="mult", base=0, coef=2,
        per="cards_in_repeated_layers"}} },
      { id="no_outliers", hook="joker_main", gate={g="count", per="singleton_cards", op="==", val=0},
        ops={{k="scale", field="chips", base=15}} },
    } },
  },

  ["f_ron-conway"] = {
    ability_text = "Whenever a Founder is hired, immediately surface 2 additional pinned Founder offers in the current Shop, or the next Shop if none is open.",
    effect_brief = "Every hire surfaces 2 more Founder offers",
    dsl = { hook="founder_hired", ops={{k="offer", kind="founder", timing="current_or_next",
      count=2, pinned=true}} },
  },

  ["f_scott-wu"] = {
    ability_text = "Each Ship also scores the Users of 1 highest-Users unplayed Tech, plus 1 more per 2 rounds held. At 2x target, gain 10% of overkill ARR as Cash.",
    effect_brief = "Agent scores unplayed Users; 2x overkill pays Cash",
    dsl = { clauses={
      { id="recursive_deploy", hook="before", ops={{k="mutate", mode="score_users", from="hand",
        select="highest_users", to="score", amount={base=1, coef=0.5, per="rounds_held", round="floor"}}} },
      { id="surplus", hook="post_resolution", gate={g="arr_ratio", stage="final", op=">=", val=2},
        ops={{k="grant", what="cash", base=0, coef=0.1, per="overkill"}} },
    } },
  },

  ["f_tommy-davis"] = {
    ability_text = "While hired, Tech Evaluation packs offer +1 option per 2 Founders on the roster, capped at +2 options. Picks do not increase.",
    effect_brief = "A larger Founder roster widens Tech Evaluation offers",
    dsl = { passive={what="pack_option_bonus", family="tech_evaluation", base=0, coef=0.5,
      per="founder_count", round="floor", cap=2} },
  },

  ["f_william-shockley"] = {
    ability_text = "Whenever any Founder is sold or fired, surface one free pinned Founder offer in the current Shop, or the next Shop if none is open.",
    effect_brief = "Founder departures surface one free replacement",
    dsl = { hook="selling_card", ops={{k="offer", kind="founder", timing="current_or_next",
      count=1, free=true, pinned=true}} },
  },
}
