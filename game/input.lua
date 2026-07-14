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

local Input = {}
Input.__index = Input

local KEY_ACTION = {
  space = "ship", f = "refactor", d = "distill", p = "promote",
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

local function overlay_open()
  local g = game()
  return g and (g.SHOW_DECK_VIEW or g.SHOW_RUN_INFO or g.SHOW_OPTIONS) == true
end

local function pack_open()
  local g = game()
  return g and g.STATES and g.STATE == g.STATES.SHOP
    and g.GAME and g.GAME.shop and g.GAME.shop.pack_open or nil
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
  local open = g.SHOW_DECK_VIEW or g.SHOW_RUN_INFO or g.SHOW_OPTIONS
  g.SHOW_DECK_VIEW, g.SHOW_RUN_INFO, g.SHOW_OPTIONS = nil, nil, nil
  return open and true or false
end

function Input.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Input)
  self.controller = Controller.new({
    virtual_width = opts.width or opts.virtual_width,
    virtual_height = opts.height or opts.virtual_height,
    click_distance = opts.click_distance,
    click_timeout = opts.click_timeout,
  })
  self._registrations, self._button_nodes, self._meta = {}, {}, {}
  self._buttons, self._founder_drag = {}, nil
  local g = game()
  if g then g.CONTROLLER = self.controller end
  return self
end

function Input:_modal_scope()
  if overlay_open() then return "overlay" end
  if state_is("TARGET_SELECT") then return "target" end
  if pack_open() then return "pack" end
  return nil
end

function Input:_sync_policy()
  local pack = pack_open()
  self.controller:set_modal(self:_modal_scope())
  self.controller:set_gameplay_locked(state_is("SCORING") or PackPresentation.input_locked(pack))
end

function Input:_scope_for_action(action, supplied)
  if supplied ~= nil then return supplied end
  if action and action:match("^opt_") then return "overlay" end
  if action and action:match("^pick_layer_") then return "target" end
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
    registration.scope = opts.scope
    registration.global = opts.global == true
    registration.action = opts.action or "activate"
    registration.allow_when_locked = opts.allow_when_locked == true
      or registration.action == "cancel" or registration.action == "back"
    registration.focusable = opts.focusable ~= false
    registration.enabled, registration.visible = opts.enabled, opts.visible
    registration.hit_test, registration.bounds = opts.hit_test, opts.bounds
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
  local seen, z = {}, 0
  local g = game()

  local function add(key, node, opts)
    z = z + 1
    opts.z = z
    self:_sync_target(key, node, opts, seen)
  end

  if selectable_state() and g and g.deck then
    add("draw_pile", g.deck, {
      id = "draw_pile", action = "draw_pile", bounds = function(node) return node.T end,
      focusable = true, meta = { kind = "draw_pile" },
    })
  end

  if (selectable_state() or state_is("TARGET_SELECT")) and g and g.hand then
    for i, card in ipairs(cards(g.hand)) do
      local target_mode = state_is("TARGET_SELECT")
      add("hand:" .. tostring(card.ID or card), card, {
        id = "hand:" .. tostring(card.ID or i), action = target_mode and "target_card" or "hand_card",
        scope = target_mode and "target" or nil,
        enabled = function(node)
          if not target_mode then return true end
          local pending = g.PENDING_CONSUMABLE
          return pending ~= nil and not pending.need_layer and not node.selected
        end,
        meta = { kind = target_mode and "target_card" or "hand_card", card = card },
      })
    end
  end

  if founder_state() and g and g.jokers then
    for i, card in ipairs(cards(g.jokers)) do
      add("founder:" .. tostring(card.ID or card), card, {
        id = "founder:" .. tostring(card.ID or i), action = "founder_card",
        scope = pack_open() and "pack" or nil,
        meta = { kind = "founder_card", card = card },
      })
    end
  end

  if founder_state() and g and g.consumables then
    for i, card in ipairs(cards(g.consumables)) do
      add("consumable:" .. tostring(card.ID or card), card, {
        id = "consumable:" .. tostring(card.ID or i), action = "consumable_card",
        scope = pack_open() and "pack" or nil,
        meta = { kind = "consumable_card", card = card },
      })
    end
  end

  if overlay_open() and g and g.WINDOW then
    local w, h = g.WINDOW.w or 0, g.WINDOW.h or 0
    local backdrops
    if g.SHOW_OPTIONS then
      local pw, ph = 420, 540
      local px, py = (w - pw) / 2, (h - ph) / 2
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
        meta = { kind = "button", action = action, index = index },
      })
    end
  end

  self:_drop_missing(seen)
  self:_sync_policy()
  self.controller:refresh()
  self:_consume()
  return self.controller.targets
end

function Input:update(dt, button_specs)
  self.controller:begin_frame(dt or 0)
  if button_specs ~= nil then self:rebuild(button_specs)
  else self:_sync_policy(); self:_consume() end
end

function Input:_call(action)
  local g = game()
  local fn = g and g.FUNCS and g.FUNCS[action]
  if not fn then return false end
  fn()
  self:_sync_policy()
  return true
end

function Input:_toggle_hand(card)
  local g = game()
  if not (selectable_state() and g and g.hand and card) then return false end
  local max_selected = (g.GAME and g.GAME.select_max) or math.huge
  if not card.selected and selected_count(g.hand) >= max_selected then return false end
  if card.toggle_select then card:toggle_select()
  else card.selected = not card.selected; if g.hand.align_cards then g.hand:align_cards() end end
  pulse(card, 0.35)
  return true
end

function Input:_pick_target(card)
  local g = game()
  local pending = g and g.PENDING_CONSUMABLE
  if not (state_is("TARGET_SELECT") and pending and not pending.need_layer and card and not card.selected) then return false end
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

function Input:_dispatch_click(intent, meta)
  local g = game()
  if not meta then return false end
  if meta.kind == "button" then
    if meta.action == "modal_backdrop" then return close_overlay() end
    if meta.action == "pack_locked" then return true end
    return self:_call(meta.action)
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
  if state_is("TARGET_SELECT") and g.CONSUMABLE_CANCEL then g.CONSUMABLE_CANCEL(); return true end
  if overlay_open() then return close_overlay() end
  if pack_open() then return self:_call("pack_skip") end
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
      self._founder_drag = { card = meta.card, grabx = (intent.origin and intent.origin.x or intent.cursor.x) - tx }
      return self:_reorder_founder(meta.card, intent.cursor.x)
    elseif intent.phase == "move" and self._founder_drag and self._founder_drag.card == meta.card then
      return self:_reorder_founder(meta.card, intent.cursor.x)
    elseif intent.phase == "end" and self._founder_drag and self._founder_drag.card == meta.card then
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

function Input:pointer_moved(x, y, device)
  self:_sync_policy()
  self.controller:pointer_move(x, y, device or "mouse")
  return self:_consume()
end

function Input:pointer_pressed(x, y, button, device)
  self:_sync_policy()
  button = button or 1
  if button == 2 then
    self.controller:pointer_move(x, y, device or "mouse")
    self.controller.hid.buttons[2] = true
    if state_is("TARGET_SELECT") then self.controller:cancel({ button = button }) end
  elseif button == 1 then
    self.controller:pointer_press(button, x, y, device or "mouse")
  else
    return false
  end
  return self:_consume()
end

function Input:pointer_released(x, y, button, device)
  self:_sync_policy()
  if (button or 1) == 2 then
    self.controller:pointer_move(x, y, device or "mouse")
    self.controller.hid.buttons[2] = nil
    return false
  end
  if (button or 1) ~= 1 then return false end
  self.controller:pointer_release(button or 1, x, y, device or "mouse")
  return self:_consume()
end

function Input:key_pressed(key, device)
  self:_sync_policy()
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

function Input:key_released(key)
  self.controller:key_release(key)
end

function Input:release_node(node)
  if not node then return end
  self.controller:release_node(node)
  self._meta[node] = nil
  local remove = {}
  for key, registration in pairs(self._registrations) do
    if registration.node == node then remove[#remove + 1] = key end
  end
  for _, key in ipairs(remove) do self._registrations[key] = nil end
  if self._founder_drag and self._founder_drag.card == node then self._founder_drag = nil end
end

function Input:reset()
  if not self.controller then return end
  self.controller:reset()
  self._registrations, self._button_nodes, self._meta = {}, {}, {}
  self._buttons, self._founder_drag = {}, nil
  local g = game()
  if g then
    g.CONTROLLER = self.controller
    g.DRAG = nil
  end
end

return Input
