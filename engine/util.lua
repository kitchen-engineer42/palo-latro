-- engine/util.lua — small global helpers (clean-room).
-- Defines a handful of globals used across the engine.

function lerp(a, b, t) return a + (b - a) * t end

function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end

function sgn(x) if x > 0 then return 1 elseif x < 0 then return -1 else return 0 end end

-- round to `places` decimal places (default 0)
function round_to(x, places)
  local m = 10 ^ (places or 0)
  return math.floor(x * m + 0.5) / m
end

-- shallow copy
function copy_table(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

-- deep copy (data tables only; no metatables/functions expected in centers)
function deep_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deep_copy(v) end
  return r
end

-- Format a number for the HUD: comma-grouped integers up to 1e9, then scientific
-- notation (Balatro-style "the screen can barely contain the number"). ARR can explode.
function format_number(n)
  if n ~= n then return "NaN" end
  if n == math.huge then return "inf" end
  if n == -math.huge then return "-inf" end
  local sign = n < 0 and "-" or ""
  n = math.floor(math.abs(n) + 0.5)
  if n < 1e9 then
    local s = tostring(n)
    local out, count = "", 0
    for i = #s, 1, -1 do
      out = s:sub(i, i) .. out
      count = count + 1
      if count % 3 == 0 and i > 1 then out = "," .. out end
    end
    return sign .. out
  end
  -- scientific: mantissa e exponent
  local exp = math.floor(math.log(n, 10))
  local mant = n / (10 ^ exp)
  return sign .. string.format("%.2fe%d", mant, exp)
end

-- Axis-aligned point-in-rect
function point_in_rect(px, py, x, y, w, h)
  return px >= x and px <= x + w and py >= y and py <= y + h
end

-- Rotate point (px,py) around (cx,cy) by -r radians (inverse rotate, for hit-testing
-- a rotated rect: rotate the cursor into the rect's local frame, then AABB test).
function rotate_point_inv(px, py, cx, cy, r)
  if r == 0 then return px, py end
  local c, s = math.cos(-r), math.sin(-r)
  local dx, dy = px - cx, py - cy
  return cx + dx * c - dy * s, cy + dx * s + dy * c
end
