-- Deterministic, fail-closed mutations for the persistent Tech deck.
--
-- Planning is side-effect free, including named RNG streams. A plan contains a
-- complete prospective deck and the fingerprints needed to reject stale work;
-- commit swaps the authoritative deck once, then reconciles its live Card views.

local Centers = require("game.centers")
local Deck = require("game.deck")
local TechLifecycle = require("game.tech_lifecycle")
local SignaturePair = require("game.signature_pair")

local Transactions = {}

local RNG_MOD, RNG_MUL = 2147483647, 48271

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  return out
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function whole(value, minimum)
  return finite(value) and value == math.floor(value) and value >= (minimum or 0)
end

local function dense_array(value)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
    count, highest = count + 1, math.max(highest, key)
  end
  return count == highest
end

local function canonical(value, seen)
  local kind = type(value)
  if kind == "nil" then return "n" end
  if kind == "boolean" then return value and "b1" or "b0" end
  if kind == "number" then
    if not finite(value) then return nil, "non-finite deck value" end
    return "d" .. string.format("%.17g", value)
  end
  if kind == "string" then return "s" .. #value .. ":" .. value end
  if kind ~= "table" or getmetatable(value) ~= nil then return nil, "deck state is not plain data" end
  seen = seen or {}
  if seen[value] then return nil, "cyclic deck state" end
  seen[value] = true
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "number" and type(key) ~= "string" then
      seen[value] = nil
      return nil, "unsupported deck key"
    end
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then return type(a) == "number" end
    return a < b
  end)
  local out = { "t", tostring(#keys), ":" }
  for _, key in ipairs(keys) do
    local encoded_key, key_reason = canonical(key, seen)
    if not encoded_key then seen[value] = nil; return nil, key_reason end
    local encoded_value, value_reason = canonical(value[key], seen)
    if not encoded_value then seen[value] = nil; return nil, value_reason end
    out[#out + 1] = tostring(#encoded_key) .. ":" .. encoded_key
    out[#out + 1] = tostring(#encoded_value) .. ":" .. encoded_value
  end
  seen[value] = nil
  return table.concat(out)
end

local function fingerprint(value)
  return canonical(value)
end

local function failed(reason, requested)
  return {
    ok = false,
    reason = reason or "Deck transaction failed",
    requested = requested or 0,
    applied = 0,
    changes = {},
    added_uids = {},
    removed_uids = {},
  }
end

local function seed_for(seed, name)
  local state = tonumber(seed) or 1
  local text = tostring(seed or "palo") .. ":" .. tostring(name)
  for i = 1, #text do state = (state * 131 + text:byte(i)) % RNG_MOD end
  return math.max(1, state)
end

local function virtual_random(game, states, bases, name, n)
  if type(name) ~= "string" or name == "" then return nil, "Deck RNG stream must be named" end
  local state = states[name]
  if state == nil then
    local raw = game.rng_streams and game.rng_streams[name]
    if raw ~= nil and (not whole(raw, 1) or raw >= RNG_MOD) then
      return nil, "Deck RNG stream state is invalid"
    end
    bases[name] = { present = raw ~= nil, state = raw }
    state = raw or seed_for(game.seed, name)
  end
  state = (state * RNG_MUL) % RNG_MOD
  states[name] = state
  local value = (state - 1) / (RNG_MOD - 1)
  return n and (math.floor(value * n) + 1) or value
end

local function center_for(entry)
  local center = entry and Centers.get(entry.center_key)
  if center and center.set == "TechCard" then return center end
end

local function base_users(entry, center)
  local value = tonumber(entry and entry.base_users)
  if value == nil then value = tonumber(center and center.base_users) or 0 end
  return value
end

local function effective_users(entry, center, game)
  if Card and Card.tech_users then return Card.tech_users(entry, center, game.era, game) end
  return TechLifecycle.effective_users(entry, center, game.era)
end

local function selector_less(a, b, selector, game)
  local ac, bc = center_for(a), center_for(b)
  local au, bu = effective_users(a, ac, game), effective_users(b, bc, game)
  local abase, bbase = base_users(a, ac), base_users(b, bc)
  if selector == "highest" then
    if au ~= bu then return au > bu end
    if abase ~= bbase then return abase > bbase end
  elseif selector == "cheapest" then
    if abase ~= bbase then return abase < bbase end
    if au ~= bu then return au < bu end
  else
    if au ~= bu then return au < bu end
    if abase ~= bbase then return abase < bbase end
  end
  local aid, bid = tonumber(a.uid) or math.huge, tonumber(b.uid) or math.huge
  if aid ~= bid then return aid < bid end
  return tostring(a.center_key or "") < tostring(b.center_key or "")
end

local function selected_entry(entries, selector, filter, game)
  local candidates = {}
  for _, entry in ipairs(entries) do
    local center = center_for(entry)
    if center and (not filter or filter(entry, center)) then candidates[#candidates + 1] = entry end
  end
  table.sort(candidates, function(a, b) return selector_less(a, b, selector, game) end)
  return candidates[1]
end

local function uid_filter(list)
  if list == nil then return nil end
  if not dense_array(list) then return false end
  local set = {}
  for _, uid in ipairs(list) do
    if not whole(uid, 1) then return false end
    set[uid] = true
  end
  return set
end

local function selected_for_op(state, selector, filter, stream)
  if selector ~= "random" then return selected_entry(state.entries, selector, filter, state.game) end
  local candidates = {}
  for _, entry in ipairs(state.entries) do
    local center = center_for(entry)
    if center and (not filter or filter(entry, center)) then candidates[#candidates + 1] = entry end
  end
  table.sort(candidates, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  if #candidates == 0 then return nil end
  return candidates[virtual_random(state.game, state.rng_states, state.rng_bases,
    stream or state.rng_stream, #candidates)]
end

local function remove_uid(entries, uid)
  for index, entry in ipairs(entries) do
    if entry.uid == uid then table.remove(entries, index); return entry end
  end
end

local function record_source(state, entry)
  if state.base_uids[entry.uid] and state.sources[entry.uid] == nil then
    state.sources[entry.uid] = assert(fingerprint(entry))
  end
end

local function next_uid(state)
  state.next_uid = state.next_uid + 1
  return state.next_uid
end

local function new_entry(state, center_key, props)
  props = props or {}
  local entry = {
    uid = next_uid(state), center_key = center_key,
    edition = props.edition,
    enhancement = props.enhancement or props.enh,
    seal = props.seal,
    modifier_state = props.modifier_state and copy(props.modifier_state) or nil,
    stickers = props.stickers and copy(props.stickers) or nil,
    layer_override = props.layer_override,
    layer_locked = props.layer_locked == true or nil,
    law_marks = props.law_marks and copy(props.law_marks) or nil,
    config = props.config and copy(props.config) or {},
  }
  TechLifecycle.acquire(entry, {
    source = props.source or "generated",
    acquired_ante = props.acquired_ante or state.game.ante,
    migrated_from = props.migrated_from,
  })
  return entry
end

local function copied_entry(state, source, props)
  props = props or {}
  local entry = copy(source)
  entry.uid = next_uid(state)
  entry.source = props.source or "copied"
  entry.acquired_ante = props.acquired_ante or state.game.ante or source.acquired_ante
  entry.copied_from_uid = source.uid
  entry.copied_from_source = source.source
  return entry
end

local function count_key(entries, key)
  local count = 0
  for _, entry in ipairs(entries) do if entry.center_key == key then count = count + 1 end end
  return count
end

local function has_copy_room(state, center, amount)
  if not state.respect_copy_cap then return true end
  local cap = Deck.copy_cap(center, state.game.market)
  return count_key(state.entries, center.key) + (amount or 1) <= cap
end

local function add_change(state, row)
  state.changes[#state.changes + 1] = row
  state.applied = state.applied + 1
end

local function normalize_amount(value)
  if value == nil then return 1 end
  if not finite(value) then return nil end
  return math.max(0, math.floor(value))
end

local function apply_add_random(state, op)
  local amount = normalize_amount(op.amount)
  if amount == nil then return nil, "Random Tech amount must be finite" end
  state.requested = state.requested + amount
  for _ = 1, amount do
    local candidates = {}
    for _, center in ipairs(Centers.pool("TechCard")) do
      local layer_allowed = not op.layer or center.layer == op.layer
      if op.layers then
        layer_allowed = false
        for _, layer in ipairs(op.layers) do if center.layer == layer then layer_allowed = true; break end end
      end
      local allowed = not center.signature and layer_allowed
        and Deck.candidate_allowed(center, state.game.market)
        and has_copy_room(state, center)
      if allowed then candidates[#candidates + 1] = center end
    end
    table.sort(candidates, function(a, b) return a.key < b.key end)
    if #candidates == 0 then return nil, "No eligible Tech candidate" end
    local stream = op.rng_stream or state.rng_stream
    local picked, reason = virtual_random(state.game, state.rng_states, state.rng_bases, stream, #candidates)
    if not picked then return nil, reason end
    local center = candidates[picked]
    local entry = new_entry(state, center.key, { source = op.source or "generated" })
    state.entries[#state.entries + 1] = entry
    add_change(state, { kind = "add", uid = entry.uid, key = entry.center_key, source = entry.source })
  end
  return true
end

local function apply_add_specific(state, op)
  local amount = normalize_amount(op.amount)
  if amount == nil then return nil, "Specific Tech amount must be finite" end
  state.requested = state.requested + amount
  local key = op.center_key or op.key
  local center = type(key) == "string" and Centers.get(key)
  if not (center and center.set == "TechCard") then return nil, "Unknown Tech candidate" end
  if center.signature and not (center.key == SignaturePair.JO_KEY
      and op.signature_injection == SignaturePair.INJECTION_TOKEN
      and op.source == "signature_pair") then
    return nil, "Signature Tech requires explicit injection"
  end
  if not center.signature then
    local allowed, reason = Deck.candidate_allowed(center, state.game.market)
    if not allowed then return nil, reason end
  end
  if not has_copy_room(state, center, amount) then return nil, "Tech copy cap reached" end
  for _ = 1, amount do
    local props = copy(op.props or {})
    props.source = props.source or op.source or "generated"
    local entry = new_entry(state, center.key, props)
    state.entries[#state.entries + 1] = entry
    add_change(state, { kind = "add", uid = entry.uid, key = entry.center_key, source = entry.source })
  end
  return true
end

local function apply_remove_key(state, op)
  local key = op.center_key or op.key
  if type(key) ~= "string" or key == "" then return nil, "Tech removal requires a key" end
  local center = Centers.get(key)
  if center and center.signature and not (key == SignaturePair.JO_KEY
      and op.signature_injection == SignaturePair.INJECTION_TOKEN
      and op.source == "signature_pair") then
    return nil, "Signature Tech requires paired removal"
  end
  local removed = {}
  for index = #state.entries, 1, -1 do
    if state.entries[index].center_key == key then
      removed[#removed + 1] = table.remove(state.entries, index)
    end
  end
  table.sort(removed, function(a, b) return (tonumber(a.uid) or 0) < (tonumber(b.uid) or 0) end)
  state.requested = state.requested + #removed
  for _, entry in ipairs(removed) do
    add_change(state, { kind = "remove", uid = entry.uid, key = entry.center_key })
  end
  return true
end

local function apply_remove_selected(state, op)
  local amount = normalize_amount(op.amount)
  if amount == nil then return nil, "Tech removal amount must be finite" end
  state.requested = state.requested + amount
  local candidates = uid_filter(op.candidate_uids)
  if candidates == false then return nil, "Tech candidate UIDs must be a dense positive-integer array" end
  for _ = 1, amount do
    local entry = selected_entry(state.entries, op.selector or op.which or "lowest", function(candidate, center)
      return not center.signature and (not candidates or candidates[candidate.uid])
        and (not op.filter or op.filter(candidate, center))
    end, state.game)
    if not entry then return nil, "No eligible Tech can be removed" end
    remove_uid(state.entries, entry.uid)
    record_source(state, entry)
    add_change(state, { kind = "remove", uid = entry.uid, key = entry.center_key })
  end
  return true
end

local function apply_copy_selected(state, op)
  local amount = normalize_amount(op.amount)
  if amount == nil then return nil, "Tech copy amount must be finite" end
  state.requested = state.requested + amount
  local candidates = uid_filter(op.candidate_uids)
  if candidates == false then return nil, "Tech candidate UIDs must be a dense positive-integer array" end
  for _ = 1, amount do
    local entry = selected_for_op(state, op.selector or op.which or "lowest", function(candidate, center)
      if center.signature then return false end
      if candidates and not candidates[candidate.uid] then return false end
      if op.filter and not op.filter(candidate, center) then return false end
      return has_copy_room(state, center)
    end, op.rng_stream)
    if not entry then return nil, "No eligible Tech can be copied" end
    record_source(state, entry)
    local duplicate = copied_entry(state, entry, {
      source = op.source or "copied", acquired_ante = state.game.ante,
    })
    if op.enhancement == "fresh_if_empty" and not duplicate.enhancement then
      local keys = require("game.tech_modifiers").ENHANCEMENT_KEYS
      local picked, reason = virtual_random(state.game, state.rng_states, state.rng_bases,
        op.rng_stream or state.rng_stream, #keys)
      if not picked then return nil, reason end
      duplicate.enhancement = keys[picked]
      if duplicate.enhancement == "cutting_edge" then
        local def = require("game.tech_modifiers").ENHANCEMENTS.cutting_edge
        duplicate.modifier_state = {
          cutting_edge_uses_left = def.min_uses,
          cutting_edge_deprecated = false,
        }
      end
    end
    state.entries[#state.entries + 1] = duplicate
    add_change(state, { kind = "copy", uid = duplicate.uid, key = duplicate.center_key,
      source_uid = entry.uid, source = duplicate.source })
  end
  return true
end

local function apply_buff_selected(state, op)
  local amount = normalize_amount(op.amount)
  if amount == nil then return nil, "Tech buff amount must be finite" end
  if not finite(op.users) or op.users <= 0 then return nil, "Tech Users buff must be positive" end
  local candidates = uid_filter(op.candidate_uids)
  if candidates == false then return nil, "Tech candidate UIDs must be a dense positive-integer array" end
  state.requested = state.requested + amount
  for _ = 1, amount do
    local entry = selected_for_op(state, op.selector or "lowest", function(candidate)
      return not candidates or candidates[candidate.uid]
    end, op.rng_stream)
    if not entry then return nil, "No eligible Tech can be upgraded" end
    state.sources[entry.uid] = state.sources[entry.uid] or fingerprint(entry)
    entry.stickers = entry.stickers or {}
    entry.stickers[#entry.stickers + 1] = {
      field="users", mode="add", amount=op.users,
      label=op.label or "Founder investment", source=op.source or "founder_buff",
    }
    if candidates then candidates[entry.uid] = nil end
    add_change(state, { kind="buff", uid=entry.uid, key=entry.center_key, users=op.users })
  end
  return true
end

local function apply_mark(state, op)
  local mark = op.mark
  if type(mark) ~= "string" or mark == "" then return nil, "Tech mark requires a key" end
  local candidates = uid_filter(op.candidate_uids)
  if candidates == false then return nil, "Tech candidate UIDs must be a dense positive-integer array" end
  local entry = selected_for_op(state, op.selector or "lowest", function(candidate)
    return not candidates or candidates[candidate.uid]
  end, op.rng_stream)
  if not entry then return nil, "No eligible Tech can be marked" end
  state.requested = state.requested + 1
  state.sources[entry.uid] = state.sources[entry.uid] or fingerprint(entry)
  entry.config = entry.config or {}
  entry.config._founder_marks = entry.config._founder_marks or {}
  entry.config._founder_marks[mark] = { age=0, source=op.source }
  add_change(state, { kind="mark", uid=entry.uid, key=entry.center_key, mark=mark })
  return true
end

local function apply_mark_update(state, op, clear)
  local mark = op.mark
  if type(mark) ~= "string" or mark == "" then return nil, "Tech mark requires a key" end
  local matched = 0
  for _, entry in ipairs(state.entries) do
    local marks = entry.config and entry.config._founder_marks
    if marks and marks[mark] then
      state.sources[entry.uid] = state.sources[entry.uid] or fingerprint(entry)
      if clear then marks[mark] = nil
      else marks[mark].age = math.max(0, (marks[mark].age or 0) + (op.amount or 1)) end
      matched = matched + 1
      add_change(state, { kind=clear and "clear_mark" or "age_mark", uid=entry.uid,
        key=entry.center_key, mark=mark, age=not clear and marks[mark].age or nil })
    end
  end
  state.requested = state.requested + math.max(1, matched)
  if matched == 0 then return nil, "Marked Tech is unavailable" end
  return true
end

local APPLY = {
  add_random = apply_add_random,
  add_specific = apply_add_specific,
  remove_key = apply_remove_key,
  remove_selected = apply_remove_selected,
  copy_selected = apply_copy_selected,
  buff_selected = apply_buff_selected,
  mark_selected = apply_mark,
  age_mark = function(state, op) return apply_mark_update(state, op, false) end,
  clear_mark = function(state, op) return apply_mark_update(state, op, true) end,
}

local function normalized_ops(request)
  if type(request) ~= "table" then return nil end
  if request.ops ~= nil then return dense_array(request.ops) and request.ops or nil end
  return { request }
end

local function validate_deck(entries)
  if not dense_array(entries) then return nil, "Master deck must be a dense array" end
  local valid, reason = Deck.validate(entries)
  if not valid then return nil, reason end
  for _, entry in ipairs(entries) do
    if not whole(entry.uid, 1) then return nil, "Deck UID must be a positive integer" end
    if not center_for(entry) then return nil, "Deck contains an unknown Tech center" end
  end
  return true
end

local function plan_payload(plan)
  return {
    base_revision = plan.base_revision,
    base_uid = plan.base_uid,
    before_fingerprint = plan.before_fingerprint,
    after_fingerprint = plan.after_fingerprint,
    after_deck = plan.after_deck,
    next_uid = plan.next_uid,
    requested = plan.requested,
    applied = plan.applied,
    changes = plan.changes,
    source_fingerprints = plan.source_fingerprints,
    rng_bases = plan.rng_bases,
    rng_states = plan.rng_states,
  }
end

function Transactions.plan(game, request, opts)
  opts = opts or {}
  game = game or (G and G.GAME)
  if not (game and type(game.master_deck) == "table") then return nil, "Master deck is unavailable" end
  local operations = normalized_ops(request)
  if not operations then return nil, "Deck transaction operations must be a dense array" end
  local valid, reason = validate_deck(game.master_deck)
  if not valid then return nil, reason end
  local before_fingerprint; before_fingerprint, reason = fingerprint(game.master_deck)
  if not before_fingerprint then return nil, reason end

  local highest_uid = math.max(0, math.floor(tonumber(game._deck_uid) or 0))
  for _, entry in ipairs(game.master_deck) do
    if whole(entry.uid, 1) then highest_uid = math.max(highest_uid, entry.uid) end
  end
  local state = {
    game = game,
    entries = copy(game.master_deck),
    next_uid = highest_uid,
    requested = 0,
    applied = 0,
    changes = {},
    sources = {},
    base_uids = {},
    rng_stream = opts.rng_stream or request.rng_stream or "generation",
    rng_states = {},
    rng_bases = {},
    respect_copy_cap = opts.respect_copy_cap == true or request.respect_copy_cap == true,
  }
  for _, entry in ipairs(game.master_deck) do state.base_uids[entry.uid] = true end
  for index, op in ipairs(operations) do
    if type(op) ~= "table" or not APPLY[op.kind] then
      return nil, "Unknown deck transaction operation at index " .. index
    end
    local ok; ok, reason = APPLY[op.kind](state, op)
    if not ok then return nil, reason end
  end
  valid, reason = validate_deck(state.entries)
  if not valid then return nil, reason end
  local after_fingerprint; after_fingerprint, reason = fingerprint(state.entries)
  if not after_fingerprint then return nil, reason end

  local plan = {
    kind = "deck_transaction_plan",
    base_revision = math.max(0, math.floor(tonumber(game._deck_revision) or 0)),
    base_uid = game._deck_uid,
    before_fingerprint = before_fingerprint,
    after_fingerprint = after_fingerprint,
    after_deck = state.entries,
    next_uid = state.next_uid,
    requested = state.requested,
    applied = state.applied,
    changes = state.changes,
    source_fingerprints = state.sources,
    rng_bases = state.rng_bases,
    rng_states = state.rng_states,
  }
  plan.integrity_fingerprint = assert(fingerprint(plan_payload(plan)))
  return plan
end

function Transactions.revalidate(game, plan)
  game = game or (G and G.GAME)
  if not (game and type(plan) == "table" and plan.kind == "deck_transaction_plan") then
    return false, "Invalid deck transaction plan"
  end
  local integrity, integrity_reason = fingerprint(plan_payload(plan))
  if not integrity or integrity ~= plan.integrity_fingerprint then
    return false, integrity_reason or "Deck transaction plan changed"
  end
  if math.max(0, math.floor(tonumber(game._deck_revision) or 0)) ~= plan.base_revision then
    return false, "Deck transaction is stale"
  end
  if game._deck_uid ~= plan.base_uid then return false, "Deck UID allocator changed" end
  local current, reason = fingerprint(game.master_deck)
  if not current then return false, reason end
  if current ~= plan.before_fingerprint then return false, "Deck fingerprint changed" end
  for uid, expected in pairs(plan.source_fingerprints or {}) do
    local entry
    for _, candidate in ipairs(game.master_deck or {}) do if candidate.uid == uid then entry = candidate; break end end
    local actual = entry and fingerprint(entry)
    if actual ~= expected then return false, "Deck source fingerprint changed" end
  end
  for stream, base in pairs(plan.rng_bases or {}) do
    local raw = game.rng_streams and game.rng_streams[stream]
    if (raw ~= nil) ~= base.present or raw ~= base.state then return false, "Deck RNG stream changed" end
  end
  local valid; valid, reason = validate_deck(plan.after_deck)
  if not valid then return false, reason end
  local prospective; prospective, reason = fingerprint(plan.after_deck)
  if prospective ~= plan.after_fingerprint then return false, reason or "Prospective deck fingerprint changed" end
  return true
end

local function sync_live_card(card, entry)
  local center = Centers.get(entry.center_key)
  card.center, card.center_key, card.layer = center, center.key, center.layer
  card.base_users = entry.base_users or center.base_users or 0
  card.source, card.acquired_ante, card.migrated_from = entry.source, entry.acquired_ante, entry.migrated_from
  card.copied_from_uid, card.copied_from_source = entry.copied_from_uid, entry.copied_from_source
  card.edition, card.enhancement, card.enh, card.seal = entry.edition, entry.enhancement or entry.enh, nil, entry.seal
  card.modifier_state = entry.modifier_state and copy(entry.modifier_state) or nil
  card.stickers = entry.stickers and copy(entry.stickers) or nil
  card.layer_override, card.layer_locked = entry.layer_override, entry.layer_locked == true
  card.law_marks = entry.law_marks and copy(entry.law_marks) or nil
  card.ability = { name = center.name, set = center.set, config = copy(center.config or {}) }
  if entry.config and next(entry.config) then card.ability.config = copy(entry.config) end
end

local function make_live_card(entry)
  if not (Card and G and G.deck) then return nil end
  local center = Centers.get(entry.center_key)
  local card = Card({ center = center, face_down = true, uid = entry.uid,
    source = entry.source, acquired_ante = entry.acquired_ante, migrated_from = entry.migrated_from,
    edition = entry.edition, enhancement = entry.enhancement or entry.enh, seal = entry.seal,
    modifier_state = entry.modifier_state, stickers = entry.stickers,
    layer_override = entry.layer_override, layer_locked = entry.layer_locked,
    law_marks = entry.law_marks,
    T = { x = G.deck.T.x, y = G.deck.T.y } })
  sync_live_card(card, entry)
  return card
end

function Transactions.sync_live(game)
  game = game or (G and G.GAME)
  if not (game and G) then return true end
  local wanted, live = {}, {}
  for _, entry in ipairs(game.master_deck or {}) do wanted[entry.uid] = entry end
  local touched = {}
  -- Keep a played/held instance over a duplicate deck view if a malformed live
  -- layout ever contains the same UID twice; the master deck remains singular.
  for _, area in ipairs({ G.play, G.hand, G.deck }) do
    for index = #((area and area.cards) or {}), 1, -1 do
      local card = area.cards[index]
      if card.uid and not wanted[card.uid] then
        if area == G.play then
          -- A scored card may be cut from the persistent deck while scoring is
          -- still iterating G.play.cards. Keep that transient view stable; the
          -- normal cash-out cleanup removes it moments later.
          card._removed_from_master = true
        else
          area:remove_card(card, true)
          if card.remove then card:remove() end
          touched[area] = true
        end
      elseif card.uid and wanted[card.uid] then
        if live[card.uid] then
          area:remove_card(card, true)
          if card.remove then card:remove() end
          touched[area] = true
        else
          sync_live_card(card, wanted[card.uid])
          live[card.uid] = true
        end
      end
    end
  end
  if G.deck then
    for _, entry in ipairs(game.master_deck or {}) do
      if not live[entry.uid] then
        local card = make_live_card(entry)
        if card then G.deck:emplace(card, true); touched[G.deck] = true end
      end
    end
  end
  for area in pairs(touched) do if area.align_cards then area:align_cards() end end
  return true
end

function Transactions.commit(game, plan)
  if plan == nil then plan, game = game, (G and G.GAME) end
  local valid, reason = Transactions.revalidate(game, plan)
  if not valid then return failed(reason, plan and plan.requested) end
  local changed = plan.applied > 0 or next(plan.rng_states or {}) ~= nil
  if changed then
    local before_deck, before_uid, before_revision = game.master_deck, game._deck_uid, game._deck_revision
    local before_rng = copy(game.rng_streams or {})
    game.master_deck = copy(plan.after_deck)
    game._deck_uid = plan.next_uid
    game._deck_revision = plan.base_revision + 1
    if next(plan.rng_states or {}) then
      game.rng_streams = game.rng_streams or {}
      for stream, state in pairs(plan.rng_states) do game.rng_streams[stream] = state end
    end
    local synced, sync_reason = pcall(Transactions.sync_live, game)
    if not synced then
      game.master_deck, game._deck_uid, game._deck_revision = before_deck, before_uid, before_revision
      game.rng_streams = before_rng
      pcall(Transactions.sync_live, game)
      return failed("Deck live-view reconciliation failed: " .. tostring(sync_reason), plan.requested)
    end
  end

  local result = {
    ok = true,
    requested = plan.requested,
    applied = plan.applied,
    changes = copy(plan.changes),
    added_uids = {},
    removed_uids = {},
    revision = math.max(0, math.floor(tonumber(game._deck_revision) or 0)),
    fingerprint = plan.after_fingerprint,
  }
  for _, change in ipairs(result.changes) do
    if change.kind == "add" or change.kind == "copy" then result.added_uids[#result.added_uids + 1] = change.uid end
    if change.kind == "remove" then result.removed_uids[#result.removed_uids + 1] = change.uid end
  end
  return result
end

function Transactions.execute(game, request, opts)
  local plan, reason = Transactions.plan(game, request, opts)
  if not plan then return failed(reason) end
  return Transactions.commit(game, plan)
end

function Transactions.operation_from_generate(kind, opts)
  opts = opts or {}
  if kind == "tech_card" then
    return { kind = "add_random", layer = opts.layer, layers = opts.layers, amount = opts.amount,
      source = opts.source or "generated", rng_stream = opts.rng_stream }
  elseif kind == "specific_tech_card" then
    return { kind = "add_specific", key = opts.key, amount = opts.amount,
      source = opts.source or "generated", signature_injection = opts.signature_injection }
  elseif kind == "remove_tech_card" then
    return { kind = "remove_key", key = opts.key, source = opts.source or "generated",
      signature_injection = opts.signature_injection }
  elseif kind == "remove_card" then
    return { kind = "remove_selected", selector = opts.which or "lowest", amount = opts.amount }
  elseif kind == "copy_card" then
    return { kind = "copy_selected", selector = opts.which or "lowest", amount = opts.amount,
      source = opts.source or "copied" }
  end
  return nil, "Unknown generation kind " .. tostring(kind)
end

function Transactions.generate(kind, opts, game)
  local operation, reason = Transactions.operation_from_generate(kind, opts)
  if not operation then return failed(reason) end
  return Transactions.execute(game or (G and G.GAME), operation, {
    rng_stream = (opts and opts.rng_stream) or "generation",
    respect_copy_cap = opts and opts.respect_copy_cap == true,
  })
end

return Transactions
