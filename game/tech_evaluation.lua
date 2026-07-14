-- Transactional Tech Evaluation service. Pack presentation chooses an offered
-- Tech, then this module either adopts it (+1 deck entry) or migrates one
-- currently Deprecated entry in place (+0 deck entries).

local Centers = require("game.centers")
local Deck = require("game.deck")
local Eras = require("game.eras")
local TechLifecycle = require("game.tech_lifecycle")

local TechEvaluation = {}

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  return out
end

local function equal(a, b, seen)
  if a == b then return true end
  if type(a) ~= type(b) or type(a) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for key, value in pairs(a) do if not equal(value, b[key], seen) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

function TechEvaluation.copy_cap(center, game)
  game = game or (G and G.GAME)
  return Deck.copy_cap(center, game and game.market)
end

function TechEvaluation.count(game, center_key, ignored_uid)
  local total = 0
  for _, entry in ipairs((game and game.master_deck) or {}) do
    if entry.uid ~= ignored_uid and entry.center_key == center_key then total = total + 1 end
  end
  return total
end

local function current_center(game, key)
  local center = type(key) == "table" and key or Centers.get(key)
  if not center or center.set ~= "TechCard" or center.signature then return nil, "invalid Tech option" end
  if not Eras.available(center, game and game.era) then return nil, "Tech option is stale for the current Era" end
  return center
end

local function valid_master(game)
  if not (game and type(game.master_deck) == "table") then return false, "master deck is unavailable" end
  return Deck.validate(game.master_deck)
end

-- Sorted/weighted candidate selection lives in Deck; supplying the named pack
-- RNG stream makes the result reproducible from the serialized run state.
function TechEvaluation.generate(game, count, rng)
  game = game or (G and G.GAME)
  if not game then return {} end
  return Deck.draft_candidates(Centers.pool("TechCard"), game.market, game.era,
    game.master_deck or {}, count or 3, rng)
end

function TechEvaluation.available_count(game)
  game = game or (G and G.GAME)
  local total = 0
  for _, center in ipairs(Centers.pool("TechCard")) do
    if not center.signature and Eras.available(center, game and game.era)
        and Deck.can_add((game and game.master_deck) or {}, center, game and game.market) then
      total = total + 1
    end
  end
  return total
end

function TechEvaluation.is_deprecated(entry, game)
  game = game or (G and G.GAME)
  local center = entry and Centers.get(entry.center_key)
  if not center then return false end
  return TechLifecycle.is_deprecated(center, game and game.era)
end

function TechEvaluation.deprecated_targets(game)
  game = game or (G and G.GAME)
  local out = {}
  for _, entry in ipairs((game and game.master_deck) or {}) do
    if TechEvaluation.is_deprecated(entry, game) then out[#out + 1] = entry end
  end
  table.sort(out, function(a, b)
    if a.center_key ~= b.center_key then return a.center_key < b.center_key end
    return tostring(a.uid) < tostring(b.uid)
  end)
  return out
end

local function acquire_provenance(entry, game)
  local context = { source = "tech_eval_adopt", acquired_ante = game.ante }
  return TechLifecycle.acquire(copy(entry), context)
end

function TechEvaluation.adopt(center_key, game)
  game = game or (G and G.GAME)
  local valid, reason = valid_master(game)
  if not valid then return nil, reason end
  local center; center, reason = current_center(game, center_key)
  if not center then return nil, reason end
  if not Deck.can_add(game.master_deck, center, game.market) then
    return nil, "Tech copy cap reached"
  end

  -- All fallible validation happens before the deck mutation. master_add is the
  -- canonical UID allocator; an unexpected postcondition rolls back completely.
  local previous_uid, previous_size = game._deck_uid, #game.master_deck
  local entry = require("game.round").master_add(center.key, {
    source = "tech_eval_adopt", acquired_ante = game.ante,
  }, game)
  if not entry then return nil, "Tech adoption failed" end
  local acquired = acquire_provenance(entry, game)
  if acquired ~= entry then game.master_deck[#game.master_deck] = acquired; entry = acquired end
  local post_valid, post_reason = Deck.validate(game.master_deck)
  if not post_valid or #game.master_deck ~= previous_size + 1 then
    while #game.master_deck > previous_size do table.remove(game.master_deck) end
    game._deck_uid = previous_uid
    return nil, post_reason or "Tech adoption violated deck invariants"
  end
  return entry
end

local function find_uid(game, uid)
  local found_index
  for index, entry in ipairs(game.master_deck or {}) do
    if entry.uid == uid then
      if found_index then return nil, nil, "duplicate migration target uid" end
      found_index = index
    end
  end
  if not found_index then return nil, nil, "migration target is stale" end
  return found_index, game.master_deck[found_index]
end

local function migrated_copy(entry, center_key, game)
  local context = { source = "tech_eval_migrate", acquired_ante = game.ante }
  return TechLifecycle.migrate(copy(entry), center_key, context)
end

function TechEvaluation.migrate(center_key, target_uid, game)
  game = game or (G and G.GAME)
  local valid, reason = valid_master(game)
  if not valid then return nil, reason end
  local center; center, reason = current_center(game, center_key)
  if not center then return nil, reason end
  local index, target; index, target, reason = find_uid(game, target_uid)
  if not index then return nil, reason end
  if not TechEvaluation.is_deprecated(target, game) then return nil, "migration target is not Deprecated" end
  if TechEvaluation.count(game, center.key, target.uid) >= TechEvaluation.copy_cap(center, game) then
    return nil, "Tech copy cap reached"
  end

  -- Build and validate an isolated replacement first. The live master entry is
  -- swapped exactly once only after every stale-target/cap/provenance check passes.
  local replacement; replacement, reason = migrated_copy(target, center.key, game)
  if not replacement then return nil, reason or "Tech migration failed" end
  if replacement.uid ~= target.uid or replacement.center_key ~= center.key then
    return nil, "Tech migration did not preserve identity"
  end
  local provenance_fields = { center_key = true, source = true, acquired_ante = true, migrated_from = true }
  for field, value in pairs(target) do
    if not provenance_fields[field] and not equal(value, replacement[field]) then
      return nil, "Tech migration changed persistent field " .. tostring(field)
    end
  end
  if replacement.migrated_from ~= target.center_key then
    return nil, "Tech migration lacks migrated_from provenance"
  end
  local prospective = {}
  for i, entry in ipairs(game.master_deck) do prospective[i] = (i == index) and replacement or entry end
  valid, reason = Deck.validate(prospective)
  if not valid or #prospective ~= #game.master_deck then return nil, reason or "Tech migration changed deck size" end
  game.master_deck[index] = replacement
  return replacement
end

return TechEvaluation
