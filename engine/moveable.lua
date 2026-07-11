-- engine/moveable.lua — the T→VT spring-easing tier. Gameplay sets a target transform T;
-- the engine eases the visible transform VT toward it every frame (no hand-animation).
-- Per-frame easing constants G.exp_times are computed once in main.update.

Moveable = Node:extend()

function Moveable:init(args)
  Moveable.super.init(self, args)
  self.VT = { x = self.T.x, y = self.T.y, w = self.T.w, h = self.T.h, r = self.T.r, scale = self.T.scale }
  self.velocity = { x = 0, y = 0, r = 0, scale = 0 }
  self.STATIONARY = true
  -- Major/Minor "welding" (shadows / edition sprites / popups) is a later module.
  self.alignment = nil
  table.insert(G.I.MOVEABLE, self)
end

-- Critically-damped easing toward target (frame-rate independent, no overshoot): a clean,
-- robust spring. `rate` sets snappiness. (The velocity-spring variant is a later tuning option.)
local function ease_axis(self, axis, rate, dt)
  local target, vt = self.T[axis], self.VT[axis]
  if math.abs(target - vt) < 0.05 then
    if vt ~= target then self.VT[axis] = target end
    return false
  end
  self.VT[axis] = vt + (target - vt) * (1 - math.exp(-rate * dt))
  return true
end

function Moveable:move(dt)
  self:move_juice()
  local moved = false
  moved = ease_axis(self, "x", 16, dt) or moved
  moved = ease_axis(self, "y", 16, dt) or moved
  moved = ease_axis(self, "r", 18, dt) or moved
  moved = ease_axis(self, "scale", 18, dt) or moved
  self.VT.w, self.VT.h = self.T.w, self.T.h   -- w/h don't animate in the slice
  self.STATIONARY = not moved
end

-- "juice up": squash-and-stretch pop on score/select (damped sine, ~0.4s). The card's draw
-- adds juice.scale / juice.r on top of its transform. Gated by reduced-motion.
function Moveable:juice_up(amount, rot_amt)
  if G.SETTINGS.reduced_motion then return end
  amount = amount or 0.4
  local r = rot_amt or 0.6 * amount
  if love.math.random() < 0.5 then r = -r end           -- randomize lean direction per pop
  self.juice = {
    scale = 0, r = 0,
    scale_amt = amount,
    r_amt = r,
    start_time = G.TIMERS.REAL,
    end_time = G.TIMERS.REAL + 0.4,
  }
  self.VT.scale = 1 - 0.6 * amount                        -- start COMPRESSED, then spring out (impact)
end

function Moveable:move_juice()
  local j = self.juice
  if not j then return end
  local now = G.TIMERS.REAL
  if now >= j.end_time then self.juice = nil; return end
  local elapsed = now - j.start_time
  local decay = (j.end_time - now) / 0.4
  j.scale = j.scale_amt * math.sin(50.8 * elapsed) * math.max(0, decay ^ 3)
  j.r     = j.r_amt * math.sin(40.8 * elapsed) * math.max(0, decay ^ 2)
end

-- set the destination (gameplay calls this, never touches VT directly)
function Moveable:set_T(x, y, w, h)
  if x then self.T.x = x end
  if y then self.T.y = y end
  if w then self.T.w = w end
  if h then self.T.h = h end
end

-- Welding seam (no-op for the slice): later attaches this Minor to a Major with an offset
-- so shadows/edition-sprites/popups follow without per-frame bookkeeping.
function Moveable:set_alignment(args) self.alignment = args end

return Moveable
