-- engine/draw.lua — fixed-order flat draw pipeline (not a recursive tree walk). Iterates
-- pools by type in a deliberate stacking order (the runtime contract / benchmark). The HUD/overlay is
-- drawn separately by ui.lua after this, and declarative UIBoxes (later) would slot in here.

-- ---- pixel-art rect primitive (P1 skin pass) -------------------------------------------------
-- A simplified clean-room take on Balatro's draw_pixellated_rect (engine/ui.lua): a chamfered-corner
-- polygon with an offset drop-shadow + a 3D emboss edge (light top/left, dark bottom/right) + border.
-- This is the one primitive that makes panels/cards/buttons read as Balatro. (The full parallax/
-- vertex-cache version is a later phase.)

-- scale a color's RGB toward white (>1) or black (<1), keeping alpha.
function brighten(c, f) return { math.min(1, c[1] * f), math.min(1, c[2] * f), math.min(1, c[3] * f), c[4] or 1 } end
function darken(c, f)   return { c[1] * f, c[2] * f, c[3] * f, c[4] or 1 } end

-- the 8 vertices of a rect with its corners cut by `c` (chamfered octagon)
local function chamfer_verts(x, y, w, h, c)
  c = math.min(c, w / 2, h / 2)
  return {
    x + c, y,         x + w - c, y,
    x + w, y + c,     x + w, y + h - c,
    x + w - c, y + h, x + c, y + h,
    x, y + h - c,     x, y + c,
  }
end

-- pixel_rect(x,y,w,h, fill, opts) — opts = { chamfer=4, shadow=true, sox=3, soy=5, emboss=true,
--   border=col, line_w=2 }. All optional; pass fill=nil to skip the fill (outline-only).
function pixel_rect(x, y, w, h, fill, opts)
  opts = opts or {}
  local lg = love.graphics
  local c = opts.chamfer or 4
  if opts.shadow ~= false and (fill or opts.shadow) then
    lg.setColor(G.C.shadow)
    lg.polygon("fill", chamfer_verts(x + (opts.sox or 3), y + (opts.soy or 5), w, h, c))
  end
  if fill then
    lg.setColor(fill)
    lg.polygon("fill", chamfer_verts(x, y, w, h, c))
    if opts.emboss ~= false then
      local lw = opts.line_w or 2
      lg.setLineWidth(lw)
      lg.setColor(brighten(fill, 1.28))                       -- light edge: bottom-left → top → top-right
      lg.line(x, y + h - c,  x, y + c,  x + c, y,  x + w - c, y,  x + w, y + c)
      lg.setColor(darken(fill, 0.62))                         -- dark edge: top-right → bottom → bottom-left
      lg.line(x + w, y + c,  x + w, y + h - c,  x + w - c, y + h,  x + c, y + h,  x, y + h - c)
      lg.setLineWidth(1)
    end
  end
  if opts.border then
    lg.setColor(opts.border)
    lg.setLineWidth(opts.line_w or 2)
    lg.polygon("line", chamfer_verts(x, y, w, h, c))
    lg.setLineWidth(1)
  end
end

-- ---- card-face composition helpers (V0.1 visual pass; shared by founder + tech card faces) ----
-- Clip drawing to a chamfered rounded-rect via a stencil, so full-bleed art doesn't poke past the card
-- corners. pcall-guarded: a context with no stencil buffer just draws unclipped (a tiny corner sliver,
-- hidden under the border) instead of erroring. (Default render path = main framebuffer, has a stencil.)
function clip_chamfer(x, y, w, h, c, fn)
  local lg = love.graphics
  c = math.min(c, w / 2, h / 2)
  local ok = pcall(function()
    lg.stencil(function() lg.polygon("fill", chamfer_verts(x, y, w, h, c)) end, "replace", 1)
    lg.setStencilTest("greater", 0)
  end)
  fn()
  if ok then pcall(lg.setStencilTest) end
end

-- A vertical alpha gradient (col at a_top→a_bot opacity, top→bottom) drawn as N strips (alloc-free) — the
-- legibility wash behind on-art text. Draw it INSIDE a clip_chamfer so it follows the rounded corners.
function fade_rect(x, y, w, h, col, a_top, a_bot, steps)
  steps = steps or 8
  local r, g, b = col[1], col[2], col[3]
  local sh = h / steps
  for i = 0, steps - 1 do
    local a = a_top + (a_bot - a_top) * (steps > 1 and i / (steps - 1) or 1)
    love.graphics.setColor(r, g, b, a)
    love.graphics.rectangle("fill", x, y + i * sh, w, sh + 1)
  end
end

-- A small rounded badge with centred text (salary / cost / rarity pips). Auto-sizes to the text; returns w,h.
function chip(x, y, text, font, fill, txtcol)
  local padx, pady = 7, 3
  local w = text_w(font, text) + padx * 2
  local h = text_h(font) + pady * 2
  pixel_rect(x, y, w, h, fill, { chamfer = math.floor(h / 3), shadow = false, emboss = false })
  draw_text(font, text, x + padx, y + pady, txtcol or G.C.text)
  return w, h
end

-- ---- resolution scaling (P2) -----------------------------------------------------------------
-- Fit the VW×VH virtual layout into the real window, preserving aspect. G.VIEW holds the transform;
-- vmap/vmouse convert real window points back to virtual coords for input.

-- (P3) Build G.FONTS at a rasterization scale `rs` (1 = the virtual base size). draw_text() divides by
-- G.FONT_S so on-screen size always equals the virtual base size — so flipping `rs` up later (to the live
-- display scale, for pixel-perfect crispness at any window size, à la Balatro) is a one-line change that
-- doesn't disturb layout. For now rs=1 (bigger base sizes carry the legibility win; nearest stays sharp).
function rebuild_fonts(rs)
  if not (love.graphics and G.FONT_FILE and G.FONT_SIZES) then return end
  rs = rs or 1
  G.FONT_S = rs
  G.FONTS = {}
  for name, base in pairs(G.FONT_SIZES) do
    local px = math.max(8, math.floor(base * rs + 0.5))
    local f = love.graphics.newFont(G.FONT_FILE, px); f:setFilter("nearest", "nearest")
    local fb = love.graphics.newFont(px); fb:setFilter("nearest", "nearest")   -- vector fallback (no tofu)
    f:setFallbacks(fb)
    G.FONTS[name] = f
  end
end

function update_view(winw, winh)
  local s = math.min(winw / G.VW, winh / G.VH)
  G.VIEW.scale = s
  G.VIEW.ox = math.floor((winw - G.VW * s) / 2)
  G.VIEW.oy = math.floor((winh - G.VH * s) / 2)
  if not G.FONTS then rebuild_fonts(1) end                                       -- build once (rs=1)
end

-- text in VIRTUAL coords, crisp at any scale: the glyph atlas is base×G.FONT_S, so we counter the world
-- scale (1/s) → drawn 1:1 on screen at the correct virtual size, with a 1px drop shadow. w/align → printf.
function draw_text(font, str, x, y, col, w, align)
  if not font then return end
  local s = G.FONT_S or 1
  love.graphics.setFont(font)
  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.scale(1 / s, 1 / s)
  love.graphics.setColor(0, 0, 0, 0.5)
  if w then love.graphics.printf(str, 2, 2, w * s, align or "left") else love.graphics.print(str, 2, 2) end
  love.graphics.setColor(col or G.C.text)
  if w then love.graphics.printf(str, 0, 0, w * s, align or "left") else love.graphics.print(str, 0, 0) end
  love.graphics.pop()
end

-- VIRTUAL text metrics (the live atlas is ×G.FONT_S, so divide back) for layout/centering/wrapping
function text_w(font, str) return font:getWidth(str) / (G.FONT_S or 1) end
function text_h(font) return font:getHeight() / (G.FONT_S or 1) end

function vmap(x, y)                              -- raw window point → virtual coords
  local v = G.VIEW
  return (x - v.ox) / v.scale, (y - v.oy) / v.scale
end

function vmouse()                               -- current mouse in virtual coords
  return vmap(love.mouse.getPosition())
end

local function draw_pool(pool)
  for _, o in ipairs(pool) do
    if not o.REMOVED and o.states and o.states.visible and o.draw then
      o:draw()
    end
  end
end

-- per-area draw-rank: lower draws first (under). Within an area, cards draw by their position index, so the
-- hand's z-order matches its left→right layout. (Was: pool-insertion order = tech-LAYER-grouped → e.g.
-- Knowledge always on top regardless of hand position.) Hand/play rows keep this order even while a card is
-- hovered or selected: every card to the right must remain above the card immediately to its left.
local CARD_AREA_Z = { deck = 1, jokers = 2, play = 3, hand = 4 }
function draw_all()
  draw_pool(G.I.CARDAREA)   -- areas (mostly invisible / debug outline)
  local list = {}
  for _, c in ipairs(G.I.CARD) do
    if not c.REMOVED and c.states and c.states.visible and c.draw then
      local area_type = c.area and c.area.config and c.area.config.type
      local rank = CARD_AREA_Z[area_type] or 5
      local idx = 0
      if c.area and c.area.cards then
        for i = 1, #c.area.cards do if c.area.cards[i] == c then idx = i; break end end
      end
      local strict_row_order = area_type == "hand" or area_type == "play"
      local lift = (not strict_row_order and ((c.states.hover and c.states.hover.is) or c.selected)) and 900 or 0
      c._zsort = rank * 1000 + idx + lift
      list[#list + 1] = c
    end
  end
  table.sort(list, function(a, b)
    if a._zsort == b._zsort then return (a.ID or 0) < (b.ID or 0) end
    return a._zsort < b._zsort
  end)
  for _, c in ipairs(list) do c:draw() end
  -- G.I.UIBOX reserved for the declarative UI module
end
