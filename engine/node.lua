-- engine/node.lua — scene-graph node: transform, children, input states, hit-test, removal.
-- For the slice, 1 game unit = 1 pixel and G.ROOM is identity, so T/VT are screen coords
-- (container scaling/rotation is a noted later refinement; the seam is here via `container`).

Node = Object:extend()

function Node:init(args)
  args = args or {}
  local t = args.T or {}
  self.T = { x = t.x or 0, y = t.y or 0, w = t.w or 1, h = t.h or 1, r = t.r or 0, scale = t.scale or 1 }
  self.container = args.container or G.ROOM or self
  self.children = {}
  self.parent = nil
  self.ID = generate_id()
  self.states = {
    visible = true,
    collide = { can = (args.collideable ~= false), is = false },
    hover   = { can = false, is = false },
    click   = { can = false, is = false },
    drag    = { can = false, is = false },
  }
  self.REMOVED = false
  table.insert(G.I.NODE, self)
  if G.STAGE and G.STAGE_OBJECTS[G.STAGE] then
    table.insert(G.STAGE_OBJECTS[G.STAGE], self)
  end
end

function Node:add_child(node)
  node.parent = self
  table.insert(self.children, node)
end

-- rotation-aware point-in-rect against the drawn transform (VT if a Moveable, else T)
function Node:collides_with_point(px, py)
  if not self.states.collide.can then return false end
  local t = self.VT or self.T
  local lx, ly = px, py
  if t.r and t.r ~= 0 then
    lx, ly = rotate_point_inv(px, py, t.x + t.w / 2, t.y + t.h / 2, t.r)
  end
  return point_in_rect(lx, ly, t.x, t.y, t.w, t.h)
end

-- override in subclasses
function Node:draw() end
function Node:update(dt) end

-- tear out of every pool + the stage registry + controller targets (no dangling refs)
function Node:remove()
  if self.children then
    for _, c in pairs(self.children) do if c.remove and not c.REMOVED then c:remove() end end
    self.children = {}
  end
  remove_from_pool(G.I.NODE, self)
  remove_from_pool(G.I.MOVEABLE, self)
  remove_from_pool(G.I.CARD, self)
  remove_from_pool(G.I.CARDAREA, self)
  remove_from_pool(G.I.UIBOX, self)
  if G.STAGE and G.STAGE_OBJECTS[G.STAGE] then
    remove_from_pool(G.STAGE_OBJECTS[G.STAGE], self)
  end
  if G.CONTROLLER then
    for _, k in ipairs({ "hovering", "clicked", "dragging", "focused" }) do
      if G.CONTROLLER[k] == self then G.CONTROLLER[k] = nil end
    end
  end
  self.REMOVED = true
end

return Node
