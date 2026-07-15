-- Player-facing Founder restorations unlocked by the completed event/state DSL.
-- These five historical mechanics now fit the shared runtime without a
-- Founder-specific operation or a change to the generated catalog.

return {
  ["f_douglas-lenat"] = {
    ability_text = "Each Ship permanently adds its distinct Layer count to Clash Capacity. Future Ships ignore up to that many clashes. Adds no score directly.",
    effect_brief = "Ships build permanent Clash Capacity from Layer breadth",
    dsl = { clauses={
      {id="apply_capacity", hook="before", ops={{k="clear_clash", base=0, coef=1,
        per="counter", state="clash_capacity"}}},
      {id="learn_capacity", hook="post_resolution", ops={{k="state", state="clash_capacity",
        mode="add", per="distinct_layers"}}},
    } },
  },

  ["f_jensen-huang"] = {
    ability_text = "Each Founder hired while Shovel Saint is on the team permanently adds 0.25 to this card's xRev.",
    effect_brief = "Founder hires permanently add 0.25 xRev",
    dsl = { clauses={
      {id="platform", hook="joker_main", ops={{k="x_add", field="mult", base=0,
        coef=1, per="counter", state="founder_hires"}}},
      {id="adoption", hook="founder_hired", ops={{k="state", state="founder_hires",
        mode="add", amount=0.25}}},
    } },
  },

  ["f_jerry-liu"] = {
    ability_text = "Gain +8 Users per round held. When a Ship contains at least 2 Data Techs, each played Data Tech retriggers once.",
    effect_brief = "+8 Users/round held; 2+ Data retrigger each Data Tech",
    dsl = { clauses={
      {id="data_moat", hook="joker_main", ops={{k="acc", field="chips", base=0,
        coef=8, state="rounds", step="round", when="post"}}},
      {id="data_retrigger", retrigger=1, gate={g="and", gs={
        {g="count", per="cards_of_layer", layer="Data", op=">=", val=2},
        {g="card_layer", layer="Data"},
      }}},
    } },
  },

  ["f_llion-jones"] = {
    ability_text = "Enters at x1.5 Rev. Each Founder sold while Transformer's Ex is on the team permanently adds 0.25 to this card's xRev.",
    effect_brief = "x1.5 Rev; Founder sales permanently add 0.25 xRev",
    dsl = { clauses={
      {id="paradigm", hook="joker_main", ops={{k="scale", field="x_mult", base=1.5,
        coef=1, per="counter", state="founder_sales"}}},
      {id="discard_paradigm", hook="selling_card", ops={{k="state", state="founder_sales",
        mode="add", amount=0.25}}},
    } },
  },

  ["f_nolan-bushnell"] = {
    ability_text = "The first Founder hired from the Shop each round arms the next Ship for xRev equal to 2 plus 0.5 per other Founder on the roster.",
    effect_brief = "First Shop hire each round arms roster-scaled xRev",
    dsl = { hook="founder_hired", gate={g="event", field="source", value="shop"},
      once=true, once_scope="blind", ops={{k="arm", field="x_mult", base=2,
        coef=0.5, per="others"}} },
  },
}
