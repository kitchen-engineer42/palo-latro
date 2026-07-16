-- game/card.lua — Card(Moveable): the universal card object. Points at a CENTER by key + holds
-- an `ability` instance copy; behavior resolves by string (founders later add `calculate`
-- branches). get_users() is a METHOD (not a constant) so the compatibility graph can make Users
-- contextual later with no caller change.

local layers = require("data.layers")
local Coverage = require("game.coverage")
local TechLifecycle = require("game.tech_lifecycle")
local TechModifiers = require("game.tech_modifiers")
local TechLaws = require("game.tech_laws")

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

-- Tech seals are defined with their mechanics in one canonical module. Keep
-- these aliases for presentation/mod-loader callers that historically looked
-- them up on Card; Founders no longer render or evaluate seals.
Card.SEALS = TechModifiers.SEALS
Card.SEAL_KEYS = TechModifiers.SEAL_KEYS

local function modifier_key(subject, field)
  if not subject then return nil end
  if field == "enhancement" then return subject.enhancement or subject.enh end
  return subject[field]
end

local function modifier_definition(kind, key)
  if not key then return nil end
  return TechModifiers.definition(kind, key)
end

local function title_key(key)
  local value = tostring(key or ""):gsub("_", " ")
  return value:gsub("(%a)([%w']*)", function(first, rest) return first:upper() .. rest end)
end

-- The presentation contract for persistent Tech modifiers. Mechanics remain in
-- game.tech_modifiers; every player-facing surface consumes these same rows so
-- a badge, tooltip, Deck View, and headless observation cannot rename a rule.
function Card.tech_modifier_rows(subject)
  local out = {}
  for _, spec in ipairs({
    { kind = "enhancement", field = "enhancement", prefix = "EN" },
    { kind = "seal", field = "seal", prefix = "SE" },
  }) do
    local key = modifier_key(subject, spec.field)
    if key then
      local definition = modifier_definition(spec.kind, key) or {}
      local label = definition.label or definition.name or title_key(key)
      local state, state_label = subject.modifier_state, nil
      if spec.kind == "enhancement" and type(state) == "table" then
        local uses_left, deprecated
        for state_key, value in pairs(state) do
          if tostring(state_key):match("uses_left$") and type(value) == "number" then uses_left = value end
          if tostring(state_key):match("deprecated$") and value == true then deprecated = true end
        end
        if deprecated then state_label = "DEPRECATED"
        elseif uses_left ~= nil then state_label = tostring(uses_left) .. " SHIPS LEFT" end
      end
      local desc = definition.desc or definition.description or ""
      if state_label then desc = desc .. " Current state: " .. state_label .. "." end
      out[#out + 1] = {
        kind = spec.kind,
        key = key,
        label = label,
        short = definition.short or definition.abbr or label,
        desc = desc,
        state_label = state_label,
        col = definition.col or definition.color
          or (spec.kind == "enhancement" and G.C.users or { 0.90, 0.78, 0.35, 1 }),
        prefix = spec.prefix,
      }
    end
  end

  local marks = type(subject and subject.law_marks) == "table" and subject.law_marks or {}
  local law_col = (G.C and G.C.arr) or { 0.76, 0.52, 0.94, 1 }
  local function add_law(key, label, short, desc, state_label, col)
    out[#out + 1] = {
      kind = "law", key = key, label = label, short = short or label,
      desc = desc or "", state_label = state_label, col = col or law_col, prefix = "LW",
    }
  end
  if marks.amdahl_bottleneck then
    add_law("amdahl_bottleneck", "Amdahl Bottleneck", "AMD",
      "Every other owned Tech has +10 Users while this remains the bottleneck.", "ACTIVE")
  end
  if marks.well_formed then
    add_law("well_formed", "Well-Formed", "WELL",
      "Negative Clashes and Substitute pairs touching this Tech are ignored.", "ACTIVE",
      (G.C and G.C.win) or { 0.42, 0.86, 0.58, 1 })
  end
  local wirth = marks.wirth_bloat
  if type(wirth) == "table" then
    local pct = math.floor((tonumber(wirth.current_factor) or 0.85) * 100 + 0.5)
    add_law("wirth_bloat", "Wirth Bloat", "WIR",
      "Users are 85% when applied, 70% next Ante, then 50% thereafter.", tostring(pct) .. "% USERS",
      (G.C and G.C.lose) or { 0.92, 0.38, 0.34, 1 })
  end
  if subject and (subject.layer_locked or marks.hyrum_layer) then
    add_law("hyrum_layer", "Hyrum Layer-Lock", "LOCK",
      "This copied Layer cannot be changed.", "LOCKED",
      (G.C and G.C.mult) or { 0.94, 0.62, 0.36, 1 })
  end

  local sticker_rows = {
    tl_metcalfes_law = { "Metcalfe Users", "MET" },
    tl_gustafsons_law = { "Gustafson Users", "GUS" },
    tl_sturgeons_law = { "Sturgeon Users", "STU" },
  }
  for _, sticker in ipairs((subject and subject.stickers) or {}) do
    local spec = sticker_rows[sticker.source]
    if spec and sticker.field == "users" and sticker.mode == "add" then
      local amount = math.max(0, tonumber(sticker.amount) or 0)
      add_law(sticker.source, spec[1], spec[2],
        "+" .. tostring(amount) .. " persistent Users from " .. spec[1] .. ".",
        "+" .. tostring(amount) .. " USERS", (G.C and G.C.users) or { 0.42, 0.72, 0.96, 1 })
    end
  end
  return out
end

-- A Tech modifier may replace the native Layer identity. Keep the label shared
-- between the face, Deck View, tooltip, and headless protocol.
function Card.tech_layer_label(subject, center)
  subject = subject or {}
  if center and not subject.center then
    local display = {}
    for key, value in pairs(subject) do display[key] = value end
    display.center, display.layer = center, subject.layer or center.layer
    subject = display
  end
  if subject.layer_override ~= nil then
    return Coverage.display_layer(subject) or "No Layer"
  end
  local options = TechModifiers.coverage_options(subject)
  if options ~= nil then
    if #options == 0 then return "No Layer" end
    if #options > 1 then return "Any Layer" end
    return options[1]
  end
  return Coverage.display_layer(subject)
end

function Card.tech_modifier_summary(subject)
  local labels = {}
  for _, row in ipairs(Card.tech_modifier_rows(subject)) do
    local label = row.label
    if row.state_label then label = label .. " [" .. row.state_label .. "]" end
    labels[#labels + 1] = label
  end
  return table.concat(labels, " · ")
end

function Card.tech_modifier_detail(subject)
  local lines = {}
  for _, row in ipairs(Card.tech_modifier_rows(subject)) do
    local kind = row.kind:gsub("^%l", string.upper)
    lines[#lines + 1] = kind .. " · " .. row.label .. (row.desc ~= "" and (": " .. row.desc) or "")
  end
  return table.concat(lines, "\n")
end

-- Layer "suit" abbreviations for the readable top-left corner when logo art is unavailable.
Card.LAYER_ABBR = { Frontend = "FE", Backend = "BE", Data = "DA", Infra = "IN", AI = "AI", Knowledge = "KN" }

-- a concise, game-facing effect line derived from the compiled DSL (P2): "+15 Users" / "×2 Rev" /
-- "Earns Cash" / "Retrigger" … Best-effort + accurate to the real magnitudes; falls back to the effect
-- category. Shown on the card face + as the tooltip headline so play-time reading is quick.
local function fmt1(x)  -- compact number: integer if whole, else 1 decimal
  if x % 1 == 0 then return tostring(math.floor(x)) end
  return string.format("%.1f", x)
end

local function dsl_specs(dsl)
  if not dsl then return {} end
  return dsl.clauses or { dsl }
end

local function state_label(key)
  local label = tostring(key or "state"):gsub("_", " ")
  return (label:gsub("^%l", string.upper))
end

function Card.founder_state_rows(center, card)
  local rows, seen = {}, {}
  local cfg = card and card.ability and card.ability.config or {}
  for _, spec in ipairs(dsl_specs(center and center.dsl)) do
    for _, op in ipairs(spec.ops or {}) do
      if op.k == "state" and op.mode ~= "clear" and op.state and not seen[op.state] then
        seen[op.state] = true
        rows[#rows + 1] = {
          key = op.state,
          label = state_label(op.state),
          value = cfg["_state_" .. op.state] or 0,
          cap = op.cap,
        }
      end
    end
  end
  return rows
end

local function state_summary(center, card)
  local row = Card.founder_state_rows(center, card)[1]
  if not row then return nil end
  local value = fmt1(row.value)
  return row.label .. " " .. value .. (row.cap and ("/" .. fmt1(row.cap)) or "")
end

function Card.effect_brief(center, card)
  if not center then return "" end
  local d = center.dsl
  -- 1) LIVE accumulated value (owned card + accumulator op) — the real number this run, on the card face.
  -- Scan ALL ops for the first growing accumulator (post-audit DSLs may place acc behind a per-op gate, not first).
  if card and d then
    local op
    for _, spec in ipairs(dsl_specs(d)) do
      for _, o in ipairs(spec.ops or {}) do
        if not o.key and o.k == "acc" and (o.field == "x_mult" or o.field == "mult" or o.field == "chips") then
          op = o; break
        end
      end
      if op then break end
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
  local live_state = card and state_summary(center, card)
  if live_state and center.effect_brief and center.effect_brief ~= "" then
    return center.effect_brief .. "  ·  " .. live_state
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
  if card and d then                                  -- live accumulator value (the real number this run)
    local op
    for _, spec in ipairs(dsl_specs(d)) do
      for _, o in ipairs(spec.ops or {}) do
        if not o.key and o.k == "acc" and (o.field == "x_mult" or o.field == "mult" or o.field == "chips") then
          op = o; break
        end
      end
      if op then break end
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
  local live_state = card and state_summary(center, card)
  if live_state then return live_state end
  if center.face_tag and center.face_tag ~= "" then return center.face_tag end
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

-- Canonical per-Founder economics for presentation/protocol consumers. Payroll due can still be
-- modified globally by the Market, boss, target, and salary relief; this projection intentionally
-- stops at the card's own live Salary (including Rental) and effect scale.
function Card.founder_terms(card, center)
  center = center or (card and card.center) or {}
  local cfg = card and card.ability and card.ability.config or {}
  local base_salary = center.salary or 0
  local salary = cfg._salary
  if salary == nil then
    salary = base_salary
    if cfg._distilled then salary = salary * 0.5 end
  end
  local rental_salary_mult = cfg._rental_salary_mult or 1
  return {
    base_salary = base_salary,
    effective_salary = salary * rental_salary_mult,
    effect_scale = cfg._effect_scale or 1,
    distilled = cfg._distilled == true,
    rental_salary_mult = rental_salary_mult,
  }
end

-- Shared full-bleed founder face — the single source of truth used by BOTH the jokers row
-- (Card:draw_body) and the immediate-mode shop offers (ui.lua), so they look identical.
-- t = {x,y,w,h} target rect; center = founder center; opts = { card=<live Card or nil>, border=, line_w= }.
function Card.draw_founder_face(t, center, opts)
  opts = opts or {}
  local lg = love.graphics
  local card = opts.card
  local edition = card and card.edition
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

  if center and center.salary then                                   -- live / base salary (top-left of the art)
    local terms = Card.founder_terms(card, center)
    local salary_label = "$" .. fmt1(terms.effective_salary)
    if terms.effective_salary ~= terms.base_salary then
      salary_label = salary_label .. " / $" .. fmt1(terms.base_salary)
    end
    local _, salary_h = chip(t.x + 5, t.y + 5, salary_label, G.FONTS.tiny,
      { 0.08, 0.10, 0.15, 0.92 }, G.C.mult)
    if card and (terms.distilled or terms.effect_scale ~= 1) then
      local effect_pct = math.floor(terms.effect_scale * 100 + 0.5)
      chip(t.x + 5, t.y + 8 + salary_h,
        (terms.distilled and "DISTILLED " or "EFFECT ") .. effect_pct .. "%",
        G.FONTS.tiny, { 0.08, 0.10, 0.15, 0.92 }, G.C.win)
    end
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
  self.source = args.source                           -- per-instance Tech acquisition provenance
  self.acquired_ante = args.acquired_ante
  self.migrated_from = args.migrated_from
  self.edition = args.edition
  self.enhancement = args.enhancement or args.enh
  self.seal = args.seal
  self.modifier_state = args.modifier_state and deep_copy(args.modifier_state) or nil
  self.stickers = args.stickers and deep_copy(args.stickers) or nil
  self.layer_override = args.layer_override
  self.layer_locked = args.layer_locked == true
  self.law_marks = args.law_marks and deep_copy(args.law_marks) or nil
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
function Card.tech_users(subject, center, era, game)
  local users, status, before_decay = TechLifecycle.effective_users(subject, center, era)
  users = TechModifiers.users(subject, users)
  users = TechLaws.users(subject, users, game or (G and G.GAME))
  return users, status, before_decay
end

function Card:get_users(context)
  local era = type(context) == "table" and context.era or context
  if self.center and self.center.set == "TechCard" then return Card.tech_users(self, self.center, era) end
  return TechLifecycle.effective_users(self, self.center, era)
end

function Card:tech_status(context)
  local era = type(context) == "table" and context.era or context
  return TechLifecycle.status(self.center, era)
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

-- Compact acquisition history shared by card tooltips and the deck-of-record
-- overlay. Provenance is deliberately instance data: two copies of the same
-- Tech may have entered the run through different decisions.
function Card.provenance_label(subject)
  subject = subject or {}
  local source = tostring(subject.source or "unknown"):gsub("_", " ")
  source = source:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest
  end)
  local out = source
  if subject.acquired_ante then out = out .. " · Ante " .. tostring(subject.acquired_ante) end
  if subject.migrated_from then out = out .. " · migrated from " .. tostring(subject.migrated_from) end
  return out
end

-- Shared Tech face used by live cards, Tech Evaluation offers, and any future
-- read-only preview. `subject` may be a live Card or a plain master_deck entry.
-- The center stays immutable; lifecycle/provenance remain per instance.
function Card.draw_tech_face(t, center, opts)
  opts = opts or {}
  local lg = love.graphics
  local subject = opts.card or opts.entry or {}
  local L = Card.tech_layer_label(subject, center)
  local native_layer = (L == "Any Layer" or L == "No Layer") and nil or L
  local col = (native_layer and layers[native_layer] and layers[native_layer].color)
    or (L == "Any Layer" and G.C.arr or G.C.panel_dim)
  local pip = (G.TECH_ART and center and G.TECH_ART[center.key])
    or (G.SUIT_ART and native_layer and G.SUIT_ART[native_layer])
  local has_tech_mark = G.TECH_ART and center and G.TECH_ART[center.key]
  local effective_users, status, before_decay = Card.tech_users(subject, center, opts.era)
  local modifier_rows = Card.tech_modifier_rows(subject)

  -- Warm-white poker stock replaces the old full layer-colour placeholder. Layer colour remains a
  -- restrained trim cue; the individual parody mark now carries the card's visual identity.
  pixel_rect(t.x, t.y, t.w, t.h, { 0.94, 0.92, 0.84, 1 }, { chamfer = 5 })
  lg.setColor(col[1], col[2], col[3], 0.85)
  lg.rectangle("fill", t.x + 4, t.y + 4, 4, t.h - 8)
  lg.rectangle("fill", t.x + t.w - 8, t.y + 4, 4, t.h - 8)

  if pip then
    local iw, ih = pip:getDimensions()
    local s = math.min((t.w * (has_tech_mark and 0.62 or 0.52)) / iw, (t.h * 0.42) / ih)
    lg.setColor(1, 1, 1, has_tech_mark and 0.96 or 0.36)
    lg.draw(pip, t.x + (t.w - iw * s) / 2, t.y + t.h * 0.12, 0, s, s)
  end

  lg.setColor(0.08, 0.09, 0.12, 0.88)
  lg.rectangle("fill", t.x + 8, t.y + t.h * 0.54, t.w - 16, t.h * 0.25, 4, 4)
  draw_text(G.FONTS.small, (center and center.name) or "?", t.x + 10, t.y + t.h * 0.565,
    G.C.text, t.w - 20, "center")

  local base_users = subject.base_users
  if base_users == nil then base_users = (center and center.base_users) or 0 end
  local enhancement_deprecated = false
  for _, row in ipairs(modifier_rows) do
    if row.kind == "enhancement" and row.state_label == "DEPRECATED" then enhancement_deprecated = true end
  end
  local users_col = (status.state == "deprecated" or enhancement_deprecated) and G.C.lose
    or ((effective_users ~= before_decay or before_decay ~= base_users) and G.C.win or G.C.users)
  draw_text(G.FONTS.normal, tostring(effective_users), t.x + 8, t.y + 6, users_col)
  local rev_label = subject.rev_sticker_label and subject:rev_sticker_label()
  if rev_label then
    local rw, rh = 58, 24
    pixel_rect(t.x + t.w - rw - 6, t.y + 6, rw, rh, { 0.08, 0.10, 0.15, 0.90 },
      { chamfer = 4, shadow = false, emboss = false })
    draw_text(G.FONTS.tiny, rev_label, t.x + t.w - rw - 4, t.y + 8, G.C.mult, rw - 4, "center")
  end

  -- Persistent modifiers are acquisition decisions, so they must be legible on
  -- the face before a player adopts a draft/Evaluation offer. The compact badge
  -- uses a stable two-letter family prefix; the full rule remains in the detail
  -- tooltip and Deck View.
  local badge_w = math.min(70, t.w * 0.49)
  for index, row in ipairs(modifier_rows) do
    local badge_h, badge_gap = 18, 2
    local bx = t.x + t.w - badge_w - 6
    local by = t.y + (rev_label and 34 or 6) + (index - 1) * (badge_h + badge_gap)
    local short = tostring(row.short or row.label or row.key)
    if row.state_label == "DEPRECATED" then short = "DEPR"
    elseif row.state_label then
      local uses = row.state_label:match("^(%d+)")
      short = short:sub(1, 3) .. (uses and (" " .. uses) or "")
    end
    if #short > 5 then short = short:sub(1, 5) end
    pixel_rect(bx, by, badge_w, badge_h, { 0.08, 0.10, 0.15, 0.94 },
      { chamfer = 3, border = row.col, line_w = 1, shadow = false, emboss = false })
    draw_text(G.FONTS.tiny, row.prefix .. " " .. short, bx + 3,
      by + (badge_h - text_h(G.FONTS.tiny)) / 2, row.col, badge_w - 6, "center")
  end
  if pip then
    local ps = 22 / pip:getWidth()
    lg.setColor(1, 1, 1, has_tech_mark and 0.98 or 0.75)
    lg.draw(pip, t.x + 9, t.y + 40, 0, ps, ps)
    lg.draw(pip, t.x + t.w - 9, t.y + t.h - 40, math.pi, ps, ps)
  else
    draw_text(G.FONTS.tiny, Card.LAYER_ABBR[L] or (L or ""):sub(1, 2):upper(),
      t.x + 9, t.y + 42, G.C.black)
  end

  -- A deprecated card must read as a gameplay state, not merely as a lower
  -- number. It owns the footer instead of colliding with the Layer label.
  if status.state == "deprecated" then
    local label = ("DEPRECATED -%d%%"):format(math.floor(status.penalty * 100 + 0.5))
    local badge_h = math.max(22, text_h(G.FONTS.tiny) + 7)
    local badge_y = t.y + t.h - badge_h - 4
    lg.setColor(0.56, 0.16, 0.14, 0.96)
    lg.rectangle("fill", t.x + 8, badge_y, t.w - 16, badge_h, 3, 3)
    draw_text(G.FONTS.tiny, label, t.x + 10,
      badge_y + (badge_h - text_h(G.FONTS.tiny)) / 2, G.C.text, t.w - 20, "center")
  else
    lg.setFont(G.FONTS.normal)
    lg.setColor(col)
    lg.printf((L or ""):upper(), t.x + 8,
      t.y + t.h - text_h(G.FONTS.normal) - 5, t.w - 16, "center")
  end

  local modifier_border = modifier_rows[1] and modifier_rows[1].col
  local border = opts.border or (status.state == "deprecated" and G.C.lose or modifier_border or G.C.border)
  pixel_rect(t.x, t.y, t.w, t.h, nil,
    { chamfer = 6, border = border, line_w = opts.line_w or (status.state == "deprecated" and 3 or 2) })
  return { effective_users = effective_users, before_decay = before_decay, status = status, layer = L,
    modifiers = modifier_rows }
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
    if self.states.hover.is or (self.states.focus and self.states.focus.is) or self.selected then -- lean toward cursor
      local mx, my
      if G.CONTROLLER and G.CONTROLLER.cursor then mx, my = G.CONTROLLER.cursor.x, G.CONTROLLER.cursor.y
      else mx, my = vmouse() end
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
    local active = self.states.hover.is or (self.states.focus and self.states.focus.is)
    local bcol = self.selected and G.C.lose or (active and G.C.hover or (ed and ed.col) or G.C.border)
    Card.draw_founder_face(t, self.center, { card = self, border = bcol, line_w = self.selected and 3 or (ed and 3 or 2) })
    if G.STATE == G.STATES.TARGET_SELECT and G.PENDING_CONSUMABLE
        and G.PENDING_CONSUMABLE.target_area_name == "founder" then
      local eligible = require("game.consumables").can_target(
        G.PENDING_CONSUMABLE.card, self, G.GAME)
      if not eligible then
        lg.setColor(0.04, 0.05, 0.08, 0.62)
        lg.rectangle("fill", t.x, t.y, t.w, t.h, 6, 6)
        lg.setColor((G.C.lose or { 0.9, 0.25, 0.25, 1 }))
        lg.setLineWidth(2); lg.rectangle("line", t.x, t.y, t.w, t.h, 6, 6); lg.setLineWidth(1)
      end
    end
    return
  end

  if self.center and self.center.set == "Consumable" then     -- Roadmap consumable face → the art IS the card
    local active = self.states.hover.is or (self.states.focus and self.states.focus.is)
    local bcol = self.selected and G.C.select or (active and G.C.hover or G.C.border)
    Card.draw_consumable_face(t, self.center, { card = self, border = bcol, line_w = self.selected and 3 or 2 })
    return
  end

  -- TECH CARD: shared preview/live renderer. Lifecycle loss is visible on the
  -- face and uses the same calculation as scoring.
  local bcol, bw = G.C.border, 2
  if self.selected then bcol, bw = G.C.select, 3
  elseif self.states.hover.is or (self.states.focus and self.states.focus.is) then bcol, bw = G.C.hover, 2 end
  local status = self:tech_status()
  if status.state == "deprecated" and not self.selected
      and not (self.states.hover.is or (self.states.focus and self.states.focus.is)) then
    bcol, bw = G.C.lose, 3
  end
  Card.draw_tech_face(t, self.center, { card = self, border = bcol, line_w = bw })
  if G.STATE == G.STATES.TARGET_SELECT and G.PENDING_CONSUMABLE
      and G.PENDING_CONSUMABLE.target_area_name == "hand" then
    local eligible = require("game.consumables").can_target(
      G.PENDING_CONSUMABLE.card, self, G.GAME)
    if not eligible then
      lg.setColor(0.04, 0.05, 0.08, 0.62)
      lg.rectangle("fill", t.x, t.y, t.w, t.h, 6, 6)
      lg.setColor((G.C.lose or { 0.9, 0.25, 0.25, 1 }))
      lg.setLineWidth(2); lg.rectangle("line", t.x, t.y, t.w, t.h, 6, 6); lg.setLineWidth(1)
    end
  end
end

return Card
