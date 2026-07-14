-- engine/controller.lua — deterministic input policy for pointer, keyboard, and gamepad adapters.
--
-- The controller does not call gameplay handlers. It owns input state and emits plain intent
-- records for the runtime adapter to consume. Its deliberately small public surface is:
--
--   Controller.new(opts)
--   :begin_frame(dt)                         -- advance the deterministic input clock
--   :add_target(node, opts) / :release_node(node_or_handle)
--   :set_modal(scope) / :set_gameplay_locked(locked)
--   :refresh()                                 -- re-resolve hover after target/layout changes
--   :pointer_move(x, y, device) / :pointer_press(button) / :pointer_release(button)
--   :focus(node) / :focus_next(direction) / :key_press(key, device) / :key_release(key)
--   :request(action)                         -- debounced semantic HID action
--   :cancel() / :back()                      -- always allowed while gameplay is locked
--   :poll() / :drain_intents() / :reset()
--
-- Targets are registered bottom-to-top. A larger `z` wins; equal-z ties are resolved by stable
-- registration order (the later target is topmost). `scope` participates in modal filtering,
-- `global = true` bypasses that filtering, and `allow_when_locked = true` is an explicit escape
-- hatch intended for cancel/back controls. Targets whose action is literally "cancel" or "back"
-- receive that allowance automatically.

local Controller = {}
Controller.__index = Controller

local DEFAULT_CLICK_DISTANCE = 6
local DEFAULT_CLICK_TIMEOUT = 0.35

local function copy_cursor(cursor)
  return { x = cursor.x, y = cursor.y }
end

local function node_state(node, name, value)
  local state = node and node.states and node.states[name]
  if state then state.is = value end
end

local function option_value(value, target)
  if type(value) == "function" then return value(target.node, target) end
  return value
end

local function distance_squared(x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  return dx * dx + dy * dy
end

function Controller.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Controller)
  self.click_distance = opts.click_distance or DEFAULT_CLICK_DISTANCE
  self.click_timeout = opts.click_timeout or DEFAULT_CLICK_TIMEOUT
  assert(self.click_distance >= 0, "click_distance must be non-negative")
  assert(self.click_timeout >= 0, "click_timeout must be non-negative")
  self.virtual_width = opts.virtual_width
  self.virtual_height = opts.virtual_height
  self.cursor = { x = opts.x or 0, y = opts.y or 0 }
  self.hid = { device = opts.device or "virtual", buttons = {}, keys = {}, last_control = nil }
  self.targets, self.intents = {}, {}
  self._target_sequence = 0
  self.frame, self.time, self._action_frame = 0, 0, nil
  self.modal_scope, self.gameplay_locked = nil, false
  self.hovering, self.focused, self.clicked, self.dragging = nil, nil, nil, nil
  self._press = nil
  self:_clamp_cursor()
  return self
end

function Controller:_clamp_cursor()
  if self.virtual_width then
    self.cursor.x = math.max(0, math.min(self.virtual_width, self.cursor.x))
  end
  if self.virtual_height then
    self.cursor.y = math.max(0, math.min(self.virtual_height, self.cursor.y))
  end
end

function Controller:begin_frame(dt)
  dt = dt or 0
  assert(dt >= 0, "controller dt must be non-negative")
  self.frame = self.frame + 1
  self.time = self.time + dt
  return self.frame
end

function Controller:add_target(node, opts)
  assert(node ~= nil, "controller target requires a node")
  opts = opts or {}
  self._target_sequence = self._target_sequence + 1
  local target = {
    node = node,
    id = opts.id or node.ID,
    z = opts.z or opts.order or 0,
    sequence = self._target_sequence,
    scope = opts.scope,
    global = opts.global == true,
    action = opts.action or "activate",
    allow_when_locked = opts.allow_when_locked == true
      or opts.action == "cancel" or opts.action == "back",
    focusable = opts.focusable ~= false,
    enabled = opts.enabled,
    visible = opts.visible,
    hit_test = opts.hit_test,
    bounds = opts.bounds,
  }
  self.targets[#self.targets + 1] = target
  return target
end

function Controller:_in_scope(target)
  return self.modal_scope == nil or target.global or target.scope == self.modal_scope
end

function Controller:_unlocked(target)
  return not self.gameplay_locked or target.allow_when_locked
end

function Controller:_eligible(target, for_focus)
  if not target or target.released or not target.node or target.node.REMOVED then return false end
  if not self:_in_scope(target) or not self:_unlocked(target) then return false end
  if for_focus and not target.focusable then return false end
  local visible = target.visible
  if visible == nil then
    local state = target.node.states and target.node.states.visible
    visible = state == nil or state == true or (type(state) == "table" and state.is ~= false)
  else
    visible = option_value(visible, target)
  end
  if not visible then return false end
  local enabled = target.enabled
  if enabled == nil then enabled = true else enabled = option_value(enabled, target) end
  return enabled == true
end

function Controller:_target_for_node(node)
  local best
  for _, target in ipairs(self.targets) do
    if target.node == node and self:_eligible(target, true) then
      if not best or target.z > best.z or (target.z == best.z and target.sequence > best.sequence) then
        best = target
      end
    end
  end
  return best
end

function Controller:ordered_targets(for_focus)
  local ordered = {}
  for _, target in ipairs(self.targets) do
    if self:_eligible(target, for_focus == true) then ordered[#ordered + 1] = target end
  end
  table.sort(ordered, function(a, b)
    if a.z ~= b.z then return a.z < b.z end
    return a.sequence < b.sequence
  end)
  return ordered
end

function Controller:_contains(target, x, y)
  if target.hit_test then return target.hit_test(target.node, x, y, target) == true end
  local bounds = option_value(target.bounds, target)
  if bounds then
    return x >= bounds.x and x <= bounds.x + bounds.w and y >= bounds.y and y <= bounds.y + bounds.h
  end
  if target.node.collides_with_point then return target.node:collides_with_point(x, y) == true end
  local t = target.node.VT or target.node.T
  return t and x >= t.x and x <= t.x + t.w and y >= t.y and y <= t.y + t.h or false
end

function Controller:resolve(x, y)
  x, y = x or self.cursor.x, y or self.cursor.y
  local best
  for _, target in ipairs(self.targets) do
    if self:_eligible(target, false) and self:_contains(target, x, y) then
      if not best or target.z > best.z or (target.z == best.z and target.sequence > best.sequence) then
        best = target
      end
    end
  end
  return best and best.node or nil, best
end

function Controller:_queue(kind, target, fields)
  local intent = {
    kind = kind,
    target = target and target.node or nil,
    target_id = target and target.id or nil,
    action = target and target.action or kind,
    frame = self.frame,
    time = self.time,
    device = self.hid.device,
    cursor = copy_cursor(self.cursor),
  }
  for k, v in pairs(fields or {}) do intent[k] = v end
  self.intents[#self.intents + 1] = intent
  return intent
end

function Controller:_queue_action(kind, target, fields)
  if target and not self:_eligible(target, false) then return nil end
  if self._action_frame == self.frame then return nil end
  self._action_frame = self.frame
  return self:_queue(kind, target, fields)
end

function Controller:_set_hover(target)
  local node = target and target.node or nil
  if node == self.hovering then return end
  local old = self.hovering and self:_target_for_node(self.hovering) or nil
  if self.hovering then
    node_state(self.hovering, "hover", false)
    self:_queue("hover", old, { phase = "leave" })
  end
  self.hovering = node
  if node then
    node_state(node, "hover", true)
    self:_queue("hover", target, { phase = "enter" })
  end
end

function Controller:_refresh_hover()
  local _, target = self:resolve()
  self:_set_hover(target)
  return target
end

function Controller:refresh()
  return self:_refresh_hover()
end

function Controller:pointer_move(x, y, device)
  assert(type(x) == "number" and type(y) == "number", "pointer coordinates must be numbers")
  local next_device = device or self.hid.device or "pointer"
  local press = self._press
  -- A pointer capture belongs to one physical pointer. In particular, a second touch must not
  -- move or finish the first touch's click/drag.
  if press and press.device and press.device ~= next_device then return self.hovering end
  self.hid.device = next_device
  self.cursor.x, self.cursor.y = x, y
  self:_clamp_cursor()
  local target = self:_refresh_hover()

  if press and press.target then
    local moved = distance_squared(press.x, press.y, self.cursor.x, self.cursor.y)
      > self.click_distance * self.click_distance
    if moved and not self.dragging then
      self.dragging = press.target.node
      node_state(self.dragging, "drag", true)
      self:_queue("drag", press.target, {
        phase = "start", button = press.button,
        origin = { x = press.x, y = press.y },
      })
    elseif self.dragging then
      self:_queue("drag", press.target, {
        phase = "move", button = press.button,
        origin = { x = press.x, y = press.y },
      })
    end
  end
  return target and target.node or nil
end

function Controller:pointer_press(button, x, y, device)
  button = button or 1
  local next_device = device or self.hid.device or "pointer"
  if self._press then return nil end
  self.hid.device = next_device
  if x ~= nil or y ~= nil then self:pointer_move(assert(x), assert(y), next_device) end
  self.hid.buttons[button] = true
  self.hid.last_control = button
  local node, target = self:resolve()
  self._press = {
    target = target, button = button, device = next_device,
    x = self.cursor.x, y = self.cursor.y, time = self.time,
  }
  self.clicked = node
  if node then node_state(node, "click", true) end
  self:_queue("press", target, { button = button })
  return node
end

function Controller:pointer_release(button, x, y, device)
  button = button or 1
  local press = self._press
  local next_device = device or (press and press.device) or self.hid.device or "pointer"
  if press and press.device and press.device ~= next_device then return nil end
  self.hid.device = next_device
  if x ~= nil or y ~= nil then self:pointer_move(assert(x), assert(y), next_device) end
  self.hid.buttons[button] = nil
  self.hid.last_control = button
  if not press or press.button ~= button then return nil end
  local _, over = self:resolve()
  local elapsed = self.time - press.time
  local moved = distance_squared(press.x, press.y, self.cursor.x, self.cursor.y)
  self:_queue("release", press.target, { button = button, over = over and over.node or nil })

  local intent
  if self.dragging then
    node_state(self.dragging, "drag", false)
    self:_queue("drag", press.target, {
      phase = "end", button = button, over = over and over.node or nil,
      origin = { x = press.x, y = press.y },
    })
  elseif press.target and over == press.target
      and moved <= self.click_distance * self.click_distance and elapsed <= self.click_timeout then
    intent = self:_queue_action("click", press.target, { button = button })
  end

  if self.clicked then node_state(self.clicked, "click", false) end
  self.clicked, self.dragging, self._press = nil, nil, nil
  return intent
end

function Controller:_set_focus(target)
  local node = target and target.node or nil
  if node == self.focused then return node end
  local old = self.focused and self:_target_for_node(self.focused) or nil
  if self.focused then
    node_state(self.focused, "focus", false)
    self:_queue("focus", old, { phase = "leave" })
  end
  self.focused = node
  if node then
    node_state(node, "focus", true)
    self:_queue("focus", target, { phase = "enter" })
  end
  return node
end

function Controller:focus(node)
  if node == nil then return self:_set_focus(nil) end
  return self:_set_focus(self:_target_for_node(node))
end

function Controller:focus_next(direction)
  local ordered = self:ordered_targets(true)
  if #ordered == 0 then return self:_set_focus(nil) end
  direction = (direction or 1) < 0 and -1 or 1
  local index
  for i, target in ipairs(ordered) do if target.node == self.focused then index = i; break end end
  if not index then index = direction > 0 and 0 or 1 end
  index = ((index - 1 + direction) % #ordered) + 1
  return self:_set_focus(ordered[index])
end

function Controller:activate_focused()
  local target = self.focused and self:_target_for_node(self.focused) or nil
  return target and self:_queue_action("click", target, { control = self.hid.last_control }) or nil
end

function Controller:request(action, fields)
  assert(type(action) == "string" and action ~= "", "controller action must be a non-empty string")
  if self.gameplay_locked and action ~= "cancel" and action ~= "back" then return nil end
  fields = fields or {}
  fields.action = action
  return self:_queue_action("action", nil, fields)
end

function Controller:cancel(fields)
  return self:_queue_action("cancel", nil, fields)
end

function Controller:back(fields)
  return self:_queue_action("back", nil, fields)
end

function Controller:key_press(key, device)
  assert(type(key) == "string", "key must be a string")
  self.hid.device = device or "keyboard"
  self.hid.keys[key] = true
  self.hid.last_control = key
  if key == "escape" or key == "cancel" then return self:cancel({ control = key }) end
  if key == "backspace" or key == "back" then return self:back({ control = key }) end
  if key == "tab" or key == "right" or key == "down" or key == "dpright" or key == "dpdown" then
    return self:focus_next(1)
  end
  if key == "left" or key == "up" or key == "dpleft" or key == "dpup" then
    return self:focus_next(-1)
  end
  if key == "return" or key == "enter" or key == "a" then
    return self:activate_focused()
  end
end

function Controller:key_release(key)
  self.hid.keys[key] = nil
end

function Controller:_cancel_capture(reason)
  if not self._press then return end
  local target = self._press.target
  self:_queue("release", target, { button = self._press.button, cancelled = true, reason = reason })
  if self.dragging then
    node_state(self.dragging, "drag", false)
    self:_queue("drag", target, { phase = "end", cancelled = true, reason = reason })
  end
  if self.clicked then node_state(self.clicked, "click", false) end
  self.clicked, self.dragging, self._press = nil, nil, nil
end

function Controller:set_modal(scope)
  if self.modal_scope == scope then return end
  self.modal_scope = scope
  if self._press and self._press.target and not self:_eligible(self._press.target, false) then
    self:_cancel_capture("modal")
  end
  if self.focused and not self:_target_for_node(self.focused) then self:_set_focus(nil) end
  self:_refresh_hover()
end

function Controller:set_gameplay_locked(locked)
  locked = locked == true
  if self.gameplay_locked == locked then return end
  self.gameplay_locked = locked
  if locked and self._press and self._press.target and not self:_unlocked(self._press.target) then
    self:_cancel_capture("locked")
  end
  if self.focused and not self:_target_for_node(self.focused) then self:_set_focus(nil) end
  self:_refresh_hover()
end

function Controller:release_node(node_or_handle)
  if not node_or_handle then return end
  local node = node_or_handle.node or node_or_handle
  if self._press and self._press.target and self._press.target.node == node then self:_cancel_capture("released") end
  if self.hovering == node then node_state(node, "hover", false); self.hovering = nil end
  if self.focused == node then node_state(node, "focus", false); self.focused = nil end
  if self.clicked == node then node_state(node, "click", false); self.clicked = nil end
  if self.dragging == node then node_state(node, "drag", false); self.dragging = nil end
  for i = #self.targets, 1, -1 do
    local target = self.targets[i]
    if target == node_or_handle or target.node == node then
      target.released = true
      table.remove(self.targets, i)
    end
  end
  for i = #self.intents, 1, -1 do
    if self.intents[i].target == node then table.remove(self.intents, i) end
  end
  self:_refresh_hover()
end

function Controller:poll()
  if #self.intents == 0 then return nil end
  return table.remove(self.intents, 1)
end

function Controller:drain_intents()
  local out = self.intents
  self.intents = {}
  return out
end

function Controller:reset(opts)
  opts = opts or {}
  self:_cancel_capture("reset")
  if self.hovering then node_state(self.hovering, "hover", false) end
  if self.focused then node_state(self.focused, "focus", false) end
  self.hovering, self.focused, self.clicked, self.dragging = nil, nil, nil, nil
  if not opts.keep_targets then
    for _, target in ipairs(self.targets) do target.released = true end
    self.targets = {}
  end
  self.intents = {}
  self.hid.buttons, self.hid.keys, self.hid.last_control = {}, {}, nil
  self.modal_scope, self.gameplay_locked = nil, false
  self._press, self._action_frame = nil, nil
  self.frame, self.time = 0, 0
  if opts.x ~= nil then self.cursor.x = opts.x end
  if opts.y ~= nil then self.cursor.y = opts.y end
  self:_clamp_cursor()
end

return Controller
