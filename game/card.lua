-- game/card.lua — Card(Moveable): the universal card object. Points at a CENTER by key + holds
-- an `ability` instance copy; behavior resolves by string (founders later add `calculate`
-- branches). get_users() is a METHOD (not a constant) so the compatibility graph can make Users
-- contextual later with no caller change.

local layers = require("data.layers")
local Coverage = require("game.coverage")

Card = Moveable:extend()

Card.W, Card.H = math.floor(2.05 * G.TILE + 0.5), math.floor(2.75 * G.TILE + 0.5)   -- Balatro 35:47, ~144×193 (P3)

-- ---- founder card-face tunables (V0.1 redesign: SQUARE art + banner, Hearthstone-style, thin frame) ----
-- The art is generated 1:1; we show it UNCROPPED (square, fit to width) so logos/mascots survive, with a
-- name plate over the art's lower edge and an effect banner below — the nickname can never be hidden by the art.
Card.FOUNDER_SCALE = 1.25          -- founder cards are bigger than tech cards (deliberate; breaks size-parity)
Card.FRAME_PAD     = 3             -- thin frame inset (px)
Card.CHAMFER       = 5             -- corner rounding
Card.BANNER_H      = 42            -- effect-banner height below the square art (in-play card)
Card.NAMEPLATE_H   = 44            -- nickname ribbon over the art's lower edge — 2-line-capable so a wrapped name never reaches the banner
Card.BANNER_COL    = { 0.90, 0.87, 0.78, 1 }   -- LIGHT parchment effect banner
Card.TAG_COL       = { 0.18, 0.13, 0.09, 1 }   -- dark tag text (reads on the light banner)
Card.SHOW_NICKNAME = true
Card.FW = math.floor(Card.W * Card.FOUNDER_SCALE + 0.5)         -- founder card width (~180)
Card.FH = Card.FW + Card.BANNER_H                              -- square art (≈FW) + banner → ~222

-- Editions: passive founder modifiers ≈ Balatro foil/holo/poly. Stored on the Card
-- instance (card.edition = key); scored in scoring.lua; assigned at acquisition (shop/pack).
Card.EDITIONS = {
  open_source   = { label = "Open-Source",   chips = 40,    col = { 0.55, 0.80, 0.92, 1 }, desc = "+40 Users when scored" },  -- ≈foil
  battle_tested = { label = "Battle-Tested", mult = 8,      col = { 0.95, 0.65, 0.50, 1 }, desc = "+8 Rev when scored" },     -- ≈holo
  viral         = { label = "Viral",         x_mult = 1.5,  col = { 0.92, 0.60, 0.96, 1 }, desc = "\195\1511.5 Rev when scored" },  -- ≈poly
}
Card.EDITION_KEYS = { "open_source", "battle_tested", "viral" }
Card.EDITION_SHADER = { open_source = "foil", battle_tested = "holo", viral = "polychrome" }  -- P4: edition → portrait shimmer

-- Seals: per-founder trigger stamps ≈ Balatro red/gold seal. The persistent tech deck now
-- exists; extending edition/seal scoring to tech cards remains a separate scoring contract.
Card.SEALS = {
  reusable  = { label = "Reusable",  col = { 0.85, 0.35, 0.35, 1 }, retrigger = 1, desc = "Triggers its effect twice" },  -- ≈Red
  monetized = { label = "Monetized", col = { 0.90, 0.78, 0.35, 1 }, cash = 8, desc = "+$8 Cash when it scores" },         -- ≈Gold
}
Card.SEAL_KEYS = { "reusable", "monetized" }

-- layer "suit" abbreviations for the readable top-left corner (until tech-logo art lands, ADR/parking-lot #4)
Card.LAYER_ABBR = { Frontend = "FE", Backend = "BE", Data = "DA", Infra = "IN", AI = "AI", Knowledge = "KN" }

-- a concise, game-facing effect line derived from the compiled DSL (P2): "+15 Users" / "×2 Rev" /
-- "Earns Cash" / "Retrigger" … Best-effort + accurate to the real magnitudes; falls back to the effect
-- category. Shown on the card face + as the tooltip headline so play-time reading is quick.
local function fmt1(x)  -- compact number: integer if whole, else 1 decimal
  if x % 1 == 0 then return tostring(math.floor(x)) end
  return string.format("%.1f", x)
end

function Card.effect_brief(center, card)
  if not center then return "" end
  local d = center.dsl
  -- 1) LIVE accumulated value (owned card + accumulator op) — the real number this run, on the card face.
  -- Scan ALL ops for the first growing accumulator (post-audit DSLs may place acc behind a per-op gate, not first).
  if card and d and d.ops then
    local op
    for _, o in ipairs(d.ops) do
      if o.k == "acc" and (o.field == "x_mult" or o.field == "mult" or o.field == "chips") then op = o; break end
    end
    if op then
      local f = op.field
      local cfg = card.ability and card.ability.config
      local cnt = (cfg and cfg["_acc_" .. (op.state or "n")]) or 0
      local live = (op.base or (f == "x_mult" and 1 or 0)) + (op.coef or 0) * cnt
      if f == "x_mult" then return "\195\151" .. fmt1(live) .. " Rev" end
      return "+" .. fmt1(live) .. (f == "chips" and " Users" or " Rev")
    end
  end
  -- 2) curated concise descriptor (subagent sweep) — accurate for growth / conditions
  if center.effect_brief and center.effect_brief ~= "" then return center.effect_brief end
  -- 3) DSL-derived fallback (founders without a curated brief, e.g. legendary forms)
  if d and d.retrigger then return "Retrigger \195\151" .. d.retrigger end
  local op = d and d.ops and d.ops[1]
  if op then
    local k, f = op.k, op.field
    if k == "scale" or k == "acc" then
      local grows = (k == "acc") or (op.coef and op.coef ~= 0)
      if f == "x_mult" then return grows and "\195\151 Rev (grows)" or ("\195\151" .. (op.base or 1) .. " Rev") end
      if f == "mult"   then return grows and ("+" .. fmt1(op.coef or 0) .. " Rev (grows)") or ("+" .. fmt1(op.base or 0) .. " Rev") end
      if f == "chips"  then return grows and ("+" .. fmt1(op.coef or 0) .. " Users (grows)") or ("+" .. fmt1(op.base or 0) .. " Users") end
    elseif k == "grant" then
      if op.what == "cash"   then return "Earns Cash" end
      if op.what == "margin" then return "+ Margin" end
      if op.what == "salary" then return "Cuts payroll" end
    elseif k == "gamble"      then return "\195\151 Rev (gamble)"
    elseif k == "gen"         then return "Creates cards"
    elseif k == "clear_clash" then return "Clears clashes"
    elseif k == "delete_card" then return "Cut Layer -> Margin"
    elseif k == "clash_tax"   then return "Skims per clash"
    elseif k == "meter"       then return "Builds reputation" end
  end
  if center.effect_brief and center.effect_brief ~= "" then return center.effect_brief end   -- curated (sweep)
  local t = center.effect and center.effect.type
  local LABEL = { xmult = "\195\151 Rev", plus_mult = "+ Rev", plus_chips = "+ Users",
                  economy = "Earns Cash", utility = "Utility", generation = "Creates cards", retrigger = "Retrigger" }
  return (t and LABEL[t]) or "Special"
end

-- A SHORT face tag (≈1 line, big font): the live accumulator value if present, else a punchy DSL-derived
-- category. The full descriptive brief stays in the tooltip — keeps the face clean (less text, larger font).
function Card.face_tag(center, card)
  if not center then return "" end
  local d = center.dsl
  if card and d and d.ops then                                  -- live accumulator value (the real number this run)
    local op
    for _, o in ipairs(d.ops) do
      if o.k == "acc" and (o.field == "x_mult" or o.field == "mult" or o.field == "chips") then op = o; break end
    end
    if op then
      local f = op.field
      local cfg = card.ability and card.ability.config
      local cnt = (cfg and cfg["_acc_" .. (op.state or "n")]) or 0
      local live = (op.base or (f == "x_mult" and 1 or 0)) + (op.coef or 0) * cnt
      if f == "x_mult" then return "\195\151" .. fmt1(live) .. " Rev" end
      return "+" .. fmt1(live) .. (f == "chips" and " Users" or " Rev")
    end
  end
  if d and d.retrigger then return "Retrigger" end               -- DSL-derived short category
  local op = d and d.ops and d.ops[1]
  if op then
    local k, f = op.k, op.field
    if k == "scale" or k == "acc" then
      local grows = (k == "acc") or (op.coef and op.coef ~= 0)
      if f == "x_mult" then return grows and "\195\151 Rev" or ("\195\151" .. fmt1(op.base or 1) .. " Rev") end
      if f == "mult"   then return grows and "+ Rev" or ("+" .. fmt1(op.base or 0) .. " Rev") end
      if f == "chips"  then return grows and "+ Users" or ("+" .. fmt1(op.base or 0) .. " Users") end
    elseif k == "grant" then
      if op.what == "cash" then return "Cash" elseif op.what == "margin" then return "+ Margin"
      elseif op.what == "salary" then return "- Payroll" end
    elseif k == "gamble"      then return "\195\151 Rev?"
    elseif k == "gen"         then return "Creates"
    elseif k == "clear_clash" then return "Clears"
    elseif k == "delete_card" then return "Cut Layer"
    elseif k == "clash_tax"   then return "Skims"
    elseif k == "meter"       then return "Rep" end
  end
  local t = center.effect and center.effect.type
  local LABEL = { xmult = "\195\151 Rev", plus_mult = "+ Rev", plus_chips = "+ Users", economy = "Cash",
                  utility = "Utility", generation = "Creates", retrigger = "Retrigger" }
  return (t and LABEL[t]) or "Special"
end

-- Shared full-bleed founder face — the single source of truth used by BOTH the jokers row
-- (Card:draw_body) and the immediate-mode shop offers (ui.lua), so they look identical.
-- t = {x,y,w,h} target rect; center = founder center; opts = { card=<live Card or nil>, border=, line_w= }.
function Card.draw_founder_face(t, center, opts)
  opts = opts or {}
  local lg = love.graphics
  local card = opts.card
  local edition = card and card.edition
  local seal = card and card.seal
  local cham = Card.CHAMFER
  local pad = Card.FRAME_PAD
  -- layout derived from the rect: square art on top, effect banner fills the remainder
  local artw = t.w - 2 * pad
  local arth = math.min(artw, t.h - 2 * pad - 34)                    -- square art (fit width); guard a min banner
  local artx, arty = t.x + pad, t.y + pad
  local by = arty + arth                                              -- banner top (just below the art)
  local bh = t.y + t.h - pad - by                                     -- effect-banner height (the remainder)

  pixel_rect(t.x, t.y, t.w, t.h, { 0.06, 0.08, 0.12, 1 }, { chamfer = cham })   -- card base (reads as a thin dark frame)

  clip_chamfer(t.x, t.y, t.w, t.h, cham, function()
    -- 1) SQUARE art, FIT (whole 1:1 image visible — no L/R crop, keeps logos/mascots)
    local img = G.FOUNDER_ART and center and G.FOUNDER_ART[center.key]
    if img then
      local iw, ih = img:getDimensions()
      local s = math.min(artw / iw, arth / ih)
      local dx, dy = artx + (artw - iw * s) / 2, arty + (arth - ih * s) / 2
      lg.setColor(1, 1, 1, 1)
      local esh = edition and shaders_enabled() and G.SHADERS[Card.EDITION_SHADER[edition] or ""]
      if esh then                                                     -- editioned portrait shimmers through its shader
        local okp = pcall(function()
          esh:send("time", shader_time())
          esh:send("phase", ((card and card.ID) or 0) * 0.6 + ((card and card.states.hover.is) and 1.5 or 0))
          lg.setShader(esh); lg.draw(img, dx, dy, 0, s, s)
        end)
        lg.setShader()
        if not okp then lg.draw(img, dx, dy, 0, s, s) end
      else
        lg.draw(img, dx, dy, 0, s, s)
      end
    else                                                              -- fallback: initials on a panel fill
      lg.setColor(G.C.btn); lg.rectangle("fill", artx, arty, artw, arth)
      draw_text(G.FONTS.big, ((center and (center.short or center.name)) or "?"):sub(1, 2),
        artx, arty + arth / 2 - text_h(G.FONTS.big) / 2, G.C.text, artw, "center")
    end
    -- 2) nickname plate over the art's lower edge (dark scrim so the name reads on top of art; 2-line-capable)
    local nph = Card.NAMEPLATE_H
    fade_rect(t.x, by - nph, t.w, nph, { 0, 0, 0 }, 0, 0.80)
    -- 3) LIGHT effect banner below the art
    lg.setColor(Card.BANNER_COL); lg.rectangle("fill", t.x, by, t.w, bh + pad)
    lg.setColor(0, 0, 0, 0.45); lg.rectangle("fill", t.x, by - 1, t.w, 2)         -- divider art↔banner
  end)

  -- nickname (tiny, confined to the plate ABOVE the banner so 2 lines never reach the tag) + the effect tag
  if Card.SHOW_NICKNAME then
    draw_text(G.FONTS.tiny, (center and (center.name or center.short)) or "",
      t.x + 3, by - Card.NAMEPLATE_H + 2, G.C.text, t.w - 6, "center")
  end
  local tag = Card.face_tag(center, card)
  if tag and tag ~= "" then
    draw_text(G.FONTS.normal, tag, t.x + 3, by + (bh - text_h(G.FONTS.normal)) / 2, Card.TAG_COL, t.w - 6, "center")
  end

  if center and center.salary then                                   -- salary chip (top-left of the art)
    chip(t.x + 5, t.y + 5, "$" .. center.salary, G.FONTS.tiny, { 0.08, 0.10, 0.15, 0.92 }, G.C.mult)
  end
  local sl = seal and Card.SEALS[seal]                               -- seal stamp (top-right of the art)
  if sl then
    local r = math.floor(t.w * 0.075)
    local sx, sy = t.x + t.w - r - 7, t.y + r + 7
    lg.setColor(sl.col); lg.circle("fill", sx, sy, r)
    lg.setColor(0, 0, 0, 0.6); lg.setLineWidth(1); lg.circle("line", sx, sy, r); lg.setLineWidth(1)
  end

  pixel_rect(t.x, t.y, t.w, t.h, nil, { chamfer = cham, border = opts.border or G.C.border, line_w = opts.line_w or 1 })
end

-- Track C B1: the consumable (Tech Law) card face. The codex art IS the complete card front (portrait,
-- framed, name lettered on it) → near-blit, chamfer-clipped, with the state border on top. Fallback (art
-- not yet deployed): a framed text face with the kind tag + name + desc so the card is still readable.
function Card.draw_consumable_face(t, center, opts)
  opts = opts or {}
  local lg = love.graphics
  local cham = 5
  local img = G.CONSUMABLE_ART and center and G.CONSUMABLE_ART[center.key]
  if img then
    pixel_rect(t.x, t.y, t.w, t.h, { 0.06, 0.08, 0.12, 1 }, { chamfer = cham })
    clip_chamfer(t.x, t.y, t.w, t.h, cham, function()
      local iw, ih = img:getDimensions()
      local s = math.max(t.w / iw, t.h / ih)                    -- cover (the art is already the card face)
      lg.setColor(1, 1, 1, 1)
      lg.draw(img, t.x + (t.w - iw * s) / 2, t.y + (t.h - ih * s) / 2, 0, s, s)
    end)
  else                                                          -- fallback text face (pre-art)
    pixel_rect(t.x, t.y, t.w, t.h, { 0.16, 0.14, 0.22, 1 }, { chamfer = cham })
    draw_text(G.FONTS.tiny, (center and center.kind or "LAW"):upper(), t.x, t.y + 8, G.C.arr, t.w, "center")
    draw_text(G.FONTS.small, (center and center.name) or "?", t.x + 6, t.y + t.h * 0.28, G.C.text, t.w - 12, "center")
    draw_text(G.FONTS.tiny, (center and center.desc) or "", t.x + 8, t.y + t.h * 0.58, G.C.text_dim, t.w - 16, "center")
  end
  pixel_rect(t.x, t.y, t.w, t.h, nil, { chamfer = cham, border = opts.border or G.C.border, line_w = opts.line_w or 2 })
end

function Card:init(args)
  args = args or {}
  local is_founder = args.center and args.center.set == "Founder"   -- founders render bigger (full-bleed redesign)
  local cw, ch = is_founder and Card.FW or Card.W, is_founder and Card.FH or Card.H
  args.T = args.T or { x = 0, y = 0, w = cw, h = ch }
  args.T.w = args.T.w or cw
  args.T.h = args.T.h or ch
  Card.super.init(self, args)

  self.center = args.center
  self.center_key = args.center and args.center.key
  self.uid = args.uid                                 -- back-ref to the master_deck entry (Track C A); nil for non-deck cards
  self.layer = args.center and args.center.layer
  self.base_users = (args.center and args.center.base_users) or 0
  self.ability = {
    name = args.center and args.center.name,
    set  = args.center and args.center.set,
    config = deep_copy((args.center and args.center.config) or {}),
  }
  self.selected = false
  self.face_down = args.face_down or false
  self.states.hover.can = true
  self.states.click.can = true
  table.insert(G.I.CARD, self)
end

-- the "build" contribution of this card (contextual seam for the compatibility graph)
function Card:get_users(context)
  local u = self.base_users or 0
  if self.stickers then                                   -- Track C: card_stat_sticker(field=users) — adds first, then muls
    local add, mul = 0, 1
    for _, s in ipairs(self.stickers) do
      if s.field == "users" then
        if s.mode == "add" then add = add + (s.amount or 0)
        elseif s.mode == "mul" then mul = mul * (s.amount or 1)
        elseif s.mode == "override" then u = s.amount or u; add, mul = 0, 1 end
      end
    end
    u = (u + add) * mul
  end
  return math.floor(u + 0.5)
end

-- Track C: per-card Rev stickers (card_stat_sticker field=rev) — the consumable engine folds these into the
-- hand mult at the per-card scoring pass (see scoring.lua). add/mul/override returned as {add, mul, override}.
function Card:rev_sticker()
  if not self.stickers then return nil end
  local add, mul, ovr = 0, 1, nil
  local any = false
  for _, s in ipairs(self.stickers) do
    if s.field == "rev" then
      any = true
      if s.mode == "add" then add = add + (s.amount or 0)
      elseif s.mode == "mul" then mul = mul * (s.amount or 1)
      elseif s.mode == "override" then ovr = s.amount end
    end
  end
  if not any then return nil end
  return { add = add, mul = mul, override = ovr }
end

-- Compact, exact description of the per-card Rev transform. Tech cards do not
-- own a standalone Rev number; their sticker changes the hand's running Rev in
-- scoring order, so showing the operation is more truthful than inventing a
-- synthetic total. Used by the card face, tooltip, and deck observability UI.
function Card:rev_sticker_label()
  local rs = self:rev_sticker()
  if not rs then return nil end
  local parts = {}
  if rs.override ~= nil then parts[#parts + 1] = "=" .. fmt1(rs.override) end
  if rs.add and rs.add ~= 0 then parts[#parts + 1] = (rs.add > 0 and "+" or "") .. fmt1(rs.add) end
  if rs.mul and rs.mul ~= 1 then parts[#parts + 1] = "×" .. fmt1(rs.mul) end
  return "Rev" .. table.concat(parts)
end

-- the joker/center behavior seam: returns an effect table or nil. Tech cards do nothing;
-- founders route to their executable abilities (game/founders.lua) via G.FOUNDER_CALC.
function Card:calculate(context)
  if self.ability.set == "Founder" and G.FOUNDER_CALC then return G.FOUNDER_CALC(self, context) end
  return nil
end

function Card:toggle_select()
  self.selected = not self.selected
  if self.area then self.area:align_cards() end
end

function Card:draw()
  if self.area and self.area.config and self.area.config.type == "deck"
    and (self._area_index or 0) < #self.area.cards - 5 then return end
  local t = self.VT
  -- juice (squash/pop) + idle sway + hover lean, applied about the card center
  local cx, cy = t.x + t.w / 2, t.y + t.h / 2
  local s = (t.scale or 1) + (self.juice and self.juice.scale or 0)
  local rot = (t.r or 0) + (self.juice and self.juice.r or 0)
  local shx, shy = 0, 0
  if not G.SETTINGS.reduced_motion then
    rot = rot + 0.02 * math.sin(G.TIMERS.REAL * 1.1 + (self.ID or 0) * 0.7)   -- idle ambient sway
    if self.states.hover.is or self.selected then                            -- lean toward cursor
      local mx, my = vmouse()
      shx = clamp((mx - cx) / 600, -0.08, 0.08)   -- gentle lean (was too strong / distorted small cards)
      shy = clamp((my - cy) / 700, -0.05, 0.05)
      s = s + 0.04
    end
  end
  love.graphics.push()
  love.graphics.translate(cx, cy)
  love.graphics.rotate(rot)
  love.graphics.shear(shx, shy)
  love.graphics.scale(s, s)
  love.graphics.translate(-cx, -cy)
  self:draw_body(t)
  love.graphics.pop()
end

function Card:draw_body(t)
  local lg = love.graphics

  if self.face_down then                            -- card back: real art when deployed, PL placeholder until then
    if G.CARD_BACK then
      pixel_rect(t.x, t.y, t.w, t.h, { 0.06, 0.08, 0.12, 1 }, { chamfer = 6 })
      clip_chamfer(t.x, t.y, t.w, t.h, 6, function()
        local iw, ih = G.CARD_BACK:getDimensions()
        local s = math.max(t.w / iw, t.h / ih)
        lg.setColor(1, 1, 1, 1)
        lg.draw(G.CARD_BACK, t.x + (t.w - iw * s) / 2, t.y + (t.h - ih * s) / 2, 0, s, s)
      end)
      pixel_rect(t.x, t.y, t.w, t.h, nil, { chamfer = 6, border = G.C.border })
    else
      pixel_rect(t.x, t.y, t.w, t.h, G.C.btn, { chamfer = 6, border = G.C.border })
      lg.setColor(G.C.btn_hi); lg.setLineWidth(2)
      lg.rectangle("line", t.x + 10, t.y + 10, t.w - 20, t.h - 20, 4, 4); lg.setLineWidth(1)
      draw_text(G.FONTS.normal, "PL", t.x, t.y + t.h / 2 - text_h(G.FONTS.normal) / 2, G.C.arr, t.w, "center")
    end
    return
  end

  if self.center and self.center.set == "Founder" then        -- founder (joker) face → shared full-bleed renderer
    local ed = self.edition and Card.EDITIONS[self.edition]
    local bcol = self.selected and G.C.lose or (self.states.hover.is and G.C.hover or (ed and ed.col) or G.C.border)
    Card.draw_founder_face(t, self.center, { card = self, border = bcol, line_w = self.selected and 3 or (ed and 3 or 2) })
    return
  end

  if self.center and self.center.set == "Consumable" then     -- Tech Law (Tarot) face → the art IS the card
    local bcol = self.selected and G.C.select or (self.states.hover.is and G.C.hover or G.C.border)
    Card.draw_consumable_face(t, self.center, { card = self, border = bcol, line_w = self.selected and 3 or 2 })
    return
  end

  -- TECH CARD: poker-style face (parking-lot "logos-as-suits") — corner Users + suit pip (mirrored
  -- bottom-right, upside down like a real deck), a BIG central suit watermark, and a name plate.
  local L = Coverage.display_layer(self)
  local col = (L and layers[L] and layers[L].color) or G.C.panel
  local pip = (G.TECH_ART and self.center and G.TECH_ART[self.center.key]) or (G.SUIT_ART and L and G.SUIT_ART[L])
  local has_tech_mark = G.TECH_ART and self.center and G.TECH_ART[self.center.key]

  -- Warm-white poker stock replaces the old full layer-colour placeholder. Layer colour remains a
  -- restrained trim cue; the individual parody mark now carries the card's visual identity.
  pixel_rect(t.x, t.y, t.w, t.h, { 0.94, 0.92, 0.84, 1 }, { chamfer = 5 })
  lg.setColor(col[1], col[2], col[3], 0.85)
  lg.rectangle("fill", t.x + 4, t.y + 4, 4, t.h - 8)
  lg.rectangle("fill", t.x + t.w - 8, t.y + 4, 4, t.h - 8)

  if pip then                                                   -- individual mark; layer pip remains the fallback
    local iw, ih = pip:getDimensions()
    local s = math.min((t.w * (has_tech_mark and 0.62 or 0.52)) / iw, (t.h * 0.42) / ih)
    lg.setColor(1, 1, 1, has_tech_mark and 0.96 or 0.36)
    lg.draw(pip, t.x + (t.w - iw * s) / 2, t.y + t.h * 0.12, 0, s, s)
  end
  -- name plate
  lg.setColor(0.08, 0.09, 0.12, 0.88); lg.rectangle("fill", t.x + 8, t.y + t.h * 0.54, t.w - 16, t.h * 0.25, 4, 4)
  draw_text(G.FONTS.small, self.ability.name or "?", t.x + 10, t.y + t.h * 0.565, G.C.text, t.w - 20, "center")
  -- corners (visible when cards overlap, Balatro rank+suit): Users + pip top-left, mirrored pip bottom-right
  local effective_users = self:get_users()
  local users_col = effective_users ~= (self.base_users or 0) and G.C.win or G.C.users
  draw_text(G.FONTS.normal, tostring(effective_users), t.x + 8, t.y + 6, users_col)
  local rev_label = self:rev_sticker_label()
  if rev_label then
    local rw, rh = 58, 24
    pixel_rect(t.x + t.w - rw - 6, t.y + 6, rw, rh, { 0.08, 0.10, 0.15, 0.90 },
      { chamfer = 4, shadow = false, emboss = false })
    draw_text(G.FONTS.tiny, rev_label, t.x + t.w - rw - 4, t.y + 8, G.C.mult, rw - 4, "center")
  end
  if pip then
    local ps = 22 / pip:getWidth()
    lg.setColor(1, 1, 1, has_tech_mark and 0.98 or 0.75)
    lg.draw(pip, t.x + 9, t.y + 40, 0, ps, ps)
    lg.draw(pip, t.x + t.w - 9, t.y + t.h - 40, math.pi, ps, ps)
  else
    draw_text(G.FONTS.tiny, Card.LAYER_ABBR[L] or (L or ""):sub(1, 2):upper(), t.x + 9, t.y + 42, G.C.black)
  end
  -- Large, clean footer: draw directly so the global drop shadow cannot crowd the glyphs at card size.
  lg.setFont(G.FONTS.normal)
  lg.setColor(col)
  lg.printf((L or ""):upper(), t.x + 8, t.y + t.h - text_h(G.FONTS.normal) - 5, t.w - 16, "center")

  -- selection / hover border
  local bcol, bw = G.C.border, 2
  if self.selected then bcol, bw = G.C.select, 3
  elseif self.states.hover.is then bcol, bw = G.C.hover, 2 end
  pixel_rect(t.x, t.y, t.w, t.h, nil, { chamfer = 6, border = bcol, line_w = bw })
end

return Card
