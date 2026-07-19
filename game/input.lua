-- game/input.lua — runtime adapter from virtual HID events to the pure engine/controller core.
--
-- This module never samples love.mouse. The caller maps window coordinates to virtual coordinates,
-- supplies the current ordered UI button specs, and forwards LÖVE callbacks through this API:
--
--   local input = Input.new({ width = G.VW, height = G.VH })
--   input:update(dt, buttons)                 -- buttons: bottom-to-top ordered array
--   input:pointer_moved(x, y, device)
--   input:pointer_pressed(x, y, button, device)
--   input:pointer_released(x, y, button, device)
--   input:key_pressed(key, device) / input:key_released(key)
--   input:release_node(node) / input:reset()
--
-- A button spec is `{ id|name|action, rect={x,y,w,h}, enabled?, scope?, global? }`.
-- The adapter reconciles targets by stable id, so a UI rebuild cannot break a press or drag that
-- spans frames. It emits no gameplay mutations except through G.FUNCS or the established card/
-- consumable interaction seams.

local Controller = require("engine.controller")
local PackPresentation = require("game.pack_presentation")
local Audio = require("game.audio")
local Guidance = require("game.guidance")
local Consumables = require("game.consumables")
local CardStack = require("game.card_stack")
local Wiki = require("game.wiki")
local Options = require("game.options")

local Input = {}
Input.__index = Input

local KEY_ACTION = {
  space = "ship", f = "refactor", d = "distill", p = "promote", x = "activate_founder",
  e = "raise", v = "market_pivot", r = "restart",
}

local function game()
  return _G.G
end

local function cards(area)
  return (area and area.cards) or {}
end

local function state_is(name)
  local g = game()
  return g and g.STATES and g.STATE == g.STATES[name]
end

local function point_rect(rect)
  return rect and type(rect.x) == "number" and type(rect.y) == "number"
    and type(rect.w) == "number" and type(rect.h) == "number"
end

local function target_node(id, rect)
  return {
    ID = "input:" .. tostring(id),
    T = rect,
    states = {
      visible = true, collide = { can = true, is = false }, hover = { can = true, is = false },
      click = { can = true, is = false }, drag = { can = false, is = false },
      focus = { can = true, is = false },
    },
  }
end

local function selectable_state()
  return state_is("SELECTING_HAND")
end

local function founder_state()
  return state_is("SELECTING_HAND") or state_is("SHOP")
end

local function shop_tech_drawer_open()
  local g = game()
  return state_is("SHOP") and g and g.GAME and g.GAME.shop
    and g.GAME.shop.tech_drawer_open == true
end

local function tech_selection_state()
  return selectable_state() or shop_tech_drawer_open()
end

local function overlay_open()
  local g = game()
  return g and (g.SHOW_DECK_VIEW or g.SHOW_RUN_INFO or g.SHOW_OPTIONS or g.SHOW_WIKI) == true
end

local function pack_open()
  local g = game()
  return g and g.STATES and g.STATE == g.STATES.SHOP
    and g.GAME and g.GAME.shop and g.GAME.shop.pack_open or nil
end

local function founder_negotiation_open()
  local g = game()
  return g and g.STATES and g.STATE == g.STATES.SHOP
    and g.GAME and g.GAME.shop and g.GAME.shop.founder_negotiation ~= nil
end

local function pulse(card, amount)
  if card and card.juice_up then card:juice_up(amount or 0.3) end
  Audio.play("select", nil, 0.5)
end

local function selected_count(area)
  if area and area.highlighted then return #area:highlighted() end
  local count = 0
  for _, card in ipairs(cards(area)) do if card.selected then count = count + 1 end end
  return count
end

local function close_overlay()
  local g = game()
  if not g then return false end
  if g.SHOW_WIKI then return Wiki.close() end
  local open = g.SHOW_DECK_VIEW or g.SHOW_RUN_INFO or g.SHOW_OPTIONS
  g.SHOW_DECK_VIEW, g.SHOW_RUN_INFO, g.SHOW_OPTIONS = nil, nil, nil
  if open then Options.reset() end
  return open and true or false
end

function Input.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Input)
  self.controller = Controller.new({
    virtual_width = opts.width or opts.virtual_width,
    virtual_height = opts.height or opts.virtual_height,
    click_distance = opts.click_distance,
    mouse_drag_distance = opts.mouse_drag_distance,
    mouse_click_slop = opts.mouse_click_slop,
    touch_drag_distance = opts.touch_drag_distance,
    touch_click_slop = opts.touch_click_slop,
    pointer_scale = opts.pointer_scale or opts.display_scale,
    click_timeout = opts.click_timeout,
  })
  self._registrations, self._button_nodes, self._meta = {}, {}, {}
  self._buttons, self._founder_drag = {}, nil
  local g = game()
  if g then g.CONTROLLER = self.controller end
  return self
end

function Input:_modal_scope()
  if Wiki.is_open() then return "wiki" end
  if overlay_open() then return "overlay" end
  if state_is("TARGET_SELECT") then return "target" end
  if founder_negotiation_open() then return "negotiation" end
  if pack_open() then return "pack" end
  return nil
end

function Input:_sync_policy()
  local pack = pack_open()
  self.controller:set_modal(self:_modal_scope())
  self.controller:set_gameplay_locked(not Wiki.is_open()
    and (state_is("SCORING") or PackPresentation.input_locked(pack)))
end

function Input:_scope_for_action(action, supplied)
  if supplied ~= nil then return supplied end
  if action and action:match("^wiki_") then return "wiki" end
  if action and action:match("^opt_") then return "overlay" end
  if action and action:match("^pick_layer_") then return "target" end
  if action and action:match("^founder_negotiation_") then return "negotiation" end
  if pack_open() and (action == "fire" or action:match("^pack_")) then return "pack" end
  return nil
end

function Input:_sync_target(key, node, opts, seen)
  seen[key] = true
  local registration = self._registrations[key]
  if registration and registration.released then
    self._registrations[key] = nil
    registration = nil
  end
  if registration and registration.node ~= node then
    if self._founder_drag and self._founder_drag.card == registration.node then
      self:_restore_founder_drag()
    end
    self.controller:release_node(registration)
    self._registrations[key] = nil
    registration = nil
  end
  if not registration then
    registration = self.controller:add_target(node, opts)
    self._registrations[key] = registration
  else
    registration.id = opts.id or node.ID
    registration.z = opts.z or 0
    registration.focus_order = opts.focus_order or opts.navigation_order
    registration.scope = opts.scope
    registration.global = opts.global == true
    registration.action = opts.action or "activate"
    registration.allow_when_locked = opts.allow_when_locked == true
      or registration.action == "cancel" or registration.action == "back"
    registration.focusable = opts.focusable ~= false
    registration.enabled, registration.visible = opts.enabled, opts.visible
    registration.hit_test, registration.bounds = opts.hit_test, opts.bounds
    registration.draggable = opts.draggable == true
    registration.released = nil
  end
  self._meta[node] = opts.meta
  return registration
end

function Input:_drop_missing(seen)
  local missing = {}
  for key in pairs(self._registrations) do if not seen[key] then missing[#missing + 1] = key end end
  table.sort(missing)
  for _, key in ipairs(missing) do
    local registration = self._registrations[key]
    local node = registration and registration.node
    if self._founder_drag and self._founder_drag.card == node then self:_restore_founder_drag() end
    self.controller:release_node(registration)
    self._registrations[key] = nil
    if node then self._meta[node] = nil end
  end
end

local function button_fields(spec)
  local action = spec.action or spec.name or spec.id or spec[1]
  local rect = spec.rect or spec.bounds or spec[2]
  if not rect and point_rect(spec) then rect = spec end
  return action, rect
end

function Input:rebuild(button_specs)
  self._buttons = button_specs or self._buttons or {}
  local seen, z, focus_sequence = {}, 0, 0
  local g = game()

  local function add(key, node, opts)
    z = z + 1
    opts.z = z
    if opts.focus_order == nil then
      focus_sequence = focus_sequence + 1
      opts.focus_order = focus_sequence
    else
      focus_sequence = math.max(focus_sequence, opts.focus_order)
    end
    self:_sync_target(key, node, opts, seen)
  end

  local function ordered_area(area)
    local list, indices = cards(area), {}
    for index, card in ipairs(list) do indices[card] = index end
    return CardStack.sorted(list), indices
  end

  if selectable_state() and g and g.deck then
    add("draw_pile", g.deck, {
      id = "draw_pile", action = "draw_pile", bounds = function(node) return node.T end,
      focusable = true, meta = { kind = "draw_pile" },
    })
  end

  local pending = state_is("TARGET_SELECT") and g and g.PENDING_CONSUMABLE or nil
  local target_area_name = pending and (pending.target_area_name
    or select(2, Consumables.target_area(pending.card)))
  local defer_shop_hand = shop_tech_drawer_open() and not pending
  local function add_hand_targets()
    local ordered, indices = ordered_area(g.hand)
    local focus_base = focus_sequence
    for _, card in ipairs(ordered) do
      local i = indices[card]
      local target_mode = pending ~= nil
      add("hand:" .. tostring(card.ID or card), card, {
        id = "hand:" .. tostring(card.ID or i), action = target_mode and "target_card" or "hand_card",
        scope = target_mode and "target" or (pack_open() and "pack" or nil),
        focus_order = focus_base + i,
        enabled = function(node)
          if not target_mode then return true end
          return pending ~= nil and not pending.need_layer and not node.selected
            and Consumables.can_target(pending.card, node, g.GAME) == true
        end,
        meta = { kind = target_mode and "target_card" or "hand_card", card = card },
      })
    end
    focus_sequence = math.max(focus_sequence, focus_base + #ordered)
  end
  if (tech_selection_state() or (pending and target_area_name == "hand"))
      and g and g.hand and not defer_shop_hand then
    add_hand_targets()
  end

  if (founder_state() or (pending and target_area_name == "founder")) and g and g.jokers then
    local ordered, indices = ordered_area(g.jokers)
    local focus_base = focus_sequence
    for _, card in ipairs(ordered) do
      local i = indices[card]
      local target_mode = pending ~= nil and target_area_name == "founder"
      add("founder:" .. tostring(card.ID or card), card, {
        id = "founder:" .. tostring(card.ID or i), action = target_mode and "target_card" or "founder_card",
        scope = target_mode and "target" or (pack_open() and "pack" or nil),
        focus_order = focus_base + i,
        enabled = function(node)
          if not target_mode then return true end
          return pending ~= nil and not pending.need_layer and not node.selected
            and Consumables.can_target(pending.card, node, g.GAME) == true
        end,
        draggable = not target_mode,
        meta = { kind = target_mode and "target_card" or "founder_card", card = card },
      })
    end
    focus_sequence = math.max(focus_sequence, focus_base + #ordered)
  end

  if founder_state() and g and g.consumables then
    local ordered, indices = ordered_area(g.consumables)
    local focus_base = focus_sequence
    for _, card in ipairs(ordered) do
      local i = indices[card]
      add("consumable:" .. tostring(card.ID or card), card, {
        id = "consumable:" .. tostring(card.ID or i), action = "consumable_card",
        scope = pack_open() and "pack" or nil,
        focus_order = focus_base + i,
        meta = { kind = "consumable_card", card = card },
      })
    end
    focus_sequence = math.max(focus_sequence, focus_base + #ordered)
  end

  if overlay_open() and not Wiki.is_open() and g and g.WINDOW then
    local w, h = g.WINDOW.w or 0, g.WINDOW.h or 0
    local backdrops
    if g.SHOW_OPTIONS then
      local panel = Options.geometry(w, h).panel
      local px, py, pw, ph = panel.x, panel.y, panel.w, panel.h
      -- Options closes only outside its panel. Four rectangles leave the panel itself inert while
      -- avoiding a custom, stateful hit-test seam.
      backdrops = {
        { x = 0, y = 0, w = w, h = py },
        { x = 0, y = py + ph, w = w, h = h - py - ph },
        { x = 0, y = py, w = px, h = ph },
        { x = px + pw, y = py, w = w - px - pw, h = ph },
      }
    else
      -- Deck and Run Info explicitly advertise click-anywhere dismissal.
      backdrops = { { x = 0, y = 0, w = w, h = h } }
    end
    for i, rect in ipairs(backdrops) do
      local key = "modal_backdrop_" .. i
      local node = self._button_nodes[key] or target_node(key, rect)
      node.T = rect; self._button_nodes[key] = node
      add("button:" .. key, node, {
        id = key, action = "modal_backdrop", scope = "overlay", focusable = false,
        bounds = function(n) return n.T end,
        meta = { kind = "button", action = "modal_backdrop" },
      })
    end
  end

  if state_is("GAME_OVER") and g and g.WINDOW then
    local rect = { x = 0, y = 0, w = g.WINDOW.w or 0, h = g.WINDOW.h or 0 }
    local node = self._button_nodes.restart_screen or target_node("restart_screen", rect)
    node.T = rect; self._button_nodes.restart_screen = node
    add("button:restart_screen", node, {
      id = "restart_screen", action = "restart", bounds = function(n) return n.T end,
      meta = { kind = "button", action = "restart" },
    })
  end

  for index, spec in ipairs(self._buttons) do
    local action, rect = button_fields(spec)
    if type(action) == "string" and point_rect(rect) then
      local id = spec.id or action
      local key = "button:" .. tostring(id)
      local node = self._button_nodes[key] or target_node(id, rect)
      node.T = rect; self._button_nodes[key] = node
      add(key, node, {
        id = id, action = action, scope = self:_scope_for_action(action, spec.scope),
        global = spec.global, enabled = spec.enabled, visible = spec.visible,
        allow_when_locked = spec.allow_when_locked,
        focusable = spec.focusable ~= false,
        bounds = function(n) return n.T end,
        meta = { kind = "button", action = action, index = index, command = spec.command },
      })
    end
  end


  -- The open Shop drawer is a foreground tray. Register its Tech cards after product controls so
  -- pointer hit order matches the cards that are drawn over the shelf; focus order stays semantic.
  if defer_shop_hand and g and g.hand then add_hand_targets() end

  self:_drop_missing(seen)
  local current_pack = pack_open()
  local current_pack_id = current_pack and (current_pack.open_id or current_pack) or nil
  if self._pack_open_id and not current_pack then
    local restore_id
    for _, spec in ipairs(self._buttons) do
      local action = spec.action or spec.name or spec.id or spec[1]
      if spec.enabled ~= false and type(action) == "string"
          and action:match("^shop_open_pack_%d+$") then
        restore_id = spec.id or action
        break
      end
    end
    restore_id = restore_id or "shop_reroll"
    local registration = self._registrations["button:" .. tostring(restore_id)]
    if registration then self.controller:focus(registration.node) end
  end
  self._pack_open_id = current_pack_id
  self:_sync_policy()
  if g and g.WIKI_RESTORE_FOCUS then
    for _, registration in pairs(self._registrations) do
      if registration.id == g.WIKI_RESTORE_FOCUS then
        self.controller:focus(registration.node)
        break
      end
    end
    g.WIKI_RESTORE_FOCUS = nil
  end
  self.controller:refresh()
  self:_consume()
  return self.controller.targets
end

function Input:update(dt, button_specs)
  self.controller:begin_frame(dt or 0)
  if button_specs ~= nil then self:rebuild(button_specs)
  else self:_sync_policy(); self:_consume() end
end

function Input:_call(action, command)
  local g = game()
  local fn = g and g.FUNCS and g.FUNCS[action]
  if not fn then return false end
  fn(command)
  self:_sync_policy()
  return true
end

function Input:_toggle_hand(card)
  local g = game()
  if not (tech_selection_state() and g and g.hand and card) then return false end
  local max_selected = (g.GAME and g.GAME.select_max) or math.huge
  if not card.selected and selected_count(g.hand) >= max_selected then return false end
  if card.toggle_select then card:toggle_select()
  else card.selected = not card.selected; if g.hand.align_cards then g.hand:align_cards() end end
  pulse(card, 0.35)
  local count = selected_count(g.hand)
  if count > 0 then
    Guidance.emit("cards_selected", { count = count })
    local lesson = Guidance.current()
    if lesson and lesson.id == "compatibility" and count >= 2 then
      Guidance.emit("compatibility_inspected", { count = count })
    end
  end
  return true
end

function Input:_pick_target(card)
  local g = game()
  local pending = g and g.PENDING_CONSUMABLE
  if not (state_is("TARGET_SELECT") and pending and not pending.need_layer and card and not card.selected
      and Consumables.can_target(pending.card, card, g.GAME) == true) then return false end
  pulse(card, 0.35)
  if g.CONSUMABLE_TARGET_PICK then g.CONSUMABLE_TARGET_PICK(card); return true end
  return false
end

function Input:_toggle_one(area, card)
  if not (area and card) then return false end
  local next_value = not card.selected
  for _, other in ipairs(cards(area)) do other.selected = false end
  card.selected = next_value
  if area.align_cards then area:align_cards() end
  pulse(card, 0.3)
  return true
end

function Input:_reorder_founder(card, x)
  local g = game()
  local area = g and g.jokers
  local list = cards(area)
  if not (area and card and #list > 1) then return false end
  local current
  for i, candidate in ipairs(list) do if candidate == card then current = i; break end end
  if not current then return false end
  local cw = card.T and card.T.w or 1
  local gap, step = 12, cw + 12
  local width = area.T and area.T.w or (#list * cw + (#list - 1) * gap)
  if #list > 1 and (#list * cw + (#list - 1) * gap) > width then step = (width - cw) / (#list - 1) end
  local start = (area.T and area.T.x or 0) + (width - ((#list - 1) * step + cw)) / 2
  local target = #list
  for i = 1, #list do
    if x < start + (i - 1) * step + cw / 2 then target = i; break end
  end
  if target ~= current then
    table.remove(list, current)
    table.insert(list, target, card)
    if area.align_cards then area:align_cards() end
  end
  if card.set_T and self._founder_drag then
    card:set_T(x - self._founder_drag.grabx, (area.T and area.T.y or 0) - 14)
  end
  return true
end

function Input:_restore_founder_drag()
  local drag = self._founder_drag
  local g = game()
  local area = g and g.jokers
  if not (drag and area and drag.card) then self._founder_drag = nil; return false end
  local list, current = cards(area), nil
  for i, candidate in ipairs(list) do if candidate == drag.card then current = i; break end end
  if current and drag.original_index and current ~= drag.original_index then
    table.remove(list, current)
    table.insert(list, math.min(drag.original_index, #list + 1), drag.card)
  end
  if area.align_cards then area:align_cards() end
  self._founder_drag = nil
  return true
end

function Input:_dispatch_click(intent, meta)
  local g = game()
  if not meta then return false end
  if meta.kind == "button" then
    if meta.action == "modal_backdrop" then return close_overlay() end
    if meta.action == "pack_locked" then return true end
    return self:_call(meta.action, meta.command)
  elseif meta.kind == "draw_pile" then
    if selectable_state() and g then g.SHOW_DECK_VIEW = true; self:_sync_policy(); return true end
  elseif meta.kind == "hand_card" then return self:_toggle_hand(meta.card)
  elseif meta.kind == "target_card" then return self:_pick_target(meta.card)
  elseif meta.kind == "founder_card" then
    return founder_state() and self:_toggle_one(g and g.jokers, meta.card) or false
  elseif meta.kind == "consumable_card" then
    return founder_state() and self:_toggle_one(g and g.consumables, meta.card) or false
  end
  return false
end

function Input:_cancel()
  local g = game()
  if not g then return false end
  if Wiki.is_open() and not state_is("COLLECTION") then
    local state = g.WIKI or {}
    if state.query and state.query ~= "" then Wiki.set_query(""); return true end
    if state.search_focused then Wiki.focus_search(false); return true end
    if Wiki.history_back() then return true end
    return self:_call("wiki_close")
  end
  if state_is("COLLECTION") then return self:_call("collection_back") end
  if state_is("TARGET_SELECT") and g.CONSUMABLE_CANCEL then g.CONSUMABLE_CANCEL(); return true end
  if overlay_open() then return close_overlay() end
  local po = pack_open()
  if po then
    local action = PackPresentation.input_locked(po) and "pack_fast_forward" or "pack_skip"
    return self:_call(action, { payload = { open_id = po.open_id } })
  end
  if g.FUNCS and g.FUNCS.cancel then g.FUNCS.cancel(); return true end
  if g.FUNCS and g.FUNCS.back then g.FUNCS.back(); return true end
  return false
end

function Input:_dispatch_intent(intent)
  local meta = intent.target and self._meta[intent.target] or nil
  if intent.kind == "click" then return self:_dispatch_click(intent, meta)
  elseif intent.kind == "action" then return self:_call(intent.action)
  elseif intent.kind == "cancel" or intent.kind == "back" then return self:_cancel()
  elseif intent.kind == "drag" and meta and meta.kind == "founder_card" then
    local g = game()
    if intent.phase == "start" and founder_state() then
      local tx = meta.card.T and meta.card.T.x or intent.cursor.x
      local original_index
      for i, candidate in ipairs(cards(g and g.jokers)) do
        if candidate == meta.card then original_index = i; break end
      end
      self._founder_drag = {
        card = meta.card, original_index = original_index,
        grabx = (intent.origin and intent.origin.x or intent.cursor.x) - tx,
      }
      return self:_reorder_founder(meta.card, intent.cursor.x)
    elseif intent.phase == "move" and self._founder_drag and self._founder_drag.card == meta.card then
      return self:_reorder_founder(meta.card, intent.cursor.x)
    elseif intent.phase == "end" and self._founder_drag and self._founder_drag.card == meta.card then
      if intent.cancelled then return self:_restore_founder_drag() end
      if g and g.jokers and g.jokers.align_cards then g.jokers:align_cards() end
      self._founder_drag = nil
      return true
    end
  end
  return false
end

function Input:_consume()
  local handled = false
  for _, intent in ipairs(self.controller:drain_intents()) do
    if self:_dispatch_intent(intent) then handled = true end
  end
  return handled
end

function Input:pointer_moved(x, y, device, physical_x, physical_y)
  self:_sync_policy()
  self.controller:pointer_move(x, y, device or "mouse", physical_x, physical_y)
  return self:_consume()
end

function Input:pointer_pressed(x, y, button, device, physical_x, physical_y)
  self:_sync_policy()
  button = button or 1
  if button == 2 then
    self.controller:pointer_move(x, y, device or "mouse", physical_x, physical_y)
    self.controller.hid.buttons[2] = true
    local po = pack_open()
    if state_is("TARGET_SELECT") then
      self.controller:cancel({ button = button })
    elseif po then
      local action = PackPresentation.input_locked(po) and "pack_fast_forward" or "pack_skip"
      return self:_call(action, { payload = { open_id = po.open_id } })
    end
  elseif button == 1 then
    self.controller:pointer_press(button, x, y, device or "mouse", physical_x, physical_y)
  else
    return false
  end
  return self:_consume()
end

function Input:pointer_released(x, y, button, device, physical_x, physical_y)
  self:_sync_policy()
  if (button or 1) == 2 then
    self.controller:pointer_move(x, y, device or "mouse", physical_x, physical_y)
    self.controller.hid.buttons[2] = nil
    return false
  end
  if (button or 1) ~= 1 then return false end
  self.controller:pointer_release(button or 1, x, y, device or "mouse", physical_x, physical_y)
  return self:_consume()
end

function Input:key_pressed(key, device)
  self:_sync_policy()
  if Wiki.is_open() then
    local state = G.WIKI or {}
    if key == "slash" or key == "/" then Wiki.focus_search(true); return true end
    if key == "backspace" and (state.search_focused or (state.query and state.query ~= "")) then
      return Wiki.backspace_query()
    end
    if key == "pageup" then Wiki.scroll(-1); return true end
    if key == "pagedown" then Wiki.scroll(1); return true end
    if key == "leftshoulder" or key == "rightshoulder" then
      local view = Wiki.snapshot()
      local delta = key == "leftshoulder" and -1 or 1
      local count = #Wiki.CATEGORIES
      local index = ((view.category_index - 1 + delta) % count) + 1
      Wiki.select_category(index)
      return true
    end
  end
  local result = self.controller:key_press(key, device or "keyboard")
  local handled = self:_consume()
  if handled then return true end
  if result ~= nil then
    return key ~= "escape" and key ~= "cancel" and key ~= "backspace" and key ~= "back"
  end
  local action = KEY_ACTION[key]
  if action and self.controller.modal_scope == nil then
    self.controller:request(action, { control = key })
    return self:_consume()
  end
  return false
end

function Input:text_input(value)
  if not Wiki.is_open() or not (G.WIKI and G.WIKI.search_focused) then return false end
  Wiki.append_text(value)
  return true
end

function Input:wheel_moved(_, y)
  if not Wiki.is_open() or y == 0 then return false end
  Wiki.scroll(y > 0 and -1 or 1)
  return true
end

function Input:key_released(key)
  self.controller:key_release(key)
end

function Input:release_node(node)
  if not node then return end
  if self._founder_drag and self._founder_drag.card == node then self:_restore_founder_drag() end
  self.controller:release_node(node)
  self._meta[node] = nil
  local remove = {}
  for key, registration in pairs(self._registrations) do
    if registration.node == node then remove[#remove + 1] = key end
  end
  for _, key in ipairs(remove) do self._registrations[key] = nil end
end

function Input:reset()
  if not self.controller then return end
  if self._founder_drag then self:_restore_founder_drag() end
  self.controller:reset()
  self._registrations, self._button_nodes, self._meta = {}, {}, {}
  self._buttons, self._founder_drag, self._pack_open_id = {}, nil, nil
  local g = game()
  if g then
    g.CONTROLLER = self.controller
    g.DRAG = nil
  end
end

return Input
