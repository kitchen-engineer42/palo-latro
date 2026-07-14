-- Pure lifecycle rules for owned Tech. Era eligibility controls supply; this
-- module controls what an already-owned instance is worth and where it came from.

local Eras = require("game.eras")

local TechLifecycle = {}

TechLifecycle.DEPRECATION_PER_ERA = 0.10
TechLifecycle.DEPRECATION_CAP = 0.30

local function current_era(value)
  if value == nil and G and G.GAME then value = G.GAME.era end
  return Eras.number(value) or 1
end

local function rounded(value)
  if value >= 0 then return math.floor(value + 0.5) end
  return math.ceil(value - 0.5)
end

-- Returns one shared status shape for UI, scoring, replacement, and mimic code.
-- A gap in a multi-Era support list is deprecated relative to the latest past
-- support, then becomes supported again when a later listed Era is reached.
function TechLifecycle.status(center, era)
  local wanted = current_era(era)
  local supported = Eras.supported_eras(center)
  local latest, next_era
  for _, n in ipairs(supported) do
    if n == wanted then
      return {
        state = "supported", era = wanted, eras_behind = 0,
        penalty = 0, factor = 1, latest_supported = wanted,
      }
    elseif n < wanted then
      latest = n
    elseif not next_era then
      next_era = n
    end
  end

  -- A Tech whose first support window has not arrived is unavailable to supply,
  -- not deprecated. If an external effect owns it early, it retains full Users.
  if not latest then
    return {
      state = "future", era = wanted, eras_behind = 0,
      penalty = 0, factor = 1, next_supported = next_era,
    }
  end

  local behind = wanted - latest
  local penalty = math.min(TechLifecycle.DEPRECATION_CAP,
    behind * TechLifecycle.DEPRECATION_PER_ERA)
  return {
    state = "deprecated", era = wanted, eras_behind = behind,
    penalty = penalty, factor = 1 - penalty,
    latest_supported = latest, next_supported = next_era,
  }
end

function TechLifecycle.is_deprecated(center, era)
  local status = TechLifecycle.status(center, era)
  return status.state == "deprecated", status
end

-- Persistent Users stickers are evaluated exactly as the live Card historically
-- did: additive stickers compose, then multiplicative stickers; an override
-- starts a new segment. No rounding happens here.
function TechLifecycle.users_with_stickers(subject, center)
  subject = subject or {}
  center = center or subject.center or {}
  local users = subject.base_users
  if users == nil then users = center.base_users or 0 end
  local add, mul = 0, 1
  for _, sticker in ipairs(subject.stickers or {}) do
    if sticker.field == "users" then
      if sticker.mode == "add" then
        add = add + (sticker.amount or 0)
      elseif sticker.mode == "mul" then
        mul = mul * (sticker.amount or 1)
      elseif sticker.mode == "override" then
        users, add, mul = sticker.amount or users, 0, 1
      end
    end
  end
  return (users + add) * mul
end

-- `subject` may be a live Card or a plain master_deck entry. Plain entries pass
-- their resolved center as the second argument. Era decay is applied after all
-- persistent Users stickers and the result is rounded once, at the very end.
function TechLifecycle.effective_users(subject, center, era)
  subject = subject or {}
  center = center or subject.center or {}
  local status = TechLifecycle.status(center, era)
  local before = TechLifecycle.users_with_stickers(subject, center)
  return rounded(before * status.factor), status, before
end

local function normalize_ante(value)
  value = tonumber(value)
  if not value then return nil end
  return math.max(1, math.floor(value))
end

local function current_ante(value)
  if value == nil and G and G.GAME then value = G.GAME.ante end
  return normalize_ante(value) or 1
end

-- Canonical per-instance provenance is intentionally flat and serializable:
--   source          acquisition channel (`starter`, `draft`, `migration`, ...)
--   acquired_ante   Ante when the current center entered this stable instance
--   migrated_from   immediately previous center_key, only for replacements
function TechLifecycle.acquire(entry, opts)
  assert(type(entry) == "table", "Tech acquisition requires a deck entry")
  opts = opts or {}
  local ante = normalize_ante(opts.acquired_ante)
    or normalize_ante(entry.acquired_ante)
    or current_ante(opts.ante)
  entry.source = opts.source or entry.source or "unknown"
  entry.acquired_ante = ante
  if opts.migrated_from ~= nil then entry.migrated_from = opts.migrated_from end
  return entry
end

-- Replace a Tech in place so references and uid stay stable. All modifier fields
-- (and unknown extension fields) survive because only identity/provenance change.
function TechLifecycle.migrate(entry, replacement_key, opts)
  assert(type(entry) == "table", "Tech migration requires a deck entry")
  assert(type(replacement_key) == "string" and replacement_key ~= "",
    "Tech migration requires a replacement center key")
  local previous = entry.center_key
  assert(type(previous) == "string" and previous ~= "",
    "Tech migration requires an existing center key")
  opts = opts or {}
  entry.center_key = replacement_key
  TechLifecycle.acquire(entry, {
    source = opts.source or "migration",
    acquired_ante = opts.acquired_ante or opts.ante,
    migrated_from = previous,
  })
  return entry
end

return TechLifecycle
