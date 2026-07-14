-- Static, authored onboarding copy. The shipped game never calls a network service or model at runtime.

local M = {}

M.script = {
  id = "indie_saas_v1",
  version = 1,
  seed = 314159,
  market_id = "indie-saas",
  cofounder = {
    id = "patch",
    name = "Patch",
    role = "Your suspiciously employable cofounder",
  },
}

-- Lessons are ordered and dependency-linked. `trigger` makes a lesson available; `complete` records
-- that the player performed the taught action. Integration code reports named events through
-- Guidance.notify instead of reaching into tutorial state directly.
M.lessons = {
  {
    id = "welcome", trigger = "run_started", complete = "acknowledged",
    title = "Meet Patch",
    body = "I'm Patch, your cofounder. I brought a laptop, a runway spreadsheet, and no adult supervision.",
    prompt = "Let's build the first company together.",
  },
  {
    id = "market", after = "welcome", trigger = "market_choices_shown", complete = "market_selected",
    require = { market_id = "indie-saas" },
    title = "Pick a market",
    body = "Start with Indie SaaS. It rewards small, useful products and gives us an extra Ship each blind.",
    prompt = "Choose Indie SaaS.",
  },
  {
    id = "selection", after = "market", trigger = "blind_started", complete = "cards_selected",
    title = "Choose the stack",
    body = "Each Tech card covers a Layer. Select a compact stack that can become a recognizable App Type.",
    prompt = "Select one to five Tech cards.",
  },
  {
    id = "ship", after = "selection", trigger = "cards_selected", complete = "ship_committed",
    title = "Ship it",
    body = "Users times Revenue becomes ARR. The preview is a forecast, not a blood oath, but it is less wrong than we are.",
    prompt = "Press Ship to score the selected stack.",
  },
  {
    id = "pivot", after = "ship", trigger = "ship_scored", complete = "pivot_committed",
    title = "Pivot with intent",
    body = "A Pivot discards the selected cards and draws replacements. Spend one when the stack cannot become the product you need.",
    prompt = "Select an awkward card, then press Pivot.",
  },
  {
    id = "compatibility", after = "pivot", trigger = "compatibility_changed", complete = "compatibility_inspected",
    title = "Read the architecture",
    body = "Substitutes and clashes create Tech Debt. Compatible cards earn Chemistry. The labels explain the cause before you commit.",
    prompt = "Inspect the compatibility and Tech Debt details.",
  },
  {
    id = "shop", after = "compatibility", trigger = "shop_entered", complete = "founder_bought",
    title = "Hire carefully",
    body = "Founders bend the rules, but salary leaves the bank after every blind. Talent is temporary; payroll is recurring.",
    prompt = "Buy one Founder whose effect fits the current build.",
  },
  {
    id = "pack", after = "shop", trigger = "pack_available", complete = "pack_picked",
    title = "Open a pack",
    body = "Packs trade Cash for a choice. Read the offer count and picks left before the wrapper becomes expensive confetti.",
    prompt = "Open a pack and choose one option.",
  },
  {
    id = "salary", after = "pack", trigger = "founder_bought", complete = "blind_settled",
    title = "Watch runway",
    body = "Income settles from the blind, then salary comes due. Cash below the credit line ends the company even if the demo was lovely.",
    prompt = "Review projected payroll and runway before continuing.",
  },
  {
    id = "boss", after = "salary", trigger = "boss_previewed", complete = "boss_entered",
    title = "Read the boss rule",
    body = "Bosses change a rule, not just the target. The preview is advance notice to alter the stack, shop plan, or financing.",
    prompt = "Prepare for the shown rule, then enter the Boss blind.",
  },
}

-- Contextual hints remain eligible after the scripted lessons and stop after the profile records its
-- first win. Each hint is shown at most once per profile.
M.hints = {
  {
    id = "no_selection", event = "ship_rejected_no_selection",
    title = "Nothing ships itself",
    body = "Select at least one Tech card first. A blank roadmap is still blank after a launch party.",
  },
  {
    id = "high_debt", event = "high_tech_debt",
    title = "Debt compounds",
    body = "This stack has visible Tech Debt. Pivot toward compatible cards or accept the drag deliberately.",
  },
  {
    id = "low_cash", event = "low_cash",
    title = "Runway check",
    body = "Cash is close to the credit line. Compare the next payroll with the purchase before spending.",
  },
  {
    id = "full_roster", event = "founder_slots_full",
    title = "No empty chair",
    body = "The Founder row is full. Fire, promote, or skip the hire; buying harder does not create furniture.",
  },
  {
    id = "boss_response", event = "boss_previewed",
    title = "Plan around the rule",
    body = "The next Boss is already known. Use this shop to find at least one different response, not merely a larger number.",
  },
}

M.chatter = {
  ship_failed = {
    "The market has declined our generous offer to exist.",
    "Good news: the postmortem already has a title.",
  },
  pivot_committed = {
    "A pivot is strategy wearing running shoes.",
    "We have preserved the vision by changing all of it.",
  },
  founder_bought = {
    "Excellent. Another person who can ask what our burn multiple is.",
    "Welcome aboard. Payroll has noticed.",
  },
  pack_opened = {
    "Nothing says disciplined capital allocation like mystery packaging.",
    "We bought optionality. It came in foil.",
  },
  boss_won = {
    "Regulation survived contact with our roadmap. Barely.",
    "We call that resilience because 'lucky' spooks investors.",
  },
  run_lost = {
    "The company is now a very focused case study.",
    "We ran out of runway, which is rude because we were still accelerating.",
  },
  run_won = {
    "IPO achieved. Please act as though this was the plan.",
  },
}

return M
