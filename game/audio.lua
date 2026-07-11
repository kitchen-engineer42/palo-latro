-- game/audio.lua — procedural chiptune SFX (asset-free; the acoustic half of the arcade vibe).
-- Tones are synthesized at load (square/tri + decay envelope); the iconic rising-pitch chip
-- count-up uses LÖVE's real-time Source:setPitch. ALL sound goes through this API, so swapping
-- to sampled / AIGC SFX later (the Option-2 fallback) touches only this file. Gated by G.SETTINGS.sound.

local Audio = {}

local function tone(freq, dur, wave, decay, amp)
  local rate = 44100
  local n = math.max(1, math.floor(rate * dur))
  local sd = love.sound.newSoundData(n, rate, 16, 1)
  amp = amp or 0.33
  for i = 0, n - 1 do
    local t = i / rate
    local env = math.exp(-(decay or 12) * t)
    local ph = freq * t
    local frac = ph - math.floor(ph)
    local s
    if wave == "square" then s = (frac < 0.5) and 1 or -1
    elseif wave == "tri" then s = 2 * math.abs(2 * frac - 1) - 1
    else s = math.sin(2 * math.pi * ph) end
    sd:setSample(i, amp * env * s)
  end
  return sd
end

local SD = {}   -- keep SoundData referenced

function Audio.load()
  SD.chip   = tone(440, 0.09, "square", 22, 0.30)
  SD.mult   = tone(330, 0.16, "tri",    11, 0.34)
  SD.cash   = tone(880, 0.12, "square", 16, 0.30)
  SD.ship   = tone(196, 0.20, "tri",     8, 0.34)
  SD.select = tone(620, 0.05, "square", 34, 0.26)
  SD.hire   = tone(523, 0.10, "square", 18, 0.30)
  SD.fire   = tone(150, 0.16, "square", 14, 0.32)
  SD.lose   = tone(110, 0.55, "tri",     3, 0.34)
  SD.tick   = tone(720, 0.03, "square",  55, 0.16)   -- per-letter "rustle"
  G.SFX = {}
  for k, v in pairs(SD) do G.SFX[k] = love.audio.newSource(v, "static") end
end

local function play_sd(key, pitch, vol)
  if not G.SETTINGS.sound or not G.SFX or not G.SFX[key] then return end
  local src = G.SFX[key]:clone()      -- clone so rapid/overlapping plays don't cut each other
  if pitch then src:setPitch(pitch) end
  src:setVolume(vol or 1)
  src:play()
end

-- rising pitch across the hand (the count-up crescendo) — subtle/musical, not shrill
function Audio.chip(step, total)
  total = math.max(1, total or 1)
  play_sd("chip", 0.92 + 0.28 * (step / total), 0.5)
end

-- per-letter "rustle" as floating text spells out (rising pitch across the word)
function Audio.letter(idx, len)
  play_sd("tick", 0.9 + 0.5 * (idx / math.max(1, len)), 0.16)
end

function Audio.play(name, pitch, vol) play_sd(name, pitch, vol) end

function Audio.win()
  play_sd("chip", 1.00, 0.5); play_sd("chip", 1.26, 0.5); play_sd("chip", 1.50, 0.5)  -- chord stab
end

return Audio
