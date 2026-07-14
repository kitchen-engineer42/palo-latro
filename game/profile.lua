-- game/game/profile.lua — the cross-run PROFILE: unlocks, discovery, beaten stakes, career stats.
-- Persisted via love.filesystem (identity "palo-latro") as a versioned, data-only literal. Legacy v1 Lua
-- literals are parsed by a restricted grammar and migrated without executing them. NO between-run player
-- power — only WHICH content is in the pool + which
-- stakes are selectable change. Locked content = the 17 legendary 2nd-forms (alternate versions; locking them
-- never gates base content or the Knowledge edge) plus an initially empty marquee list.

local Profile = {}
local Codec = require("game.profile_codec")

Profile.SAVE = "profile.lua"
Profile.VERSION = Codec.VERSION
Profile.MARQUEE_LOCK = {}            -- thin marquee tier to lock (empty v1; the mechanism is here)

local function default()
  return { unlocked = {}, discovered = {}, beaten_stakes = {},
           career = { runs = 0, wins = 0, best_arr = 0, best_ante = 1 } }
end
Profile.default = default

-- a center is locked-by-default if it's a legendary 2nd-form or in MARQUEE_LOCK.
local function locks_by_default(c)
  if c.is_form then return true end
  for _, k in ipairs(Profile.MARQUEE_LOCK) do if k == c.key then return true end end
  return false
end
Profile.locks_by_default = locks_by_default

local function available()
  return love and love.filesystem and love.filesystem.getInfo and love.filesystem.read
end

local function backup_once(name, contents)
  if love.filesystem.getInfo(name) then return true end
  local ok, err = love.filesystem.write(name, contents)
  return ok, err
end

-- love.filesystem has no cross-version rename primitive. Write and verify a sibling first, then use the
-- host's atomic rename inside LÖVE's save directory. The fallback preserves/restores the old file on hosts
-- that refuse replacing an existing destination directly (notably Windows).
local function atomic_write(name, contents)
  local temp = name .. ".tmp"
  local ok, err = love.filesystem.write(temp, contents)
  if not ok then return false, "temporary profile write failed: " .. tostring(err) end
  local verify = love.filesystem.read(temp)
  if verify ~= contents then
    love.filesystem.remove(temp)
    return false, "temporary profile verification failed"
  end

  if love.filesystem.getSaveDirectory and os and os.rename then
    local root = love.filesystem.getSaveDirectory()
    local source, destination = root .. "/" .. temp, root .. "/" .. name
    local moved, move_err = os.rename(source, destination)
    if moved then return true end

    local previous = destination .. ".previous"
    if os.remove then os.remove(previous) end
    local kept_old = os.rename(destination, previous)
    moved, move_err = os.rename(source, destination)
    if moved then
      if kept_old and os.remove then os.remove(previous) end
      return true
    end
    if kept_old then os.rename(previous, destination) end
    love.filesystem.remove(temp)
    return false, "atomic profile replace failed: " .. tostring(move_err)
  end

  love.filesystem.remove(temp)
  return false, "atomic profile replace is unavailable on this platform"
end

function Profile.load()
  Profile.last_error = nil
  G.PROFILE = default()
  if not available() or not love.filesystem.getInfo(Profile.SAVE) then return G.PROFILE end

  local raw, read_err = love.filesystem.read(Profile.SAVE)
  if not raw then Profile.last_error = "profile read failed: " .. tostring(read_err); return G.PROFILE end
  local data, meta, decode_err = Codec.decode(raw)
  if not data then
    Profile.last_error = "profile rejected: " .. tostring(decode_err)
    local quarantine = Profile.SAVE .. ".corrupt"
    local backed, backup_err = love.filesystem.write(quarantine, raw)
    if backed then love.filesystem.remove(Profile.SAVE)
    else Profile.last_error = Profile.last_error .. "; quarantine failed: " .. tostring(backup_err) end
    return G.PROFILE
  end

  G.PROFILE = data
  if meta.legacy then
    local backed, backup_err = backup_once(Profile.SAVE .. ".bak", raw)
    if not backed then
      Profile.last_error = "legacy profile backup failed: " .. tostring(backup_err)
      return G.PROFILE
    end
    local encoded, encode_err = Codec.encode(G.PROFILE)
    if not encoded then Profile.last_error = "profile migration failed: " .. tostring(encode_err); return G.PROFILE end
    local migrated, migrate_err = atomic_write(Profile.SAVE, encoded)
    if not migrated then Profile.last_error = migrate_err end
  end
  return G.PROFILE
end

function Profile.save()
  Profile.last_error = nil
  if not available() or not love.filesystem.write then return false, "profile filesystem is unavailable" end
  local encoded, encode_err = Codec.encode(G.PROFILE or default())
  if not encoded then Profile.last_error = encode_err; return false, encode_err end
  local ok, err = atomic_write(Profile.SAVE, encoded)
  if not ok then Profile.last_error = err end
  return ok, err
end

-- apply the profile's unlock/discovery state onto the loaded centers (call after Centers.load_all + Profile.load)
function Profile.apply_to_centers(Centers)
  local p = G.PROFILE or default()
  for _, set in ipairs({ "Founder" }) do
    for _, c in ipairs(Centers.pool(set)) do
      if p.unlocked[c.key] then c.unlocked = true
      elseif locks_by_default(c) then c.unlocked = false
      else c.unlocked = true end
      if p.discovered[c.key] then c.discovered = true end
    end
  end
end

function Profile.unlock(key) (G.PROFILE.unlocked)[key] = true end
function Profile.discover(key) (G.PROFILE.discovered)[key] = true end

-- highest selectable stake = 1 + highest beaten (cap 8).
function Profile.max_stake()
  local m = 1
  for n in pairs(G.PROFILE.beaten_stakes or {}) do if n + 1 > m then m = math.min(n + 1, 8) end end
  return m
end

-- Progressive form reveal: legendary 2nd-forms unlock by how DEEP the player has reached,
-- not all-at-once on a win. Sorted by key for a stable order; a deeper best-ante reveals a larger fraction.
--   reach ante 4 → ~⅓ of forms · ante 6 → ~⅔ · ante 8 / IPO win → all.
-- Tying the reveal to depth (achievable mid-run) makes forms a felt progression rather than a single win-wall.
Profile.FORM_TIERS = { { 4, 0.33 }, { 6, 0.66 }, { 8, 1.0 } }
function Profile.check_unlocks(Centers)
  local p = G.PROFILE
  local ba = p.career.best_ante or 1
  local frac = 0
  for _, t in ipairs(Profile.FORM_TIERS) do if ba >= t[1] then frac = t[2] end end
  if frac <= 0 then return end
  local forms = {}
  for _, c in ipairs(Centers.pool("Founder")) do if c.is_form then forms[#forms + 1] = c end end
  table.sort(forms, function(a, b) return a.key < b.key end)
  local n = math.floor(#forms * frac + 0.5)
  for i = 1, n do p.unlocked[forms[i].key] = true; forms[i].unlocked = true end
end

-- end-of-run: update career, persist discovery of founders seen this run, beat-stake on a win, reveal forms by depth.
function Profile.record_run(Centers)
  local p, g = G.PROFILE, G.GAME
  if not p or not g then return end                      -- no profile loaded (e.g. headless smoke) → no-op
  p.career.runs = (p.career.runs or 0) + 1
  p.career.best_arr = math.max(p.career.best_arr or 0, g.cumulative_arr or 0)
  p.career.best_ante = math.max(p.career.best_ante or 1, g.ante or 1)
  for _, c in ipairs(Centers.pool("Founder")) do if c.discovered then p.discovered[c.key] = true end end
  if g.won then
    p.career.wins = (p.career.wins or 0) + 1
    p.beaten_stakes[g.stake or 1] = true                 -- beat stake N → stake N+1 selectable
  end
  Profile.check_unlocks(Centers)                         -- progressive form reveal (any run, by best-ante)
  Profile.save()
end

return Profile
