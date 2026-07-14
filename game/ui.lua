-- game/ui.lua — immediate-mode HUD / buttons / overlay (the declarative UIBox system is a later
-- module). All strings come from G.TEXT; all buttons fire G.FUNCS[name]() — so the later rewrite
-- swaps rendering without touching handlers/text. Render and input (button_at) are separate.

local UI = {}
UI.rects = {}

local lg = love.graphics
local Juice = require("game.juice")
local Shop = require("game.shop")
local PackPresentation = require("game.pack_presentation")
local RunState = require("game.runstate")
local Coverage = require("game.coverage")

local SHOP_RARITY_COL = {
  Legendary = { 0.80, 0.45, 0.42, 1 }, Rare = { 0.62, 0.50, 0.78, 1 },
  Uncommon = { 0.45, 0.62, 0.78, 1 }, Common = { 0.50, 0.66, 0.52, 1 },
}

local function panel(x, y, w, h, col)
  pixel_rect(x, y, w, h, col or G.C.panel, { chamfer = 5, border = G.C.border, line_w = 2 })
end

-- crisp pixel-art label with a drop shadow (P3): delegates to the scale-compensated global draw_text so
-- text stays sharp at any window size. w/align optional → printf when given.
function UI.text(font, str, x, y, col, w, align)
  draw_text(font, str, x, y, col, w, align)
end

-- draw colored segments centered on a row (chips × mult = arr), each crisp + shadowed
local function centered_segments(segs, cy, font)
  local total = 0
  for _, s in ipairs(segs) do total = total + text_w(font, s.text) end
  local x = (G.WINDOW.w - total) / 2
  for _, s in ipairs(segs) do
    draw_text(font, s.text, x, cy, s.color)
    x = x + text_w(font, s.text)
  end
end

local function draw_button(r, label, enabled, hovered)
  local pressed = enabled and hovered and love.mouse.isDown(1)
  local col = enabled and (hovered and G.C.btn_hi or G.C.btn) or G.C.btn_off
  local ox, oy = 0, 0
  if pressed then ox, oy = 2, 2 end                          -- sink into the page on press
  pixel_rect(r.x + ox, r.y + oy, r.w, r.h, col,
    { chamfer = 4, border = G.C.border, line_w = 2, shadow = not pressed, soy = 4 })
  UI.text(G.FONTS.normal, label, r.x + ox, r.y + oy + r.h / 2 - 13,
    enabled and G.C.text or G.C.text_dim, r.w, "center")
end

local function ease_out_cubic(t)
  t = clamp(t, 0, 1)
  return 1 - (1 - t) ^ 3
end

-- Immediate-mode pack choices are not live Card objects, so they need a small shared back renderer.
local function draw_pack_card_back(t)
  if G.CARD_BACK then
    pixel_rect(t.x, t.y, t.w, t.h, { 0.06, 0.08, 0.12, 1 }, { chamfer = 6 })
    clip_chamfer(t.x, t.y, t.w, t.h, 6, function()
      local iw, ih = G.CARD_BACK:getDimensions()
      local s = math.max(t.w / iw, t.h / ih)
      lg.setColor(1, 1, 1, 1)
      lg.draw(G.CARD_BACK, t.x + (t.w - iw * s) / 2, t.y + (t.h - ih * s) / 2, 0, s, s)
    end)
    pixel_rect(t.x, t.y, t.w, t.h, nil, { chamfer = 6, border = G.C.border, line_w = 2 })
  else
    pixel_rect(t.x, t.y, t.w, t.h, G.C.btn, { chamfer = 6, border = G.C.arr, line_w = 2 })
    lg.setColor(G.C.btn_hi); lg.setLineWidth(2)
    lg.rectangle("line", t.x + 10, t.y + 10, t.w - 20, t.h - 20, 4, 4); lg.setLineWidth(1)
    UI.text(G.FONTS.normal, "PL", t.x, t.y + t.h / 2 - 16, G.C.arr, t.w, "center")
  end
end

local function draw_pack_cover(W, H, frame, title, pack_open)
  local p = ease_out_cubic(frame.cover_progress or 0)
  local scale = 0.68 + p * 0.32
  local w, h = 260 * scale, 350 * scale
  local play_x = 332
  local cx, cy = play_x + (W - play_x) / 2, H / 2 - 28
  local x, y = cx - w / 2, cy - h / 2
  local tear = frame.tear_progress or 0
  -- Balatro's booster does not gain a second card frame when opened: the pack artwork itself
  -- juices, wobbles, then dissolves into a light particle release. Preserve our art's own jagged
  -- wrapper silhouette and never put a grey panel, yellow outline, or drop shadow behind it.
  local release = frame.tearing and clamp((tear - 0.62) / 0.38, 0, 1) or 0
  local alpha = 1 - release
  local burst_scale = 1 + (frame.tearing and 0.08 * tear or 0)

  lg.push()
  lg.translate(cx, cy)
  if frame.tearing then lg.rotate(math.sin(tear * math.pi) * 0.025) end
  lg.scale(burst_scale, burst_scale)
  lg.translate(-cx, -cy)
  local cvr = G.PACK_ART and (G.PACK_ART[pack_open and pack_open.art_key] or G.PACK_ART.hiring_round)
  if cvr then
    local iw, ih = cvr:getDimensions()
    local s = math.min(w / iw, h / ih)
    lg.setColor(1, 1, 1, alpha)
    lg.draw(cvr, cx - iw * s / 2, cy - ih * s / 2, 0, s, s)
  else
    pixel_rect(x, y, w, h, { 0.11, 0.13, 0.18, alpha }, { chamfer = 8 })
    UI.text(G.FONTS.big, title, x + 12, cy - 48, { G.C.arr[1], G.C.arr[2], G.C.arr[3], alpha }, w - 24, "center")
    UI.text(G.FONTS.small, "OPEN TO REVEAL", x + 12, cy + 40, { 1, 1, 1, alpha }, w - 24, "center")
  end
  lg.pop()

  if frame.tearing then
    -- Deterministic wrapper-colour fragments replace the literal drawn tear seam. The expanding
    -- release follows Balatro's booster explode/materialize rhythm without copying its code/assets.
    local spread = 20 + tear * 150
    local fleck_alpha = math.sin(math.pi * tear) * 0.9
    local fleck_cols = { { 0.92, 0.56, 0.20 }, { 0.20, 0.43, 0.42 }, { 0.88, 0.76, 0.48 } }
    for i = 1, 12 do
      local ang = i * 2.399963 + 0.35
      local radius = spread * (0.56 + (i % 4) * 0.11)
      local fx, fy = cx + math.cos(ang) * radius, cy + math.sin(ang) * radius * 0.72
      local fc = fleck_cols[(i - 1) % #fleck_cols + 1]
      lg.setColor(fc[1], fc[2], fc[3], fleck_alpha)
      lg.push(); lg.translate(fx, fy); lg.rotate(ang + tear * 2.4)
      lg.rectangle("fill", -5, -2, 10, 4); lg.pop()
    end
  end
end

-- the shared LEFT COUNTER PANEL (Balatro layout) — used by both the play screen and the shop. `shop_mode`
-- swaps the blind header for a SHOP badge. Everything else (target/score/chips×mult/ships/cash/ante·round/
-- run-info·options/extras) is identical, mirroring how Balatro keeps the same left rail in the shop.
function UI.left_panel(GAME, shop_mode)
  local mx, my = vmouse()
  local bl = GAME.blind or { target = 1, kind = "?", stage = "?" }
  local px, py, pw, ph = 12, 14, 320, G.WINDOW.h - 28
  panel(px, py, pw, ph)
  local ix, iw = px + 16, pw - 32
  local half = (iw - 12) / 2
  local rx = ix + half + 12
  local function box(x, y, w, h, col) pixel_rect(x, y, w, h, col or G.C.panel_dim, { chamfer = 4, border = G.C.border }) end
  local function statbox(x, y, w, lab, val, vcol)
    box(x, y, w, 58); UI.text(G.FONTS.tiny, lab, x, y + 7, G.C.text_dim, w, "center")
    UI.text(G.FONTS.normal, val, x, y + 25, vcol or G.C.text, w, "center")
  end
  local function segs_in(x0, w, y, font, segs)
    local total = 0; for _, sg in ipairs(segs) do total = total + text_w(font, sg[1]) end
    local cxx = x0 + (w - total) / 2
    for _, sg in ipairs(segs) do draw_text(font, sg[1], cxx, y, sg[2]); cxx = cxx + text_w(font, sg[1]) end
  end

  -- header: SHOP badge (shop) or blind / boss
  if shop_mode then
    pixel_rect(ix, py + 12, iw, 48, G.C.arr, { chamfer = 4, border = G.C.border })
    UI.text(G.FONTS.normal, "SHOP", ix, py + 19, { 0, 0, 0, 1 }, iw, "center")
    UI.text(G.FONTS.tiny, "improve your run", ix, py + 66, G.C.text_dim, iw, "center")
  else
    local kindcol = bl.is_boss and G.C.lose or (bl.kind == "Big" and G.C.mult or G.C.arr)
    pixel_rect(ix, py + 12, iw, 48, kindcol, { chamfer = 4, border = G.C.border })
    UI.text(G.FONTS.normal, (bl.kind or "?") .. " Blind", ix, py + 19, { 0, 0, 0, 1 }, iw, "center")
    UI.text(G.FONTS.tiny, (bl.stage or "?") .. "  \194\183  Ante " .. (GAME.ante or 1) .. "/8", ix, py + 66, G.C.text_dim, iw, "center")
    -- market + boss telegraph live in the TOP-LEFT header (Balatro-style), not buried at the rail bottom
    UI.text(G.FONTS.tiny, (GAME.market and GAME.market.name or ""), ix, py + 82, G.C.arr, iw, "center")
    if bl.is_boss and bl.event then UI.text(G.FONTS.tiny, "! " .. bl.event, ix, py + 96, G.C.lose, iw, "center") end
  end

  -- ARR target + progress + raised
  box(ix, py + 110, iw, 110)
  UI.text(G.FONTS.tiny, shop_mode and "Next blind" or "Reach", ix, py + 116, G.C.text_dim, iw, "center")
  UI.text(G.FONTS.big, "$" .. format_number(bl.target), ix, py + 134, G.C.arr, iw, "center")
  local frac = clamp((GAME.cumulative_arr or 0) / math.max(bl.target, 1), 0, 1)
  lg.setColor(G.C.bg); lg.rectangle("fill", ix + 12, py + 182, iw - 24, 10, 3, 3)
  lg.setColor(G.C.arr); lg.rectangle("fill", ix + 12, py + 182, (iw - 24) * frac, 10, 3, 3)
  UI.text(G.FONTS.small, "$" .. format_number(GAME.cumulative_arr or 0) .. " raised", ix, py + 196, G.C.text, iw, "center")

  -- chips × mult = ARR readout
  local s = GAME.score or { chips = 0, mult = 0, arr = 0 }
  local ps = Juice.field_scale("score")
  pixel_rect(ix, py + 232, iw, 96, { 0.09, 0.11, 0.15, 1 }, { chamfer = 4, border = G.C.border })
  local midx, cyr = px + pw / 2, py + 274
  lg.push(); lg.translate(midx, cyr); lg.scale(ps, ps); lg.translate(-midx, -cyr)
  segs_in(ix, iw, py + 248, G.FONTS.big, {
    { format_number(s.chips), G.C.users }, { "  \195\151  ", G.C.text_dim }, { format_number(round_to(s.mult, 2)), G.C.mult } })
  UI.text(G.FONTS.normal, "= $" .. format_number(s.arr), ix, py + 292, G.C.arr, iw, "center")
  lg.pop()
  UI.text(G.FONTS.tiny, "Users  \195\151  Rev/user", ix, py + 332, G.C.text_dim, iw, "center")

  -- Ships / Pivots / Cash / Ante / Round + Run Info / Options
  statbox(ix, py + 356, half, "Ships", tostring(GAME.ships_left or 0), G.C.users)
  statbox(rx, py + 356, half, "Pivots", tostring(GAME.pivots_left or 0), G.C.mult)
  if GAME.cash ~= UI._last_cash then if UI._last_cash ~= nil then Juice.pulse("cash") end; UI._last_cash = GAME.cash end
  -- Cash + canonical payroll due for this blind. `RunState.payroll_due` includes Distill, Rental,
  -- passive relief, boss modifiers, and the current target; raw salary sums must not be labelled payroll.
  statbox(ix, py + 422, half, "Cash", "$" .. format_number(GAME.cash or 0), (GAME.cash or 0) < 0 and G.C.lose or G.C.arr)
  do
    local due = RunState.payroll_due()
    statbox(rx, py + 422, half, "Payroll due", "-$" .. format_number(due),
      ((GAME.cash or 0) < due) and G.C.lose or G.C.mult)
  end
  statbox(ix, py + 488, half, "Ante", (GAME.ante or 1) .. "/8", G.C.text)
  statbox(rx, py + 488, half, "Round", tostring((GAME.round_num or 0) + 1), G.C.text)
  UI.rects.run_info = { x = ix, y = py + 554, w = half, h = 50 }
  draw_button(UI.rects.run_info, "Run Info", true, point_in_rect(mx, my, ix, py + 554, half, 50))
  UI.rects.options = { x = rx, y = py + 554, w = half, h = 50 }
  draw_button(UI.rects.options, "Options", true, point_in_rect(mx, my, rx, py + 554, half, 50))
  UI.text(G.FONTS.tiny, ("Runway %s \194\183 Rung %d \194\183 Eq %d%% \194\183 Debt %d"):format(
    (GAME.runway or 99) >= 99 and "long" or tostring(GAME.runway), GAME.maturity_rung or 1, GAME.equity_pct or 100,
    math.floor(require("game.meters").get("tech_debt") or 0)), ix, py + 634, G.C.text_dim, iw, "center")
end

function UI.render()
  local W, H = G.WINDOW.w, G.WINDOW.h
  UI.rects = {}                                         -- rebuild button rects per frame/state
  if G.STATE == G.STATES.MENU then UI.render_menu(W, H); return end
  local GAME = G.GAME
  if not GAME then return end
  if G.STATE == G.STATES.MARKET_SELECT then UI.render_market_select(W, H, GAME); return end
  if G.STATE == G.STATES.TECH_DRAFT then UI.render_tech_draft(W, H, GAME); return end
  if G.STATE == G.STATES.BLIND_SELECT then UI.render_blind_select(W, H, GAME); return end
  if G.STATE == G.STATES.SHOP then UI.render_shop(W, H, GAME); return end

  local mx, my = vmouse()
  local bl = GAME.blind or { target = 1, kind = "?", stage = "?" }
  local selecting = (G.STATE == G.STATES.SELECTING_HAND)
  local n_sel = #G.hand:highlighted()

  UI.left_panel(GAME)                                   -- the shared Balatro-style counter column

  -- ===== RIGHT PLAY ZONE: labels, counts, controls =====
  UI.text(G.FONTS.tiny, "FOUNDERS  " .. #G.jokers.cards .. "/5", G.jokers.T.x, G.jokers.T.y - 24, G.C.text_dim)
  -- consumables slot (reserved: Tech Laws / Playbooks / Moonshots — P4)
  -- Track C B1: the consumable (Tech Law) inventory — real cards live in G.consumables (drawn by draw_all);
  -- the framed placeholder shows only while empty, the count always.
  local csw, csx = 220, W - 220 - 24
  local ncons = (G.consumables and #G.consumables.cards) or 0
  if ncons == 0 then
    pixel_rect(csx, 24, csw, Card.H, { 0.12, 0.13, 0.16, 1 }, { chamfer = 6, border = G.C.border })
    UI.text(G.FONTS.tiny, "Tech Laws", csx, 24 + Card.H / 2 - 10, G.C.text_dim, csw, "center")
  end
  UI.text(G.FONTS.tiny, "Tech Laws  " .. ncons .. "/" .. (GAME.consumable_slots or 2), csx, 24 + Card.H + 6, G.C.text_dim, csw, "center")
  -- selected consumable → Use / Sell buttons beneath it (B2/B5)
  local selC
  if G.consumables then for _, c in ipairs(G.consumables.cards) do if c.selected then selC = c; break end end end
  if selC and selecting then
    local bw2, bh2 = 92, 28
    local bx = selC.VT.x + (selC.VT.w - bw2 * 2 - 8) / 2
    local by2 = selC.VT.y + selC.VT.h + 4
    UI.rects.use_consumable = { x = bx, y = by2, w = bw2, h = bh2 }
    draw_button(UI.rects.use_consumable, "Use", true, point_in_rect(mx, my, bx, by2, bw2, bh2))
    UI.rects.sell_consumable = { x = bx + bw2 + 8, y = by2, w = bw2, h = bh2 }
    draw_button(UI.rects.sell_consumable, "Sell $" .. Shop.consumable_sell_value(selC.center),
      true, point_in_rect(mx, my, bx + bw2 + 8, by2, bw2, bh2))
  end
  -- B4: targeting banner + Conway's layer picker overlay
  if G.STATE == G.STATES.TARGET_SELECT and G.PENDING_CONSUMABLE then
    local pc = G.PENDING_CONSUMABLE
    lg.setColor(0, 0, 0, 0.35); lg.rectangle("fill", 0, 260, W, 44)
    UI.text(G.FONTS.small, pc.need_layer and "Pick the new Layer:" or
      ("Select a target card for " .. (pc.center.name or "?") .. "  (right-click to cancel)"), 0, 270, G.C.arr, W, "center")
    if pc.need_layer then
      local Ls = { "Frontend", "Backend", "Data", "Infra", "AI" }
      local lw, lh, lgap = 150, 40, 12
      local lx0 = (W - (#Ls * lw + (#Ls - 1) * lgap)) / 2
      for i, L in ipairs(Ls) do
        local lx = lx0 + (i - 1) * (lw + lgap)
        UI.rects["pick_layer_" .. L] = { x = lx, y = 320, w = lw, h = lh }
        draw_button(UI.rects["pick_layer_" .. L], L, true, point_in_rect(mx, my, lx, 320, lw, lh))
      end
    end
  end
  -- product / app-type
  UI.text(G.FONTS.tiny, "PRODUCT  (shipped)", G.play.T.x, G.play.T.y - 24, G.C.text_dim)
  if GAME.scoring_name then UI.text(G.FONTS.normal, GAME.scoring_name, G.play.T.x, G.play.T.y - 4, G.C.text, G.play.T.w, "center") end
  if selecting and n_sel > 0 then
    local selected = G.hand:highlighted()
    local preview = require("game.preview").evaluate(selected)
    local app, cov, stack, rel, fit = preview.app, preview.coverage, preview.best_stack, preview.reliability, preview.fit
    local stack_text = stack and ((stack.complete and stack.name) or (stack.name .. " " .. stack.matched .. "/" .. stack.total)) or "none"
    UI.text(G.FONTS.tiny, ("Preview: %s · Coverage %d/5 · Stack %s · Fit ×%.2f · Reliability %d/10"):format(
      app.name, cov.distinct, stack_text, fit, rel.score) .. " · Base ARR " .. format_number(preview.arr),
      G.play.T.x, G.play.T.y + G.play.T.h + 10,
      rel.score < 7 and G.C.lose or G.C.text_dim, G.play.T.w, "center")
  end
  -- hand
  UI.text(G.FONTS.tiny, "YOUR TECH  \194\183  " .. n_sel .. "/" .. (GAME.select_max or 5) .. " selected",
    G.hand.T.x + 8, G.hand.T.y - 24, G.C.text_dim)
  UI.text(G.FONTS.tiny, #G.deck.cards .. " in deck", G.deck.T.x - 10, G.deck.T.y - 24, G.C.text_dim, Card.W + 20, "center")
  -- Balatro layout: Ship · Sort(Users/Layer) · Pivot centered in the BOTTOM-MID row under the hand
  local Hb = G.WINDOW.h
  local shipw, sortw, bh3, gap3 = 170, 80, 40, 10
  local rowx = G.hand.T.x + (G.hand.T.w - (shipw * 2 + sortw * 2 + gap3 * 3)) / 2
  local rowy = Hb - 48
  local ship_on  = selecting and n_sel >= 1 and n_sel <= GAME.select_max and GAME.ships_left > 0
  local pivot_on = selecting and n_sel >= 1 and GAME.pivots_left > 0
  UI.rects.ship = { x = rowx, y = rowy, w = shipw, h = bh3 }
  draw_button(UI.rects.ship, G.TEXT.ship, ship_on, point_in_rect(mx, my, rowx, rowy, shipw, bh3))
  UI.rects.sort_users = { x = rowx + shipw + gap3, y = rowy, w = sortw, h = bh3 }
  draw_button(UI.rects.sort_users, "Users", true, point_in_rect(mx, my, UI.rects.sort_users.x, rowy, sortw, bh3))
  UI.rects.sort_layer = { x = rowx + shipw + sortw + gap3 * 2, y = rowy, w = sortw, h = bh3 }
  draw_button(UI.rects.sort_layer, "Layer", true, point_in_rect(mx, my, UI.rects.sort_layer.x, rowy, sortw, bh3))
  UI.text(G.FONTS.tiny, "sort hand", rowx + shipw + gap3, rowy - 17, G.C.text_dim, sortw * 2 + gap3, "center")
  UI.rects.pivot = { x = rowx + shipw + sortw * 2 + gap3 * 3, y = rowy, w = shipw, h = bh3 }
  draw_button(UI.rects.pivot, G.TEXT.pivot, pivot_on, point_in_rect(mx, my, UI.rects.pivot.x, rowy, shipw, bh3))

  -- selected founder -> a Fire button below it (Balatro-style two-step sell)
  UI.rects.fire = nil
  local fsel
  for _, c in ipairs(G.jokers.cards) do if c.selected then fsel = c; break end end
  if fsel then
    local bw, bh = 90, 30
    local bx, by = fsel.VT.x + (fsel.VT.w - bw) / 2, G.jokers.T.y + G.jokers.T.h + 4
    UI.rects.fire = { x = bx, y = by, w = bw, h = bh }
    pixel_rect(bx, by, bw, bh, point_in_rect(mx, my, bx, by, bw, bh) and G.C.lose or { 0.70, 0.26, 0.26, 1 }, { chamfer = 3, border = G.C.border })
    UI.text(G.FONTS.small, "Fire", bx, by + 3, G.C.text, bw, "center")
  end

  -- game over overlay
  if G.STATE == G.STATES.GAME_OVER then
    lg.setColor(0, 0, 0, 0.72); lg.rectangle("fill", 0, 0, W, H)
    local won = GAME.won
    UI.text(G.FONTS.huge, won and G.TEXT.win_title or G.TEXT.lose_title, 0, H / 2 - 110, won and G.C.win or G.C.lose, W, "center")
    lg.setFont(G.FONTS.normal); lg.setColor(G.C.text)
    lg.printf(won and G.TEXT.win_sub or G.TEXT.lose_sub, 0, H / 2 - 24, W, "center")
    local bl = GAME.blind or { target = 0, stage = "?" }
    local summary = won and ("Reached IPO — retained value $" .. format_number(GAME.ipo_value or 0) ..
      " (" .. tostring(GAME.equity_pct or 0) .. "% equity)")
      or ("Ante " .. (GAME.ante or 1) .. " (" .. (bl.stage or "?") .. ")   ·   $" ..
          format_number(GAME.cumulative_arr) .. " / $" .. format_number(bl.target) .. " ARR")
    lg.printf(summary, 0, H / 2 + 16, W, "center")
    lg.setFont(G.FONTS.small); lg.setColor(G.C.text_dim)
    lg.printf(G.TEXT.restart, 0, H / 2 + 70, W, "center")
  end
end

function UI.render_market_select(W, H, GAME)
  local mx, my = vmouse()
  UI.text(G.FONTS.big, "CHOOSE YOUR MARKET", 0, 54, G.C.arr, W, "center")
  UI.text(G.FONTS.small, "Your Market defines the starting stack, operating perk, Fit, and future drafts.",
    0, 108, G.C.text_dim, W, "center")
  local choices = GAME.market_choices or {}
  local cw, ch, gap, y = 340, 390, 34, 176
  local x0 = (W - (#choices * cw + math.max(0, #choices - 1) * gap)) / 2
  for i, market in ipairs(choices) do
    local x = x0 + (i - 1) * (cw + gap)
    local rules = require("data.gameplay.market_rules").for_market(market)
    pixel_rect(x, y, cw, ch, { 0.12, 0.14, 0.18, 1 }, { chamfer = 8, border = G.C.border, line_w = 2 })
    UI.text(G.FONTS.normal, market.name, x + 12, y + 24, G.C.arr, cw - 24, "center")
    UI.text(G.FONTS.tiny, (market.audience or "") .. "  ·  " .. (market.industry or ""),
      x + 12, y + 72, G.C.text_dim, cw - 24, "center")
    UI.text(G.FONTS.small, (market.perk and market.perk.name) or "Market Perk",
      x + 18, y + 122, G.C.win, cw - 36, "center")
    lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
    lg.printf((market.perk and market.perk.effect) or "Structured market perk", x + 28, y + 158, cw - 56, "center")
    lg.setColor(G.C.text_dim)
    lg.printf("40-card E" .. tostring(rules.start_era or 1) .. " deck\nFit: " .. tostring(rules.scenario_id),
      x + 28, y + 232, cw - 56, "center")
    local b = { x = x + 55, y = y + ch - 72, w = cw - 110, h = 48 }
    UI.rects["market_pick_" .. i] = b
    draw_button(b, "Build here ›", true, point_in_rect(mx, my, b.x, b.y, b.w, b.h))
  end
end

function UI.render_tech_draft(W, H, GAME)
  local mx, my = vmouse()
  UI.text(G.FONTS.big, "ERA TECH DRAFT", 0, 54, G.C.arr, W, "center")
  UI.text(G.FONTS.small, "Choose one technology to add permanently to your company stack.",
    0, 106, G.C.text_dim, W, "center")
  local choices = (GAME.tech_draft and GAME.tech_draft.choices) or {}
  local Centers = require("game.centers")
  local cw, ch, gap, y = (#choices > 3 and 260 or 320), 350, 32, 184
  local x0 = (W - (#choices * cw + math.max(0, #choices - 1) * gap)) / 2
  for i, key in ipairs(choices) do
    local center, x = Centers.get(key), x0 + (i - 1) * (cw + gap)
    pixel_rect(x, y, cw, ch, { 0.12, 0.14, 0.18, 1 }, { chamfer = 8, border = G.C.border, line_w = 2 })
    UI.text(G.FONTS.normal, center and center.name or key, x + 16, y + 28, G.C.arr, cw - 32, "center")
    UI.text(G.FONTS.small, (center and center.layer or "Tech") .. "  ·  " .. (center and center.sub_role or ""),
      x + 16, y + 92, G.C.text_dim, cw - 32, "center")
    lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
    lg.printf((center and center.desc) or "", x + 28, y + 144, cw - 56, "center")
    local b = { x = x + 55, y = y + ch - 66, w = cw - 110, h = 44 }
    UI.rects["tech_pick_" .. i] = b
    draw_button(b, "Add to deck", true, point_in_rect(mx, my, b.x, b.y, b.w, b.h))
  end
end

-- hover tooltip: full ability text for the card under the cursor (founders) or tech-card desc.
-- Drawn LAST (after cards + HUD) so it sits on top of everything. Hover flags are set in love.update.
local function wrapped_height(text, font, w)
  local _, lines = font:getWrap(text, w)
  return #lines * font:getHeight()
end

-- reusable tooltip box: full name + ability_name + (wrapped, full) ability text near an anchor point.
function UI.tip_box(ax, ay, title, sub, body)
  sub, body = sub or "", body or ""
  if not title then return end
  local w, pad = 380, 10                          -- wide enough that full sketches stay a reasonable height
  local px = clamp(ax, 8, G.WINDOW.w - w - 8)
  local th = G.FONTS.small:getHeight()
  local sh = sub ~= "" and (G.FONTS.tiny:getHeight() + 2) or 0
  local bh = body ~= "" and (wrapped_height(body, G.FONTS.tiny, w - 2 * pad) + 4) or 0
  local h = pad * 2 + th + sh + bh
  local py = clamp(ay, 8, G.WINDOW.h - h - 8)
  lg.setColor(0, 0, 0, 0.94); lg.rectangle("fill", px, py, w, h, 8, 8)
  lg.setColor(G.C.border); lg.setLineWidth(2); lg.rectangle("line", px, py, w, h, 8, 8); lg.setLineWidth(1)
  local y = py + pad
  lg.setFont(G.FONTS.small); lg.setColor(G.C.arr); lg.printf(title, px + pad, y, w - 2 * pad, "left"); y = y + th
  if sub ~= "" then lg.setFont(G.FONTS.tiny); lg.setColor(G.C.mult); lg.printf(sub, px + pad, y, w - 2 * pad, "left"); y = y + sh end
  if body ~= "" then lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text); lg.printf(body, px + pad, y + 2, w - 2 * pad, "left") end
end

function UI.draw_tooltip()
  if G.STATE == G.STATES.MENU then return end             -- no cards in the menu
  if not love.mouse.isDown(2) then return end             -- RIGHT-CLICK / press-and-hold to inspect (no blocking on hover)
  local mx, my = vmouse()
  local hovered
  for _, area in ipairs({ G.jokers, G.hand, G.play }) do
    if area and area.cards then
      for i = #area.cards, 1, -1 do
        local c = area.cards[i]
        if c.center and c:collides_with_point(mx, my) then hovered = c; break end
      end
    end
    if hovered then break end
  end
  if not hovered then return end
  local c = hovered.center
  local founder = c.set == "Founder"
  local sub, body
  if founder then
    sub = Card.effect_brief(c, hovered) .. "   \194\183   " .. (c.rarity or "")   -- headline (live value for accumulators)
    body = (c.ability_name or "")
    local ed = hovered.edition and Card.EDITIONS[hovered.edition]
    local sl = hovered.seal and Card.SEALS[hovered.seal]
    if ed then body = body .. "\n\226\156\166 " .. ed.label .. " edition: " .. (ed.desc or "") end
    if sl then body = body .. "\n\226\151\137 " .. sl.label .. " seal: " .. (sl.desc or "") end
    body = body .. "\n\n" .. (c.ability_text or c.hint or "")          -- flavor sketch (secondary)
  else
    local effective = hovered.get_users and hovered:get_users() or (hovered.base_users or 0)
    local base = hovered.base_users or 0
    local users = "Users " .. format_number(effective)
    if effective ~= base then users = users .. " (base " .. format_number(base) .. ")" end
    local rev = hovered.rev_sticker_label and hovered:rev_sticker_label()
    sub = (Coverage.display_layer(hovered) or "") .. "  ·  " .. users .. (rev and ("  ·  " .. rev) or "")
    body = c.desc or ""
  end
  UI.tip_box(hovered.VT.x + hovered.VT.w + 10, hovered.VT.y, c.name or c.short or "?", sub, body)
end

-- the pre-run MENU: career stats + collection summary + Funding-Stake select + Start.
function UI.render_menu(W, H)
  local mx, my = vmouse()
  local Centers = require("game.centers")
  local Profile = require("game.profile")
  local p = G.PROFILE or { career = {} }
  G.MENU = G.MENU or { stake = 1 }
  UI.text(G.FONTS.huge, "PALO LATRO", 0, 56, G.C.arr, W, "center")
  lg.setFont(G.FONTS.small); lg.setColor(G.C.text_dim)
  lg.printf("idea \194\183 IPO \194\183 a tech-startup roguelike", 0, 112, W, "center")
  local c = p.career or {}
  lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text_dim)
  lg.printf(("Runs %d \194\183 IPOs %d \194\183 best $%s ARR \194\183 best ante %d"):format(
    c.runs or 0, c.wins or 0, format_number(c.best_arr or 0), c.best_ante or 1), 0, 148, W, "center")
  local disc, forms = 0, 0
  for _, f in ipairs(Centers.pool("Founder")) do
    if f.discovered then disc = disc + 1 end
    if f.is_form and f.unlocked then forms = forms + 1 end
  end
  lg.printf(("Founders discovered %d \194\183 Legendary 2nd-forms unlocked %d/17"):format(disc, forms), 0, 168, W, "center")

  UI.text(G.FONTS.normal, "Select Funding Stake", 0, 216, G.C.text, W, "center")
  local maxst = Profile.max_stake()
  local n, bw, gap = 8, 132, 12
  local x0, y = (W - (n * bw + (n - 1) * gap)) / 2, 254
  for s = 1, n do
    local x = x0 + (s - 1) * (bw + gap)
    local mod = require("game.stakes").list[s]
    local unlocked = s <= maxst
    if unlocked then UI.rects["stake_" .. s] = { x = x, y = y, w = bw, h = 72 } end
    local sel = (G.MENU.stake == s)
    pixel_rect(x, y, bw, 72, sel and G.C.arr or (unlocked and G.C.btn or G.C.btn_off),
      { chamfer = 4, border = G.C.border, line_w = sel and 3 or 2 })
    lg.setColor(unlocked and G.C.text or G.C.text_dim); lg.setFont(G.FONTS.tiny)
    lg.printf("Stake " .. s, x, y + 10, bw, "center")
    lg.printf(unlocked and (mod and mod.name or "") or "locked", x + 4, y + 34, bw - 8, "center")
  end
  if G.MENU.stake > maxst then G.MENU.stake = maxst end
  local sr = { x = W / 2 - 120, y = y + 116, w = 240, h = 56 }
  UI.rects.start_run_at = sr
  draw_button(sr, "Start Run \194\187", true, point_in_rect(mx, my, sr.x, sr.y, sr.w, sr.h))
  lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text_dim)
  lg.printf("higher stakes unlock by reaching IPO \194\183 winning unlocks Legendary 2nd-forms", 0, y + 186, W, "center")
end

-- boss "market event" telegraph descriptions (mirrors Markets.event_mult)
local EVENT_DESC = {
  ai_winter      = "AI Winter \194\183 AI-layer plays \195\1510.7",
  platform_shift = "Platform Shift \194\183 Infra plays \195\1510.7",
  dotcom_bust    = "Dot-com Bust \194\183 all plays \195\1510.85",
}

-- the BLIND-SELECT page (P2): preview the upcoming blind before committing. Shows the ante's three blinds
-- (Small/Big/Boss) with ARR targets, the current one highlighted, the boss event telegraphed, the economy
-- readout, a Play button, and a disabled Skip seam (Leads/Tags come later).
function UI.render_blind_select(W, H, GAME)
  local mx, my = vmouse()
  local bl = GAME.blind or {}
  UI.text(G.FONTS.big, ("ANTE %d / 8"):format(GAME.ante or 1), 0, 40, G.C.arr, W, "center")
  lg.setFont(G.FONTS.small); lg.setColor(G.C.text_dim)
  lg.printf((bl.stage or "?") .. "  \194\183  choose your next blind", 0, 88, W, "center")

  local kinds = { "Small", "Big", "Boss" }
  local EV = { "ai_winter", "platform_shift", "dotcom_bust" }     -- mirrors set_blind's cyclic boss telegraph
  local boss_event = bl.event or (GAME.boss_sequence and GAME.boss_sequence[GAME.ante or 1])
    or EV[(((GAME.ante or 1) - 1) % #EV) + 1]
  local n, cw, ch, gap, y0 = 3, 300, 248, 40, 168
  local x0 = (W - (n * cw + (n - 1) * gap)) / 2
  for i = 1, n do
    local x = x0 + (i - 1) * (cw + gap)
    local current = (bl.idx or 1) == i
    local target = RunState.blind_target(GAME.ante or 1, i)
    local kindcol = (i == 3 and G.C.lose) or (i == 2 and G.C.mult) or G.C.users
    local fill = current and { 0.18, 0.20, 0.26, 1 } or { 0.11, 0.12, 0.15, 1 }
    pixel_rect(x, y0, cw, ch, fill, { chamfer = 6, border = current and G.C.arr or G.C.border, line_w = current and 3 or 2 })
    lg.setColor(kindcol); lg.rectangle("fill", x + 4, y0 + 4, cw - 8, 40)
    UI.text(G.FONTS.normal, kinds[i], x, y0 + 10, { 0, 0, 0, 1 }, cw, "center")
    UI.text(G.FONTS.small, "Reach", x, y0 + 72, G.C.text_dim, cw, "center")
    UI.text(G.FONTS.big, "$" .. format_number(target), x, y0 + 94, G.C.arr, cw, "center")
    UI.text(G.FONTS.tiny, "ARR", x, y0 + 138, G.C.text_dim, cw, "center")
    local reward = (RunState.BLIND_REWARD_UNITS[i] or 0) * require("game.economy").unit(GAME, RunState.ANTE_BASE)
    UI.text(G.FONTS.tiny, "Close reward +$" .. format_number(reward),
      x, y0 + 200, G.C.win, cw, "center")
    if i == 3 then
      lg.setFont(G.FONTS.tiny); lg.setColor(G.C.lose)
      local boss = require("game.bosses").rule(boss_event)
      local desc = EVENT_DESC[boss_event] or (boss and (boss.name .. " · respond: " .. table.concat(boss.responses or {}, ", "))) or "market event"
      lg.printf("! " .. desc, x + 12, y0 + 160, cw - 24, "center")
    else
      lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text_dim)
      lg.printf("standard blind", x + 12, y0 + 172, cw - 24, "center")
    end
    local label = ((i < (bl.idx or 1)) and "cleared") or (current and "NOW PLAYING" or "upcoming")
    UI.text(G.FONTS.tiny, label, x, y0 + ch - 26, current and G.C.arr or G.C.text_dim, cw, "center")
  end

  local payroll = RunState.payroll_due()
  lg.setFont(G.FONTS.small); lg.setColor((GAME.cash or 0) < 0 and G.C.lose or G.C.text_dim)
  lg.printf(("Cash $%s   \194\183   payroll due $%s   \194\183   founders %d"):format(
    format_number(GAME.cash or 0), payroll, #((G.jokers and G.jokers.cards) or {})), 0, y0 + ch + 26, W, "center")

  local pb = { x = W / 2 - 130, y = y0 + ch + 62, w = 260, h = 60 }
  UI.rects.play_blind = pb
  draw_button(pb, "Play " .. (bl.kind or "Blind") .. " \194\187", true, point_in_rect(mx, my, pb.x, pb.y, pb.w, pb.h))
  if (bl.idx or 1) < 3 then
    local sk = { x = W / 2 - 120, y = pb.y + 74, w = 240, h = 34 }
    UI.rects.skip_blind = sk
    local reward = (bl.idx or 1) == 1 and "Angel check" or "Expanded Tech draft"
    draw_button(sk, "Skip for " .. reward, true, point_in_rect(mx, my, sk.x, sk.y, sk.w, sk.h))
  end
end

-- the between-blinds SHOP screen: founder offers + reroll + continue. Immediate-mode;
-- offer panels are drawn from center data (no Card objects to manage). Buttons → G.FUNCS.shop_*.
function UI.render_shop(W, H, GAME)
  local mx, my = vmouse()
  UI.left_panel(GAME, true)                              -- same left counter rail as play, with a SHOP badge
  -- shiny page title (top-centre) + a short founders label (the sell hint moved to the tooltip flow)
  UI.text(G.FONTS.big, "*  THE SHOP  *", 330, 2, G.C.arr, W - 330, "center")   -- ASCII stars: m5x7/m6x11 lack the fancy glyphs
  UI.text(G.FONTS.tiny, "FOUNDERS  " .. #((G.jokers and G.jokers.cards) or {}) .. "/5",
    G.jokers and G.jokers.T.x or 352, (G.jokers and G.jokers.T.y or 24) - 24, G.C.text_dim)

  local sh = GAME.shop or { founders = {} }

  -- sell the selected founder (frees a slot, refunds value) — works in the shop AND during a pack open
  local selF
  for _, c in ipairs((G.jokers and G.jokers.cards) or {}) do if c.selected then selF = c; break end end
  if selF and selF.center then
    local bw, bh = 100, 28
    local bx = selF.VT.x + (selF.VT.w - bw) / 2
    local by = selF.VT.y + selF.VT.h + 4
    UI.rects.fire = { x = bx, y = by, w = bw, h = bh }
    local hov = point_in_rect(mx, my, bx, by, bw, bh)
    pixel_rect(bx, by, bw, bh, hov and G.C.lose or { 0.70, 0.26, 0.26, 1 }, { chamfer = 3, border = G.C.border })
    UI.text(G.FONTS.small, "Sell $" .. Shop.sell_value(selF), bx, by + 5, G.C.text, bw, "center")
  end

  -- Pack ceremony: shop dims, the cover opens, cards deal face-down and flip in sequence. The options
  -- already exist (shop.lua owns RNG); this timeline only gates when the player may interact with them.
  if sh.pack_open then
    local po = sh.pack_open
    local frame = PackPresentation.snapshot(po)
    local title = (po.name or (po.kind == "playbook" and "Playbook Workshop" or
      (po.kind == "tech_law" and "Tech Law Pack" or "Hiring Round"))):upper()

    lg.setColor(0, 0, 0, frame.ready and 0.58 or 0.72)
    lg.rectangle("fill", 332, 0, W - 332, H)

    if frame.cover then
      draw_pack_cover(W, H, frame, title, po)
      if frame.reduced then
        UI.text(G.FONTS.tiny, "Opening...", 332, H - 74, G.C.text_dim, W - 332, "center")
      elseif frame.tearing then
        UI.text(G.FONTS.small, "BREAKTHROUGH", 332, H - 76, G.C.arr, W - 332, "center")
      end
    end

    if not frame.cover then
      lg.setFont(G.FONTS.normal); lg.setColor(G.C.arr)
      local capacity_hint = po.kind == "hiring" and "  (sell a founder above to free a slot)" or
        (po.kind == "tech_law" and "  (use or sell a Tech Law to free a slot)" or "")
      lg.printf(title .. " \194\183 pick " .. po.picks_left .. capacity_hint, 332, 318, W - 332, "center")
    end
    local n = #po.options
    local cw, ch, gap, y0 = 160, 206, 30, 360            -- pick options as founder faces (square art + banner), pick below
    local play_cx = 332 + (W - 332) / 2
    local x0 = play_cx - (n * cw + (n - 1) * gap) / 2
    local hc, hx, hy
    for i = 1, n do
      local c = po.options[i]
      local x = x0 + (i - 1) * (cw + gap)
      local cf = frame.cards[i] or { visible = true, face_down = false, deal = 1, scale_x = 1 }
      if c and cf.visible then
        local deal = ease_out_cubic(cf.deal or 1)
        local dx = play_cx + (x - play_cx) * deal
        local dy = 252 + (y0 - 252) * deal
        local card_scale = 0.86 + 0.14 * deal
        local dw, dh = cw * card_scale, ch * card_scale
        local tx, ty = dx + (cw - dw) / 2, dy + (ch - dh) / 2
        local hov = frame.ready and point_in_rect(mx, my, x, y0, cw, ch)
        local rc = SHOP_RARITY_COL[c.rarity] or G.C.border
        lg.push()
        lg.translate(tx + dw / 2, ty + dh / 2)
        lg.scale(cf.scale_x or 1, 1)
        lg.translate(-(tx + dw / 2), -(ty + dh / 2))
        if cf.face_down then
          draw_pack_card_back({ x = tx, y = ty, w = dw, h = dh })
        elseif po.kind == "playbook" then
          pixel_rect(tx, ty, dw, dh, { 0.13, 0.15, 0.20, 1 }, { chamfer = 6, border = hov and G.C.hover or G.C.arr })
          UI.text(G.FONTS.small, c.name, tx + 8, ty + 32, G.C.arr, dw - 16, "center")
          local level = require("game.playbooks").level(c.key)
          UI.text(G.FONTS.tiny, "Level " .. level .. " -> " .. (level + 1), tx, ty + 116, G.C.win, dw, "center")
        elseif po.kind == "tech_law" then
          Card.draw_consumable_face({ x = tx, y = ty, w = dw, h = dh }, c,
            { border = hov and G.C.hover or G.C.arr, line_w = hov and 3 or 2 })
        else
          Card.draw_founder_face({ x = tx, y = ty, w = dw, h = dh }, c,
            { border = hov and G.C.hover or rc, line_w = hov and 3 or 2 })
          if frame.ready then
            local rl = (c.rarity or ""):upper()
            chip(tx + dw - (text_w(G.FONTS.tiny, rl) + 14) - 6, ty + 5, rl, G.FONTS.tiny, rc, { 0, 0, 0, 1 })
            if c.edition then chip(tx + 6, ty + 5, tostring(c.edition), G.FONTS.tiny, G.C.arr, { 0, 0, 0, 1 }) end
          end
        end
        lg.pop()
        if frame.ready then
          local r = { x = x + 10, y = y0 + ch + 8, w = cw - 20, h = 32 }
          UI.rects["pack_pick_" .. i] = r
          local can_pick = po.kind == "playbook" or
            (po.kind == "tech_law" and #(GAME.consumables or {}) < (GAME.consumable_slots or 2)) or
            (po.kind == "hiring" and #G.jokers.cards < Shop.founder_cap())
          draw_button(r, "Pick", can_pick,
            point_in_rect(mx, my, r.x, r.y, r.w, r.h))
          if hov then hc, hx, hy = c, x + cw + 10, y0 end
        end
      else
        if not c and frame.ready then
          pixel_rect(x, y0, cw, ch, { 0.12, 0.12, 0.14, 1 }, { chamfer = 6, border = G.C.border, shadow = false, emboss = false })
          lg.setColor(G.C.text_dim); lg.setFont(G.FONTS.small); lg.printf("(taken)", x, y0 + ch / 2 - 10, cw, "center")
        end
      end
    end
    if frame.ready then
      local sk = { x = play_cx - 100, y = y0 + ch + 50, w = 200, h = 46 }
      UI.rects.pack_skip = sk
      draw_button(sk, "Skip", true, point_in_rect(mx, my, sk.x, sk.y, sk.w, sk.h))
      if hc and po.kind == "hiring" then UI.tip_box(hx, hy, hc.name,
        Card.effect_brief(hc) .. "   \194\183   " .. (hc.rarity or ""),
        (hc.ability_name or "") .. "\n\n" .. (hc.ability_text or hc.hint or ""))
      elseif hc and po.kind == "tech_law" then UI.tip_box(hx, hy, hc.name,
        (hc.kind or "Tech Law") .. "   \194\183   " .. (hc.rarity or ""), hc.desc or "") end
    end
    return
  end

  local slots = Shop.slots()
  local cw, ch, gap, y0 = 160, 206, 30, 312            -- offers as founder faces (square art + banner; buy below)
  local x0 = (W - (slots * cw + (slots - 1) * gap)) / 2
  local hovc, hovx, hovy                               -- hovered offer → full-detail tooltip
  for i = 1, slots do
    local c = sh.founders[i]
    local x = x0 + (i - 1) * (cw + gap)
    if c then
      local hov = point_in_rect(mx, my, x, y0, cw, ch)
      local rc = SHOP_RARITY_COL[c.rarity] or G.C.border
      Card.draw_founder_face({ x = x, y = y0, w = cw, h = ch }, c, { border = hov and G.C.hover or rc, line_w = hov and 3 or 2 })
      local rl = (c.rarity or ""):upper()                                    -- rarity pip (top-right corner)
      chip(x + cw - (text_w(G.FONTS.tiny, rl) + 14) - 6, y0 + 5, rl, G.FONTS.tiny, rc, { 0, 0, 0, 1 })
      if c.edition then chip(x + 6, y0 + 5, tostring(c.edition), G.FONTS.tiny, G.C.arr, { 0, 0, 0, 1 }) end
      if c.stake_mod then UI.text(G.FONTS.tiny, tostring(c.stake_mod.kind), x, y0 + ch - 24, G.C.lose, cw, "center") end
      local price, r = Shop.price(c), { x = x + 10, y = y0 + ch + 8, w = cw - 20, h = 32 }
      UI.rects["shop_buy_" .. i] = r
      local can = (GAME.cash or 0) >= price and #G.jokers.cards < Shop.founder_cap()
      draw_button(r, "Buy $" .. price, can, point_in_rect(mx, my, r.x, r.y, r.w, r.h))
      if hov then hovc, hovx, hovy = c, x + cw + 10, y0 end
    else
      pixel_rect(x, y0, cw, ch, { 0.12, 0.12, 0.14, 1 }, { chamfer = 6, border = G.C.border, shadow = false, emboss = false })
      lg.setColor(G.C.text_dim); lg.setFont(G.FONTS.small); lg.printf("(sold)", x, y0 + ch / 2 - 10, cw, "center")
    end
  end

  -- Track C B3: one Tech Law consumable offer per shop (rendered with the real card face)
  local hovcc, hovccx, hovccy
  local cc = sh.consumable
  if cc then
    local cx2 = x0 + slots * (cw + gap)
    local hov2 = point_in_rect(mx, my, cx2, y0, Card.W, Card.H)
    Card.draw_consumable_face({ x = cx2, y = y0, w = Card.W, h = Card.H }, cc,
      { border = hov2 and G.C.hover or G.C.arr, line_w = hov2 and 3 or 2 })
    local price2 = Shop.consumable_price(cc)
    local r2 = { x = cx2, y = y0 + Card.H + 8, w = Card.W, h = 32 }
    UI.rects.shop_buy_consumable = r2
    local can2 = (GAME.cash or 0) >= price2 and ((G.consumables and #G.consumables.cards) or 0) < (GAME.consumable_slots or 2)
    draw_button(r2, "Buy $" .. price2, can2, point_in_rect(mx, my, r2.x, r2.y, r2.w, r2.h))
    if hov2 then hovcc, hovccx, hovccy = cc, cx2 + Card.W + 10, y0 end
  end

  local rcost = sh.reroll_cost or Shop.reroll_cost(0)
  local rr = { x = W / 2 - 230, y = y0 + ch + 50, w = 200, h = 50 }     -- +50: clear the per-offer Buy buttons
  UI.rects.shop_reroll = rr
  draw_button(rr, "Reroll $" .. rcost, (GAME.cash or 0) >= rcost, point_in_rect(mx, my, rr.x, rr.y, rr.w, rr.h))
  local cont = { x = W / 2 + 30, y = y0 + ch + 50, w = 200, h = 50 }
  UI.rects.shop_continue = cont
  draw_button(cont, "Next Blind \194\187", true, point_in_rect(mx, my, cont.x, cont.y, cont.w, cont.h))

  -- Investment voucher (one per shop)
  local v = sh.voucher
  if v then
    local vw, vy = 480, y0 + ch + 112
    local vx = (W - vw) / 2
    pixel_rect(vx, vy, vw, 54, { 0.18, 0.16, 0.20, 1 }, { chamfer = 4, border = G.C.arr, line_w = 2 })
    lg.setColor(G.C.text); lg.setFont(G.FONTS.small); lg.printf("INVESTMENT \194\183 " .. (v.name or ""), vx + 12, vy + 6, vw - 130, "left")
    lg.setColor(G.C.text_dim); lg.setFont(G.FONTS.tiny); lg.printf(v.desc or "", vx + 12, vy + 28, vw - 130, "left")
    local vp = Shop.voucher_price(v)
    local vr = { x = vx + vw - 108, y = vy + 12, w = 96, h = 30 }
    UI.rects.shop_redeem = vr
    draw_button(vr, "Buy $" .. vp, (GAME.cash or 0) >= vp, point_in_rect(mx, my, vr.x, vr.y, vr.w, vr.h))
  end

  -- Booster row: Hiring (Founder), Playbook (App-Type), and Tech Law families.
  local packs = sh.packs or {}
  local np = #packs
  if np > 0 then
    local pw = 220
    local px0 = (W - (np * pw + (np - 1) * 24)) / 2
    local py = y0 + ch + 174
    for i = 1, np do
      local x = px0 + (i - 1) * (pw + 24)
      local r = { x = x, y = py, w = pw, h = 44 }
      UI.rects["shop_open_pack_" .. i] = r
      local pp = packs[i] and Shop.pack_price(packs[i]) or 0
      local lbl = packs[i] and ((packs[i].name or "Pack") .. " $" .. pp) or "(opened)"
      draw_button(r, lbl, packs[i] and (GAME.cash or 0) >= pp, point_in_rect(mx, my, r.x, r.y, r.w, r.h))
      local cvr = packs[i] and G.PACK_ART and (G.PACK_ART[packs[i].art_key] or G.PACK_ART.hiring_round)
      if cvr then   -- cover thumbnail (right edge, clear of the label)
        local cs = (r.h - 4) / cvr:getHeight()
        lg.setColor(1, 1, 1, 1); lg.draw(cvr, r.x + r.w - cvr:getWidth() * cs - 3, r.y + 2, 0, cs, cs)
      end
    end
  end

  local payroll = RunState.payroll_due()
  lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text_dim)
  lg.printf("Your founders: " .. #G.jokers.cards .. "/" .. Shop.founder_cap() ..
    "   payroll due $" .. format_number(payroll), 0, y0 + ch + 230, W, "center")
  if hovc then UI.tip_box(hovx, hovy, hovc.name, Card.effect_brief(hovc) .. "   \194\183   " .. (hovc.rarity or ""), (hovc.ability_name or "") .. "\n\n" .. (hovc.ability_text or hovc.hint or "")) end
  if hovcc then UI.tip_box(hovccx, hovccy, hovcc.name, (hovcc.kind or "Tech Law") .. "   \194\183   " .. (hovcc.rarity or ""), hovcc.desc or "") end
end

-- input: which button (if any) is under the point — handler validates enabled state
function UI.button_at(x, y)
  local po = G.STATE == G.STATES.SHOP and G.GAME and G.GAME.shop and G.GAME.shop.pack_open
  if PackPresentation.input_locked(po) then return "pack_locked" end
  for name, r in pairs(UI.rects) do
    if point_in_rect(x, y, r.x, r.y, r.w, r.h) then return name end
  end
  return nil
end

-- ── Phase 4B overlays: deck view · run info · options (topmost, any page; click-outside closes) ────
function UI.draw_overlays()
  if not (G.SHOW_DECK_VIEW or G.SHOW_RUN_INFO or G.SHOW_OPTIONS) then return end
  local W, H = G.WINDOW.w, G.WINDOW.h
  local mx, my = vmouse()
  lg.setColor(0, 0, 0, 0.62); lg.rectangle("fill", 0, 0, W, H)

  if G.SHOW_DECK_VIEW then
    local pw, ph = 1000, 640
    local px0, py0 = (W - pw) / 2, (H - ph) / 2
    pixel_rect(px0, py0, pw, ph, { 0.10, 0.12, 0.16, 1 }, { chamfer = 8, border = G.C.arr, line_w = 2 })
    local total = (G.GAME and G.GAME.master_deck and #G.GAME.master_deck) or 0
    local remaining = (G.deck and #G.deck.cards) or 0
    UI.text(G.FONTS.normal, "YOUR DECK", px0, py0 + 12, G.C.arr, pw, "center")
    UI.text(G.FONTS.tiny, remaining .. " in the draw pile  \194\183  " .. total .. " owned  \194\183  click anywhere to close",
      px0, py0 + 46, G.C.text_dim, pw, "center")
    local layersmod = require("data.layers")
    local byl = {}
    for _, c in ipairs((G.deck and G.deck.cards) or {}) do
      local L = Coverage.display_layer(c) or "?"
      byl[L] = byl[L] or {}; table.insert(byl[L], c)
    end
    local y = py0 + 74
    for _, L in ipairs({ "Frontend", "Backend", "Data", "Infra", "AI", "Knowledge" }) do
      local list = byl[L]
      if list and #list > 0 then
        table.sort(list, function(a, b)
          local au = (a.get_users and a:get_users()) or (a.base_users or 0)
          local bu = (b.get_users and b:get_users()) or (b.base_users or 0)
          return au > bu
        end)
        local lcol = (layersmod[L] and layersmod[L].color) or G.C.text
        UI.text(G.FONTS.tiny, L:upper() .. "  (" .. #list .. ")", px0 + 20, y, lcol, pw - 40, "left")
        y = y + 20
        local cx0, cw2, ch2, g2 = px0 + 20, 30, 36, 4
        local xx = cx0
        for _, c in ipairs(list) do
          if xx + cw2 > px0 + pw - 20 then xx = cx0; y = y + ch2 + g2 end
          pixel_rect(xx, y, cw2, ch2, lcol, { chamfer = 3, shadow = false, emboss = false })
          local users = (c.get_users and c:get_users()) or (c.base_users or 0)
          draw_text(G.FONTS.tiny, tostring(users), xx, y + 5, G.C.black, cw2, "center")
          if c.rev_sticker_label and c:rev_sticker_label() then
            draw_text(G.FONTS.tiny, "R", xx, y + 20, G.C.mult, cw2, "center")
          end
          xx = xx + cw2 + g2
        end
        y = y + ch2 + 12
      end
    end
    return
  end

  if G.SHOW_RUN_INFO then
    local pw, ph = 980, 620
    local px0, py0 = (W - pw) / 2, (H - ph) / 2
    pixel_rect(px0, py0, pw, ph, { 0.10, 0.12, 0.16, 1 }, { chamfer = 8, border = G.C.arr, line_w = 2 })
    UI.text(G.FONTS.normal, "RUN INFO", px0, py0 + 12, G.C.arr, pw, "center")
    UI.text(G.FONTS.tiny, "click anywhere to close", px0, py0 + 44, G.C.text_dim, pw, "center")
    -- LEFT: the App-Type payout table (what each "hand" is worth)
    local AppTypes = require("game.apptypes")
    local ty = py0 + 74
    UI.text(G.FONTS.tiny, "APP TYPE", px0 + 30, ty, G.C.text_dim, 300, "left")
    UI.text(G.FONTS.tiny, "USERS  \195\151  REV", px0 + 340, ty, G.C.text_dim, 160, "left")
    UI.text(G.FONTS.tiny, "MARGIN", px0 + 500, ty, G.C.text_dim, 90, "left")
    ty = ty + 22
    for _, a in ipairs(AppTypes.list or {}) do
      UI.text(G.FONTS.tiny, a.name or "?", px0 + 30, ty, G.C.text, 300, "left")
      UI.text(G.FONTS.tiny, (a.base_chips or 0) .. "  \195\151  " .. (a.base_mult or 0), px0 + 340, ty, G.C.users, 160, "left")
      UI.text(G.FONTS.tiny, math.floor((a.margin or 0) * 100 + 0.5) .. "%", px0 + 500, ty, G.C.mult, 90, "left")
      ty = ty + 19
    end
    -- RIGHT: run facts
    local RS = require("game.runstate")
    local g = G.GAME or {}
    local fx, fy = px0 + 630, py0 + 74
    local function fact(lab, val, col)
      UI.text(G.FONTS.tiny, lab, fx, fy, G.C.text_dim, 320, "left")
      UI.text(G.FONTS.small, val, fx, fy + 14, col or G.C.text, 320, "left")
      fy = fy + 46
    end
    fact("MARKET", (g.market and g.market.name) or "?", G.C.arr)
    fact("STAKE", tostring(g.stake or 1) .. " \194\183 " .. (RS.STAGE_NAME[g.ante or 1] or ""))
    fact("BOSS TELEGRAPH", (g.blind and g.blind.event) or "(see blind select)")
    fact("PAYROLL DUE", "-$" .. format_number(RS.payroll_due() or 0), G.C.mult)
    fact("CLOSE REWARD", "+$" .. format_number((RS.BLIND_REWARD_UNITS[g.blind_idx or 1] or 0) *
      require("game.economy").unit(g, RS.ANTE_BASE)), G.C.win)
    local vlist = {}
    for k in pairs(g.vouchers_owned or {}) do vlist[#vlist + 1] = (k:gsub("^v_", "")) end
    fact("INVESTMENTS", #vlist > 0 and table.concat(vlist, ", ") or "(none)")
    return
  end

  if G.SHOW_OPTIONS then
    local pw, ph = 420, 540
    local px0, py0 = (W - pw) / 2, (H - ph) / 2
    pixel_rect(px0, py0, pw, ph, { 0.10, 0.12, 0.16, 1 }, { chamfer = 8, border = G.C.arr, line_w = 2 })
    UI.text(G.FONTS.normal, "OPTIONS", px0, py0 + 12, G.C.arr, pw, "center")
    local rows = {
      { "opt_motion", "Motion FX:  " .. (G.SETTINGS.reduced_motion and "OFF" or "ON") },
      { "opt_sound",  "Sound:  " .. (G.SETTINGS.sound == false and "OFF" or "ON") },
      { "opt_shake",  "Screen shake:  " .. (G.SETTINGS.shake == false and "OFF" or "ON") },
      { "opt_flash",  "Screen flash:  " .. (G.SETTINGS.flash == false and "OFF" or "ON") },
      { "opt_particles", "Particles:  " .. (G.SETTINGS.particles == false and "OFF" or "ON") },
      { "opt_crt",    "CRT filter:  " .. (G.SETTINGS.crt and "ON" or "OFF") },
      { "opt_quit",   "Quit to menu" },
    }
    local by3 = py0 + 64
    for _, r in ipairs(rows) do
      UI.rects[r[1]] = { x = px0 + 60, y = by3, w = pw - 120, h = 46 }
      draw_button(UI.rects[r[1]], r[2], true, point_in_rect(mx, my, px0 + 60, by3, pw - 120, 46))
      by3 = by3 + 58
    end
    UI.text(G.FONTS.tiny, "click outside to close", px0, py0 + ph - 26, G.C.text_dim, pw, "center")
    return
  end
end

return UI
