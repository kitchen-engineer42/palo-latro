-- game/ui.lua — game-specific rendering over a retained UIBox target tree. The existing renderers
-- still draw the authored fixed-pixel screens; UI.prepare builds their interactive geometry before
-- input, so drawing is no longer responsible for hit-test or focus ownership.

local UI = {}
UI.rects = {}

local lg = love.graphics
local Juice = require("game.juice")
local Shop = require("game.shop")
local PackPresentation = require("game.pack_presentation")
local RunState = require("game.runstate")
local Coverage = require("game.coverage")
local UIBox = require("engine.uibox")
local Collection = require("game.collection")
local Wiki = require("game.wiki")
local Options = require("game.options")
local Guidance = require("game.guidance")
local Bosses = require("game.bosses")
local Deck = require("game.deck")
local Centers = require("game.centers")
local AIMaturity = require("game.ai_maturity")
local Economy = require("game.economy")
local Pricing = require("game.pricing")
local Markets = require("game.markets")
local Leads = require("game.leads")
local Consumables = require("game.consumables")
local Moonshots = require("game.moonshots")
local FounderActions = require("game.founder_actions")
local CardStack = require("game.card_stack")
local ShopView = require("game.shop_view")
local SignaturePair = require("game.signature_pair")

local function roadmap_pack(kind)
  return kind == "tech_law" or kind == "moonshot"
end

local function pack_command(action, pack_open, index)
  return {
    action = action,
    payload = { open_id = pack_open and pack_open.open_id or nil, index = index },
  }
end

-- One geometry projection feeds retained input targets and the immediate-mode
-- term sheet. The modal deliberately starts to the right of the 332px run rail.
local function founder_negotiation_geometry(W, H, view)
  local play_x, pad = 332, 28
  local panel = { x = play_x + pad, y = 86, w = W - play_x - pad * 2, h = H - 132 }
  local content_x = panel.x + 238
  local content_w = panel.w - 266
  local geometry = {
    panel = panel,
    portrait = { x = panel.x + 30, y = panel.y + 116, w = 178, h = 228 },
    rules = { x = content_x, y = panel.y + 116, w = content_w, h = 50 },
    prompt = { x = content_x, y = panel.y + 174, w = content_w, h = 52 },
    standard = { x = content_x, y = panel.y + panel.h - 62, w = 260, h = 40 },
    walk = { x = content_x + content_w - 184, y = panel.y + panel.h - 62, w = 184, h = 40 },
    choices = {},
  }
  if view and view.phase == "question" then
    for i = 1, 3 do
      geometry.choices[i] = { x = content_x, y = panel.y + 246 + (i - 1) * 70,
        w = content_w, h = 56 }
    end
  else
    geometry.continue = { x = content_x, y = panel.y + 486, w = content_w, h = 48 }
  end
  return geometry
end

local function lead_state(game)
  local view = Leads.view(game)
  return type(view) == "table" and view or { offers = {}, pending = {}, history = {}, can_skip = false }
end

local function lead_status(row)
  if not row then return "" end
  if row.key == "warm_intro" then return "next shop: first Founder $0" end
  if row.amount_cash ~= nil then
    return "+$" .. format_number(row.amount_cash) .. " on next blind clear"
  end
  if row.amount ~= nil then
    return "+$" .. format_number(row.amount) .. " on next blind clear"
  end
  if row.pack_key then return "next shop: free Hiring Round" end
  if row.edition then
    local edition = Card and Card.EDITIONS and Card.EDITIONS[row.edition]
    return "next Founder: " .. tostring((edition and edition.label) or row.edition)
  end
  return row.description or row.trigger or row.status or "queued"
end

local function lead_detail(row)
  if not row then return "" end
  if row.key == "warm_intro" then return "The first Founder in the next shop costs $0." end
  if row.amount_cash ~= nil or row.amount ~= nil then
    return "Clear the next played blind: +$"
      .. format_number(row.amount_cash or row.amount) .. " Cash."
  end
  if row.pack_key then return "The next shop adds a free Hiring Round." end
  if row.edition then
    local edition = Card and Card.EDITIONS and Card.EDITIONS[row.edition]
    return "The next Founder acquired gains "
      .. tostring((edition and edition.label) or row.edition) .. "."
  end
  return row.description or lead_status(row)
end

local function lead_line(row)
  if not row then return "" end
  local status = lead_status(row)
  return tostring(row.name or row.key or "Lead") .. (status ~= "" and (" · " .. status) or "")
end

local function skipped_with_lead(state, ante, blind_idx)
  for _, row in ipairs((state and state.history) or {}) do
    local source_ante = row.source_ante or row.ante
    local source_blind = row.source_blind_idx or row.blind_idx
    if source_ante == ante and source_blind == blind_idx then return true end
  end
  return false
end

local function tech_offer_center(option)
  if type(option) == "string" then return Centers.get(option) end
  if type(option) ~= "table" then return nil end
  return option.center or Centers.get(option.key or option.center_key)
end

local function tech_offer_subject(option, center)
  if type(option) == "table" then return option end
  return { key = option, center = center }
end

local function cursor()
  if G.CONTROLLER and G.CONTROLLER.cursor then return G.CONTROLLER.cursor.x, G.CONTROLLER.cursor.y end
  return vmouse()
end

local SHOP_RARITY_COL = {
  Legendary = { 0.80, 0.45, 0.42, 1 }, Rare = { 0.62, 0.50, 0.78, 1 },
  Uncommon = { 0.45, 0.62, 0.78, 1 }, Common = { 0.50, 0.66, 0.52, 1 },
  ordinary = { 0.44, 0.64, 0.78, 1 }, special = { 0.92, 0.62, 0.24, 1 },
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

local function button_hovered(r, fallback)
  if G.CONTROLLER then
    local function matches(node)
      local bounds = node and (node.VT or node.T)
      return bounds and bounds.x == r.x and bounds.y == r.y
        and bounds.w == r.w and bounds.h == r.h or false
    end
    return matches(G.CONTROLLER.hovering) or matches(G.CONTROLLER.focused)
  end
  return fallback == true
end

local function draw_button(r, label, enabled, hovered, font)
  hovered = button_hovered(r, hovered)
  local pressed = enabled and hovered and G.CONTROLLER and G.CONTROLLER.clicked == G.CONTROLLER.hovering
    and G.CONTROLLER.hid and G.CONTROLLER.hid.buttons[1] == true
  local col = enabled and (hovered and G.C.btn_hi or G.C.btn) or G.C.btn_off
  local ox, oy = 0, 0
  if pressed then ox, oy = 2, 2 end                          -- sink into the page on press
  pixel_rect(r.x + ox, r.y + oy, r.w, r.h, col,
    { chamfer = 4, border = G.C.border, line_w = 2, shadow = not pressed, soy = 4 })
  font = font or G.FONTS.normal
  UI.text(font, label, r.x + ox, r.y + oy + (r.h - text_h(font)) / 2,
    enabled and G.C.text or G.C.text_dim, r.w, "center")
end

local function collection_geometry(W, view)
  local geometry = { categories = {}, filters = {} }
  geometry.back = { x = 24, y = 22, w = 128, h = 42 }
  local cat_gap, cat_x = 10, 34
  local cat_w = (W - cat_x * 2 - cat_gap * (#Collection.CATEGORIES - 1)) / #Collection.CATEGORIES
  for index = 1, #Collection.CATEGORIES do
    geometry.categories[index] = { x = cat_x + (index - 1) * (cat_w + cat_gap),
      y = 82, w = cat_w, h = 46 }
  end
  local filters = view.filters or {}
  local filter_gap = 10
  local filter_w = math.min(150, (W - 80 - filter_gap * math.max(0, #filters - 1)) / math.max(1, #filters))
  local filter_x = (W - (#filters * filter_w + math.max(0, #filters - 1) * filter_gap)) / 2
  for index = 1, #filters do
    geometry.filters[index] = { x = filter_x + (index - 1) * (filter_w + filter_gap),
      y = 146, w = filter_w, h = 38 }
  end
  geometry.prev = { x = W / 2 - 160, y = 752, w = 120, h = 38 }
  geometry.next = { x = W / 2 + 40, y = 752, w = 120, h = 38 }
  return geometry
end

local function wiki_geometry(W, H, view)
  local panel = { x = 18, y = 16, w = W - 36, h = H - 32 }
  local geometry = { panel = panel, categories = {}, facets = {}, items = {}, letters = {},
    related = {}, backlinks = {} }
  geometry.close = { x = panel.x + panel.w - 116, y = panel.y + 14, w = 96, h = 36 }
  geometry.search = { x = panel.x + 22, y = panel.y + 112, w = 370, h = 42 }
  geometry.clear = { x = geometry.search.x + geometry.search.w - 66, y = geometry.search.y + 6, w = 58, h = 30 }
  local cat_x, cat_y, cat_gap = panel.x + 150, panel.y + 62, 6
  local cat_w = (panel.w - 170 - cat_gap * (#Wiki.CATEGORIES - 1)) / #Wiki.CATEGORIES
  for index = 1, #Wiki.CATEGORIES do
    geometry.categories[index] = { x = cat_x + (index - 1) * (cat_w + cat_gap), y = cat_y, w = cat_w, h = 34 }
  end
  local facet_x, facet_y, facet_gap = panel.x + 420, panel.y + 112, 7
  local facet_w = math.min(116, (panel.w - 448 - facet_gap * math.max(0, #view.facets - 1)) / math.max(1, #view.facets))
  for index = 1, #view.facets do
    geometry.facets[index] = { x = facet_x + (index - 1) * (facet_w + facet_gap), y = facet_y, w = facet_w, h = 34 }
  end
  local letter_w = 27
  for index = 1, 26 do
    local col, row = (index - 1) % 13, math.floor((index - 1) / 13)
    geometry.letters[index] = { x = panel.x + 28 + col * letter_w,
      y = panel.y + 166 + row * 25, w = letter_w - 3, h = 22 }
  end
  local item_x, item_y, item_w, item_h = panel.x + 22, panel.y + 222, 370, 37
  for index = 1, Wiki.PAGE_SIZE do
    geometry.items[index] = { x = item_x, y = item_y + (index - 1) * item_h, w = item_w, h = item_h - 3 }
  end
  geometry.prev = { x = item_x, y = panel.y + panel.h - 48, w = 104, h = 32 }
  geometry.next = { x = item_x + item_w - 104, y = geometry.prev.y, w = 104, h = 32 }
  geometry.body = { x = panel.x + 420, y = panel.y + 166, w = panel.w - 442, h = panel.h - 184 }
  geometry.scroll_up = { x = panel.x + panel.w - 84, y = geometry.body.y + 4, w = 28, h = 28 }
  geometry.scroll_down = { x = panel.x + panel.w - 48, y = geometry.body.y + 4, w = 28, h = 28 }
  local oy = -(view.scroll or 0) * 54
  local has_story = view.selected and view.selected.story and view.selected.story ~= ""
  local link_y = geometry.body.y + (has_story and 394 or 260) + oy
  local col_w = (geometry.body.w - 26) / 2
  for index = 1, Wiki.RELATED_LIMIT do
    geometry.related[index] = { x = geometry.body.x + 2, y = link_y + 28 + (index - 1) * 30, w = col_w, h = 26 }
    geometry.backlinks[index] = { x = geometry.body.x + col_w + 24,
      y = link_y + 28 + (index - 1) * 30, w = col_w, h = 26 }
  end
  geometry.content_offset_y = oy
  return geometry
end

local function guidance_geometry(W, H)
  local in_rail = G.STATE ~= G.STATES.MENU and G.STATE ~= G.STATES.COLLECTION
    and G.STATE ~= G.STATES.MARKET_SELECT and G.STATE ~= G.STATES.BLIND_SELECT
    and G.STATE ~= G.STATES.TECH_DRAFT
  local panel = in_rail and { x = 20, y = H - 182, w = 304, h = 162 }
    or { x = W / 2 - 330, y = H - 168, w = 660, h = 148 }
  return panel, { x = panel.x + panel.w - 112, y = panel.y + panel.h - 40, w = 96, h = 28 }
end

-- One read-only projection feeds both retained hit targets and immediate-mode labels so the two
-- cannot disagree about capital terms or legality.
local function capital_controls(GAME, state)
  local equity_cost, cash_fraction = Economy.raise_terms(GAME)
  local market = Markets.view(GAME and GAME.market)
  local raise_mult = market and market.economy and market.economy.raise_cash_mult or 1
  local raise_cash = math.floor(((GAME and GAME.run_best_arr) or 0) * cash_fraction * raise_mult)
  local raise_allowed = state == G.STATES.SELECTING_HAND or state == G.STATES.SHOP
    or state == G.STATES.TECH_DRAFT
  local raise_enabled = raise_allowed and GAME.raise_available == true
    and (GAME.equity_pct or 0) > equity_cost and raise_cash > 0
  local raise_label
  if not raise_allowed then
    raise_label = "Fundraise · in play/shop"
  elseif GAME.raise_available == nil then
    raise_label = "Fundraise after Boss"
  elseif GAME.raise_available == false then
    raise_label = "Fundraise · already used"
  elseif (GAME.equity_pct or 0) <= equity_cost then
    raise_label = "Fundraise · low equity"
  elseif raise_cash <= 0 then
    raise_label = "Fundraise after Ship"
  else
    raise_label = ("Fundraise +$%d"):format(raise_cash)
  end

  local pivot_cost = Pricing.base_reroll(GAME, RunState.ANTE_BASE)
    * math.min(2, 1 + (GAME.market_pivots or 0))
  local founder_count = #((G.jokers and G.jokers.cards) or {})
  local has_queueable_market, pivot_block_reason = false, nil
  for _, destination in ipairs(Markets.list or {}) do
    if not GAME.market or destination.id ~= GAME.market.id then
      local allowed, reason = Markets.can_queue(GAME, destination, founder_count)
      if allowed then has_queueable_market = true; break end
      pivot_block_reason = pivot_block_reason or reason
    end
  end
  local pivot_enabled = state == G.STATES.SELECTING_HAND
    and has_queueable_market and GAME.last_market_pivot_ante ~= GAME.ante
    and (GAME.cash or 0) >= pivot_cost
  local pivot_label
  if GAME.pending_market then
    local allowed, reason = Markets.can_queue(GAME, GAME.pending_market, founder_count)
    pivot_label = allowed and ("Next: " .. (GAME.pending_market.name or "Market"))
      or (reason or "Destination blocked")
    pivot_enabled = false
  elseif GAME.last_market_pivot_ante == GAME.ante then
    pivot_label = "Market changed A" .. tostring(GAME.ante or 1)
  elseif state ~= G.STATES.SELECTING_HAND then
    pivot_label = "Market · in play"
  elseif not has_queueable_market then
    pivot_label = pivot_block_reason or "No legal Market"
  elseif (GAME.cash or 0) < pivot_cost then
    pivot_label = "Market · need $" .. tostring(pivot_cost)
  else
    pivot_label = "Change Market · $" .. tostring(pivot_cost)
  end
  return {
    raise = { label = raise_label, enabled = raise_enabled,
      detail = { "Cash now", ("Costs %d%% equity"):format(equity_cost) } },
    pivot = { label = pivot_label, enabled = pivot_enabled,
      detail = { "Switches next blind", "Costs $" .. tostring(pivot_cost) } },
  }
end

-- Build every button from current state without drawing. UIBox owns deterministic z/order/focus
-- metadata; the runtime input adapter consumes the flattened specs bottom-to-top.
function UI.prepare()
  local W, H, GAME = G.WINDOW.w, G.WINDOW.h, G.GAME
  local definitions, rects = {}, {}
  local order = 0
  local function add(action, rect, enabled, scope, z, command, allow_when_locked)
    if not (action and rect) then return end
    order = order + 1
    rects[action] = rect
    definitions[#definitions + 1] = UIBox.button({
      id = "ui:" .. action, action = action, w = rect.w, h = rect.h,
      offset_x = rect.x, offset_y = rect.y, order = order, focus_order = order,
      z = z or 10, enabled = enabled ~= false, modal_scope = scope,
      metadata = command and { command = command } or nil,
      allow_when_locked = allow_when_locked == true,
    })
  end
  local function selected(area)
    for _, card in ipairs((area and area.cards) or {}) do if card.selected then return card end end
  end
  local function add_left_rail()
    local px, py, pw = 12, 14, 320
    local ix, iw = px + 16, pw - 32
    local half, rx = (iw - 12) / 2, ix + (iw - 12) / 2 + 12
    add("run_info", { x = ix, y = py + 554, w = half, h = 50 }, true)
    add("options", { x = rx, y = py + 554, w = half, h = 50 }, true)
    local controls = capital_controls(GAME, G.STATE)
    add("raise", { x = ix, y = py + 612, w = half, h = 38 }, controls.raise.enabled)
    if G.STATE == G.STATES.SELECTING_HAND then
      add("market_pivot", { x = rx, y = py + 612, w = half, h = 38 }, controls.pivot.enabled)
    end
  end

  if G.STATE == G.STATES.MENU then
    G.MENU = G.MENU or { stake = 1 }
    local maxst = require("game.profile").max_stake()
    local n, bw, gap, y = 8, 132, 12, 254
    local x0 = (W - (n * bw + (n - 1) * gap)) / 2
    for stake = 1, n do
      if stake <= maxst then
        add("stake_" .. stake, { x = x0 + (stake - 1) * (bw + gap), y = y, w = bw, h = 72 }, true)
      end
    end
    add("start_run_at", { x = W / 2 - 120, y = y + 116, w = 240, h = 56 }, true)
    add("wiki_open", { x = W / 2 - 120, y = y + 184, w = 240, h = 48 }, true)
  elseif G.STATE == G.STATES.COLLECTION then
    local view = Collection.snapshot()
    local geometry = collection_geometry(W, view)
    add("collection_back", geometry.back, true)
    for index, rect in ipairs(geometry.categories) do
      add("collection_category_" .. index, rect, true)
    end
    for index, rect in ipairs(geometry.filters) do
      add("collection_filter_" .. index, rect, true)
    end
    add("collection_prev", geometry.prev, view.page > 1)
    add("collection_next", geometry.next, view.page < view.page_count)
    UI.collection_view = view
  elseif G.STATE == G.STATES.MARKET_SELECT and GAME then
    local choices, cw, ch, gap, y = GAME.market_choices or {}, 340, 390, 34, 176
    local x0 = (W - (#choices * cw + math.max(0, #choices - 1) * gap)) / 2
    local lesson = Guidance.current()
    for i = 1, #choices do
      local enabled = not (lesson and lesson.id == "welcome")
        and (not GAME.tutorial_market_id or choices[i].id == GAME.tutorial_market_id)
      add("market_pick_" .. i, { x = x0 + (i - 1) * (cw + gap) + 55,
        y = y + ch - 72, w = cw - 110, h = 48 }, enabled)
    end
  elseif G.STATE == G.STATES.TECH_DRAFT and GAME then
    local choices = (GAME.tech_draft and GAME.tech_draft.choices) or {}
    local cw, ch, gap, y = (#choices > 3 and 260 or 320), 350, 32, 184
    local x0 = (W - (#choices * cw + math.max(0, #choices - 1) * gap)) / 2
    for i = 1, #choices do
      add("tech_pick_" .. i, { x = x0 + (i - 1) * (cw + gap) + 55,
        y = y + ch - 66, w = cw - 110, h = 44 }, true)
    end
    local controls = capital_controls(GAME, G.STATE)
    add("raise", { x = W / 2 - 120, y = H - 68, w = 240, h = 42 }, controls.raise.enabled)
  elseif G.STATE == G.STATES.BLIND_SELECT and GAME then
    local y0, ch = 168, 285
    local play = { x = W / 2 - 130, y = y0 + ch + 62, w = 260, h = 60 }
    add("play_blind", play, true)
    if Leads.can_skip(GAME) then
      add("skip_blind", { x = W / 2 - 140, y = play.y + 74, w = 280, h = 48 }, true)
    end
  elseif G.STATE == G.STATES.GAME_OVER and GAME then
    -- Input owns one full-screen restart target. Do not prepare obscured HUD controls above it.
  elseif G.STATE == G.STATES.SHOP and GAME then
    add_left_rail()
    local sh = GAME.shop or { founders = {} }
    local negotiation = Shop.negotiation_view()
    if negotiation then
      local ng = founder_negotiation_geometry(W, H, negotiation)
      if negotiation.phase == "question" then
        for i = 1, #(negotiation.question and negotiation.question.choices or {}) do
          add("founder_negotiation_answer_" .. i, ng.choices[i], true, "negotiation", 60)
        end
      elseif negotiation.phase == "feedback" then
        add("founder_negotiation_continue", ng.continue, true, "negotiation", 60)
      end
      add("founder_negotiation_standard_terms", ng.standard, true, "negotiation", 60)
      add("founder_negotiation_walk_away", ng.walk, true, "negotiation", 60)
    else
    local drawer_scope = sh.pack_open and "pack" or nil
    local drawer_rect = sh.pack_open and { x = 344, y = 264, w = 150, h = 34 }
      or ShopView.layout(Shop.snapshot(), W, H).drawer_toggle
    add("shop_tech_drawer", drawer_rect, true, drawer_scope, 55)
    local founder = selected(G.jokers)
    if founder and founder.center then
      local descriptor = FounderActions.descriptor(founder)
      local y, scope = founder.VT.y + founder.VT.h + 4, sh.pack_open and "pack" or nil
      if descriptor then
        local total, gap, activate_w, fire_w = 154, 6, 88, 60
        local x = founder.VT.x + (founder.VT.w - total) / 2
        add("activate_founder", { x=x, y=y, w=activate_w, h=28 },
          FounderActions.can_activate(founder, FounderActions.selected_target_uid(founder)), scope)
        add("fire", { x=x + activate_w + gap, y=y, w=fire_w, h=28 }, true, scope)
      else
        add("fire", { x = founder.VT.x + (founder.VT.w - 100) / 2,
          y = y, w = 100, h = 28 }, true, scope)
      end
    end
    local consumable = selected(G.consumables)
    if consumable and consumable.center then
      local bw, bh = 92, 28
      local x = consumable.VT.x + (consumable.VT.w - bw * 2 - 8) / 2
      local y = consumable.VT.y + consumable.VT.h + 4
      local usable = Consumables.selected_use_view(consumable, GAME).legal
      local scope = sh.pack_open and "pack" or nil
      add("use_consumable", { x = x, y = y, w = bw, h = bh }, usable == true, scope)
      add("sell_consumable", { x = x + bw + 8, y = y, w = bw, h = bh }, true, scope)
    end
    if sh.pack_open then
      local po, frame = sh.pack_open, PackPresentation.snapshot(sh.pack_open)
      if not frame.ready then
        add("pack_fast_forward", { x = 332, y = 0, w = W - 332, h = H }, true,
          "pack", 90, pack_command("fast_forward", po), true)
      else
        local pack_layout = ShopView.pack_layout(po, W, H)
        if po.kind == "tech_evaluation" then
          local targets = Shop.tech_migration_targets()
          for i, option in ipairs(po.options or {}) do
            if option then
              local product = pack_layout.options[i]
              local can_adopt = Deck.can_add(GAME.master_deck, option, GAME.market)
              add("pack_adopt_" .. i, product.adopt, can_adopt, "pack", nil,
                pack_command("adopt", po, i))
              add("pack_migrate_" .. i, product.migrate,
                #targets > 0 and Deck.can_add(GAME.master_deck, option, GAME.market), "pack", nil,
                pack_command("migrate", po, i))
            end
          end
          add("pack_target_prev", pack_layout.target_prev, #targets > 1, "pack")
          add("pack_target_next", pack_layout.target_next, #targets > 1, "pack")
        else
          local can_pick = po.kind == "playbook"
            or (roadmap_pack(po.kind) and #(GAME.consumables or {}) < (GAME.consumable_slots or 2))
            or (po.kind == "hiring" and #G.jokers.cards < Shop.founder_cap())
          for i, option in ipairs(po.options or {}) do
            if option then add("pack_pick_" .. i, pack_layout.options[i].pick,
              can_pick, "pack", nil, pack_command("pick", po, i)) end
          end
        end
        add("pack_skip", pack_layout.skip, true, "pack", nil,
          pack_command("skip", po))
      end
    else
      local snapshot = Shop.snapshot()
      local layout = ShopView.layout(snapshot, W, H)
      for i, product in ipairs(layout.primary.founders) do
        local offer = snapshot.offers.founders[i]
        add("shop_buy_" .. i, product.control, offer and not offer.disabled_reason,
          nil, nil, offer and offer.command)
      end
      local roadmap = snapshot.offers.roadmap
      add("shop_buy_consumable", layout.primary.roadmap.control,
        roadmap and not roadmap.disabled_reason, nil, nil, roadmap and roadmap.command)
      local voucher = snapshot.offers.voucher
      add("shop_redeem", layout.voucher.control, voucher and not voucher.disabled_reason,
        nil, nil, voucher and voucher.command)
      add("shop_reroll", layout.actions.reroll,
        not snapshot.commands.reroll.disabled_reason, nil, nil, snapshot.commands.reroll)
      add("shop_continue", layout.actions.next_blind,
        not snapshot.commands.next_blind.disabled_reason, nil, nil, snapshot.commands.next_blind)
      for i, product in ipairs(layout.packs) do
        local pack = snapshot.offers.packs[i]
        add("shop_open_pack_" .. i, product.control, pack and not pack.disabled_reason,
          nil, nil, pack and pack.command)
      end
    end
    end
  elseif GAME then
    add_left_rail()
    local selecting = G.STATE == G.STATES.SELECTING_HAND
    local highlighted = G.hand and G.hand:highlighted() or {}
    local n_selected = #highlighted
    local consumable = selected(G.consumables)
    if consumable and selecting then
      local bw, bh = 92, 28
      local x = consumable.VT.x + (consumable.VT.w - bw * 2 - 8) / 2
      local y = consumable.VT.y + consumable.VT.h + 4
      local usable = Consumables.selected_use_view(consumable, GAME).legal
      add("use_consumable", { x = x, y = y, w = bw, h = bh }, usable == true)
      add("sell_consumable", { x = x + bw + 8, y = y, w = bw, h = bh }, true)
    end
    if G.STATE == G.STATES.TARGET_SELECT and G.PENDING_CONSUMABLE
        and G.PENDING_CONSUMABLE.need_layer then
      local layers = G.PENDING_CONSUMABLE.layer_options or Coverage.CORE_ORDER
      local lw, lh, gap = 150, 40, 12
      local play_x, total = 332, #layers * lw + (#layers - 1) * gap
      local x0 = play_x + ((W - play_x) - total) / 2
      for i, layer in ipairs(layers) do
        add("pick_layer_" .. layer, { x = x0 + (i - 1) * (lw + gap), y = 320, w = lw, h = lh },
          true, "target")
      end
    end
    local shipw, sortw, bh, gap = 170, 80, 40, 10
    local rowx = G.hand and (G.hand.T.x + (G.hand.T.w - (shipw * 2 + sortw * 2 + gap * 3)) / 2) or 0
    local rowy = H - 48
    add("ship", { x = rowx, y = rowy, w = shipw, h = bh },
      selecting and n_selected >= 1 and n_selected <= (GAME.select_max or 5) and (GAME.ships_left or 0) > 0)
    add("sort_users", { x = rowx + shipw + gap, y = rowy, w = sortw, h = bh }, selecting)
    add("sort_layer", { x = rowx + shipw + sortw + gap * 2, y = rowy, w = sortw, h = bh }, selecting)
    add("pivot", { x = rowx + shipw + sortw * 2 + gap * 3, y = rowy, w = shipw, h = bh },
      selecting and n_selected >= 1 and (GAME.pivots_left or 0) > 0)
    local founder = selected(G.jokers)
    if founder then
      local descriptor = FounderActions.descriptor(founder)
      local y = G.jokers.T.y + G.jokers.T.h + 4
      if descriptor then
        local total, gap, activate_w, fire_w = 154, 6, 88, 60
        local x = founder.VT.x + (founder.VT.w - total) / 2
        add("activate_founder", { x=x, y=y, w=activate_w, h=30 },
          FounderActions.can_activate(founder, FounderActions.selected_target_uid(founder)))
        add("fire", { x=x + activate_w + gap, y=y, w=fire_w, h=30 }, true)
      else
        add("fire", { x = founder.VT.x + (founder.VT.w - 90) / 2,
          y = y, w = 90, h = 30 }, true)
      end
    end
  end

  local lesson = Guidance.current()
  if lesson and lesson.id == "welcome" then
    local _, ack = guidance_geometry(W, H)
    add("guidance_ack", ack, true, nil, 80)
  end

  if G.SHOW_OPTIONS then
    local geometry = Options.geometry(W, H)
    for _, row in ipairs(geometry.rows) do
      add(row.action, row.rect, true, "overlay", 100)
    end
  end

  if G.SHOW_WIKI then
    local view = Wiki.snapshot()
    local geometry = wiki_geometry(W, H, view)
    add("wiki_close", geometry.close, true, "wiki", 200, nil, true)
    add("wiki_search", geometry.search, true, "wiki", 200)
    if view.query ~= "" then add("wiki_clear", geometry.clear, true, "wiki", 201) end
    for index, rect in ipairs(geometry.categories) do add("wiki_category_" .. index, rect, true, "wiki", 200) end
    for index, rect in ipairs(geometry.facets) do add("wiki_facet_" .. index, rect, true, "wiki", 200) end
    for index, rect in ipairs(geometry.letters) do
      add("wiki_letter_" .. string.char(string.byte("A") + index - 1), rect, true, "wiki", 200)
    end
    for index, item in ipairs(view.items) do
      add("wiki_item_" .. index, geometry.items[index], true, "wiki", 200,
        { handle = item.handle })
    end
    add("wiki_prev", geometry.prev, view.page > 1, "wiki", 200)
    add("wiki_next", geometry.next, view.page < view.page_count, "wiki", 200)
    add("wiki_scroll_up", geometry.scroll_up, view.scroll > 0, "wiki", 200)
    add("wiki_scroll_down", geometry.scroll_down, view.scroll < 4, "wiki", 200)
    local page = view.selected
    for index, row in ipairs((page and page.related) or {}) do
      add("wiki_related_" .. index, geometry.related[index], true, "wiki", 200,
        { handle = row.handle })
    end
    for index, row in ipairs((page and page.backlinks) or {}) do
      add("wiki_backlink_" .. index, geometry.backlinks[index], true, "wiki", 200,
        { handle = row.handle })
    end
    UI.wiki_view = view
  else
    UI.wiki_view = nil
  end

  local box = UIBox.new(UIBox.root({ id = "ui:root" }, definitions),
    { bounds = { x = 0, y = 0, w = W, h = H } })
  G.UI_ROOT, G.UI_OWNER.stage, G.UI_OWNER.state = box, G.STAGE, G.STATE
  UI.rects, UI.buttons = rects, {}
  for _, target in ipairs(box:targets(nil, { order = "draw" })) do
    UI.buttons[#UI.buttons + 1] = {
      id = target.id, action = target.action, rect = target.bounds,
      enabled = target.enabled, visible = target.visible, scope = target.modal_scope,
      global = target.global, allow_when_locked = target.allow_when_locked,
      focusable = target.focusable,
      command = target.metadata and target.metadata.command or nil,
    }
  end
  return UI.buttons
end

function UI.button_specs()
  return UI.buttons or UI.prepare()
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
  local cvr = G.PACK_ART and (G.PACK_ART[pack_open and pack_open.art_key]
    or G.PACK_ART[pack_open and pack_open.fallback_art] or G.PACK_ART.hiring_round)
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
  local mx, my = cursor()
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
    local telegraph = ""
    if bl.is_boss and bl.event then
      local boss = Bosses.rule(bl.event)
      telegraph = "! " .. ((boss and boss.name) or bl.event)
    end
    if GAME.pending_market then
      telegraph = telegraph .. (telegraph ~= "" and "  ·  " or "") .. "Next: " .. GAME.pending_market.name
    end
    if telegraph ~= "" then UI.text(G.FONTS.tiny, telegraph, ix, py + 96,
      bl.is_boss and G.C.lose or G.C.win, iw, "center") end
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
  local controls = capital_controls(GAME, G.STATE)
  UI.rects.raise = { x = ix, y = py + 612, w = half, h = 38 }
  draw_button(UI.rects.raise, controls.raise.label, controls.raise.enabled,
    point_in_rect(mx, my, ix, py + 612, half, 38), G.FONTS.tiny)
  UI.rects.market_pivot = { x = rx, y = py + 612, w = half, h = 38 }
  draw_button(UI.rects.market_pivot, controls.pivot.label, controls.pivot.enabled,
    point_in_rect(mx, my, rx, py + 612, half, 38), G.FONTS.tiny)
  UI.text(G.FONTS.tiny, controls.raise.detail[1], ix, py + 650, G.C.text_dim, half, "center")
  UI.text(G.FONTS.tiny, controls.raise.detail[2], ix, py + 666, G.C.text_dim, half, "center")
  UI.text(G.FONTS.tiny, controls.pivot.detail[1], rx, py + 650, G.C.text_dim, half, "center")
  UI.text(G.FONTS.tiny, controls.pivot.detail[2], rx, py + 666, G.C.text_dim, half, "center")
  UI.text(G.FONTS.tiny, ("Runway %s \194\183 Rung %d \194\183 Eq %d%% \194\183 Debt %d"):format(
    (GAME.runway or 99) >= 99 and "long" or tostring(GAME.runway), GAME.maturity_rung or 1, GAME.equity_pct or 100,
    math.floor(require("game.meters").get("tech_debt") or 0)), ix, py + 687, G.C.text_dim, iw, "center")

  local pending = Leads.pending(GAME)
  if #pending > 0 then
    UI.text(G.FONTS.tiny, "ACTIVE LEADS", ix, py + 708, G.C.win, iw, "center")
    local shown = math.min(2, #pending)
    for i = 1, shown do
      local suffix = (i == shown and #pending > shown) and ("  +" .. (#pending - shown) .. " more") or ""
      local y = py + 708 + (i - 1) * 30 + 18
      UI.text(G.FONTS.tiny, tostring(pending[i].name or pending[i].key or "Lead") .. suffix,
        ix + 4, y, G.C.text, iw - 8, "left")
      UI.text(G.FONTS.tiny, lead_status(pending[i]),
        ix + 4, y + 15, G.C.text_dim, iw - 8, "left")
    end
  end
end

function UI.render()
  local W, H = G.WINDOW.w, G.WINDOW.h
  UI.prepare()                                          -- pure retained tree; draw only consumes it
  if G.STATE == G.STATES.MENU then UI.render_menu(W, H); return end
  if G.STATE == G.STATES.COLLECTION then UI.render_collection(W, H); return end
  local GAME = G.GAME
  if not GAME then return end
  if G.STATE == G.STATES.MARKET_SELECT then UI.render_market_select(W, H, GAME); return end
  if G.STATE == G.STATES.TECH_DRAFT then UI.render_tech_draft(W, H, GAME); return end
  if G.STATE == G.STATES.BLIND_SELECT then UI.render_blind_select(W, H, GAME); return end
  if G.STATE == G.STATES.SHOP then UI.render_shop(W, H, GAME); return end

  local mx, my = cursor()
  local bl = GAME.blind or { target = 1, kind = "?", stage = "?" }
  local selecting = (G.STATE == G.STATES.SELECTING_HAND)
  local n_sel = #G.hand:highlighted()

  UI.left_panel(GAME)                                   -- the shared Balatro-style counter column

  -- ===== RIGHT PLAY ZONE: labels, counts, controls =====
  UI.text(G.FONTS.tiny, "FOUNDERS  " .. #G.jokers.cards .. "/" .. tostring(GAME.founder_slots or 5),
    G.jokers.T.x, G.jokers.T.y - 24, G.C.text_dim)
  -- Shared Roadmap inventory for Tech Laws and later Moonshots.
  -- Real cards live in G.consumables (drawn by draw_all);
  -- the framed placeholder shows only while empty, the count always.
  local csw, csx = 220, W - 220 - 24
  local ncons = (G.consumables and #G.consumables.cards) or 0
  if ncons == 0 then
    pixel_rect(csx, 24, csw, Card.H, { 0.12, 0.13, 0.16, 1 }, { chamfer = 6, border = G.C.border })
    UI.text(G.FONTS.tiny, "Roadmap", csx, 24 + Card.H / 2 - 10, G.C.text_dim, csw, "center")
  end
  UI.text(G.FONTS.tiny, "Roadmap  " .. ncons .. "/" .. (GAME.consumable_slots or 2),
    csx, 24 + Card.H + 6, G.C.text_dim, csw, "center")
  -- selected consumable → Use / Sell buttons beneath it (B2/B5)
  local selC
  if G.consumables then for _, c in ipairs(G.consumables.cards) do if c.selected then selC = c; break end end end
  if selC and selecting then
    local bw2, bh2 = 92, 28
    local bx = selC.VT.x + (selC.VT.w - bw2 * 2 - 8) / 2
    local by2 = selC.VT.y + selC.VT.h + 4
    UI.rects.use_consumable = { x = bx, y = by2, w = bw2, h = bh2 }
    local use_view = Consumables.selected_use_view(selC, GAME)
    local usable, reason = use_view.legal, use_view.reason
    draw_button(UI.rects.use_consumable, "Use", usable == true,
      point_in_rect(mx, my, bx, by2, bw2, bh2))
    UI.rects.sell_consumable = { x = bx + bw2 + 8, y = by2, w = bw2, h = bh2 }
    draw_button(UI.rects.sell_consumable, "Sell $" .. Shop.consumable_sell_value(selC),
      true, point_in_rect(mx, my, bx + bw2 + 8, by2, bw2, bh2))
    if not usable and reason then
      UI.text(G.FONTS.tiny, tostring(reason), math.max(340, bx - 100), by2 + bh2 + 5,
        G.C.lose, math.min(420, W - math.max(340, bx - 100) - 12), "center")
    end
  end
  -- B4: targeting banner + Conway's layer picker overlay
  if G.STATE == G.STATES.TARGET_SELECT and G.PENDING_CONSUMABLE then
    local pc = G.PENDING_CONSUMABLE
    lg.setColor(0, 0, 0, 0.35); lg.rectangle("fill", 0, 260, W, 44)
    local target_label = pc.target_area_name == "founder" and "Founder" or "Tech card"
    UI.text(G.FONTS.small, pc.need_layer and "Pick the new Layer:" or
      ("Select a " .. target_label .. " for " .. (pc.center.name or "?") .. "  (right-click to cancel)"),
      332, 270, G.C.arr, W - 332, "center")
    if pc.error then
      UI.text(G.FONTS.tiny, tostring(pc.error), 332, 294, G.C.lose, W - 332, "center")
    end
    if pc.need_layer then
      local Ls = pc.layer_options or Coverage.CORE_ORDER
      local lw, lh, lgap = 150, 40, 12
      local play_x, total = 332, #Ls * lw + (#Ls - 1) * lgap
      local lx0 = play_x + ((W - play_x) - total) / 2
      for i, L in ipairs(Ls) do
        local lx = lx0 + (i - 1) * (lw + lgap)
        UI.rects["pick_layer_" .. L] = { x = lx, y = 320, w = lw, h = lh }
        draw_button(UI.rects["pick_layer_" .. L], L, true, point_in_rect(mx, my, lx, 320, lw, lh))
      end
    end
  end
  -- product / app-type
  UI.text(G.FONTS.tiny, "PRODUCT  (shipped)", G.play.T.x, G.play.T.y - 24, G.C.text_dim)
  if GAME.scoring_name then
    UI.text(G.FONTS.normal, GAME.product_identity or GAME.scoring_name,
      G.play.T.x, G.play.T.y - 4, G.C.text, G.play.T.w, "center")
  end
  if selecting and n_sel > 0 then
    local selected = G.hand:highlighted()
    local selected_set, held = {}, {}
    for _, card in ipairs(selected) do selected_set[card] = true end
    for _, card in ipairs(G.hand.cards or {}) do if not selected_set[card] then held[#held + 1] = card end end
    local preview = require("game.preview").evaluate(selected, { held_cards = held })
    local app, cov, stack, rel, fit = preview.app, preview.coverage, preview.best_stack, preview.reliability, preview.fit
    local stack_text = stack and ((stack.complete and stack.name) or (stack.name .. " " .. stack.matched .. "/" .. stack.total)) or "none"
    UI.text(G.FONTS.tiny, ("Preview: %s · Coverage %d/5 · Stack %s · Fit ×%.2f · Reliability %d/10"):format(
      app.name, cov.distinct, stack_text, fit, rel.score) .. " · Base ARR " .. format_number(preview.arr),
      G.play.T.x, G.play.T.y + G.play.T.h + 10,
      rel.score < 7 and G.C.lose or G.C.text_dim, G.play.T.w, "center")
    local compat_y = G.play.T.y + G.play.T.h + 31
    if preview.ai_maturity then
      local maturity = preview.ai_maturity
      UI.text(G.FONTS.tiny, ("AI ladder %d/6 · %s · +%d Users · ×%.2f Rev"):format(
        maturity.rung, maturity.name, maturity.users_bonus, maturity.rev_mult),
        G.play.T.x, compat_y, G.C.arr, G.play.T.w, "center")
      compat_y = compat_y + 21
    end
    UI.text(G.FONTS.tiny, ("Compatibility: Chemistry ×%.2f · %d clash%s · %d substitute%s"):format(
      preview.chemistry, preview.clashes, preview.clashes == 1 and "" or "es",
      preview.substitutes, preview.substitutes == 1 and "" or "s"),
      G.play.T.x, compat_y,
      preview.clashes > 0 and G.C.lose or G.C.text_dim, G.play.T.w, "center")
    if preview.tech_modifier_summary and preview.tech_modifier_summary ~= "" then
      local effects = preview.tech_modifiers and preview.tech_modifiers.effects or {}
      local effect_text = {}
      if (effects.repetitions or 0) > 0 then effect_text[#effect_text + 1] = "+" .. effects.repetitions .. " trigger" end
      if (effects.played_rev or 0) ~= 0 then effect_text[#effect_text + 1] = "+" .. effects.played_rev .. " Rev" end
      if (effects.held_rev_mult or 1) ~= 1 then effect_text[#effect_text + 1] = "held ×" .. effects.held_rev_mult .. " Rev" end
      if (effects.blind_clear_cash or 0) > 0 then
        effect_text[#effect_text + 1] = "+$" .. effects.blind_clear_cash .. " at blind clear"
      end
      UI.text(G.FONTS.tiny, "Tech modifiers · " .. preview.tech_modifier_summary
          .. (#effect_text > 0 and (" · " .. table.concat(effect_text, " · ")) or ""),
        G.play.T.x, compat_y + 21, G.C.win, G.play.T.w, "center")
    end
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
  draw_button(UI.rects.sort_users, "Users", selecting, point_in_rect(mx, my, UI.rects.sort_users.x, rowy, sortw, bh3))
  UI.rects.sort_layer = { x = rowx + shipw + sortw + gap3 * 2, y = rowy, w = sortw, h = bh3 }
  draw_button(UI.rects.sort_layer, "Layer", selecting, point_in_rect(mx, my, UI.rects.sort_layer.x, rowy, sortw, bh3))
  UI.text(G.FONTS.tiny, "sort hand", rowx + shipw + gap3, rowy - 17, G.C.text_dim, sortw * 2 + gap3, "center")
  UI.rects.pivot = { x = rowx + shipw + sortw * 2 + gap3 * 3, y = rowy, w = shipw, h = bh3 }
  draw_button(UI.rects.pivot, G.TEXT.pivot, pivot_on, point_in_rect(mx, my, UI.rects.pivot.x, rowy, shipw, bh3))

  -- selected founder -> explicit action / Fire controls below it.
  local fsel
  for _, c in ipairs(G.jokers.cards) do if c.selected then fsel = c; break end end
  if fsel then
    local descriptor = FounderActions.descriptor(fsel)
    if descriptor then
      draw_button(UI.rects.activate_founder, descriptor.label,
        FounderActions.can_activate(fsel, FounderActions.selected_target_uid(fsel)),
        UI.rects.activate_founder and point_in_rect(mx, my, UI.rects.activate_founder.x,
          UI.rects.activate_founder.y, UI.rects.activate_founder.w, UI.rects.activate_founder.h), G.FONTS.tiny)
    end
    local fire = UI.rects.fire
    if fire then
      pixel_rect(fire.x, fire.y, fire.w, fire.h, button_hovered(fire,
        point_in_rect(mx, my, fire.x, fire.y, fire.w, fire.h)) and G.C.lose or { 0.70, 0.26, 0.26, 1 },
        { chamfer = 3, border = G.C.border })
      UI.text(G.FONTS.small, "Fire", fire.x, fire.y + 3, G.C.text, fire.w, "center")
    end
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
  local mx, my = cursor()
  local lesson = Guidance.current()
  UI.text(G.FONTS.big, "CHOOSE YOUR MARKET", 0, 54, G.C.arr, W, "center")
  UI.text(G.FONTS.small, "Your Market defines the starting stack, operating perk, Fit, and future drafts.",
    0, 108, G.C.text_dim, W, "center")
  local choices = GAME.market_choices or {}
  local cw, ch, gap, y = 340, 390, 34, 176
  local x0 = (W - (#choices * cw + math.max(0, #choices - 1) * gap)) / 2
  for i, market in ipairs(choices) do
    local x = x0 + (i - 1) * (cw + gap)
    local view = require("game.markets").view(market)
    pixel_rect(x, y, cw, ch, { 0.12, 0.14, 0.18, 1 }, { chamfer = 8, border = G.C.border, line_w = 2 })
    UI.text(G.FONTS.normal, market.name, x + 12, y + 24, G.C.arr, cw - 24, "center")
    UI.text(G.FONTS.tiny, (market.audience or "") .. "  ·  " .. (market.industry or ""),
      x + 12, y + 72, G.C.text_dim, cw - 24, "center")
    UI.text(G.FONTS.small, (view.perk and view.perk.name) or "Market Perk",
      x + 18, y + 122, G.C.win, cw - 36, "center")
    lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
    lg.printf((view.perk and view.perk.effect) or "Structured market perk", x + 28, y + 158, cw - 56, "center")
    lg.setColor(G.C.text_dim)
    lg.printf(tostring(view.starter_size or 24) .. "-card E" .. tostring(view.start_era or 1)
      .. " authored deck\nFit: " .. tostring(view.fit.label),
      x + 28, y + 232, cw - 56, "center")
    local b = { x = x + 55, y = y + ch - 72, w = cw - 110, h = 48 }
    UI.rects["market_pick_" .. i] = b
    local enabled = not (lesson and lesson.id == "welcome")
      and (not GAME.tutorial_market_id or market.id == GAME.tutorial_market_id)
    draw_button(b, enabled and "Build here ›" or (GAME.tutorial_market_id == market.id and "Meet Patch first" or "Tutorial: Indie SaaS"),
      enabled, point_in_rect(mx, my, b.x, b.y, b.w, b.h))
  end
end

function UI.render_tech_draft(W, H, GAME)
  local mx, my = cursor()
  local deck_before = #(GAME.master_deck or {})
  UI.text(G.FONTS.big, "BOSS TECH DRAFT", 0, 54, G.C.arr, W, "center")
  UI.text(G.FONTS.small, "Guaranteed Boss reward · adopt one technology permanently.",
    0, 106, G.C.text_dim, W, "center")
  UI.text(G.FONTS.tiny, ("Deck %d → %d · source: Boss draft"):format(deck_before, deck_before + 1),
    0, 138, G.C.win, W, "center")
  local choices = (GAME.tech_draft and GAME.tech_draft.choices) or {}
  local offers = (GAME.tech_draft and GAME.tech_draft.offers) or {}
  local cw, ch, gap, y = (#choices > 3 and 260 or 320), 350, 32, 184
  local x0 = (W - (#choices * cw + math.max(0, #choices - 1) * gap)) / 2
  local hovered, hover_x, hover_y
  for i, key in ipairs(choices) do
    local offer = offers[i] or key
    local center, x = tech_offer_center(offer) or Centers.get(key), x0 + (i - 1) * (cw + gap)
    local subject = tech_offer_subject(offer, center)
    local hov = point_in_rect(mx, my, x, y, cw, ch)
    pixel_rect(x, y, cw, ch, { 0.12, 0.14, 0.18, 1 }, { chamfer = 8, border = G.C.border, line_w = 2 })
    local fw, fh = math.min(Card.W, cw - 48), 218
    Card.draw_tech_face({ x = x + (cw - fw) / 2, y = y + 16, w = fw, h = fh }, center,
      { entry = subject, era = GAME.era, border = hov and G.C.hover or G.C.border, line_w = hov and 3 or 2 })
    local summary = Card.tech_modifier_summary(subject)
    UI.text(G.FONTS.tiny, summary ~= "" and summary or "Unmodified Tech",
      x + 12, y + 246, summary ~= "" and G.C.win or G.C.text_dim, cw - 24, "center")
    local b = { x = x + 55, y = y + ch - 66, w = cw - 110, h = 44 }
    UI.rects["tech_pick_" .. i] = b
    draw_button(b, "Adopt (+1)", true, point_in_rect(mx, my, b.x, b.y, b.w, b.h))
    if hov then hovered, hover_x, hover_y = { center = center, subject = subject }, x + cw + 10, y end
  end
  if hovered and hovered.center then
    local detail = hovered.center.desc or ""
    local modifiers = Card.tech_modifier_detail(hovered.subject)
    if modifiers ~= "" then detail = detail .. "\n\n" .. modifiers end
    UI.tip_box(hover_x, hover_y, hovered.center.name or "Tech",
      (hovered.center.layer or "Tech") .. " · Boss draft offer", detail)
  end
  local controls = capital_controls(GAME, G.STATE)
  local raise = { x = W / 2 - 120, y = H - 68, w = 240, h = 42 }
  UI.rects.raise = raise
  draw_button(raise, controls.raise.label, controls.raise.enabled,
    point_in_rect(mx, my, raise.x, raise.y, raise.w, raise.h), G.FONTS.tiny)
end

-- hover tooltip: bounded run rules for the card under the cursor (founders) or tech-card desc.
-- Drawn LAST (after cards + HUD) so it sits on top of everything. Hover flags are set in love.update.
local function wrapped_height(text, font, w)
  local _, lines = font:getWrap(text, w)
  return #lines * font:getHeight()
end

-- reusable tooltip box: full name + ability name + wrapped rules near an anchor point.
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
  if G.STATE == G.STATES.MENU or G.STATE == G.STATES.COLLECTION then return end
  if not (G.CONTROLLER and G.CONTROLLER.hid and G.CONTROLLER.hid.buttons[2]) then return end
  local mx, my = cursor()
  local hovered
  for _, area in ipairs({ G.consumables, G.jokers, G.hand, G.play }) do
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
  local consumable = c.set == "Consumable"
  local sub, body
  if consumable then
    local use_view = Consumables.selected_use_view(hovered, G.GAME)
    local usable, reason = use_view.legal, use_view.reason
    sub = (c.kind or "Consumable") .. "  ·  " .. tostring(c.rarity or "")
    body = c.desc or ""
    if c.kind == "Moonshot" then
      local payload_text, _, payload_preview = Moonshots.payload_summary(hovered, nil, G.GAME)
      if payload_text and payload_preview and payload_preview.kind ~= "none" then
        body = body .. "\n\nPre-rolled outcome · " .. payload_text
      end
    end
    if usable then body = body .. "\n\nReady to use."
    elseif reason then body = body .. "\n\nUnavailable: " .. tostring(reason) end
    body = body .. "\nSell value $" .. tostring(Shop.consumable_sell_value(hovered))
  elseif founder then
    sub = Card.effect_brief(c, hovered) .. "   \194\183   " .. (c.rarity or "")   -- headline (live value for accumulators)
    local terms = Card.founder_terms(hovered, c)
    local economics = ("Salary $%s (base $%s) \194\183 Effect %d%%"):format(
      format_number(terms.effective_salary), format_number(terms.base_salary),
      math.floor(terms.effect_scale * 100 + 0.5))
    if terms.distilled then economics = economics .. " \194\183 Distilled" end
    if terms.rental_salary_mult ~= 1 then
      economics = economics .. (" \194\183 Rental \195\151%.2f"):format(terms.rental_salary_mult)
    end
    body = economics .. "\n" .. (c.ability_name or "")
    local ed = hovered.edition and Card.EDITIONS[hovered.edition]
    if ed then body = body .. "\n\226\156\166 " .. ed.label .. " edition: " .. (ed.desc or "") end
    body = body .. "\n\n" .. (c.rules_text or c.hint or "")
    local identity = SignaturePair.identity_label(c)
    if identity then body = body .. "\n\nIdentity · " .. identity end
  else
    local effective, status, before_decay = Card.tech_users(hovered, c)
    local base = hovered.base_users or c.base_users or 0
    local users = "Users " .. format_number(effective)
    if effective ~= base then users = users .. " (base " .. format_number(base) .. ")" end
    local rev = hovered.rev_sticker_label and hovered:rev_sticker_label()
    sub = (Card.tech_layer_label(hovered, c) or "") .. "  ·  " .. users .. (rev and ("  ·  " .. rev) or "")
    body = c.desc or ""
    local identity = SignaturePair.identity_label(c)
    if identity then body = body .. "\n\nIdentity · " .. identity end
    if status.state == "deprecated" then
      body = body .. ("\n\nDEPRECATED · %d Era%s behind · -%d%% Users (%s → %s)."):format(
        status.eras_behind, status.eras_behind == 1 and "" or "s",
        math.floor(status.penalty * 100 + 0.5), format_number(before_decay), format_number(effective))
    elseif status.state == "future" then
      body = body .. "\n\nFuture Tech · retains full Users while already owned."
    end
    local provenance = Card.provenance_label(hovered)
    if hovered.migrated_from then
      local previous = Centers.get(hovered.migrated_from)
      if previous then provenance = provenance:gsub(tostring(hovered.migrated_from), previous.name or previous.key) end
    end
    body = body .. "\n\nAcquisition · " .. provenance
    local modifier_detail = Card.tech_modifier_detail(hovered)
    if modifier_detail ~= "" then body = body .. "\n\n" .. modifier_detail end
  end
  UI.tip_box(hovered.VT.x + hovered.VT.w + 10, hovered.VT.y, c.name or c.short or "?", sub, body)
end

-- the pre-run MENU: career stats + collection summary + Funding-Stake select + Start.
function UI.render_menu(W, H)
  local mx, my = cursor()
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
  local cr = { x = W / 2 - 120, y = y + 184, w = 240, h = 48 }
  UI.rects.wiki_open = cr
  draw_button(cr, "Wiki", true, point_in_rect(mx, my, cr.x, cr.y, cr.w, cr.h))
  lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text_dim)
  lg.printf("higher stakes unlock by reaching IPO \194\183 discovery never changes gameplay eligibility",
    0, y + 248, W, "center")
end

local function draw_collection_tab(rect, label, selected)
  local highlighted = selected or button_hovered(rect, false)
  pixel_rect(rect.x, rect.y, rect.w, rect.h, highlighted and G.C.arr or G.C.btn,
    { chamfer = 4, border = G.C.border, line_w = selected and 3 or 2 })
  UI.text(G.FONTS.tiny, label, rect.x + 4, rect.y + rect.h / 2 - 10,
    selected and G.C.black or G.C.text, rect.w - 8, "center")
end

-- Read-only discovery catalogs. The Collection model has already replaced hidden content with
-- silhouette-safe projections, so this renderer never reaches into centers or the profile.
function UI.render_collection(W, H)
  local view = UI.collection_view or Collection.snapshot()
  local geometry = collection_geometry(W, view)
  local mx, my = cursor()
  UI.text(G.FONTS.normal, "COLLECTION", 0, 22, G.C.arr, W, "center")
  draw_button(geometry.back, "\194\171 Back", true,
    point_in_rect(mx, my, geometry.back.x, geometry.back.y, geometry.back.w, geometry.back.h))

  for index, category in ipairs(Collection.CATEGORIES) do
    local progress = view.progress[category.id] or { discovered = 0, total = 0 }
    draw_collection_tab(geometry.categories[index],
      category.label .. "  " .. progress.discovered .. "/" .. progress.total,
      index == view.category_index)
  end
  for index, filter in ipairs(view.filters) do
    draw_collection_tab(geometry.filters[index], filter.label, index == view.filter_index)
  end

  local progress_text = ("%s discovered %d/%d"):format(
    view.category.label, view.discovered, view.total)
  if view.filter.id ~= "all" then
    progress_text = progress_text .. ("  \194\183  %s %d/%d"):format(
      view.filter.label, view.filtered_discovered, view.filtered_total)
  end
  UI.text(G.FONTS.tiny, progress_text, 40, 190, G.C.text_dim, W - 80, "center")
  local bar_x, bar_y, bar_w = 220, 212, W - 440
  pixel_rect(bar_x, bar_y, bar_w, 8, G.C.panel_dim, { chamfer = 3, shadow = false, emboss = false })
  if view.total > 0 and view.discovered > 0 then
    pixel_rect(bar_x, bar_y, bar_w * view.discovered / view.total, 8, G.C.arr,
      { chamfer = 3, shadow = false, emboss = false })
  end

  local cols, card_gap, card_x, card_y = 4, 14, 34, 236
  local card_w = (W - card_x * 2 - card_gap * (cols - 1)) / cols
  local card_h, row_gap = 150, 14
  for index, item in ipairs(view.items) do
    local col, row = (index - 1) % cols, math.floor((index - 1) / cols)
    local x, y = card_x + col * (card_w + card_gap), card_y + row * (card_h + row_gap)
    local fill = item.discovered and { 0.12, 0.14, 0.18, 1 } or { 0.065, 0.075, 0.095, 1 }
    pixel_rect(x, y, card_w, card_h, fill,
      { chamfer = 6, border = item.discovered and G.C.border or G.C.panel_dim, line_w = 2 })
    if item.discovered then
      UI.text(G.FONTS.small, item.name, x + 12, y + 12, G.C.arr, card_w - 24, "center")
      UI.text(G.FONTS.tiny, item.subtitle, x + 12, y + 48, G.C.mult, card_w - 24, "center")
      lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
      lg.printf(item.detail or "", x + 16, y + 78, card_w - 32, "center")
    else
      UI.text(G.FONTS.big, "?", x, y + 25, G.C.text_dim, card_w, "center")
      UI.text(G.FONTS.tiny, item.subtitle, x, y + 88, G.C.text_dim, card_w, "center")
      UI.text(G.FONTS.tiny, "Keep building to reveal", x, y + 114, G.C.panel_dim, card_w, "center")
    end
  end

  local page_label = ("Page %d/%d  \194\183  showing %d-%d of %d"):format(
    view.page, view.page_count, view.first, view.last, view.filtered_total)
  UI.text(G.FONTS.tiny, page_label, 0, 722, G.C.text_dim, W, "center")
  draw_button(geometry.prev, "\194\171 Prev", view.page > 1,
    point_in_rect(mx, my, geometry.prev.x, geometry.prev.y, geometry.prev.w, geometry.prev.h))
  draw_button(geometry.next, "Next \194\187", view.page < view.page_count,
    point_in_rect(mx, my, geometry.next.x, geometry.next.y, geometry.next.w, geometry.next.h))
end

-- the BLIND-SELECT page (P2): preview the upcoming blind before committing. Small/Big show their
-- deterministic Leads before the player chooses; skipping claims that Lead while explicitly forfeiting
-- the blind's income, close reward, and shop. Boss blinds are never skippable.
function UI.render_blind_select(W, H, GAME)
  local mx, my = cursor()
  local bl = GAME.blind or {}
  local leads = lead_state(GAME)
  UI.text(G.FONTS.big, ("ANTE %d / 8"):format(GAME.ante or 1), 0, 40, G.C.arr, W, "center")
  lg.setFont(G.FONTS.small); lg.setColor(G.C.text_dim)
  lg.printf((bl.stage or "?") .. "  \194\183  choose your next blind", 0, 88, W, "center")

  if #leads.pending > 0 then
    local queued = {}
    for i = 1, math.min(3, #leads.pending) do queued[#queued + 1] = lead_line(leads.pending[i]) end
    if #leads.pending > 3 then queued[#queued + 1] = "+" .. (#leads.pending - 3) .. " more" end
    UI.text(G.FONTS.tiny, "QUEUED LEADS  \194\183  " .. table.concat(queued, "   |   "),
      50, 128, G.C.win, W - 100, "center")
  end

  local kinds = { "Small", "Big", "Boss" }
  local EV = { "ai_winter", "platform_shift", "dotcom_bust" }     -- mirrors set_blind's cyclic boss telegraph
  local boss_event = bl.event or (GAME.boss_sequence and GAME.boss_sequence[GAME.ante or 1])
    or EV[(((GAME.ante or 1) - 1) % #EV) + 1]
  local n, cw, ch, gap, y0 = 3, 300, 285, 40, 168
  local x0 = (W - (n * cw + (n - 1) * gap)) / 2
  for i = 1, n do
    local x = x0 + (i - 1) * (cw + gap)
    local current = (bl.idx or 1) == i
    local past = i < (bl.idx or 1)
    local skipped = past and skipped_with_lead(leads, GAME.ante or 1, i)
    local target = RunState.blind_target(GAME.ante or 1, i)
    local kindcol = (i == 3 and G.C.lose) or (i == 2 and G.C.mult) or G.C.users
    local fill = current and { 0.18, 0.20, 0.26, 1 } or { 0.11, 0.12, 0.15, 1 }
    pixel_rect(x, y0, cw, ch, fill,
      { chamfer = 6, border = current and G.C.arr or G.C.border, line_w = current and 3 or 2 })
    lg.setColor(kindcol); lg.rectangle("fill", x + 4, y0 + 4, cw - 8, 40)
    UI.text(G.FONTS.normal, kinds[i], x, y0 + 10, { 0, 0, 0, 1 }, cw, "center")
    UI.text(G.FONTS.small, "Reach", x, y0 + 72, G.C.text_dim, cw, "center")
    UI.text(G.FONTS.big, "$" .. format_number(target), x, y0 + 94, G.C.arr, cw, "center")
    UI.text(G.FONTS.tiny, "ARR", x, y0 + 138, G.C.text_dim, cw, "center")
    local reward = (RunState.BLIND_REWARD_UNITS[i] or 0)
      * require("game.economy").unit(GAME, RunState.ANTE_BASE)
    if i == 3 then
      lg.setFont(G.FONTS.tiny); lg.setColor(G.C.lose)
      local boss = Bosses.rule(boss_event)
      local desc = boss and (boss.name .. " · " .. Bosses.describe(boss_event)) or "market event"
      lg.printf("! " .. desc, x + 12, y0 + 160, cw - 24, "center")
      UI.text(G.FONTS.tiny, skipped and "Close reward forfeited"
          or ("Close reward +$" .. format_number(reward)),
        x, y0 + 237, skipped and G.C.lose or G.C.win, cw, "center")
    else
      local offer = Leads.offer_for(GAME, i)
      if offer then
        UI.text(G.FONTS.tiny, "LEAD  \194\183  " .. tostring(offer.name or offer.key),
          x + 12, y0 + 156, G.C.win, cw - 24, "center")
        lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
        lg.printf(lead_detail(offer), x + 18, y0 + 177, cw - 36, "center")
      else
        UI.text(G.FONTS.tiny, "standard blind", x + 12, y0 + 172, G.C.text_dim, cw - 24, "center")
      end
      UI.text(G.FONTS.tiny, skipped and "Close reward forfeited"
          or ("Close reward +$" .. format_number(reward)),
        x, y0 + 237, skipped and G.C.lose or G.C.win, cw, "center")
    end
    local label = (skipped and "SKIPPED \194\183 LEAD CLAIMED")
      or (past and "cleared") or (current and "NOW PLAYING" or "upcoming")
    UI.text(G.FONTS.tiny, label, x, y0 + ch - 26, current and G.C.arr or G.C.text_dim, cw, "center")
  end

  local payroll = RunState.payroll_due()
  lg.setFont(G.FONTS.small); lg.setColor((GAME.cash or 0) < 0 and G.C.lose or G.C.text_dim)
  lg.printf(("Cash $%s   \194\183   payroll due $%s   \194\183   founders %d"):format(
    format_number(GAME.cash or 0), payroll, #((G.jokers and G.jokers.cards) or {})),
    0, y0 + ch + 26, W, "center")

  local pb = { x = W / 2 - 130, y = y0 + ch + 62, w = 260, h = 60 }
  UI.rects.play_blind = pb
  draw_button(pb, "Play " .. (bl.kind or "Blind") .. " \194\187",
    true, point_in_rect(mx, my, pb.x, pb.y, pb.w, pb.h))
  if Leads.can_skip(GAME) then
    local offer = Leads.current_offer(GAME)
    local sk = { x = W / 2 - 140, y = pb.y + 74, w = 280, h = 48 }
    UI.rects.skip_blind = sk
    draw_button(sk, "Skip \194\183 Claim " .. tostring((offer and offer.name) or "Lead"), true,
      point_in_rect(mx, my, sk.x, sk.y, sk.w, sk.h), G.FONTS.small)
    UI.text(G.FONTS.tiny, "Forgo this blind's income, close reward, and shop.",
      0, sk.y + sk.h + 10, G.C.lose, W, "center")
  end
end

-- the between-blinds SHOP screen: founder offers + reroll + continue. Immediate-mode;
-- offer panels are drawn from center data (no Card objects to manage). Buttons → G.FUNCS.shop_*.
local function draw_founder_negotiation(W, H, view, mx, my)
  local ng = founder_negotiation_geometry(W, H, view)
  local p = ng.panel
  lg.setColor(0, 0, 0, 0.68)
  lg.rectangle("fill", 332, 0, W - 332, H)
  pixel_rect(p.x, p.y, p.w, p.h, { 0.055, 0.075, 0.11, 0.99 },
    { chamfer = 8, border = G.C.arr, line_w = 3, shadow = true, soy = 6 })

  local center = Centers.get(view.center_key)
  local founder_name = (view.founder and view.founder.name)
    or (center and center.name) or "Legendary Founder"
  UI.text(G.FONTS.tiny, "LEGENDARY FOUNDER · TERM SHEET", p.x + 24, p.y + 18,
    G.C.arr, p.w - 48, "center")
  UI.text(G.FONTS.big, founder_name, p.x + 24, p.y + 44, G.C.text, p.w - 48, "center")
  UI.text(G.FONTS.small, ("ROUND %d/%d   ·   RAPPORT %d/6   ·   SALARY $%d  (BASE $%d)"):format(
      view.round or 1, view.rounds or 3, view.rapport or 0,
      view.projected_salary or view.base_salary or 0, view.base_salary or 0),
    p.x + 24, p.y + 82, G.C.win, p.w - 48, "center")
  UI.text(G.FONTS.tiny, "PITCH LOCKED  ·  WALK AWAY FORFEITS THE OPEN PACK",
    p.x + 24, p.y + 104, G.C.text_dim, p.w - 48, "center")
  UI.text(G.FONTS.tiny, (view.founder and view.founder.rules_text)
      or (center and center.rules_text) or "",
    ng.rules.x, ng.rules.y, G.C.text_dim, ng.rules.w, "left")

  if center then
    local preview = { ability = { config = { _salary = view.projected_salary } } }
    Card.draw_founder_face(ng.portrait, center,
      { card = preview, border = G.C.arr, line_w = 3 })
  end
  UI.text(G.FONTS.tiny, "YOUR NOTES", ng.portrait.x, ng.portrait.y + ng.portrait.h + 18,
    G.C.text_dim, ng.portrait.w, "center")
  local notes_y = ng.portrait.y + ng.portrait.h + 42
  for i, answer in ipairs(view.answers or {}) do
    local note = ("R%d  +%d rapport  ·  %s"):format(i, answer.rapport_delta or 0,
      tostring(answer.text or ""))
    UI.text(G.FONTS.tiny, note, ng.portrait.x, notes_y + (i - 1) * 48,
      G.C.text_dim, ng.portrait.w, "left")
  end

  local question = view.question or {}
  UI.text(G.FONTS.small, question.prompt or "", ng.prompt.x, ng.prompt.y,
    G.C.text, ng.prompt.w, "left")
  if view.phase == "question" then
    for i, choice in ipairs(question.choices or {}) do
      local r = ng.choices[i]
      UI.rects["founder_negotiation_answer_" .. i] = r
      draw_button(r, choice.text or ("Answer " .. i), true,
        point_in_rect(mx, my, r.x, r.y, r.w, r.h), G.FONTS.small)
    end
  elseif view.phase == "feedback" and view.feedback then
    local feedback = view.feedback
    local answer = view.answers and view.answers[#view.answers]
    UI.text(G.FONTS.tiny, "YOU PITCHED", ng.prompt.x, p.y + 224, G.C.text_dim, ng.prompt.w, "left")
    UI.text(G.FONTS.small, answer and answer.text or "", ng.prompt.x, p.y + 248,
      G.C.text, ng.prompt.w, "left")
    UI.text(G.FONTS.tiny, ("RAPPORT +%d  ·  PROJECTED SALARY $%d"):format(
        feedback.rapport_delta or 0, view.projected_salary or view.base_salary or 0),
      ng.prompt.x, p.y + 310, G.C.win, ng.prompt.w, "left")
    UI.text(G.FONTS.small, feedback.reply or "", ng.prompt.x, p.y + 344,
      G.C.arr, ng.prompt.w, "left")
    pixel_rect(ng.prompt.x, p.y + 402, ng.prompt.w, 88, { 0.08, 0.10, 0.14, 0.98 },
      { chamfer = 4, border = G.C.border, line_w = 1, shadow = false })
    UI.text(G.FONTS.tiny, "CONTEXT  ·  " .. tostring(feedback.fact or ""),
      ng.prompt.x + 12, p.y + 416, G.C.text_dim, ng.prompt.w - 24, "left")
    UI.rects.founder_negotiation_continue = ng.continue
    draw_button(ng.continue,
      (view.round or 1) >= (view.rounds or 3) and "Sign negotiated terms" or "Continue the pitch",
      true, point_in_rect(mx, my, ng.continue.x, ng.continue.y, ng.continue.w, ng.continue.h))
  end

  UI.rects.founder_negotiation_standard_terms = ng.standard
  UI.rects.founder_negotiation_walk_away = ng.walk
  draw_button(ng.standard, "Accept standard terms  ·  $" .. tostring(view.base_salary or 0), true,
    point_in_rect(mx, my, ng.standard.x, ng.standard.y, ng.standard.w, ng.standard.h), G.FONTS.tiny)
  draw_button(ng.walk, "Walk away", true,
    point_in_rect(mx, my, ng.walk.x, ng.walk.y, ng.walk.w, ng.walk.h), G.FONTS.tiny)
end

local function draw_shop_tech_drawer(W, H, shop, mx, my)
  local toggle = UI.rects.shop_tech_drawer
  if toggle then
    draw_button(toggle, shop.tech_drawer_open and "Close Tech" or "Your Tech", true,
      point_in_rect(mx, my, toggle.x, toggle.y, toggle.w, toggle.h), G.FONTS.tiny)
  end
  if not shop.tech_drawer_open then return end
  local panel = { x = 332, y = H - Card.H - 86, w = W - 332, h = Card.H + 86 }
  pixel_rect(panel.x, panel.y, panel.w, panel.h, { 0.045, 0.055, 0.08, 0.98 },
    { chamfer = 6, border = G.C.arr, line_w = 2, shadow = false })
  UI.text(G.FONTS.tiny, "YOUR TECH  ·  Select targets, then choose a Roadmap and press Use",
    panel.x + 12, panel.y + 10, G.C.arr, panel.w - 24, "center")
  for _, card in ipairs(CardStack.sorted((G.hand and G.hand.cards) or {})) do card:draw() end
end

function UI.render_shop(W, H, GAME)
  local mx, my = cursor()
  UI.left_panel(GAME, true)                              -- same left counter rail as play, with a SHOP badge
  -- shiny page title (top-centre) + a short founders label (the sell hint moved to the tooltip flow)
  UI.text(G.FONTS.big, "*  THE SHOP  *", 330, 2, G.C.arr, W - 330, "center")   -- ASCII stars: m5x7/m6x11 lack the fancy glyphs
  UI.text(G.FONTS.tiny, "FOUNDERS  " .. #((G.jokers and G.jokers.cards) or {}) .. "/" .. tostring(GAME.founder_slots or 5),
    G.jokers and G.jokers.T.x or 352, (G.jokers and G.jokers.T.y or 24) - 24, G.C.text_dim)

  local sh = GAME.shop or { founders = {} }
  local negotiation = Shop.negotiation_view()
  if negotiation then
    draw_founder_negotiation(W, H, negotiation, mx, my)
    return
  end

  local selC
  for _, c in ipairs((G.consumables and G.consumables.cards) or {}) do if c.selected then selC = c; break end end
  local function draw_consumable_controls()
    if not (selC and selC.center) then return end
    local bw, bh = 92, 28
    local bx = selC.VT.x + (selC.VT.w - bw * 2 - 8) / 2
    local by = selC.VT.y + selC.VT.h + 4
    local use_view = Consumables.selected_use_view(selC, GAME)
    local usable, reason = use_view.legal, use_view.reason
    UI.rects.use_consumable = { x = bx, y = by, w = bw, h = bh }
    draw_button(UI.rects.use_consumable, "Use", usable == true,
      point_in_rect(mx, my, bx, by, bw, bh))
    UI.rects.sell_consumable = { x = bx + bw + 8, y = by, w = bw, h = bh }
    draw_button(UI.rects.sell_consumable, "Sell $" .. Shop.consumable_sell_value(selC), true,
      point_in_rect(mx, my, bx + bw + 8, by, bw, bh))
    if not usable and reason then
      UI.text(G.FONTS.tiny, tostring(reason), math.max(340, bx - 100), by + bh + 5,
        G.C.lose, math.min(420, W - math.max(340, bx - 100) - 12), "center")
    end
  end

  -- sell the selected founder (frees a slot, refunds value) — works in the shop AND during a pack open
  local selF
  for _, c in ipairs((G.jokers and G.jokers.cards) or {}) do if c.selected then selF = c; break end end
  if selF and selF.center then
    local descriptor = FounderActions.descriptor(selF)
    if descriptor then
      draw_button(UI.rects.activate_founder, descriptor.label,
        FounderActions.can_activate(selF, FounderActions.selected_target_uid(selF)),
        UI.rects.activate_founder and point_in_rect(mx, my, UI.rects.activate_founder.x,
          UI.rects.activate_founder.y, UI.rects.activate_founder.w, UI.rects.activate_founder.h), G.FONTS.tiny)
    end
    local fire = UI.rects.fire
    if fire then
      local hov = button_hovered(fire, point_in_rect(mx, my, fire.x, fire.y, fire.w, fire.h))
      pixel_rect(fire.x, fire.y, fire.w, fire.h, hov and G.C.lose or { 0.70, 0.26, 0.26, 1 }, { chamfer = 3, border = G.C.border })
      UI.text(G.FONTS.small, "Sell $" .. Shop.sell_value(selF), fire.x, fire.y + 5, G.C.text, fire.w, "center")
    end
  end

  -- Pack ceremony: shop dims, the cover opens, cards deal face-down and flip in sequence. The options
  -- already exist (shop.lua owns RNG); this timeline only gates when the player may interact with them.
  if sh.pack_open then
    local po = sh.pack_open
    local frame = PackPresentation.snapshot(po)
    local title = (po.name or (po.kind == "playbook" and "Playbook Workshop" or
      (po.kind == "tech_law" and "Tech Law Pack" or
      (po.kind == "moonshot" and "Skunkworks" or
      (po.kind == "tech_evaluation" and "Tech Evaluation" or "Hiring Round"))))):upper()

    lg.setColor(0, 0, 0, frame.ready and 0.58 or 0.72)
    lg.rectangle("fill", 332, 0, W - 332, H)
    draw_consumable_controls()

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
        (roadmap_pack(po.kind) and "  (use or sell a Roadmap card to free a slot)" or
        (po.kind == "tech_evaluation" and "  ·  Adopt +1 or Migrate +0" or ""))
      lg.printf(title .. " \194\183 pick " .. po.picks_left .. capacity_hint, 332, 318, W - 332, "center")
      if po.kind == "tech_evaluation" then
        UI.text(G.FONTS.tiny, "Visible offer modifiers apply on Adopt · Migrate keeps the target's modifiers",
          332, 340, G.C.win, W - 332, "center")
      end
    end
    local n = #po.options
    local pack_layout = ShopView.pack_layout(po, W, H)
    local first_product = pack_layout.options[1].product
    local cw, ch, y0 = first_product.w, first_product.h, first_product.y
    local play_cx = pack_layout.play_center
    local hc, hx, hy
    local migration_targets, migration_target, migration_center
    local migration_effective, migration_before, migration_status
    if po.kind == "tech_evaluation" then
      migration_targets = Shop.tech_migration_targets()
      for _, entry in ipairs(migration_targets) do
        if entry.uid == po.migration_target_uid then migration_target = entry; break end
      end
      migration_target = migration_target or migration_targets[1]
      if migration_target then
        migration_center = Centers.get(migration_target.center_key)
        migration_effective, migration_status, migration_before =
          Card.tech_users(migration_target, migration_center, GAME.era)
      end
    end
    for i = 1, n do
      local c = po.options[i]
      local tech_center = po.kind == "tech_evaluation" and tech_offer_center(c) or nil
      local tech_subject = tech_center and tech_offer_subject(c, tech_center) or nil
      local product_geometry = pack_layout.options[i]
      local x = product_geometry.product.x
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
        elseif roadmap_pack(po.kind) then
          Card.draw_consumable_face({ x = tx, y = ty, w = dw, h = dh }, c,
            { border = hov and G.C.hover or G.C.arr, line_w = hov and 3 or 2 })
        elseif po.kind == "tech_evaluation" then
          Card.draw_tech_face({ x = tx, y = ty, w = dw, h = dh }, tech_center,
            { entry = tech_subject, border = hov and G.C.hover or G.C.border,
              line_w = hov and 3 or 2, era = GAME.era })
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
          if po.kind == "tech_evaluation" then
            local adopt, migrate = product_geometry.adopt, product_geometry.migrate
            UI.rects["pack_adopt_" .. i], UI.rects["pack_migrate_" .. i] = adopt, migrate
            local can_adopt = Deck.can_add(GAME.master_deck, c, GAME.market)
            local can_migrate = migration_target ~= nil and Deck.can_add(GAME.master_deck, c, GAME.market)
            draw_button(adopt, "Adopt", can_adopt,
              point_in_rect(mx, my, adopt.x, adopt.y, adopt.w, adopt.h), G.FONTS.tiny)
            draw_button(migrate, "Migrate", can_migrate,
              point_in_rect(mx, my, migrate.x, migrate.y, migrate.w, migrate.h), G.FONTS.tiny)
            if migration_target then
              local replacement_users = Card.tech_users(migration_target, tech_center, GAME.era)
              UI.text(G.FONTS.tiny, ("Deck +0 · %s -> %s"):format(
                format_number(migration_effective), format_number(replacement_users)),
                x, y0 + ch + 43, can_migrate and G.C.win or G.C.text_dim, cw, "center")
            else
              UI.text(G.FONTS.tiny, "Deck +1", x, y0 + ch + 43, G.C.text_dim, cw, "center")
            end
          else
            local r = product_geometry.pick
            UI.rects["pack_pick_" .. i] = r
            local can_pick = po.kind == "playbook" or
              (roadmap_pack(po.kind) and #(GAME.consumables or {}) < (GAME.consumable_slots or 2)) or
              (po.kind == "hiring" and #G.jokers.cards < Shop.founder_cap())
            local pick_label = po.kind == "hiring"
              and (c.center or c).rarity == "Legendary" and not (c.center or c).signature
              and "Pitch" or "Pick"
            draw_button(r, pick_label, can_pick,
              point_in_rect(mx, my, r.x, r.y, r.w, r.h))
          end
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
      if po.kind == "tech_evaluation" then
        local prev, next = pack_layout.target_prev, pack_layout.target_next
        local target_box = { x = play_cx - 268, y = y0 + ch + 68, w = 536, h = 38 }
        UI.rects.pack_target_prev, UI.rects.pack_target_next = prev, next
        draw_button(prev, "‹", #(migration_targets or {}) > 1,
          point_in_rect(mx, my, prev.x, prev.y, prev.w, prev.h))
        draw_button(next, "›", #(migration_targets or {}) > 1,
          point_in_rect(mx, my, next.x, next.y, next.w, next.h))
        pixel_rect(target_box.x, target_box.y, target_box.w, target_box.h,
          { 0.08, 0.10, 0.14, 0.96 }, { chamfer = 4, border = migration_target and G.C.lose or G.C.border, line_w = 2 })
        if migration_target and migration_center then
          local percent = math.floor((migration_status.penalty or 0) * 100 + 0.5)
          local source_names = { starter = "START", boss_draft = "BOSS", tech_eval_adopt = "EVAL+A",
            tech_eval_migrate = "EVAL+M", generated = "GEN", copied = "COPY", tech_law = "LAW" }
          local source = source_names[migration_target.source]
            or tostring(migration_target.source or "unknown"):gsub("_", " "):upper()
          if migration_target.acquired_ante then source = source .. " A" .. tostring(migration_target.acquired_ante) end
          local target_name = migration_center.short or migration_center.name or migration_center.key
          if #target_name > 20 then target_name = target_name:sub(1, 19) .. "..." end
          UI.text(G.FONTS.tiny, ("REPLACE  %s #%s  ·  %s -> %s Users  ·  -%d%%  ·  %s"):format(
            target_name, tostring(migration_target.uid),
            format_number(migration_before), format_number(migration_effective), percent,
            source),
            target_box.x + 8, target_box.y + 10, G.C.text, target_box.w - 16, "center")
        else
          UI.text(G.FONTS.tiny, "NO DEPRECATED TECH · Migrate is unavailable in this Era",
            target_box.x + 8, target_box.y + 10, G.C.text_dim, target_box.w - 16, "center")
        end
      end
      local sk = pack_layout.skip
      UI.rects.pack_skip = sk
      draw_button(sk, "Skip", true, point_in_rect(mx, my, sk.x, sk.y, sk.w, sk.h))
      if po.error then
        UI.text(G.FONTS.tiny, "Cannot complete evaluation: " .. tostring(po.error),
          332, sk.y + sk.h + 8, G.C.lose, W - 332, "center")
      end
      if hc and po.kind == "hiring" then UI.tip_box(hx, hy, hc.name,
        Card.effect_brief(hc) .. "   \194\183   " .. (hc.rarity or ""),
        (hc.ability_name or "") .. "\n\n" .. (hc.rules_text or hc.hint or ""))
      elseif hc and roadmap_pack(po.kind) then
        local detail = hc.desc or ""
        if po.kind == "moonshot" then
          local payload_text, _, payload_preview = Moonshots.payload_summary(
            hc, hc.moonshot_payload, GAME)
          if payload_text and payload_preview and payload_preview.kind ~= "none" then
            detail = detail .. "\n\nPre-rolled outcome · " .. payload_text
          end
        end
        UI.tip_box(hx, hy, hc.name,
          (hc.kind or "Roadmap") .. "   \194\183   " .. (hc.rarity or ""), detail)
      elseif hc and po.kind == "tech_evaluation" then
        local center = tech_offer_center(hc)
        local subject = tech_offer_subject(hc, center)
        local replacement_users = migration_target and Card.tech_users(migration_target, center, GAME.era)
        local detail = (center.desc or "") .. "\n\nAdopt adds this exact card and its visible modifiers to the deck."
        local modifier_detail = Card.tech_modifier_detail(subject)
        if modifier_detail ~= "" then detail = detail .. "\n\n" .. modifier_detail end
        if migration_target and migration_center then
          detail = detail .. ("\nMigrate replaces %s in place: %s → %s Users; its existing UID and modifiers survive, so the offer modifiers do not apply."):format(
            migration_center.name or migration_center.key, format_number(migration_effective),
            format_number(replacement_users))
        else
          detail = detail .. "\nMigrate needs an owned Deprecated Tech."
        end
        UI.tip_box(hx, hy, center.name, (center.layer or "Tech") .. " · Tech Evaluation", detail)
      end
    end
    draw_shop_tech_drawer(W, H, sh, mx, my)
    return
  end

  draw_consumable_controls()

  local snapshot = Shop.snapshot()
  local layout = ShopView.layout(snapshot, W, H)
  local hovc, hovx, hovy, hovcc, hovccx, hovccy

  local status = layout.actions.status
  pixel_rect(status.x, status.y, status.w, status.h, { 0.08, 0.10, 0.15, 0.98 },
    { chamfer = 5, border = G.C.border, line_w = 1, shadow = false })
  UI.text(G.FONTS.small, "$" .. format_number(snapshot.cash), status.x + 10,
    status.y + 9, G.C.win, status.w - 20, "left")
  UI.text(G.FONTS.tiny, ("Payroll $%s  ·  Founders %d/%d"):format(
    format_number(RunState.payroll_due()), snapshot.capacity.founders.used,
    snapshot.capacity.founders.limit), status.x + 10, status.y + 43,
    G.C.text_dim, status.w - 20, "left")

  local rr, cont = layout.actions.reroll, layout.actions.next_blind
  UI.rects.shop_reroll, UI.rects.shop_continue = rr, cont
  draw_button(rr, "Reroll $" .. tostring(snapshot.commands.reroll.price or 0),
    not snapshot.commands.reroll.disabled_reason,
    point_in_rect(mx, my, rr.x, rr.y, rr.w, rr.h))
  draw_button(cont, "Next Blind \194\187", not snapshot.commands.next_blind.disabled_reason,
    point_in_rect(mx, my, cont.x, cont.y, cont.w, cont.h))

  for i, product in ipairs(layout.primary.founders) do
    local row, r, control = snapshot.offers.founders[i], product.product, product.control
    UI.rects["shop_buy_" .. i] = control
    if row and row.available then
      local center = Centers.get(row.key) or row
      local hov = point_in_rect(mx, my, r.x, r.y, r.w, r.h)
      local rc = SHOP_RARITY_COL[row.rarity] or G.C.border
      Card.draw_founder_face(r, center,
        { border = hov and G.C.hover or rc, line_w = hov and 3 or 2 })
      local rarity = (row.rarity or ""):upper()
      chip(r.x + r.w - (text_w(G.FONTS.tiny, rarity) + 14) - 6, r.y + 5,
        rarity, G.FONTS.tiny, rc, { 0, 0, 0, 1 })
      if row.edition then chip(r.x + 6, r.y + 5, tostring(row.edition),
        G.FONTS.tiny, G.C.arr, { 0, 0, 0, 1 }) end
      draw_button(control, "Buy $" .. tostring(row.price), not row.disabled_reason,
        point_in_rect(mx, my, control.x, control.y, control.w, control.h), G.FONTS.tiny)
      if hov then hovc, hovx, hovy = center, r.x + r.w + 10, r.y end
    else
      pixel_rect(r.x, r.y, r.w, r.h, { 0.12, 0.12, 0.14, 1 },
        { chamfer = 6, border = G.C.border, shadow = false, emboss = false })
      UI.text(G.FONTS.small, "(sold)", r.x, r.y + r.h / 2 - 10,
        G.C.text_dim, r.w, "center")
    end
  end

  local roadmap, roadmap_box = snapshot.offers.roadmap, layout.primary.roadmap
  UI.rects.shop_buy_consumable = roadmap_box.control
  if roadmap and roadmap.available then
    local center = Centers.get(roadmap.key) or roadmap
    local r, control = roadmap_box.product, roadmap_box.control
    local hov = point_in_rect(mx, my, r.x, r.y, r.w, r.h)
    Card.draw_consumable_face(r, center,
      { border = hov and G.C.hover or G.C.arr, line_w = hov and 3 or 2 })
    draw_button(control, "Buy $" .. tostring(roadmap.price), not roadmap.disabled_reason,
      point_in_rect(mx, my, control.x, control.y, control.w, control.h), G.FONTS.tiny)
    if hov then hovcc, hovccx, hovccy = center, r.x + r.w + 10, r.y end
  else
    local r = roadmap_box.product
    pixel_rect(r.x, r.y, r.w, r.h, { 0.12, 0.12, 0.14, 1 },
      { chamfer = 6, border = G.C.border, shadow = false, emboss = false })
    UI.text(G.FONTS.small, "(sold)", r.x, r.y + r.h / 2 - 10, G.C.text_dim, r.w, "center")
  end

  local voucher, voucher_box = snapshot.offers.voucher, layout.voucher
  UI.rects.shop_redeem = voucher_box.control
  local vr = voucher_box.product
  pixel_rect(vr.x, vr.y, vr.w, vr.h, { 0.18, 0.16, 0.20, 1 },
    { chamfer = 4, border = voucher and voucher.available and G.C.arr or G.C.border, line_w = 2 })
  if voucher and voucher.available then
    UI.text(G.FONTS.small, "INVESTMENT \194\183 " .. (voucher.name or ""),
      vr.x + 12, vr.y + 6, G.C.text, vr.w - 130, "left")
    UI.text(G.FONTS.tiny, voucher.description or "", vr.x + 12, vr.y + 28,
      G.C.text_dim, vr.w - 130, "left")
    local control = voucher_box.control
    draw_button(control, "Buy $" .. tostring(voucher.price), not voucher.disabled_reason,
      point_in_rect(mx, my, control.x, control.y, control.w, control.h), G.FONTS.tiny)
  else
    UI.text(G.FONTS.small, "INVESTMENT  ·  REDEEMED", vr.x, vr.y + 18,
      G.C.text_dim, vr.w, "center")
  end

  for i, product in ipairs(layout.packs) do
    local row, r, control = snapshot.offers.packs[i], product.product, product.control
    UI.rects["shop_open_pack_" .. i] = control
    pixel_rect(r.x, r.y, r.w, r.h, { 0.08, 0.10, 0.14, 1 },
      { chamfer = 6, border = row and row.available and G.C.arr or G.C.border, line_w = 2 })
    if row and row.available then
      local cvr = G.PACK_ART and (G.PACK_ART[row.art_key]
        or G.PACK_ART[row.fallback_art] or G.PACK_ART.hiring_round)
      if cvr then
        local iw, ih = cvr:getDimensions()
        local scale = math.min(r.w / iw, r.h / ih)
        lg.setColor(1, 1, 1, 1)
        lg.draw(cvr, r.x + (r.w - iw * scale) / 2,
          r.y + (r.h - ih * scale) / 2, 0, scale, scale)
      else
        UI.text(G.FONTS.small, row.name or "Pack", r.x + 6, r.y + 32,
          G.C.arr, r.w - 12, "center")
      end
      local bonus = math.max(0, (row.options or 0) - ((sh.packs[i] and sh.packs[i].options) or 0))
      local label = "Open $" .. tostring(row.price) .. (bonus > 0 and ("  +" .. bonus) or "")
      draw_button(control, label, not row.disabled_reason,
        point_in_rect(mx, my, control.x, control.y, control.w, control.h), G.FONTS.tiny)
    else
      UI.text(G.FONTS.small, "(opened)", r.x, r.y + r.h / 2 - 10,
        G.C.text_dim, r.w, "center")
    end
  end
  draw_shop_tech_drawer(W, H, sh, mx, my)
  if not sh.tech_drawer_open then
    if hovc then UI.tip_box(hovx, hovy, hovc.name,
      Card.effect_brief(hovc) .. "   \194\183   " .. (hovc.rarity or ""),
      (hovc.ability_name or "") .. "\n\n" .. (hovc.rules_text or hovc.hint or "")) end
    if hovcc then UI.tip_box(hovccx, hovccy, hovcc.name, (hovcc.kind or "Tech Law") .. "   \194\183   " .. (hovcc.rarity or ""), hovcc.desc or "") end
  end
end

-- Compatibility query for tooling that has not adopted game.input yet. The retained list is ordered,
-- so overlays and later/higher-z controls win deterministically.
function UI.button_at(x, y)
  local po = G.STATE == G.STATES.SHOP and G.GAME and G.GAME.shop and G.GAME.shop.pack_open
  if PackPresentation.input_locked(po) then return "pack_fast_forward" end
  for i = #(UI.buttons or {}), 1, -1 do
    local button, r = UI.buttons[i], UI.buttons[i].rect
    if button.enabled ~= false and button.visible ~= false
        and point_in_rect(x, y, r.x, r.y, r.w, r.h) then return button.action end
  end
  return nil
end

-- Static authored onboarding/chatter. It is deliberately presentation-only: gameplay handlers publish
-- events through Guidance, while this function only reads the active lesson or transient toast.
function UI.draw_guidance()
  if G.STATE == G.STATES.MENU or G.STATE == G.STATES.COLLECTION then return end
  local lesson = Guidance.current()
  local toast = G.GUIDANCE_TOAST
  local toast_item = toast and toast.expires > (G.TIMERS.REAL or 0) and toast.message or nil
  if toast_item then
    local prefs = Guidance.preferences()
    if (toast_item.kind == "chatter" and not prefs.cofounder_chatter)
        or (toast_item.kind ~= "chatter" and not prefs.guidance) then toast_item = nil end
  end
  local item = (G.STATE == G.STATES.GAME_OVER and toast_item) or lesson or toast_item
  if not item then return end

  local panel_rect, ack = guidance_geometry(G.WINDOW.w, G.WINDOW.h)
  local compact = panel_rect.w < 400
  pixel_rect(panel_rect.x, panel_rect.y, panel_rect.w, panel_rect.h, { 0.08, 0.10, 0.14, 0.97 },
    { chamfer = 7, border = G.C.arr, line_w = 2 })
  local avatar = { x = panel_rect.x + 12, y = panel_rect.y + 12, w = 42, h = 42 }
  pixel_rect(avatar.x, avatar.y, avatar.w, avatar.h, G.C.arr,
    { chamfer = 5, border = G.C.border, line_w = 2, shadow = false })
  UI.text(G.FONTS.normal, "P", avatar.x, avatar.y + 6, G.C.black, avatar.w, "center")
  local speaker = (item.cofounder and item.cofounder.name) or "Patch"
  local kind = item.kind == "chatter" and "COFOUNDER"
    or (item.kind == "hint" and "TIP" or "BEGINNER GUIDE")
  UI.text(G.FONTS.small, kind,
    avatar.x + avatar.w + 10, panel_rect.y + 10, G.C.arr,
    panel_rect.w - avatar.w - 76, "left")
  UI.text(G.FONTS.tiny, speaker .. (item.title and (" · " .. item.title) or ""),
    avatar.x + avatar.w + 10, panel_rect.y + 35, G.C.text_dim,
    panel_rect.w - avatar.w - 76, "left")
  lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
  lg.printf(item.body or "", panel_rect.x + 14, panel_rect.y + 58, panel_rect.w - 28, "left")
  if item.prompt then
    UI.text(G.FONTS.tiny, item.prompt, panel_rect.x + 14,
      panel_rect.y + panel_rect.h - (compact and 42 or 36), G.C.mult,
      panel_rect.w - (item.id == "welcome" and 138 or 28), "left")
  end
  if item.id == "welcome" then
    local mx, my = cursor()
    draw_button(ack, "Got it", true, point_in_rect(mx, my, ack.x, ack.y, ack.w, ack.h))
  end
end

local function draw_wiki(W, H)
  local view = UI.wiki_view or Wiki.snapshot()
  local geometry = wiki_geometry(W, H, view)
  local panel, mx, my = geometry.panel, cursor()
  pixel_rect(panel.x, panel.y, panel.w, panel.h, { 0.075, 0.09, 0.125, 1 },
    { chamfer = 8, border = G.C.arr, line_w = 2 })
  UI.text(G.FONTS.normal, "PALO LATRO WIKI", panel.x + 22, panel.y + 18, G.C.arr, 360, "left")
  UI.text(G.FONTS.tiny, "Rules, stories, and the links between them", panel.x + 386, panel.y + 25,
    G.C.text_dim, panel.w - 530, "left")
  draw_button(geometry.close, "Close", true,
    point_in_rect(mx, my, geometry.close.x, geometry.close.y, geometry.close.w, geometry.close.h))

  for index, category in ipairs(Wiki.CATEGORIES) do
    draw_collection_tab(geometry.categories[index], category.label, index == view.category_index)
  end

  local search_fill = view.search_focused and { 0.13, 0.17, 0.22, 1 } or { 0.09, 0.11, 0.15, 1 }
  pixel_rect(geometry.search.x, geometry.search.y, geometry.search.w, geometry.search.h, search_fill,
    { chamfer = 4, border = view.search_focused and G.C.arr or G.C.border, line_w = 2 })
  local query = view.query ~= "" and view.query or "Press / or click to search"
  UI.text(G.FONTS.tiny, query .. (view.search_focused and "_" or ""), geometry.search.x + 12,
    geometry.search.y + 10, view.query ~= "" and G.C.text or G.C.text_dim, geometry.search.w - 86, "left")
  if view.query ~= "" then
    draw_button(geometry.clear, "Clear", true,
      point_in_rect(mx, my, geometry.clear.x, geometry.clear.y, geometry.clear.w, geometry.clear.h), G.FONTS.tiny)
  end
  for index, facet in ipairs(view.facets) do
    draw_collection_tab(geometry.facets[index], facet.label, index == view.facet_index)
  end
  local progress = view.progress[view.category.id] or { discovered = view.discovered, total = view.total }
  UI.text(G.FONTS.tiny, ("%s discovered %d/%d"):format(view.category.label,
    progress.discovered or 0, progress.total or 0), geometry.body.x, panel.y + 142,
    G.C.text_dim, geometry.body.w, "left")
  for index, rect in ipairs(geometry.letters) do
    local letter = string.char(string.byte("A") + index - 1)
    local selected = view.letter == letter
    lg.setColor(selected and G.C.arr or G.C.text_dim)
    lg.rectangle("fill", rect.x, rect.y, rect.w, rect.h, 2, 2)
    UI.text(G.FONTS.tiny, letter, rect.x, rect.y + 2, selected and G.C.black or G.C.bg, rect.w, "center")
  end

  pixel_rect(panel.x + 18, panel.y + 216, 378, panel.h - 270, { 0.055, 0.065, 0.09, 1 },
    { chamfer = 5, border = G.C.panel_dim, line_w = 1, shadow = false })
  for index, item in ipairs(view.items) do
    local rect = geometry.items[index]
    local selected = view.selected and view.selected.handle == item.handle
    local fill = selected and { 0.18, 0.24, 0.30, 1 }
      or (item.discovered and { 0.105, 0.125, 0.165, 1 } or { 0.065, 0.075, 0.095, 1 })
    pixel_rect(rect.x, rect.y, rect.w, rect.h, fill,
      { chamfer = 3, border = selected and G.C.arr or G.C.panel_dim, line_w = selected and 2 or 1,
        shadow = false, emboss = false })
    UI.text(G.FONTS.tiny, item.name, rect.x + 9, rect.y + 3,
      item.discovered and G.C.text or G.C.text_dim, rect.w - 18, "left")
    UI.text(G.FONTS.tiny, item.subtitle, rect.x + 9, rect.y + 18,
      item.discovered and G.C.mult or G.C.panel_dim, rect.w - 18, "left")
  end
  UI.text(G.FONTS.tiny, ("%d result%s · page %d/%d"):format(view.filtered_total,
    view.filtered_total == 1 and "" or "s", view.page, view.page_count),
    geometry.prev.x + geometry.prev.w + 4, geometry.prev.y + 6,
    G.C.text_dim, geometry.next.x - geometry.prev.x - geometry.prev.w - 8, "center")
  draw_button(geometry.prev, "‹ Prev", view.page > 1,
    point_in_rect(mx, my, geometry.prev.x, geometry.prev.y, geometry.prev.w, geometry.prev.h), G.FONTS.tiny)
  draw_button(geometry.next, "Next ›", view.page < view.page_count,
    point_in_rect(mx, my, geometry.next.x, geometry.next.y, geometry.next.w, geometry.next.h), G.FONTS.tiny)

  pixel_rect(geometry.body.x, geometry.body.y, geometry.body.w, geometry.body.h,
    { 0.095, 0.11, 0.145, 1 }, { chamfer = 6, border = G.C.border, line_w = 1, shadow = false })
  draw_button(geometry.scroll_up, "↑", view.scroll > 0,
    point_in_rect(mx, my, geometry.scroll_up.x, geometry.scroll_up.y,
      geometry.scroll_up.w, geometry.scroll_up.h), G.FONTS.tiny)
  draw_button(geometry.scroll_down, "↓", view.scroll < 4,
    point_in_rect(mx, my, geometry.scroll_down.x, geometry.scroll_down.y,
      geometry.scroll_down.w, geometry.scroll_down.h), G.FONTS.tiny)

  local page, oy = view.selected, geometry.content_offset_y
  local previous_scissor = { lg.getScissor() }
  local scale, ox, sy = G.VIEW.scale or 1, G.VIEW.ox or 0, G.VIEW.oy or 0
  lg.setScissor(ox + (geometry.body.x + 1) * scale, sy + (geometry.body.y + 1) * scale,
    (geometry.body.w - 2) * scale, (geometry.body.h - 2) * scale)
  if page then
    local bx, bw = geometry.body.x + 24, geometry.body.w - 48
    UI.text(G.FONTS.big, page.name, bx, geometry.body.y + 14 + oy,
      page.discovered and G.C.arr or G.C.text_dim, bw - 90, "left")
    UI.text(G.FONTS.tiny, page.subtitle or "", bx, geometry.body.y + 66 + oy,
      G.C.mult, bw - 90, "left")
    if page.discovered then
      local facet_line = table.concat(page.facets or {}, "  ·  ")
      UI.text(G.FONTS.tiny, facet_line, bx, geometry.body.y + 92 + oy, G.C.text_dim, bw, "left")
      UI.text(G.FONTS.tiny, "EXACT RULES", bx, geometry.body.y + 128 + oy, G.C.arr, bw, "left")
      lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
      lg.printf(page.rules or "", bx, geometry.body.y + 154 + oy, bw, "left")
      if page.story and page.story ~= "" then
        UI.text(G.FONTS.tiny, "STORY", bx, geometry.body.y + 258 + oy, G.C.arr, bw, "left")
        lg.setFont(G.FONTS.tiny); lg.setColor(G.C.text)
        lg.printf(page.story, bx, geometry.body.y + 284 + oy, bw, "left")
      end
      local link_y = geometry.related[1].y - 28
      local col_w = (geometry.body.w - 26) / 2
      UI.text(G.FONTS.tiny, "RELATED", bx, link_y, G.C.arr, col_w, "left")
      UI.text(G.FONTS.tiny, "BACKLINKS", bx + col_w + 22, link_y, G.C.arr, col_w, "left")
      for index, row in ipairs(page.related or {}) do
        local rect = geometry.related[index]
        pixel_rect(rect.x, rect.y, rect.w, rect.h, { 0.12, 0.15, 0.20, 1 },
          { chamfer = 3, border = G.C.panel_dim, line_w = 1, shadow = false })
        UI.text(G.FONTS.tiny, row.label .. " · " .. row.name, rect.x + 7, rect.y + 3,
          G.C.text, rect.w - 14, "left")
      end
      for index, row in ipairs(page.backlinks or {}) do
        local rect = geometry.backlinks[index]
        pixel_rect(rect.x, rect.y, rect.w, rect.h, { 0.12, 0.15, 0.20, 1 },
          { chamfer = 3, border = G.C.panel_dim, line_w = 1, shadow = false })
        UI.text(G.FONTS.tiny, row.label .. " · " .. row.name, rect.x + 7, rect.y + 3,
          G.C.text, rect.w - 14, "left")
      end
      local notes = {}
      if page.hidden_related > 0 then notes[#notes + 1] = page.hidden_related .. " undiscovered relation(s)" end
      if page.related_more > 0 then notes[#notes + 1] = "+" .. page.related_more .. " related" end
      if page.hidden_backlinks > 0 then notes[#notes + 1] = page.hidden_backlinks .. " undiscovered backlink(s)" end
      if page.backlinks_more > 0 then notes[#notes + 1] = "+" .. page.backlinks_more .. " backlinks" end
      if #notes > 0 then
        UI.text(G.FONTS.tiny, table.concat(notes, "  ·  "), bx, link_y + 214,
          G.C.text_dim, bw, "left")
      end
    else
      UI.text(G.FONTS.normal, "?", bx, geometry.body.y + 140 + oy, G.C.text_dim, bw, "center")
      UI.text(G.FONTS.tiny, page.rules, bx, geometry.body.y + 210 + oy, G.C.text_dim, bw, "center")
    end
  else
    UI.text(G.FONTS.normal, "No matching pages", geometry.body.x, geometry.body.y + 210,
      G.C.text_dim, geometry.body.w, "center")
  end
  if previous_scissor[1] then lg.setScissor(unpack(previous_scissor)) else lg.setScissor() end
end

-- ── Phase 4B overlays: deck view · run info · options (topmost, any page; click-outside closes) ────
function UI.draw_overlays()
  if not (G.SHOW_DECK_VIEW or G.SHOW_RUN_INFO or G.SHOW_OPTIONS or G.SHOW_WIKI) then return end
  local W, H = G.WINDOW.w, G.WINDOW.h
  local mx, my = cursor()
  lg.setColor(0, 0, 0, 0.62); lg.rectangle("fill", 0, 0, W, H)

  if G.SHOW_WIKI then draw_wiki(W, H); return end

  if G.SHOW_DECK_VIEW then
    local pw, ph = 1000, 640
    local px0, py0 = (W - pw) / 2, (H - ph) / 2
    pixel_rect(px0, py0, pw, ph, { 0.10, 0.12, 0.16, 1 }, { chamfer = 8, border = G.C.arr, line_w = 2 })
    local master = (G.GAME and G.GAME.master_deck) or {}
    local total = #master
    local remaining = (G.deck and #G.deck.cards) or 0
    local layersmod = require("data.layers")
    local byl, source_counts, deprecated = {}, {}, 0
    local source_short = {
      starter = "START", boss_draft = "BOSS", tech_eval_adopt = "EVAL+A",
      tech_eval_migrate = "EVAL+M", generated = "GEN", copied = "COPY", tech_law = "LAW",
    }
    for _, entry in ipairs(master) do
      local center = Centers.get(entry.center_key)
      if center then
        local L = Card.tech_layer_label(entry, center) or "?"
        local effective, status, before = Card.tech_users(entry, center, G.GAME and G.GAME.era)
        byl[L] = byl[L] or {}
        byl[L][#byl[L] + 1] = { entry = entry, center = center, effective = effective,
          before = before, status = status }
        if status.state == "deprecated" then deprecated = deprecated + 1 end
        local source = entry.source or "unknown"
        source_counts[source] = (source_counts[source] or 0) + 1
      end
    end

    UI.text(G.FONTS.normal, "YOUR TECH DECK", px0, py0 + 12, G.C.arr, pw, "center")
    UI.text(G.FONTS.tiny, ("%d in draw pile  \194\183  %d owned  \194\183  %d Deprecated  \194\183  click anywhere to close"):format(
      remaining, total, deprecated), px0, py0 + 44, deprecated > 0 and G.C.lose or G.C.text_dim, pw, "center")
    local source_parts = {}
    for source, count in pairs(source_counts) do source_parts[#source_parts + 1] = { source = source, count = count } end
    table.sort(source_parts, function(a, b) return a.source < b.source end)
    local source_text = {}
    for _, item in ipairs(source_parts) do
      source_text[#source_text + 1] = (source_short[item.source] or item.source:gsub("_", " "):upper()) .. " " .. item.count
    end
    UI.text(G.FONTS.tiny, "ACQUISITION  " .. table.concat(source_text, "  \194\183  "),
      px0 + 20, py0 + 66, G.C.text_dim, pw - 40, "center")

    local order = { "Frontend", "Backend", "Data", "Infra", "AI", "Knowledge" }
    if #(byl["Any Layer"] or {}) > 0 then order[#order + 1] = "Any Layer" end
    if #(byl["No Layer"] or {}) > 0 then order[#order + 1] = "No Layer" end
    local gap, inner_x, inner_w = 8, px0 + 20, pw - 40
    local col_w = (inner_w - gap * (#order - 1)) / #order
    local top, row_h, row_gap = py0 + 100, 42, 4
    local max_rows = math.floor((py0 + ph - 24 - (top + 28)) / (row_h + row_gap))
    local function clipped_name(value)
      value = tostring(value or "?")
      return #value > 17 and (value:sub(1, 16) .. "...") or value
    end
    for _, L in ipairs(order) do
      local list, col_index = byl[L] or {}, 1
      for index, name in ipairs(order) do if name == L then col_index = index; break end end
      local x = inner_x + (col_index - 1) * (col_w + gap)
      local lcol = (layersmod[L] and layersmod[L].color) or G.C.text
      pixel_rect(x, top, col_w, 24, { 0.07, 0.09, 0.13, 0.96 },
        { chamfer = 3, border = lcol, line_w = 2, shadow = false })
      UI.text(G.FONTS.tiny, L:upper() .. "  " .. #list, x + 3, top + 4, lcol, col_w - 6, "center")
      table.sort(list, function(a, b)
        local ad, bd = a.status.state == "deprecated", b.status.state == "deprecated"
        if ad ~= bd then return ad end
        if a.center.name ~= b.center.name then return a.center.name < b.center.name end
        return tostring(a.entry.uid) < tostring(b.entry.uid)
      end)
      for i = 1, math.min(#list, max_rows) do
        local item = list[i]
        local y = top + 28 + (i - 1) * (row_h + row_gap)
        local is_deprecated = item.status.state == "deprecated"
        local bg = is_deprecated and { 0.29, 0.10, 0.10, 0.96 } or { 0.14, 0.16, 0.21, 0.96 }
        pixel_rect(x, y, col_w, row_h, bg,
          { chamfer = 3, border = is_deprecated and G.C.lose or lcol, line_w = is_deprecated and 2 or 1,
            shadow = false, emboss = false })
        local value = tostring(item.effective)
        if is_deprecated then value = value .. " (-" .. math.floor(item.status.penalty * 100 + 0.5) .. "%)" end
        UI.text(G.FONTS.tiny, value .. "  " .. clipped_name(item.center.short or item.center.name),
          x + 5, y + 2, is_deprecated and G.C.lose or G.C.text, col_w - 10, "left")
        local modifier_parts = {}
        for _, row in ipairs(Card.tech_modifier_rows(item.entry)) do
          local short = tostring(row.short or row.label or row.key)
          if #short > 6 then short = short:sub(1, 6) end
          modifier_parts[#modifier_parts + 1] = row.prefix .. ":" .. short
        end
        UI.text(G.FONTS.tiny, #modifier_parts > 0 and table.concat(modifier_parts, " · ") or "NO MODIFIERS",
          x + 5, y + 15, #modifier_parts > 0 and G.C.win or G.C.panel_dim, col_w - 10, "left")
        local src = source_short[item.entry.source] or tostring(item.entry.source or "UNKNOWN"):upper()
        if item.entry.acquired_ante then src = src .. " A" .. tostring(item.entry.acquired_ante) end
        if item.entry.migrated_from then
          local old = Centers.get(item.entry.migrated_from)
          src = src .. " <- " .. clipped_name(old and (old.short or old.name) or item.entry.migrated_from)
        end
        UI.text(G.FONTS.tiny, src, x + 5, y + 28, G.C.text_dim, col_w - 10, "left")
      end
      if #list > max_rows then
        UI.text(G.FONTS.tiny, "+" .. (#list - max_rows) .. " more", x, py0 + ph - 22, G.C.text_dim, col_w, "center")
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
    ty = ty + 10
    UI.text(G.FONTS.tiny, "AI SOLUTION LADDER  (highest evidence)", px0 + 30, ty, G.C.arr, 550, "left")
    ty = ty + 22
    for index, rung in ipairs(AIMaturity.list or {}) do
      UI.text(G.FONTS.tiny, index .. ".  " .. rung.name, px0 + 30, ty, G.C.text, 300, "left")
      UI.text(G.FONTS.tiny, ("+%d Users  ×%.2f Rev"):format(rung.users_bonus, rung.rev_mult),
        px0 + 340, ty, G.C.users, 190, "left")
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
    local market_view = Markets.view(g.market)
    local market_state = Markets.active_state(g)
    fact("MARKET", ((g.market and g.market.name) or "?") ..
      (g.pending_market and (" → " .. g.pending_market.name .. " next blind") or ""), G.C.arr)
    fact("FIT DEMAND", market_view and market_view.fit.label or "?")
    fact("MARKET RULE", market_view and market_view.perk.effect or "?")
    if market_view and (market_view.economy.free_distill_per_ante or 0) > 0 then
      fact("MARKET STATUS", market_state.free_distill_ready and "Free Distill ready" or "Free Distill used this Ante",
        market_state.free_distill_ready and G.C.win or G.C.text_dim)
    end
    fact("STAKE", tostring(g.stake or 1) .. " \194\183 " .. (RS.STAGE_NAME[g.ante or 1] or ""))
    local boss_key = g.blind and g.blind.event
    local boss = boss_key and Bosses.rule(boss_key)
    fact("BOSS TELEGRAPH", boss and (boss.name .. ": " .. Bosses.describe(boss_key)) or "(see blind select)")
    fact("PAYROLL DUE", "-$" .. format_number(RS.payroll_due() or 0), G.C.mult)
    local fixed_reward = (RS.BLIND_REWARD_UNITS[g.blind_idx or 1] or 0) * Economy.unit(g, RS.ANTE_BASE)
    local close_projection = {}
    for key, value in pairs(g) do close_projection[key] = value end
    close_projection.ships_left = math.max(0, (g.ships_left or 0) - 1)
    local early_reward = Economy.early_close_reward(close_projection, RS.ANTE_BASE)
    fact("CLOSE \194\183 BLIND + EARLY",
      ("+$%s \194\183 operating income separate"):format(
        format_number(fixed_reward + early_reward)), G.C.win)
    if market_view and (market_view.economy or {}).high_fit_lead then
      local floor = market_view.economy.high_fit_floor or 0
      local best = market_state.best_fit_this_blind or 0
      local last = market_state.last_lead and Leads.get(market_state.last_lead)
      local health_status, health_col
      if last then
        health_status, health_col = "Last clear granted " .. last.name, G.C.win
      elseif Markets.earns_high_fit_lead(g) then
        health_status, health_col = ("Ready on clear \194\183 Fit ×%.2f"):format(best), G.C.win
      else
        health_status, health_col = ("Need Fit ×%.2f+ \194\183 best ×%.2f"):format(floor, best), G.C.text_dim
      end
      fact("HEALTHTECH HIGH-FIT LEAD", health_status, health_col)
    end
    local vlist = {}
    for k in pairs(g.vouchers_owned or {}) do vlist[#vlist + 1] = (k:gsub("^v_", "")) end
    fact("INVESTMENTS", #vlist > 0 and table.concat(vlist, ", ") or "(none)")
    return
  end

  if G.SHOW_OPTIONS then
    local geometry = Options.geometry(W, H)
    local panel = geometry.panel
    pixel_rect(panel.x, panel.y, panel.w, panel.h, { 0.10, 0.12, 0.16, 1 },
      { chamfer = 8, border = G.C.arr, line_w = 2 })
    UI.text(G.FONTS.normal, geometry.title, panel.x, panel.y + 14, G.C.arr, panel.w, "center")
    for _, row in ipairs(geometry.rows) do
      UI.rects[row.action] = row.rect
      draw_button(row.rect, row.label, true,
        point_in_rect(mx, my, row.rect.x, row.rect.y, row.rect.w, row.rect.h))
    end
    UI.text(G.FONTS.tiny, geometry.page == "root" and "Choose a category" or "Settings apply immediately",
      panel.x, panel.y + panel.h - 48, G.C.text_dim, panel.w, "center")
    UI.text(G.FONTS.tiny, "click outside to close", panel.x, panel.y + panel.h - 25,
      G.C.panel_dim, panel.w, "center")
    return
  end
end

return UI
