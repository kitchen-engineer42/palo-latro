-- game/audio.lua — semantic procedural SFX. Gameplay asks for an event (score users,
-- multiplier, penalty, purchase...) and this module layers deterministic synth voices.
-- A small voice budget prevents retrigger-heavy hands from turning into clipping noise.

local Audio = { active = {}, active_by_event = {}, max_voices = 24, max_per_event = 5 }

local function tone(freq, dur, wave, decay, amp)
  local rate, n = 44100, math.max(1, math.floor(44100 * dur))
  local sd = love.sound.newSoundData(n, rate, 16, 1)
  amp = amp or 0.3
  for i = 0, n - 1 do
    local t, env = i / rate, math.exp(-(decay or 12) * i / rate)
    local frac = freq * t - math.floor(freq * t)
    local s = wave == "square" and (frac < 0.5 and 1 or -1)
      or wave == "tri" and (2 * math.abs(2 * frac - 1) - 1)
      or math.sin(2 * math.pi * freq * t)
    sd:setSample(i, amp * env * s)
  end
  return sd
end

-- Layers are {voice, pitch, volume}. Intensity changes emphasis, never timing/game state.
local EVENTS = {
  select        = {{"tick", 1.00, .34}},
  denied        = {{"low", .72, .35}, {"tick", .70, .18}},
  hire          = {{"bright", 1.00, .40}, {"bright", 1.26, .26}},
  fire          = {{"low", .78, .42}, {"noise", .80, .18}},
  cash          = {{"bright", 1.30, .38}, {"tick", 1.65, .20}},
  ship          = {{"low", 1.00, .34}, {"soft", 1.50, .22}},
  score_users   = {{"chip", 1.00, .34}, {"tick", 1.25, .12}},
  score_mult    = {{"soft", 1.00, .38}, {"bright", 1.25, .18}},
  score_xmult   = {{"soft", .84, .34}, {"bright", 1.26, .30}, {"bright", 1.59, .18}},
  score_system  = {{"soft", 1.18, .28}, {"tick", 1.45, .13}},
  score_penalty = {{"low", .82, .38}, {"noise", .90, .13}},
  score_final   = {{"low", 1.00, .34}, {"bright", 1.00, .30}, {"bright", 1.50, .24}},
  flip          = {{"noise", 1.45, .16}, {"tick", 1.10, .18}},
  pack_open     = {{"noise", .72, .32}, {"low", 1.25, .24}},
  reveal        = {{"bright", 1.00, .32}, {"bright", 1.50, .18}},
  lose          = {{"low", .58, .50}, {"soft", .55, .24}},
  win           = {{"bright", 1.00, .30}, {"bright", 1.26, .28}, {"bright", 1.50, .28}},
  letter        = {{"tick", 1.00, .12}},
  hover         = {{"tick", 1.18, .10}},
  press         = {{"low", 1.08, .14}, {"tick", .92, .09}},
  select_card   = {{"tick", 1.04, .20}, {"bright", 1.34, .10}},
  deselect_card = {{"tick", .82, .16}},
  cancel        = {{"low", .86, .18}},
  transition    = {{"soft", .72, .18}, {"bright", 1.08, .12}},
  acquire       = {{"bright", 1.08, .28}, {"bright", 1.42, .18}},
  remove        = {{"low", .78, .26}, {"noise", .86, .11}},
  purchase      = {{"bright", 1.16, .26}, {"bright", 1.55, .17}},
  reroll        = {{"noise", 1.18, .18}, {"tick", 1.34, .12}},
  cash_gain     = {{"bright", 1.30, .30}, {"tick", 1.65, .16}},
  cash_spend    = {{"tick", .88, .16}, {"low", 1.12, .16}},
  deal          = {{"noise", 1.28, .11}, {"tick", 1.08, .10}},
  return_card   = {{"noise", .92, .11}, {"tick", .86, .09}},
  reorder       = {{"tick", .96, .12}},
  pack_ready    = {{"bright", 1.12, .24}, {"bright", 1.50, .14}},
}

local SD = {}

function Audio.load()
  SD.chip   = tone(440, .09, "square", 22, .28)
  SD.tick   = tone(720, .035, "square", 55, .14)
  SD.soft   = tone(330, .17, "tri", 11, .30)
  SD.bright = tone(660, .12, "tri", 16, .28)
  SD.low    = tone(150, .24, "tri", 8, .32)
  SD.noise  = tone(92, .10, "square", 28, .16)
  G.SFX = {}
  for k, v in pairs(SD) do G.SFX[k] = love.audio.newSource(v, "static") end
  Audio.active, Audio.active_by_event = {}, {}
end

local function reap()
  for i = #Audio.active, 1, -1 do
    local v = Audio.active[i]
    if not v.source:isPlaying() then
      Audio.active_by_event[v.event] = math.max(0, (Audio.active_by_event[v.event] or 1) - 1)
      table.remove(Audio.active, i)
    end
  end
end

local function voice(event, key, pitch, volume)
  if not G.SETTINGS.sound or not G.SFX or not G.SFX[key] then return false end
  reap()
  if #Audio.active >= Audio.max_voices or (Audio.active_by_event[event] or 0) >= Audio.max_per_event then return false end
  local src = G.SFX[key]:clone()
  local master = clamp(G.SETTINGS.sfx_volume == nil and 1 or G.SETTINGS.sfx_volume, 0, 1)
  src:setPitch(clamp(pitch or 1, .45, 2.25)); src:setVolume(clamp((volume or 1) * master, 0, .7)); src:play()
  Audio.active[#Audio.active + 1] = { source = src, event = event }
  Audio.active_by_event[event] = (Audio.active_by_event[event] or 0) + 1
  return true
end

function Audio.event(name, opts)
  opts = opts or {}
  local layers = EVENTS[name]
  if not layers then return false end
  local intensity = clamp(opts.intensity or 1, .25, 2.5)
  local pitch = opts.pitch or 1
  for i, layer in ipairs(layers) do
    -- Extra layers grow gently; loudness remains bounded even on spectacular scores.
    local gain = layer[3] * math.min(1.35, .72 + .28 * intensity) / math.sqrt(i)
    voice(name, layer[1], layer[2] * pitch, gain)
  end
  return true
end

function Audio.chip(step, total)
  total = math.max(1, total or 1)
  Audio.event("score_users", { pitch = .92 + .28 * (step / total), intensity = 1 })
end

function Audio.letter(idx, len)
  Audio.event("letter", { pitch = .9 + .5 * (idx / math.max(1, len)), intensity = .5 })
end

-- Compatibility bridge for existing call sites; new feedback should use Audio.event.
local LEGACY = { mult = "score_mult", cash = "cash", select = "select", hire = "hire",
  fire = "fire", lose = "lose", ship = "ship", flip = "flip", reveal = "reveal" }
function Audio.play(name, pitch, vol)
  Audio.event(LEGACY[name] or name, { pitch = pitch or 1, intensity = vol and clamp(vol * 2, .25, 2) or 1 })
end
function Audio.win() Audio.event("win", { intensity = 1.5 }) end

return Audio
