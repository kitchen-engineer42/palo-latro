-- Player-facing Founder restoration manifest.
--
-- This file is intentionally data-only: it records the player-facing contract
-- and executable Founder DSL without coupling this content block to catalog
-- registration.

return {
  ["f_aileen-lee"] = {
    ability_text = "After a Ship reaches at least 2x its target, bank +1 Rev permanently, once per blind.",
    effect_brief = "2x target Ships permanently bank +1 Rev",
    dsl = { clauses = {
      { id="portfolio", hook="joker_main", ops={{k="scale", field="mult", base=0, coef=1, per="counter", state="unicorn_rounds"}} },
      { id="unicorn", hook="post_resolution", gate={g="arr_ratio", stage="final", op=">=", val=2},
        once=true, once_scope="blind", ops={{k="state", state="unicorn_rounds", mode="add", amount=1}} },
    } },
  },

  ["f_andrew-mason"] = {
    ability_text = "After a Ship covers fewer than 3 Layers, the next Ship gains xUsers equal to that hand's size. Once per blind.",
    effect_brief = "Shallow Ship arms next Ship's xUsers by hand size",
    dsl = { hook="post_resolution", gate={g="count", per="distinct_layers", op="<", val=3},
      once=true, once_scope="blind", ops={{k="arm", field="x_chips", base=0, coef=1, per="hand_size"}} },
  },

  ["f_andrew-ng"] = {
    ability_text = "The first AI-backed Ship each blind permanently adds 0.4 to xRev, up to five times.",
    effect_brief = "First AI Ship per blind: permanent +0.4 xRev",
    dsl = { clauses = {
      { id="flywheel", hook="joker_main", ops={{k="x_add", field="mult", base=0, coef=0.4, per="counter", state="ai_ships"}} },
      { id="learn", hook="post_resolution", gate={g="layer_present", layer="AI"}, once=true, once_scope="blind",
        ops={{k="state", state="ai_ships", mode="add", amount=1, cap=5}} },
    } },
  },

  ["f_arthur-rock"] = {
    ability_text = "Gain +1 Rev per round held. The first time the team reaches 3 Founders, arm x1.5 Rev for the next Ship.",
    effect_brief = "+1 Rev/round held; first 3-Founder team arms x1.5 Rev",
    dsl = { clauses = {
      { id="patient_capital", hook="joker_main", ops={{k="scale", field="mult", base=0, coef=1, per="rounds_held"}} },
      { id="right_people", hook="founder_hired", gate={g="count", per="others", op=">=", val=2}, once=true, once_scope="run",
        ops={{k="arm", field="x_mult", base=1.5}} },
    } },
  },

  ["f_biz-stone"] = {
    ability_text = "A Ship that leaves at least 3 cards unplayed permanently banks +2 Rev, once per blind.",
    effect_brief = "Hold back 3+ cards to bank +2 Rev",
    dsl = { clauses = {
      { id="voice", hook="joker_main", ops={{k="scale", field="mult", base=0, coef=1, per="counter", state="restraint"}} },
      { id="decline_obvious", hook="post_resolution", gate={g="count", per="unplayed_cards", op=">=", val=3},
        once=true, once_scope="blind", ops={{k="state", state="restraint", mode="add", amount=2}} },
    } },
  },

  ["f_bono"] = {
    ability_text = "A Ship that clears its target without exceeding 1.15x permanently banks +1 Rev, once per blind.",
    effect_brief = "Barely clear the target to bank +1 Rev",
    dsl = { clauses = {
      { id="brand", hook="joker_main", ops={{k="scale", field="mult", base=0, coef=1, per="counter", state="brand_equity"}} },
      { id="lean_deal", hook="post_resolution", gate={g="and", gs={
          {g="arr_ratio", stage="final", op=">=", val=1}, {g="arr_ratio", stage="final", op="<=", val=1.15},
        }}, once=true, once_scope="blind", ops={{k="state", state="brand_equity", mode="add", amount=1}} },
    } },
  },

  ["f_craig-newmark"] = {
    ability_text = "At round end, gain 1 Salary relief plus 0.5 per round held. If no Cash was spent this round, gain 0.05 Margin, up to 0.20.",
    effect_brief = "Tenure lowers Salary; no-spend rounds bank Margin",
    dsl = { clauses = {
      { id="skeleton_crew", hook="end_of_round", ops={{k="grant", what="salary", amount=1, coef=0.5, per="rounds_held"}} },
      { id="no_upgrades", hook="end_of_round", gate={g="count", per="cash_spent_round", op="==", val=0},
        ops={{k="grant", what="margin", amount=0.05, max=0.20}} },
    } },
  },

  ["f_david-heinemeier-hansson"] = {
    ability_text = "After a Ship, each unplayed card banks 0.05 Margin, with this Founder's lifetime contribution capped at 0.20.",
    effect_brief = "+0.05 Margin/unplayed card, max +0.20",
    dsl = { hook="after", ops={{k="grant", what="margin", base=0, coef=0.05, per="unplayed_cards", cap=0.20, max=0.20}} },
  },

  ["f_elizabeth-holmes"] = {
    ability_text = "Each blind won permanently adds 0.15 to xRev.",
    effect_brief = "+0.15 xRev per blind won",
    dsl = { clauses = {
      { id="narrative", hook="joker_main", ops={{k="x_add", field="mult", base=0, coef=0.15, per="counter", state="blinds_won"}} },
      { id="story_grows", hook="blind_won", ops={{k="state", state="blinds_won", mode="add", amount=1, cap=26}} },
    } },
  },

  ["f_jack-ma"] = {
    ability_text = "From Stage 3, the first Ship each blind permanently adds 0.15 xRev. End a round with no Cash for +0.03 Margin. At Stage 8+, gain x2 Rev.",
    effect_brief = "Stage 3 compounding, bootstrap Margin, Stage 8 x2",
    dsl = { clauses = {
      { id="customers", hook="joker_main", ops={{k="x_add", field="mult", base=0, coef=0.15, per="counter", state="patient_ships"}} },
      { id="patient_growth", hook="post_resolution", gate={g="ante", op=">=", val=3}, once=true, once_scope="blind",
        ops={{k="state", state="patient_ships", mode="add", amount=1, cap=20}} },
      { id="bootstrap", hook="end_of_round", gate={g="count", per="cash", op="==", val=0},
        ops={{k="grant", what="margin", amount=0.03, max=0.12}} },
      { id="empire", hook="joker_main", gate={g="ante", op=">=", val=8}, ops={{k="scale", field="x_mult", base=2}} },
    } },
  },

  ["f_john-doerr"] = {
    ability_text = "Each Ship at or above 2x its target permanently adds 0.16 to xRev, once per blind.",
    effect_brief = "2x target Ships bank +0.16 xRev",
    dsl = { clauses = {
      { id="okr", hook="joker_main", ops={{k="x_add", field="mult", base=0, coef=0.16, per="counter", state="objectives"}} },
      { id="key_result", hook="post_resolution", gate={g="arr_ratio", stage="final", op=">=", val=2},
        once=true, once_scope="blind", ops={{k="state", state="objectives", mode="add", amount=1, cap=25}} },
    } },
  },

  ["f_john-lasseter"] = {
    ability_text = "After 2 or more Pivots this round, the next Ship gains x3 Rev. Once per blind.",
    effect_brief = "2+ Pivots: next Ship x3 Rev",
    dsl = { hook="joker_main", gate={g="count", per="pivots_round", op=">=", val=2},
      once=true, once_scope="blind", ops={{k="scale", field="x_mult", base=3}} },
  },

  ["f_ken-howery"] = {
    ability_text = "Before Cash Out, gain 15% Salary relief. The first 2x-target Ship each blind also converts 20% of its overkill ARR to Cash.",
    effect_brief = "15% Salary relief; 2x clears cash 20% of overkill",
    dsl = { clauses = {
      { id="runway", hook="pre_cash_out", ops={{k="grant", what="salary", pct=0.15}} },
      { id="surplus", hook="post_resolution", gate={g="arr_ratio", stage="final", op=">=", val=2},
        once=true, once_scope="blind", ops={{k="grant", what="cash", base=0, coef=0.20, per="overkill"}} },
    } },
  },

  ["f_kevin-systrom"] = {
    ability_text = "If you Pivoted this round, the next Ship gains +20 Users. Once per blind.",
    effect_brief = "Pivot first: next Ship +20 Users",
    dsl = { hook="joker_main", gate={g="count", per="pivots_round", op=">=", val=1},
      once=true, once_scope="blind", ops={{k="scale", field="chips", base=20}} },
  },

  ["f_lucy-guo"] = {
    ability_text = "Each blind won builds 1 Stake. At 3+ Stake, activate to cash out 15% of the last Ship's ARR and clear Stake.",
    effect_brief = "Build 3 Stake, then activate for 15% ARR Cash",
    dsl = { action={label="Cash Out", description="Convert a mature retained stake into Cash."}, clauses = {
      { id="hold", hook="blind_won", ops={{k="state", state="stake", mode="add", amount=1, cap=8}} },
      { id="cash_out", hook="activated", gate={g="state", state="stake", op=">=", val=3},
        ops={{k="grant", what="cash", base=0, coef=0.15, per="final_arr"}, {k="state", state="stake", mode="clear"}} },
    } },
  },

  ["f_marc-andreessen"] = {
    ability_text = "The first Ship each blind covering fewer than 5 Layers banks +1.5 Rev. A 5-Layer Ship gains x2 Rev.",
    effect_brief = "Focused Ships bank Rev; full stack gains x2 Rev",
    dsl = { clauses = {
      { id="conviction", hook="joker_main", ops={{k="scale", field="mult", base=0, coef=1, per="counter", state="conviction"}} },
      { id="contrarian", hook="post_resolution", gate={g="count", per="distinct_layers", op="<", val=5},
        once=true, once_scope="blind", ops={{k="state", state="conviction", mode="add", amount=1.5}} },
      { id="world_eaten", hook="joker_main", gate={g="count", per="distinct_layers", op=">=", val=5},
        ops={{k="scale", field="x_mult", base=2}} },
    } },
  },

  ["f_mark-pincus"] = {
    ability_text = "Gain +8 Users per distinct App Type shipped this run. The first 2x-target Ship each blind converts one third of overkill ARR to Cash.",
    effect_brief = "+8 Users/App Type; 2x clears cash one-third overkill",
    dsl = { clauses = {
      { id="signals", hook="joker_main", ops={{k="scale", field="chips", base=0, coef=8, per="distinct_app_types_shipped"}} },
      { id="monetize", hook="post_resolution", gate={g="arr_ratio", stage="final", op=">=", val=2},
        once=true, once_scope="blind", ops={{k="grant", what="cash", base=0, coef=0.3333333333, per="overkill"}} },
    } },
  },

  ["f_martin-eberhard"] = {
    ability_text = "Each completed Ship permanently adds 0.4 to xRev, up to +2.0. Losing a blind resets the conviction.",
    effect_brief = "+0.4 xRev/Ship to +2; resets on loss",
    dsl = { clauses = {
      { id="proof", hook="joker_main", ops={{k="x_add", field="mult", base=0, coef=0.4, per="counter", state="conviction"}} },
      { id="spreadsheet", hook="post_resolution", ops={{k="state", state="conviction", mode="add", amount=1, cap=5, reset_on={"blind_lost"}}} },
    } },
  },

  ["f_michael-truell"] = {
    ability_text = "Gain +1 Rev each round held. The first card sold each Ante arms +20 Users for the next Ship.",
    effect_brief = "+1 Rev/round; first sale each Ante arms +20 Users",
    dsl = { clauses = {
      { id="iterate", hook="joker_main", ops={{k="acc", field="mult", base=0, coef=1, state="iteration", step="round", when="post"}} },
      { id="replace", hook="selling_card", once=true, once_scope="ante", ops={{k="arm", field="chips", base=20}} },
    } },
  },

  ["f_mitch-kapor"] = {
    ability_text = "At 3 or more distinct Layers, gain xRev equal to Coverage minus 2.",
    effect_brief = "3+ Layers: x(Coverage - 2) Rev",
    dsl = { hook="joker_main", gate={g="count", per="distinct_layers", op=">=", val=3},
      ops={{k="scale", field="x_mult", base=-2, coef=1, per="distinct_layers"}} },
  },

  ["f_morris-chang"] = {
    ability_text = "Each Infra card played raises Node Floor by 1. At round end, gain 2 Cash per Node Floor.",
    effect_brief = "Infra plays build Node Floor; pays 2 Cash each",
    dsl = { clauses = {
      { id="node", hook="individual", gate={g="card_layer", layer="Infra"}, ops={{k="state", state="node_floor", mode="add", amount=1}} },
      { id="foundry", hook="end_of_round", ops={{k="grant", what="cash", base=0, coef=2, per="counter", state="node_floor"}} },
    } },
  },

  ["f_mustafa-suleyman"] = {
    ability_text = "The first Ship each blind finishing at 0.7x to below target pays 40% of its shortfall as Cash and arms +2 Rev for the next Ship.",
    effect_brief = "Near miss: 40% shortfall Cash, arm +2 Rev",
    dsl = { hook="post_resolution", gate={g="and", gs={
        {g="arr_ratio", stage="final", op=">=", val=0.7}, {g="arr_ratio", stage="final", op="<", val=1},
      }}, once=true, once_scope="blind", ops={
        {k="grant", what="cash", base=0, coef=0.4, per="target_shortfall"}, {k="arm", field="mult", base=2},
      } },
  },

  ["f_nando-de-freitas"] = {
    ability_text = "Gain a stacking +15 Users each round held, capped at +60.",
    effect_brief = "+15 Users/round, max +60",
    dsl = { hook="joker_main", ops={{k="acc", field="chips", base=0, coef=15, state="scale", step="round", when="post", max=4,
      reset_on={"selling_self"}}} },
  },

  ["f_nat-friedman"] = {
    ability_text = "Waive 5 Salary while hired. At round end, gain 2 Cash plus 1 per other ai-grant Founder.",
    effect_brief = "Waive Salary; ai-grant crew generates Cash",
    dsl = { passive={what="salary", amount=5}, hook="end_of_round",
      ops={{k="grant", what="cash", amount=1, coef=1, per="count_group", group="ai-grant"}} },
  },

  ["f_nick-frosst"] = {
    ability_text = "The first round you hold at least 3 ai-engineer-wave Founders, gain 12 Cash.",
    effect_brief = "3 AI-wave Founders: 12 Cash once per run",
    dsl = { hook="end_of_round", gate={g="has_group", group="ai-engineer-wave", val=3},
      once=true, once_scope="run", ops={{k="grant", what="cash", amount=12}} },
  },

  ["f_niki-parmar"] = {
    ability_text = "Gain a stacking +12 Users each round. Discarding or losing a blind resets the stack.",
    effect_brief = "+12 Users/round; discard or loss resets",
    dsl = { hook="joker_main", ops={{k="acc", field="chips", base=0, coef=12, state="momentum", step="round", when="post",
      reset_on={"discard", "blind_lost"}}} },
  },

  ["f_palmer-luckey"] = {
    ability_text = "The first 2x-target Ship each blind converts its overkill ARR to Cash. Once per blind, activate and spend 2 Cash to arm +2 Rev.",
    effect_brief = "2x overkill becomes Cash; spend 2 to arm +2 Rev",
    dsl = { action={label="Prebuild", description="Spend 2 Cash to arm the next Ship."}, clauses = {
      { id="finished_product", hook="post_resolution", gate={g="arr_ratio", stage="final", op=">=", val=2},
        once=true, once_scope="blind", ops={{k="grant", what="cash", base=0, coef=1, per="overkill"}} },
      { id="prebuild", hook="activated", gate={g="count", per="cash", op=">=", val=2}, once=true, once_scope="blind",
        ops={{k="spend", amount=2}, {k="arm", field="mult", base=2}} },
    } },
  },

  ["f_pony-ma"] = {
    ability_text = "Once per run, the first Ship projected between 1x and 1.5x target gains xRev equal to 1 plus 0.5 per Layer.",
    effect_brief = "Once/run restrained clear: x(1 + 0.5 per Layer) Rev",
    dsl = { hook="after", gate={g="and", gs={
        {g="arr_ratio", stage="pre_after", op=">=", val=1}, {g="arr_ratio", stage="pre_after", op="<", val=1.5},
      }}, once=true, once_scope="run", ops={{k="scale", field="x_mult", base=1, coef=0.5, per="distinct_layers"}} },
  },

  ["f_ray-ozzie"] = {
    ability_text = "Each card left unplayed buffers offline demand. Gain +8 Users per unplayed card on Ship.",
    effect_brief = "+8 Users per unplayed card",
    dsl = { hook="before", ops={{k="scale", field="chips", base=0, coef=8, per="unplayed_cards"}} },
  },

  ["f_robert-noyce"] = {
    ability_text = "Gain xRev equal to 1 + 0.25 per distinct Layer + 0.10 per round held.",
    effect_brief = "Add Layer breadth and tenure inside one xRev multiplier",
    dsl = { hook="joker_main", ops={
      {k="x_add", field="mult", base=0, coef=0.25, per="distinct_layers"},
      {k="x_add", field="mult", base=0, coef=0.10, per="rounds_held"},
    } },
  },

  ["f_rupert-murdoch"] = {
    ability_text = "The first below-target Ship each blind pays 50% of its shortfall as Cash. Each Cash-spending transaction permanently banks +1 Rev.",
    effect_brief = "Shortfall becomes Cash; spending transactions bank Rev",
    dsl = { clauses = {
      { id="flywheel", hook="joker_main", ops={{k="scale", field="mult", base=0, coef=1, per="counter", state="acquisitions"}} },
      { id="tabloid_cash", hook="post_resolution", gate={g="arr_ratio", stage="final", op="<", val=1},
        once=true, once_scope="blind", ops={{k="grant", what="cash", base=0, coef=0.5, per="target_shortfall"}} },
      { id="acquire", hook="cash_spent", ops={{k="state", state="acquisitions", mode="add", amount=1}} },
    } },
  },

  ["f_sandy-lerner"] = {
    ability_text = "The first below-target Ship each blind generates one Tech card per distinct Layer played.",
    effect_brief = "Below target: generate Tech equal to Layer coverage",
    dsl = { hook="post_resolution", gate={g="arr_ratio", stage="final", op="<", val=1}, once=true, once_scope="blind",
      ops={{k="gen", kind="tech_card", base=0, coef=1, per="distinct_layers"}} },
  },

  ["f_steve-case"] = {
    ability_text = "Once per Ante, spend all held Cash for +3 Users each. If that Ship reaches 2x target, refund 25% of the spend.",
    effect_brief = "Spend Cash for +3 Users each; 2x target refunds 25%",
    dsl = { clauses = {
      { id="blitz", hook="joker_main", gate={g="count", per="cash", op=">", val=0}, once=true, once_scope="ante", ops={
        {k="scale", field="chips", base=0, coef=3, per="cash"},
        {k="state", state="campaign_spend", mode="set", per="cash", coef=1},
        {k="spend", base=0, coef=1, per="cash"},
      } },
      { id="rebate", hook="post_resolution", gate={g="state", state="campaign_spend", op=">", val=0}, ops={
        {k="grant", what="cash", base=0, coef=0.25, per="counter", state="campaign_spend",
          gate={g="arr_ratio", stage="final", op=">=", val=2}},
        {k="state", state="campaign_spend", mode="clear"},
      } },
    } },
  },

  ["f_steve-jobs"] = {
    ability_text = "If projected ARR is below target, gain x1.6 Rev and floor ARR at the target. With 3 or fewer Founders, also gain x1.5 Rev.",
    effect_brief = "Misses get x1.6 and target floor; small team x1.5",
    dsl = { clauses = {
      { id="distortion", hook="after", gate={g="arr_ratio", stage="pre_after", op="<", val=1},
        ops={{k="scale", field="x_mult", base=1.6}, {k="score_floor", what="arr", per="blind_target", coef=1}} },
      { id="small_team", hook="joker_main", gate={g="count", per="others", op="<=", val=2},
        ops={{k="scale", field="x_mult", base=1.5}} },
    } },
  },

  ["f_sualeh-asif"] = {
    ability_text = "Each App Type keeps its own tab: +8 Rev the first time it Ships, then +8 more on every repeat. Losing a blind clears all tabs.",
    effect_brief = "Repeated App Types grow their own +8 Rev tab",
    dsl = { hook="joker_main", ops={{k="acc", field="mult", base=0, coef=8, state="tab", key="scoring_name", when="post",
      reset_on={"selling_self", "blind_lost"}}} },
  },

  ["f_thomas-wolf"] = {
    ability_text = "Gain +1 Users per distinct App Type shipped. Using a consumable this blind doubles that bonus until the next blind.",
    effect_brief = "+1 Users/App Type; publication doubles it",
    dsl = { clauses = {
      { id="community", hook="joker_main", ops={
        {k="scale", field="chips", base=0, coef=1, per="distinct_app_types_shipped"},
        {k="scale", field="chips", base=0, coef=1, per="distinct_app_types_shipped", gate={g="state", state="published", op=">=", val=1}},
      } },
      { id="publish", hook="use_consumable", ops={{k="state", state="published", mode="set", amount=1}} },
      { id="new_issue", hook="setting_blind", ops={{k="state", state="published", mode="clear"}} },
    } },
  },

  ["f_tim-oreilly"] = {
    ability_text = "Gain a permanent +1 Rev each round held. While hired, gain +1 Founder slot.",
    effect_brief = "+1 Rev/round and +1 Founder slot",
    dsl = { passive={what="founder_slots", amount=1}, hook="joker_main",
      ops={{k="acc", field="mult", base=0, coef=1, state="platform", step="round", when="post"}} },
  },
}
