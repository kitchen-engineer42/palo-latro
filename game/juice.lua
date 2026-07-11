-- game/juice.lua — the visual game-feel layer: floating combat text, screen shake, and the
-- score-readout pulse. All gated by G.SETTINGS.reduced_motion. (Card squash/pop lives on Moveable;
-- sound lives in audio.lua.)

local Juice = {}
Juice.pulses = {}
local Audio = require("game.audio")

-- floating combat text: "+N Users" / "x N Rev" / "+$N" pops above a scoring card and rises/fades
function Juice.text(x, y, str, color)
  if G.SETTINGS.reduced_motion then return end
  table.insert(G.FLOATING, {
    x = x, y = y, str = str,
    color = { color[1], color[2], color[3] },
    born = G.TIMERS.REAL, life = 0.9, revealed = 0,
  })
end

-- screen shake: accumulate amplitude; decays each frame in update
function Juice.shake(amt)
  if G.SETTINGS.reduced_motion then return end
  G.SHAKE = G.SHAKE + (amt or 1)
end

-- score-readout pulse: bump a key; field_scale returns a brief scale spike that decays
function Juice.pulse(key)
  if G.SETTINGS.reduced_motion then return end
  Juice.pulses[key] = G.TIMERS.REAL
end

-- full-screen flash: a brief, SUBTLE colored wash over everything (the crescendo / win-lose punctuation).
-- Drawn last in love.draw via Juice.draw_flash(); decays from a low alpha so it never blinds.
function Juice.flash(dur, col)
  if G.SETTINGS.reduced_motion then return end
  G.FLASH = { born = G.TIMERS.REAL, dur = dur or 0.18, col = col or G.C.white }
end

function Juice.draw_flash()
  local f = G.FLASH
  if not f then return end
  local age = G.TIMERS.REAL - f.born
  if age >= f.dur then G.FLASH = nil; return end
  love.graphics.setColor(f.col[1], f.col[2], f.col[3], (1 - age / f.dur) * 0.18)   -- subtle, decaying
  love.graphics.rectangle("fill", 0, 0, G.WINDOW.w, G.WINDOW.h)
end

function Juice.field_scale(key)
  local p = Juice.pulses[key]
  if not p then return 1 end
  local age = G.TIMERS.REAL - p
  if age >= 0.22 then return 1 end
  return 1 + 0.16 * (1 - age / 0.22)
end

function Juice.update(dt)
  G.SHAKE = math.max(0, G.SHAKE * (1 - 5 * dt))
  local now = G.TIMERS.REAL
  for i = #G.FLOATING, 1, -1 do
    local f = G.FLOATING[i]
    f.y = f.y - 34 * dt                      -- rise
    local appeared = math.min(#f.str, math.floor((now - f.born) / 0.035))
    if appeared > f.revealed then            -- a new letter just popped: rustle tick
      Audio.letter(appeared, #f.str)
      f.revealed = appeared
    end
    if now - f.born >= f.life then table.remove(G.FLOATING, i) end
  end
end

-- shake transform around the screen scene (push; pop_transform after the scene)
function Juice.apply_transform()
  love.graphics.push()
  if G.SETTINGS.reduced_motion or G.SHAKE <= 0.02 then return end
  local t = G.TIMERS.REAL
  local mag = math.min(G.SHAKE, 8) * 1.4
  local cx, cy = G.WINDOW.w / 2, G.WINDOW.h / 2
  love.graphics.translate(mag * math.sin(t * 53), mag * math.sin(t * 61))
  love.graphics.translate(cx, cy)
  love.graphics.rotate(0.0016 * math.min(G.SHAKE, 8) * math.sin(t * 47))
  love.graphics.translate(-cx, -cy)
end

function Juice.pop_transform() love.graphics.pop() end

-- draw floating texts (call within the scene transform, after cards)
function Juice.draw()
  local now = G.TIMERS.REAL
  local fnt = G.FONTS.normal
  love.graphics.setFont(fnt)
  for _, f in ipairs(G.FLOATING) do
    local age = now - f.born
    local fade = 1
    if age > f.life - 0.25 then fade = math.max(0, (f.life - age) / 0.25) end
    local x0 = f.x - fnt:getWidth(f.str) / 2     -- left edge so letters reveal L->R
    local cursor = 0
    for i = 1, #f.str do
      local ch = f.str:sub(i, i)
      local cw = fnt:getWidth(ch)
      local p = clamp((age - (i - 1) * 0.035) / 0.09, 0, 1)   -- per-letter staggered pop-in
      if p > 0 then
        local sc = 0.4 + 0.6 * p
        love.graphics.setColor(f.color[1], f.color[2], f.color[3], fade * p)
        love.graphics.push()
        love.graphics.translate(x0 + cursor + cw / 2, f.y)
        love.graphics.scale(sc, sc)
        love.graphics.print(ch, -cw / 2, -10)
        love.graphics.pop()
      end
      cursor = cursor + cw
    end
  end
end

return Juice
