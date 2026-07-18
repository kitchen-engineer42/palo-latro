-- Compact, always-visible rules pages for the in-game Wiki.  These are intentionally
-- short: the Wiki explains the shipped game, it does not duplicate the design archive.

return {
  {
    id = "mechanic:scoring", name = "Scoring and Ship", aliases = { "ARR", "score", "Users", "Revenue" },
    facets = { "Scoring" },
    rules = "Select 1–5 Tech cards and Ship. The App Type supplies base Users and Rev; Tech, Founder, Market, Fit, and modifier effects then change those lanes. Final ARR is Users × Rev.",
    story = "A startup needs both reach and monetization. A huge audience with no revenue—or rich revenue with no users—cannot carry the company alone.",
  },
  {
    id = "mechanic:layers", name = "Layers and Coverage", aliases = { "Frontend", "Backend", "Data", "Infra", "AI", "Knowledge" },
    facets = { "Architecture" },
    rules = "The five scoring Layers are Frontend, Backend, Data, Infra, and AI. Distinct Layers determine App Type breadth. Knowledge is an affinity overlay and never adds a sixth scoring slot.",
    story = "Breadth describes how much of a product the hand can actually deliver; depth describes how heavily it invests in one part of the stack.",
  },
  {
    id = "mechanic:app_types", name = "App Types", aliases = { "Playbooks", "hand types", "product type" },
    facets = { "Scoring" },
    rules = "Every shipped stack is classified from its Layer coverage, depth, and selected Tech roles. Its App Type sets the hand's base Users, Rev, and operating Margin. Playbooks permanently improve those bases.",
    story = "Your stack is your app: the product category emerges from the technologies shipped together rather than from a poker pattern.",
  },
  {
    id = "mechanic:ai_maturity", name = "AI Maturity", aliases = { "Prompt Engineering", "Context Engineering", "Workflows", "Agents", "Harnesses", "Meta Works" },
    facets = { "AI" },
    rules = "AI App Types take the highest maturity rung evidenced by their shipped Layers and roles: Prompt, Context, Workflows, Agents, Harnesses, then Meta Works. The active rung adds bounded Users and Rev.",
    story = "The ladder rewards what the product actually ships. A player can use a mature component directly without replaying every historical precursor.",
  },
  {
    id = "mechanic:market_fit", name = "Market Fit", aliases = { "PMF", "Market", "scenario fit" },
    facets = { "Market" },
    rules = "Each Market has one demand scenario and one run-long perk. The Tech cards in a Ship are rated against that scenario; their average rating becomes the visible Fit multiplier.",
    story = "A strong stack is contextual. The same technology can be excellent for one customer and awkward for another.",
  },
  {
    id = "mechanic:compatibility", name = "Compatibility and Tech Debt", aliases = { "clash", "substitute", "complement", "reliability" },
    facets = { "Architecture" },
    rules = "Complementary Tech improves chemistry. Clashing Tech can lose scoring value and create Tech Debt; substitutes add redundancy. Refactor and specific effects can repair these costs.",
    story = "The compatibility graph turns architecture knowledge into a useful edge without making prior technical knowledge a gate to play.",
  },
  {
    id = "mechanic:economy", name = "Economy and Runway", aliases = { "Cash", "Income", "Margin", "Burn", "interest", "funding" },
    facets = { "Economy" },
    rules = "Blind close pays fixed rewards and operating Income. Income depends on ARR and App Type Margin; Founder Salaries create Burn. Cash, interest, raises, and Runway determine whether the company survives.",
    story = "A growing company can bootstrap from Margin or spend ahead of revenue. Both paths trade immediate safety against future scale.",
  },
  {
    id = "mechanic:founders", name = "Founders and Salary", aliases = { "Founder slots", "hire", "fire", "forms" },
    facets = { "Founders" },
    rules = "Founders occupy limited roster slots, apply their exact rules while active, and charge Salary at blind close. Hiring, firing, forms, and signature lifecycles never alter discovery eligibility.",
    story = "Founders are persistent strategic commitments: their ability can reshape a build, but every extra voice also increases the company's burn.",
  },
  {
    id = "mechanic:roadmap", name = "Roadmap Cards", aliases = { "Tech Law", "Moonshot", "consumable", "targeting" },
    facets = { "Cards" },
    rules = "Tech Laws are controlled interventions; Moonshots are double-edged bets. Select any required Tech or Founder targets first, select the Roadmap card, then Use. Invalid targets consume nothing.",
    story = "Roadmap cards change the company between Ships: laws impose disciplined structure, while Moonshots accept a sharp cost for a larger possibility.",
  },
  {
    id = "mechanic:packs", name = "Packs and Negotiation", aliases = { "Hiring Round", "Skunkworks", "Tech Evaluation", "pack" },
    facets = { "Shop" },
    rules = "A purchased pack creates one stable opening session. Choose from its revealed options or explicitly skip when ready. Mega packs retain the same session across picks; Legendary hiring may open a negotiation.",
    story = "Packs concentrate a shop decision into a small draft. The opening ceremony presents the choice but never changes its already-materialized outcome.",
  },
}
