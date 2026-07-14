-- engine/uibox.lua -- retained, declarative layout and input-target foundation.
--
-- UIBox deliberately owns no gameplay behavior and has no Controller dependency. A definition is
-- compiled into stable element records, measured, and laid out before input. Drawing only reads the
-- resulting tree. Interactive elements can be extracted as plain targets or registered through a
-- small adapter (including Controller:add_target when that method is available).
--
-- Definition fields shared by all node types:
--   type/kind              root | row | column | box | text | button
--   id, children           stable identity and a dense child array
--   w/h, min_w/min_h       fixed and minimum sizes
--   padding, gap           number or {x,y}/{left,right,top,bottom}
--   align, justify         cross-axis and main-axis alignment
--   align_x, align_y       alignment inside root/box overlay containers
--   z, order, focus_order  deterministic paint, hit, and focus ordering
--   visible, enabled       booleans or predicates(context, element)
--   action, modal_scope    input action string and optional modal scope
--
-- Text measurement may be injected with UIBox.new(def, {measure_text = fn}). Without an injected
-- function, the module uses the configured font, the engine text metrics, or a deterministic fallback.

local UIBox = {}
UIBox.__index = UIBox
UIBox.VERSION = "palo-latro.uibox.v1"

local Element = {}
Element.__index = Element

local VALID_KIND = {
  root = true, row = true, column = true, box = true, text = true, button = true,
}

local function finite_number(value, fallback)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return fallback
  end
  return value
end

local function non_negative(value, fallback)
  return math.max(0, finite_number(value, fallback or 0))
end

local function dense_length(values, label)
  if values == nil then return 0 end
  assert(type(values) == "table", label .. " must be an array")
  local count, maximum = 0, 0
  for key in pairs(values) do
    assert(type(key) == "number" and key >= 1 and key % 1 == 0, label .. " must be a dense array")
    count, maximum = count + 1, math.max(maximum, key)
  end
  assert(count == maximum, label .. " must be a dense array")
  for i = 1, maximum do assert(values[i] ~= nil, label .. " must be a dense array") end
  return maximum
end

local function padding(value, default_value)
  value = value == nil and default_value or value
  if type(value) == "number" then
    local amount = non_negative(value)
    return { left = amount, right = amount, top = amount, bottom = amount }
  end
  value = value or {}
  assert(type(value) == "table", "padding must be a number or table")
  local horizontal = value.x or value.horizontal or value.h or 0
  local vertical = value.y or value.vertical or value.v or 0
  return {
    left = non_negative(value.left or value.l, horizontal),
    right = non_negative(value.right or value.r, horizontal),
    top = non_negative(value.top or value.t, vertical),
    bottom = non_negative(value.bottom or value.b, vertical),
  }
end

local function predicate(value, context, element, default)
  if value == nil then return default end
  if type(value) == "function" then return value(context, element) == true end
  return value == true
end

local function copy_bounds(bounds)
  return { x = bounds.x, y = bounds.y, w = bounds.w, h = bounds.h }
end

local function set_bounds(bounds, x, y, w, h)
  bounds.x, bounds.y = x, y
  bounds.w, bounds.h = math.max(0, w), math.max(0, h)
end

local function split_lines(text)
  local out, start = {}, 1
  while true do
    local stop = text:find("\n", start, true)
    if not stop then out[#out + 1] = text:sub(start); break end
    out[#out + 1] = text:sub(start, stop - 1)
    start = stop + 1
  end
  return out
end

local function constructor(kind, props, children)
  if props == nil then props = {} end
  assert(type(props) == "table", kind .. " definition must be a table")
  local out = {}
  for key, value in pairs(props) do out[key] = value end
  out.type = kind
  if children ~= nil then out.children = children end
  return out
end

function UIBox.root(props, children) return constructor("root", props, children) end
function UIBox.row(props, children) return constructor("row", props, children) end
function UIBox.column(props, children) return constructor("column", props, children) end
function UIBox.box(props, children) return constructor("box", props, children) end
function UIBox.button(props, children) return constructor("button", props, children) end

function UIBox.text(value, props)
  if type(value) == "table" and props == nil then return constructor("text", value) end
  props = props or {}
  assert(type(props) == "table", "text definition must be a table")
  local out = constructor("text", props)
  out.text = value == nil and out.text or value
  return out
end

function Element:is_visible(context)
  if self.REMOVED or self.states.visible == false then return false end
  if self.parent and not self.parent:is_visible(context) then return false end
  return predicate(self.visible, context, self, true)
end

function Element:is_enabled(context)
  if self.REMOVED then return false end
  if self.parent and not self.parent:is_enabled(context) then return false end
  return predicate(self.enabled, context, self, true)
end

function Element:collides_with_point(x, y)
  local frame = self.frame
  return x >= frame.x and x <= frame.x + frame.w and y >= frame.y and y <= frame.y + frame.h
end

local function compile(self, definition, parent)
  assert(type(definition) == "table", "UIBox node definition must be a table")
  local kind = definition.type or definition.kind
  assert(VALID_KIND[kind], "unknown UIBox node type: " .. tostring(kind))

  self._sequence = self._sequence + 1
  local sequence = self._sequence
  local id = definition.id or ("uibox:" .. tostring(sequence))
  assert(self.by_id[id] == nil, "duplicate UIBox id: " .. tostring(id))

  local default_padding = kind == "button" and (self.options.button_padding or { x = 12, y = 8 }) or 0
  local interactive = type(definition.action) == "string" and definition.target ~= false
  local frame = { x = 0, y = 0, w = 0, h = 0 }
  local element = setmetatable({
    kind = kind,
    id = id,
    parent = parent,
    children = {},
    frame = frame,
    T = frame,
    states = {
      visible = true,
      hover = { can = kind == "button" or interactive, is = false },
      click = { can = kind == "button" or interactive, is = false },
      drag = { can = false, is = false },
      focus = { can = kind == "button" or interactive, is = false },
    },
    REMOVED = false,
    _tree_order = sequence,
    order = finite_number(definition.order, sequence),
    z = finite_number(definition.z, parent and parent.z or 0),
    focus_order = finite_number(definition.focus_order,
      finite_number(definition.order, sequence)),
    w = definition.w or definition.width,
    h = definition.h or definition.height,
    min_w = non_negative(definition.min_w or definition.min_width),
    min_h = non_negative(definition.min_h or definition.min_height),
    padding = padding(definition.padding, default_padding),
    gap = non_negative(definition.gap),
    align = definition.align or "start",
    justify = definition.justify or "start",
    align_x = definition.align_x,
    align_y = definition.align_y or definition.valign,
    align_self = definition.align_self,
    offset_x = finite_number(definition.offset_x, 0),
    offset_y = finite_number(definition.offset_y, 0),
    text = definition.text,
    label = definition.label,
    font = definition.font,
    text_align = definition.text_align or "left",
    fill = definition.fill or definition.color,
    border = definition.border,
    text_color = definition.text_color,
    style = definition.style,
    draw_callback = definition.draw,
    visible = definition.visible,
    enabled = definition.enabled,
    action = definition.action,
    modal_scope = definition.modal_scope or definition.scope,
    global = definition.global == true,
    allow_when_locked = definition.allow_when_locked == true,
    focusable = definition.focusable ~= false and (kind == "button" or definition.focusable == true),
    target = definition.target ~= false,
    metadata = definition.metadata,
  }, Element)

  if element.w ~= nil then element.w = non_negative(element.w) end
  if element.h ~= nil then element.h = non_negative(element.h) end
  if element.action ~= nil then assert(type(element.action) == "string", "UIBox action must be a string") end

  self.by_id[id] = element
  self.elements[#self.elements + 1] = element

  local children = definition.children
  local child_count = dense_length(children, "UIBox children")
  assert(child_count == 0 or kind ~= "text", "text nodes cannot have children")
  for i = 1, child_count do element.children[i] = compile(self, children[i], element) end
  return element
end

local function fallback_text_measure(text, font)
  local lines = split_lines(text)
  local width, line_height = 0, 16
  if rawget(_G, "text_h") and font then line_height = text_h(font)
  elseif font and font.getHeight then line_height = font:getHeight() end
  for _, line in ipairs(lines) do
    local line_width
    if rawget(_G, "text_w") and font then line_width = text_w(font, line)
    elseif font and font.getWidth then line_width = font:getWidth(line)
    else line_width = #line * 8 end
    width = math.max(width, line_width)
  end
  return width, line_height * math.max(1, #lines)
end

local function measure_text(self, element, context)
  local text = tostring(element.text or element.label or "")
  if self.options.measure_text then
    local width, height = self.options.measure_text(text, element, context)
    return non_negative(width), non_negative(height)
  end
  local game = rawget(_G, "G")
  local font = element.font or (game and game.FONTS
    and (element.kind == "button" and game.FONTS.normal or game.FONTS.tiny))
  return fallback_text_measure(text, font)
end

local function measure_element(self, element, context)
  local content_w, content_h = 0, 0
  local count = #element.children

  if element.kind == "text" then
    content_w, content_h = measure_text(self, element, context)
  elseif element.kind == "button" then
    content_w, content_h = measure_text(self, element, context)
    for _, child in ipairs(element.children) do
      local measured = measure_element(self, child, context)
      content_w, content_h = math.max(content_w, measured.w), math.max(content_h, measured.h)
    end
  elseif element.kind == "row" then
    for i, child in ipairs(element.children) do
      local measured = measure_element(self, child, context)
      content_w = content_w + measured.w + (i > 1 and element.gap or 0)
      content_h = math.max(content_h, measured.h)
    end
  elseif element.kind == "column" then
    for i, child in ipairs(element.children) do
      local measured = measure_element(self, child, context)
      content_w = math.max(content_w, measured.w)
      content_h = content_h + measured.h + (i > 1 and element.gap or 0)
    end
  else -- root/box are layered containers; their intrinsic size is their largest child.
    for _, child in ipairs(element.children) do
      local measured = measure_element(self, child, context)
      content_w, content_h = math.max(content_w, measured.w), math.max(content_h, measured.h)
    end
  end

  local pad = element.padding
  local width = content_w + pad.left + pad.right
  local height = content_h + pad.top + pad.bottom
  if element.w ~= nil then width = element.w end
  if element.h ~= nil then height = element.h end
  width, height = math.max(width, element.min_w), math.max(height, element.min_h)
  element.measured = { w = width, h = height, content_w = content_w, content_h = content_h, count = count }
  return element.measured
end

local function aligned_position(start, available, size, alignment)
  local spare = available - size
  if alignment == "center" then return start + spare / 2 end
  if alignment == "end" or alignment == "right" or alignment == "bottom" then return start + spare end
  return start
end

local function main_axis(count, natural, available, gap, justify)
  local spare = available - natural
  local offset, actual_gap = 0, gap
  if spare > 0 then
    if justify == "center" then offset = spare / 2
    elseif justify == "end" or justify == "right" or justify == "bottom" then offset = spare
    elseif justify == "space-between" and count > 1 then actual_gap = gap + spare / (count - 1)
    elseif justify == "space-around" and count > 0 then
      actual_gap = gap + spare / count
      offset = spare / (2 * count)
    end
  end
  return offset, actual_gap
end

local function arrange_element(element, x, y, width, height)
  set_bounds(element.frame, x + element.offset_x, y + element.offset_y, width, height)
  local frame, pad = element.frame, element.padding
  local cx, cy = frame.x + pad.left, frame.y + pad.top
  local cw = math.max(0, frame.w - pad.left - pad.right)
  local ch = math.max(0, frame.h - pad.top - pad.bottom)

  if element.kind == "row" then
    local natural = 0
    for i, child in ipairs(element.children) do
      natural = natural + child.measured.w + (i > 1 and element.gap or 0)
    end
    local offset, gap = main_axis(#element.children, natural, cw, element.gap, element.justify)
    local cursor = cx + offset
    for _, child in ipairs(element.children) do
      local align = child.align_self or element.align
      local child_h = align == "stretch" and math.max(ch, child.min_h) or child.measured.h
      local child_y = aligned_position(cy, ch, child_h, align)
      arrange_element(child, cursor, child_y, child.measured.w, child_h)
      cursor = cursor + child.measured.w + gap
    end
  elseif element.kind == "column" then
    local natural = 0
    for i, child in ipairs(element.children) do
      natural = natural + child.measured.h + (i > 1 and element.gap or 0)
    end
    local offset, gap = main_axis(#element.children, natural, ch, element.gap, element.justify)
    local cursor = cy + offset
    for _, child in ipairs(element.children) do
      local align = child.align_self or element.align
      local child_w = align == "stretch" and math.max(cw, child.min_w) or child.measured.w
      local child_x = aligned_position(cx, cw, child_w, align)
      arrange_element(child, child_x, cursor, child_w, child.measured.h)
      cursor = cursor + child.measured.h + gap
    end
  elseif element.kind == "root" or element.kind == "box" or element.kind == "button" then
    for _, child in ipairs(element.children) do
      local ax = child.align_x or element.align_x or element.align or "start"
      local ay = child.align_y or element.align_y or "start"
      local child_w = ax == "stretch" and math.max(cw, child.min_w) or child.measured.w
      local child_h = ay == "stretch" and math.max(ch, child.min_h) or child.measured.h
      arrange_element(child,
        aligned_position(cx, cw, child_w, ax),
        aligned_position(cy, ch, child_h, ay), child_w, child_h)
    end
  end
end

function UIBox.new(definition, options)
  options = options or {}
  assert(type(options) == "table", "UIBox options must be a table")
  local self = setmetatable({
    options = options,
    elements = {},
    by_id = {},
    _sequence = 0,
  }, UIBox)
  self.root_element = compile(self, definition, nil)
  assert(self.root_element.kind == "root", "UIBox definition must begin with a root node")
  self:layout(options.bounds, options.context)
  return self
end

function UIBox:find(id)
  return self.by_id[id]
end

function UIBox:measure(context)
  local measured = measure_element(self, self.root_element, context)
  return { w = measured.w, h = measured.h }
end

function UIBox:layout(a, b, c, d, e)
  local bounds, context
  if type(a) == "table" then
    bounds, context = a, b
  elseif a ~= nil then
    bounds, context = { x = a, y = b, w = c, h = d }, e
  else
    bounds, context = nil, b
  end

  local measured = measure_element(self, self.root_element, context)
  bounds = bounds or {}
  local x, y = finite_number(bounds.x, 0), finite_number(bounds.y, 0)
  local width = bounds.w == nil and measured.w or non_negative(bounds.w)
  local height = bounds.h == nil and measured.h or non_negative(bounds.h)
  width = math.max(width, self.root_element.min_w)
  height = math.max(height, self.root_element.min_h)
  arrange_element(self.root_element, x, y, width, height)
  return self.root_element
end

local function draw_sort(a, b)
  if a.z ~= b.z then return a.z < b.z end
  if a.order ~= b.order then return a.order < b.order end
  return a._tree_order < b._tree_order
end

local function hit_sort(a, b)
  if a.z ~= b.z then return a.z > b.z end
  if a.order ~= b.order then return a.order > b.order end
  return a._tree_order > b._tree_order
end

local function focus_sort(a, b)
  if a.focus_order ~= b.focus_order then return a.focus_order < b.focus_order end
  if a.order ~= b.order then return a.order < b.order end
  return a._tree_order < b._tree_order
end

local function target_from(element, context)
  local bounds = element.frame
  return {
    node = element,
    id = element.id,
    action = element.action,
    scope = element.modal_scope,
    modal_scope = element.modal_scope,
    z = element.z,
    order = element.order,
    focus_order = element.focus_order,
    focusable = element.focusable,
    global = element.global,
    allow_when_locked = element.allow_when_locked,
    enabled = element:is_enabled(context),
    visible = element:is_visible(context),
    bounds = bounds,
    x = bounds.x, y = bounds.y, w = bounds.w, h = bounds.h,
    metadata = element.metadata,
    enabled_predicate = function(next_context) return element:is_enabled(next_context or context) end,
    visible_predicate = function(next_context) return element:is_visible(next_context or context) end,
    contains = function(_, x, y) return element:collides_with_point(x, y) end,
  }
end

function UIBox:targets(context, options)
  options = options or {}
  local out = {}
  for _, element in ipairs(self.elements) do
    if element.target and type(element.action) == "string" then
      local target = target_from(element, context)
      local scope_ok = options.modal_scope == nil or target.global or target.modal_scope == options.modal_scope
      local enabled_ok = options.include_disabled ~= false or target.enabled
      local visible_ok = options.include_hidden == true or target.visible
      if scope_ok and enabled_ok and visible_ok then out[#out + 1] = target end
    end
  end
  local order = options.order or "hit"
  table.sort(out, order == "focus" and focus_sort or order == "draw" and draw_sort or hit_sort)
  return out
end

function UIBox:focus_targets(context, options)
  options = options or {}
  local copy = {}
  for key, value in pairs(options) do copy[key] = value end
  copy.order = "focus"
  local all, out = self:targets(context, copy), {}
  for _, target in ipairs(all) do if target.focusable and target.enabled then out[#out + 1] = target end end
  return out
end

local function registration_sort(a, b)
  if a.z ~= b.z then return a.z < b.z end
  if a.order ~= b.order then return a.order < b.order end
  return a.node._tree_order < b.node._tree_order
end

function UIBox:register_targets(registry, context, options)
  assert(registry ~= nil, "UIBox target registry is required")
  options = options or {}
  local targets = self:targets(context, options)
  table.sort(targets, registration_sort) -- bottom-to-top for stable last-registration-wins controllers
  local handles = {}

  for _, target in ipairs(targets) do
    local handle
    if options.adapter then
      handle = options.adapter(registry, target)
    elseif type(registry) == "function" then
      handle = registry(target)
    elseif type(registry.add_target) == "function" then
      local enabled = type(target.node.enabled) == "function"
        and function() return target.node:is_enabled(context) end or target.enabled
      local visible = type(target.node.visible) == "function"
        and function() return target.node:is_visible(context) end or target.visible
      handle = registry:add_target(target.node, {
        id = target.id,
        z = target.z,
        order = target.order,
        scope = target.modal_scope,
        global = target.global,
        action = target.action,
        allow_when_locked = target.allow_when_locked,
        focusable = target.focusable,
        enabled = enabled,
        visible = visible,
        bounds = target.bounds,
      })
    elseif type(registry.register_target) == "function" then
      handle = registry:register_target(target)
    elseif type(registry.register) == "function" then
      handle = registry:register(target)
    else
      error("UIBox target registry must be a function or expose add_target/register_target/register")
    end
    handles[#handles + 1] = handle == nil and target or handle
  end
  return handles, targets
end

local function style_value(element, key, fallback)
  local style = element.style
  if type(style) == "table" and style[key] ~= nil then return style[key] end
  if element[key] ~= nil then return element[key] end
  return fallback
end

local function default_draw(element, state)
  local frame = element.frame
  local game = rawget(_G, "G")
  local colors = game and game.C or {}
  local rect = rawget(_G, "pixel_rect")
  local text_renderer = rawget(_G, "draw_text")
  local is_button = element.kind == "button"
  local fill = style_value(element, "fill",
    is_button and (state.enabled and colors.btn or colors.btn_off) or nil)
  local border = style_value(element, "border", is_button and colors.border or nil)

  if rect and (fill or border) and element.kind ~= "text" then
    rect(frame.x, frame.y, frame.w, frame.h, fill, {
      chamfer = style_value(element, "chamfer", is_button and 4 or 5),
      border = border,
      line_w = style_value(element, "line_w", 2),
      shadow = style_value(element, "shadow", is_button),
    })
  end

  if text_renderer and (element.kind == "text" or is_button) then
    local pad = element.padding
    local text = tostring(element.text or element.label or "")
    local font = element.font or (game and game.FONTS and (is_button and game.FONTS.normal or game.FONTS.tiny))
    local color = style_value(element, "text_color",
      is_button and (state.enabled and colors.text or colors.text_dim) or colors.text)
    local x, y = frame.x + pad.left, frame.y + pad.top
    local width = math.max(0, frame.w - pad.left - pad.right)
    text_renderer(font, text, x, y, color, width, element.text_align or (is_button and "center" or "left"))
  end
end

function UIBox:draw(context, renderer)
  local ordered = {}
  for _, element in ipairs(self.elements) do
    if element:is_visible(context) then ordered[#ordered + 1] = element end
  end
  table.sort(ordered, draw_sort)

  for _, element in ipairs(ordered) do
    local state = {
      bounds = copy_bounds(element.frame),
      enabled = element:is_enabled(context),
      visible = true,
    }
    if renderer then
      if type(renderer) == "function" then renderer(element, state)
      else
        local fn = renderer[element.kind] or renderer.draw_node
        if fn then fn(renderer, element, state) end
      end
    elseif element.draw_callback then
      element.draw_callback(element, state, context)
    else
      default_draw(element, state)
    end
  end
end

return UIBox
