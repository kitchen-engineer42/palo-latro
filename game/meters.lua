-- game/meters.lua — the generic threshold-counter primitive (engine v2). One abstraction so 8+
-- mechanics are CONTENT, not engine work: tech_debt, knowledge_charge, hype (decays), credibility
-- (monotonic), moat_strength, oss_lean, per-lineage mafia tiers, rung_progress. Stored in
-- G.GAME.meters[name] = { value, min, max, decay_per_round, thresholds[], monotonic, tier }.

local Meters = {}

-- define (idempotent): registers a meter with its shape. Call from runstate/mechanic setup.
function Meters.def(name, spec)
  spec = spec or {}
  local m = G.GAME.meters[name]
  if not m then
    m = {
      value = spec.start or 0, min = spec.min or 0, max = spec.max,
      decay_per_round = spec.decay_per_round or 0,
      thresholds = spec.thresholds or {},               -- ascending numeric cut points → tier index
      monotonic = spec.monotonic or false,              -- true = never decreases
      tier = 0,
    }
    G.GAME.meters[name] = m
    Meters._retier(m)
  end
  return m
end

local function clamp(m, v)
  if m.monotonic and v < m.value then v = m.value end
  if v < m.min then v = m.min end
  if m.max and v > m.max then v = m.max end
  return v
end

function Meters._retier(m)
  local t = 0
  for i, cut in ipairs(m.thresholds) do if m.value >= cut then t = i else break end end
  m.tier = t
end

-- add (delta may be negative unless monotonic). Returns the new tier (for on-cross effects).
function Meters.add(name, delta)
  local m = G.GAME.meters[name] or Meters.def(name)
  local before = m.tier
  m.value = clamp(m, m.value + (delta or 0))
  Meters._retier(m)
  return m.tier, (m.tier > before)                      -- new tier, crossed-up?
end

function Meters.get(name)  local m = G.GAME.meters[name]; return m and m.value or 0 end
function Meters.tier(name) local m = G.GAME.meters[name]; return m and m.tier or 0 end

-- decay every defined meter by its per-round rate (call on end_of_round). Monotonic meters ignore it.
function Meters.decay_all()
  for _, m in pairs(G.GAME.meters or {}) do
    if not m.monotonic and m.decay_per_round ~= 0 then
      m.value = clamp(m, m.value - m.decay_per_round)
      Meters._retier(m)
    end
  end
end

return Meters
