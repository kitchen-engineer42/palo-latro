-- The four skip rewards in the first Lead wave. Definitions are authored player
-- text; live instances add their pre-rolled value (Cash or Founder edition).

return {
  warm_intro = {
    key = "warm_intro", order = 1, name = "Warm Intro", trigger = "next_shop",
    description = "The first Founder offer in the next shop costs $0. Rerolling leaves the intro behind.",
  },
  term_sheet = {
    key = "term_sheet", order = 2, name = "Term Sheet", trigger = "next_blind_clear",
    amount_units = 4,
    description = "Clear the next played blind to receive 4 funding units of Cash. Further skips do not consume it.",
  },
  demo_day = {
    key = "demo_day", order = 3, name = "Demo Day", trigger = "next_shop",
    pack_key = "hiring",
    description = "The next shop adds a free Hiring Round: choose 1 of 2 Founders.",
  },
  press_coverage = {
    key = "press_coverage", order = 4, name = "Press Coverage", trigger = "next_founder",
    description = "The next Founder you acquire gains the edition shown on this Lead.",
  },
}
