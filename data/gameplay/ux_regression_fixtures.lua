-- Deterministic public fixtures for interaction and product-layout regression tests.
--
-- The module deliberately contains no screenshots or test-runner coupling.  Consumers receive a
-- defensive copy so a failed test cannot contaminate the next scenario in the same LÖVE process.

local FIXTURES = {
  pointer = {
    display_scales = { 0.75, 1, 1.5 },
    cases = {
      { id = "mouse_click", input = "mouse", points = { { 100, 100 }, { 107, 100 } }, result = "click" },
      { id = "mouse_micro_drag", input = "mouse", points = { { 100, 100 }, { 109, 100 }, { 104, 100 } }, result = "click" },
      { id = "mouse_founder_drag", input = "mouse", draggable = true,
        points = { { 100, 100 }, { 110, 100 }, { 140, 100 } }, result = "drag" },
      { id = "mouse_card_noop", input = "mouse", draggable = false,
        points = { { 100, 100 }, { 113, 100 }, { 100, 100 } }, result = "noop" },
      { id = "touch_click", input = "touch", points = { { 200, 100 }, { 217, 100 } }, result = "click" },
      { id = "touch_micro_drag", input = "touch", points = { { 200, 100 }, { 223, 100 }, { 204, 100 } }, result = "click" },
      { id = "touch_founder_drag", input = "touch", draggable = true,
        points = { { 200, 100 }, { 218, 100 }, { 250, 100 } }, result = "drag" },
      { id = "touch_card_noop", input = "touch", draggable = false,
        points = { { 200, 100 }, { 225, 100 }, { 200, 100 } }, result = "noop" },
      { id = "overlap_boundary", input = "mouse", points = { { 130, 100 }, { 134, 100 } },
        captured_id = "card-right", result = "click" },
      { id = "resize_during_gesture", input = "mouse", display_scale = 1.5,
        resized_scale = 0.75, points = { { 100, 100 }, { 108, 100 } }, result = "click" },
      { id = "release_outside", input = "mouse", points = { { 100, 100 }, { 160, 160 } }, result = "cancel" },
      { id = "target_removed", input = "mouse", points = { { 100, 100 }, { 100, 100 } },
        mutation = "remove_target", result = "cancel" },
      { id = "modal_masked", input = "mouse", points = { { 100, 100 }, { 100, 100 } },
        mutation = "open_modal", result = "cancel" },
      { id = "stale_capture", input = "mouse", points = { { 100, 100 }, { 100, 100 } },
        mutation = "replace_target", result = "cancel" },
    },
  },

  overlap = {
    hand = {
      area = { x = 100, y = 500, w = 420, h = 150, type = "hand" },
      cards = {
        { id = "hand-01", index = 1, x = 100, y = 520, w = 90, h = 120 },
        { id = "hand-02", index = 2, x = 147, y = 520, w = 90, h = 120, hovered = true },
        { id = "hand-03", index = 3, x = 194, y = 494, w = 90, h = 120, selected = true },
        { id = "hand-04", index = 4, x = 241, y = 520, w = 90, h = 120 },
        { id = "hand-05", index = 5, x = 288, y = 520, w = 90, h = 120 },
        { id = "hand-06", index = 6, x = 335, y = 520, w = 90, h = 120 },
        { id = "hand-07", index = 7, x = 382, y = 520, w = 90, h = 120 },
        { id = "hand-08", index = 8, x = 430, y = 520, w = 90, h = 120 },
      },
    },
    founders = {
      area = { x = 620, y = 80, w = 320, h = 150, type = "jokers" },
      cards = {
        { id = "founder-01", index = 1, x = 630, y = 90, w = 90, h = 120 },
        { id = "founder-02", index = 2, x = 685, y = 90, w = 90, h = 120, hovered = true },
        { id = "founder-03", index = 3, x = 740, y = 64, w = 90, h = 120, selected = true },
        { id = "founder-04", index = 4, x = 795, y = 90, w = 90, h = 120 },
        { id = "founder-05", index = 5, x = 850, y = 90, w = 90, h = 120, dragged = true },
      },
    },
  },

  consumables = {
    { id = "one-tech", key = "tl_monetizable", selected_ids = { 101 } },
    { id = "three-tech", key = "ms_stack_rewrite", selected_ids = { 101, 102, 103 } },
    { id = "one-founder", key = "ms_spinout", selected_ids = { 201 } },
    { id = "layer-follow-up", key = "tl_conways_law", selected_ids = { 101 }, layer = "Knowledge" },
    { id = "instant", key = "tl_seed_round", selected_ids = {} },
    { id = "hand-effect", key = "tl_wirths_law", selected_ids = { 102 } },
    { id = "shop-effect", key = "tl_pareto_principle", selected_ids = { 104 } },
  },

  shop = {
    normal = { founders = 2, roadmaps = 2, vouchers = 1, packs = 2, cash = 24 },
    maximum = { founders = 4, roadmaps = 4, vouchers = 1, packs = 5, cash = 999 },
    pack_ids = { "pack-01", "pack-02", "pack-03", "pack-04", "pack-05" },
    reveal_ids = { "option-01", "option-02", "option-03", "option-04", "option-05", "option-06" },
  },

  founders = {
    tooltip = {
      id = "founder-tooltip-worst-case",
      name = "A Founder Name With Deliberately Wide Glyphs",
      face_tag = "xRev +1.25 · 3/5",
      rules_text = "The first qualifying Ship each blind gains x1.5 Rev.\n\nAt round end, bank +0.10 Margin, up to +0.30.",
    },
  },

  signature = {
    taxonomy = { era = "E4", product_identity = "Agent", maturity = "agent_harnesses", layer = "Knowledge" },
    scenarios = {
      { id = "ante-6-ineligible", ante = 6, kind = "hiring_mega", roll = 0, offered = false },
      { id = "ordinary-ineligible", ante = 7, kind = "hiring", roll = 0, offered = false },
      { id = "eligible-miss", ante = 7, kind = "hiring_mega", roll = 0.01, offered = false },
      { id = "eligible-hit", ante = 7, kind = "hiring_mega", roll = 0.009999, offered = true },
      { id = "one-off", ante = 8, kind = "hiring_mega", roll = 0, already_offered = true, offered = false },
    },
  },
}

local function clone(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do out[clone(key, seen)] = clone(item, seen) end
  return out
end

return {
  all = function() return clone(FIXTURES) end,
  get = function(name) return clone(FIXTURES[name]) end,
}
