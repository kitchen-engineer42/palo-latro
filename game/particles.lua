-- game/particles.lua — lightweight sparkle-burst particles for scoring juice. A flat pool
-- (G.PARTICLES); drawn inside the scene/shake transform. Gated by reduced_motion. Count-capped.

local Particles = {}

function Particles.burst(x, y, color, n)
  if G.SETTINGS.reduced_motion then return end
  n = n or 6
  for _ = 1, n do
    local ang = love.math.random() * math.pi * 2
    local spd = 40 + love.math.random() * 110
    table.insert(G.PARTICLES, {
      x = x, y = y,
      vx = math.cos(ang) * spd,
      vy = math.sin(ang) * spd - 50,                 -- bias upward
      size = 3 + love.math.random() * 4,
      color = { color[1], color[2], color[3] },
      born = G.TIMERS.REAL, life = 0.5 + love.math.random() * 0.45,
    })
  end
  while #G.PARTICLES > 500 do table.remove(G.PARTICLES, 1) end   -- hard cap
end

function Particles.update(dt)
  local now = G.TIMERS.REAL
  for i = #G.PARTICLES, 1, -1 do
    local p = G.PARTICLES[i]
    p.x = p.x + p.vx * dt
    p.y = p.y + p.vy * dt
    p.vy = p.vy + 240 * dt                           -- gravity
    p.vx = p.vx * (1 - 1.6 * dt)                     -- drag
    if now - p.born >= p.life then table.remove(G.PARTICLES, i) end
  end
end

function Particles.draw()
  local now = G.TIMERS.REAL
  for _, p in ipairs(G.PARTICLES) do
    local a = math.max(0, 1 - (now - p.born) / p.life)
    love.graphics.setColor(p.color[1], p.color[2], p.color[3], a)
    love.graphics.rectangle("fill", p.x - p.size / 2, p.y - p.size / 2, p.size, p.size, 1, 1)
  end
end

return Particles
