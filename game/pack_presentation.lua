-- game/game/pack_presentation.lua -- presentation-only timing for shop pack ceremonies.
-- Choice generation and acquisition stay in shop.lua; this module only describes what the UI
-- should show at a given wall-clock time. That separation keeps presentation speed out of RNG.

local PackPresentation = {}
local Audio = require("game.audio")
local Juice = require("game.juice")

local FULL = {
  cover_end = 0.42,
  tear_end = 0.78,
  first_deal = 0.80,
  deal_gap = 0.11,
  deal_duration = 0.28,
  first_flip = 1.16,
  flip_gap = 0.18,
  flip_duration = 0.16,
  ready_pad = 0.08,
}

local REDUCED_READY = 0.12

local function clamp01(v)
  return math.max(0, math.min(1, v))
end

local function now()
  return (G.TIMERS and G.TIMERS.REAL) or 0
end

local function ready_age(pack_open)
  if G.SETTINGS and G.SETTINGS.reduced_motion then return REDUCED_READY end
  local count = #((pack_open and pack_open.options) or {})
  return FULL.first_flip + math.max(0, count - 1) * FULL.flip_gap
    + FULL.flip_duration + FULL.ready_pad
end

function PackPresentation.begin(pack_open, source_index, definition)
  if not pack_open then return end
  pack_open.presentation = {
    started_at = now(),
    source_index = source_index,
    pack_key = definition and definition.key or pack_open.kind,
  }
end

-- Returns an immutable frame description. UI code can render it without advancing game state.
function PackPresentation.snapshot(pack_open)
  local p = pack_open and pack_open.presentation
  if not p then
    return { age = math.huge, ready = true, cover = false, tearing = false, cards = {} }
  end

  local age = math.max(0, now() - (p.started_at or 0))
  local count = #(pack_open.options or {})
  local reduced = G.SETTINGS and G.SETTINGS.reduced_motion
  local out = { age = age, cards = {}, reduced = reduced }

  if reduced then
    out.cover = age < REDUCED_READY
    out.cover_progress = clamp01(age / REDUCED_READY)
    out.tearing = false
    out.ready = age >= REDUCED_READY
    for i = 1, count do
      out.cards[i] = { visible = true, face_down = false, deal = 1, flip = 1, scale_x = 1 }
    end
    return out
  end

  out.cover = age < FULL.tear_end
  out.cover_progress = clamp01(age / FULL.cover_end)
  out.tearing = age >= FULL.cover_end and age < FULL.tear_end
  out.tear_progress = clamp01((age - FULL.cover_end) / (FULL.tear_end - FULL.cover_end))

  local last_flip = FULL.first_flip + math.max(0, count - 1) * FULL.flip_gap
  out.ready = age >= last_flip + FULL.flip_duration + FULL.ready_pad
  for i = 1, count do
    local deal_at = FULL.first_deal + (i - 1) * FULL.deal_gap
    local flip_at = FULL.first_flip + (i - 1) * FULL.flip_gap
    local flip = clamp01((age - flip_at) / FULL.flip_duration)
    out.cards[i] = {
      visible = age >= deal_at,
      face_down = age < flip_at + FULL.flip_duration * 0.5,
      deal = clamp01((age - deal_at) / FULL.deal_duration),
      flip = flip,
      scale_x = math.max(0.04, math.abs(2 * flip - 1)),
    }
  end
  return out
end

function PackPresentation.input_locked(pack_open)
  return pack_open ~= nil and not PackPresentation.snapshot(pack_open).ready
end

function PackPresentation.fast_forward(pack_open)
  local p = pack_open and pack_open.presentation
  if not p or not PackPresentation.input_locked(pack_open) then return false end
  p.started_at = now() - ready_age(pack_open)
  p.fast_forwarded = true
  p.tear_cued, p.ready_cued, p.flip_cued = true, true, {}
  for index = 1, #((pack_open and pack_open.options) or {}) do p.flip_cued[index] = true end
  return true
end

-- Fire tactile cues once as the pure timeline crosses its beats. Presentation flags live beside
-- the timeline only; they never alter pack contents, cost, picks, or gameplay RNG.
function PackPresentation.update(pack_open)
  local p = pack_open and pack_open.presentation
  if not p or (G.SETTINGS and G.SETTINGS.reduced_motion) then return end
  local age = math.max(0, now() - (p.started_at or 0))
  if age >= FULL.cover_end and not p.tear_cued then
    p.tear_cued = true
    Audio.event("pack_open", { intensity = 1.3 })
    Juice.shake(0.8); Juice.flash(0.10, G.C.arr)
  end
  p.flip_cued = p.flip_cued or {}
  for i = 1, #(pack_open.options or {}) do
    local flip_at = FULL.first_flip + (i - 1) * FULL.flip_gap
    if age >= flip_at and not p.flip_cued[i] then
      p.flip_cued[i] = true
      Audio.event("flip", { pitch = 0.94 + i * 0.08, intensity = 0.8 })
    end
  end
  local ready_at = FULL.first_flip + math.max(0, #(pack_open.options or {}) - 1) * FULL.flip_gap
    + FULL.flip_duration + FULL.ready_pad
  if age >= ready_at and not p.ready_cued then
    p.ready_cued = true
    Audio.event("reveal", { intensity = 1.2 })
  end
end

return PackPresentation
