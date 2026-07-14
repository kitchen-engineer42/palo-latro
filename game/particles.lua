-- game/particles.lua — deterministic, pooled presentation particles. These deliberately
-- avoid love.math.random so cosmetic bursts never advance gameplay RNG.

local Particles = { serial = 0 }

local PRESETS = {
  score   = { n = 6,  speed = 115, gravity = 240, life = .72, size = 5, shape = "square" },
  mult    = { n = 8,  speed = 90,  gravity = 70,  life = .62, size = 4, shape = "diamond" },
  system  = { n = 10, speed = 75,  gravity = 20,  life = .82, size = 4, shape = "circle" },
  final   = { n = 22, speed = 180, gravity = 210, life = .95, size = 7, shape = "diamond" },
  penalty = { n = 8,  speed = 65,  gravity = 180, life = .68, size = 5, shape = "square", downward = true },
  cash    = { n = 10, speed = 100, gravity = 190, life = .80, size = 5, shape = "circle" },
}

local function rand01(seed)
  local x = math.sin(seed * 12.9898 + 78.233) * 43758.5453
  return x - math.floor(x)
end

function Particles.emit(kind, x, y, color, intensity)
  if G.SETTINGS.reduced_motion or G.SETTINGS.particles == false then return end
  local p = PRESETS[kind] or PRESETS.score
  intensity = clamp(intensity or 1, .3, 2.5)
  local n = math.floor(p.n * math.min(1.7, .65 + .35 * intensity) + .5)
  Particles.serial = Particles.serial + 1
  for i = 1, n do
    local seed = Particles.serial * 97 + i * 17
    local ang = rand01(seed) * math.pi * 2
    if p.downward then ang = math.pi * (.15 + .7 * rand01(seed + 2)) end
    local speed = p.speed * (.55 + .7 * rand01(seed + 1)) * math.min(1.4, .8 + .2 * intensity)
    G.PARTICLES[#G.PARTICLES + 1] = {
      x = x, y = y, vx = math.cos(ang) * speed, vy = math.sin(ang) * speed - (p.downward and 0 or 35),
      size = p.size * (.65 + .65 * rand01(seed + 3)), rotation = ang, vr = (rand01(seed + 4) - .5) * 9,
      gravity = p.gravity, color = { color[1], color[2], color[3] }, shape = p.shape,
      born = G.TIMERS.REAL, life = p.life * (.8 + .35 * rand01(seed + 5)),
    }
  end
  while #G.PARTICLES > 500 do table.remove(G.PARTICLES, 1) end
end

function Particles.burst(x, y, color, n)
  local scale = n and clamp(n / PRESETS.score.n, .3, 2.5) or 1
  Particles.emit("score", x, y, color, scale)
end

function Particles.update(dt)
  local now = G.TIMERS.REAL
  for i = #G.PARTICLES, 1, -1 do
    local p = G.PARTICLES[i]
    p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
    p.vy, p.vx = p.vy + (p.gravity or 240) * dt, p.vx * math.max(0, 1 - 1.6 * dt)
    p.rotation = (p.rotation or 0) + (p.vr or 0) * dt
    if now - p.born >= p.life then table.remove(G.PARTICLES, i) end
  end
end

function Particles.draw()
  local now = G.TIMERS.REAL
  for _, p in ipairs(G.PARTICLES) do
    local progress = clamp((now - p.born) / p.life, 0, 1)
    local envelope = math.sin(math.pi * progress) -- ease in and out instead of blinking on
    local size, alpha = p.size * (.25 + .75 * envelope), math.min(1, envelope * 1.4)
    love.graphics.setColor(p.color[1], p.color[2], p.color[3], alpha)
    love.graphics.push(); love.graphics.translate(p.x, p.y); love.graphics.rotate(p.rotation or 0)
    if p.shape == "circle" then love.graphics.circle("fill", 0, 0, size / 2)
    elseif p.shape == "diamond" then
      love.graphics.polygon("fill", 0, -size / 2, size / 2, 0, 0, size / 2, -size / 2, 0)
    else love.graphics.rectangle("fill", -size / 2, -size / 2, size, size, 1, 1) end
    love.graphics.pop()
  end
end

return Particles
