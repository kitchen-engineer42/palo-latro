-- Persistent, per-instance modifiers for Tech cards.  Centers remain immutable:
-- every enhancement, seal, and stateful countdown lives on the master-deck
-- entry, its live Card view, or an explicit acquisition offer.

local RNG = require("game.rng")

local TechModifiers = {}

TechModifiers.ENHANCEMENT_CHANCE = 0.20
TechModifiers.SEAL_CHANCE = 0.08

TechModifiers.ENHANCEMENTS = {
  scalable = {
    label = "Scalable", users_add = 30,
    desc = "+30 Users when played.",
  },
  monetizable = {
    label = "Monetizable", rev_add = 2,
    desc = "+2 Rev when played.",
  },
  polyglot = {
    label = "Polyglot", wild_layer = true,
    desc = "Counts as any core Layer.",
  },
  cutting_edge = {
    label = "Cutting-Edge", users_mult = 2, deprecated_users_mult = 0.5,
    min_uses = 2, max_uses = 4,
    desc = "x2 Users until its visible Ship countdown expires; then x0.5 Users.",
  },
  load_bearing = {
    label = "Load-Bearing", held_rev_mult = 1.25, held_cap = 3, max_total_rev_mult = 2,
    desc = "x1.25 Rev while held (up to 3 cards, x2 total cap).",
  },
  cash_cow = {
    label = "Cash-Cow", held_cash = 3, held_cap = 3, max_cash_per_blind = 9,
    desc = "+$3 when held at blind clear (up to $9 per blind).",
  },
  legacy = {
    label = "Legacy", users_override = 60, no_layer = true,
    desc = "Scores a flat 60 Users but has no Layer.",
  },
}

TechModifiers.SEALS = {
  reusable = {
    label = "Reusable", repetitions = 1, max_repetitions = 1,
    desc = "Retriggers this Tech once when played.",
  },
  patent = {
    label = "Patent", playbook_cap_per_blind = 1,
    desc = "Creates the last shipped App Type's Playbook when held at blind clear (max 1).",
  },
  monetized = {
    label = "Monetized", played_cash = 3, max_cash_per_ship = 9,
    desc = "+$3 when this Tech scores (up to $9 per Ship).",
  },
  r_and_d = {
    label = "R&D", law_cap_per_discard = 1,
    desc = "Creates a Tech Law when discarded (max 1 per Pivot; inventory space required).",
  },
}

TechModifiers.ENHANCEMENT_KEYS = {
  "scalable", "monetizable", "polyglot", "cutting_edge",
  "load_bearing", "cash_cow", "legacy",
}
TechModifiers.SEAL_KEYS = { "reusable", "patent", "monetized", "r_and_d" }

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  return out
end

local function modifier_key(subject)
  return subject and (subject.enhancement or subject.enh)
end

local function is_tech(subject)
  return subject and ((subject.center and subject.center.set == "TechCard")
    or (subject.ability and subject.ability.set == "TechCard")) or false
end
TechModifiers.is_tech = is_tech

function TechModifiers.definition(kind, key)
  if kind == "enhancement" or kind == "enh" then return TechModifiers.ENHANCEMENTS[key] end
  if kind == "seal" then return TechModifiers.SEALS[key] end
end

-- Upgrade old in-memory entries to the canonical field without touching their
-- center. Validation remains a separate boundary operation so malformed data
-- is reported rather than silently converted into a different card.
function TechModifiers.normalize(subject)
  if type(subject) ~= "table" then return subject end
  subject.enhancement = modifier_key(subject)
  subject.enh = nil
  return subject
end

function TechModifiers.validate(subject, path)
  path = path or "Tech modifier"
  if type(subject) ~= "table" then return false, path .. " must be a table" end
  if subject.enhancement ~= nil and subject.enh ~= nil and subject.enhancement ~= subject.enh then
    return false, path .. " has conflicting enhancement and legacy enh fields"
  end
  local enhancement = modifier_key(subject)
  if enhancement ~= nil and not TechModifiers.ENHANCEMENTS[enhancement] then
    return false, path .. " has unknown enhancement " .. tostring(enhancement)
  end
  if subject.seal ~= nil and not TechModifiers.SEALS[subject.seal] then
    return false, path .. " has unknown seal " .. tostring(subject.seal)
  end
  local state = subject.modifier_state
  if state ~= nil and type(state) ~= "table" then
    return false, path .. ".modifier_state must be a table"
  end
  if enhancement == "cutting_edge" then
    local def = TechModifiers.ENHANCEMENTS.cutting_edge
    if type(state) ~= "table" then return false, path .. " Cutting-Edge state is missing" end
    local uses = state.cutting_edge_uses_left
    if type(uses) ~= "number" or uses % 1 ~= 0 or uses < 0 or uses > def.max_uses then
      return false, path .. " Cutting-Edge uses must be an integer from 0 to " .. def.max_uses
    end
    if type(state.cutting_edge_deprecated) ~= "boolean" then
      return false, path .. " Cutting-Edge deprecated flag must be boolean"
    end
    for key in pairs(state) do
      if key ~= "cutting_edge_uses_left" and key ~= "cutting_edge_deprecated" then
        return false, path .. " has unknown Cutting-Edge state " .. tostring(key)
      end
    end
  elseif state ~= nil and next(state) ~= nil then
    return false, path .. " has state without a stateful enhancement"
  end
  return true
end

local function roll_key(keys, rng)
  return keys[math.floor(rng() * #keys) + 1]
end

local function state_for(enhancement, rng)
  if enhancement ~= "cutting_edge" then return nil end
  local def = TechModifiers.ENHANCEMENTS.cutting_edge
  return {
    cutting_edge_uses_left = def.min_uses
      + math.floor(rng() * (def.max_uses - def.min_uses + 1)),
    cutting_edge_deprecated = false,
  }
end

-- Acquisition randomness is resolved before the player chooses. The returned
-- offer is plain serializable data except for its read-only center reference.
function TechModifiers.make_offer(center, rng, opts)
  rng, opts = rng or love.math.random, opts or {}
  local offer = { key = center.key, center_key = center.key, center = center }
  if opts.enhancement ~= nil then
    offer.enhancement = opts.enhancement or nil
  elseif rng() < (opts.enhancement_chance or TechModifiers.ENHANCEMENT_CHANCE) then
    offer.enhancement = roll_key(TechModifiers.ENHANCEMENT_KEYS, rng)
  end
  if opts.seal ~= nil then
    offer.seal = opts.seal or nil
  elseif rng() < (opts.seal_chance or TechModifiers.SEAL_CHANCE) then
    offer.seal = roll_key(TechModifiers.SEAL_KEYS, rng)
  end
  offer.modifier_state = opts.modifier_state and copy(opts.modifier_state)
    or state_for(offer.enhancement, rng)
  return TechModifiers.normalize(offer)
end

function TechModifiers.apply_offer(target, offer)
  target, offer = target or {}, offer or {}
  target.enhancement = modifier_key(offer)
  target.enh = nil
  target.seal = offer.seal
  target.modifier_state = offer.modifier_state and copy(offer.modifier_state) or nil
  return TechModifiers.normalize(target)
end

-- Apply enhancement Users after the normal Tech lifecycle has resolved its
-- stickers and Era decay. Cutting-Edge's countdown is pre-rolled and visible;
-- scoring never performs a hidden break roll.
function TechModifiers.users(subject, base)
  local key, value = modifier_key(subject), base or 0
  local def = TechModifiers.ENHANCEMENTS[key]
  if not def then return value end
  if def.users_override then return def.users_override end
  if def.users_add then value = value + def.users_add end
  if def.users_mult then
    local state = subject.modifier_state or {}
    local mult = state.cutting_edge_deprecated and def.deprecated_users_mult or def.users_mult
    value = value * mult
  end
  return math.floor(value + 0.5)
end

-- nil means native Coverage; a returned array replaces it. Polyglot is a wild
-- Layer card, while Legacy deliberately participates in no Layer at all.
function TechModifiers.coverage_options(subject)
  if not is_tech(subject) then return nil end
  local def = TechModifiers.ENHANCEMENTS[modifier_key(subject)]
  if not def then return nil end
  if def.no_layer then return {} end
  if def.wild_layer then return { "Frontend", "Backend", "Data", "Infra", "AI" } end
  return nil
end

function TechModifiers.repetitions(card)
  if not is_tech(card) then return 1 end
  local def = TechModifiers.SEALS[card.seal]
  return 1 + math.min((def and def.repetitions) or 0, (def and def.max_repetitions) or 0)
end

-- Per-trigger effects. `budget` is shared across retriggers/cards for one Ship
-- and makes the Monetized cap explicit rather than relying on caller order.
function TechModifiers.played_effect(card, budget)
  budget = budget or {}
  local out = { chips = 0, mult = 0, dollars = 0, events = {} }
  if not is_tech(card) then return out end
  local enhancement = TechModifiers.ENHANCEMENTS[modifier_key(card)]
  if enhancement and enhancement.rev_add then
    out.mult = enhancement.rev_add
    out.events[#out.events + 1] = { kind = "enhancement", key = modifier_key(card), mult = out.mult }
  end
  local seal = TechModifiers.SEALS[card.seal]
  if seal and seal.played_cash then
    local used = budget.monetized_cash or 0
    out.dollars = math.max(0, math.min(seal.played_cash, seal.max_cash_per_ship - used))
    budget.monetized_cash = used + out.dollars
    if out.dollars > 0 then
      out.events[#out.events + 1] = { kind = "seal", key = card.seal, dollars = out.dollars }
    end
  end
  return out
end

function TechModifiers.held_effect(cards)
  local load_bearing, cash_cow = 0, 0
  for _, card in ipairs(cards or {}) do
    if is_tech(card) then
      local key = modifier_key(card)
      if key == "load_bearing" then load_bearing = load_bearing + 1 end
      if key == "cash_cow" then cash_cow = cash_cow + 1 end
    end
  end
  local load = TechModifiers.ENHANCEMENTS.load_bearing
  load_bearing = math.min(load_bearing, load.held_cap)
  local x_mult = math.min(load.max_total_rev_mult, load.held_rev_mult ^ load_bearing)
  return {
    x_mult = x_mult, dollars = 0,
    load_bearing_count = load_bearing, cash_cow_count = cash_cow,
    events = {},
  }
end

local function master_entry(uid)
  for _, entry in ipairs((G and G.GAME and G.GAME.master_deck) or {}) do
    if entry.uid == uid then return entry end
  end
end

local function sync_state(card)
  local entry = card and card.uid and master_entry(card.uid)
  if not entry then return end
  entry.enhancement = modifier_key(card)
  entry.enh = nil
  entry.seal = card.seal
  entry.modifier_state = card.modifier_state and copy(card.modifier_state) or nil
end

-- Tick stateful enhancements once per played card, after their current Ship has
-- received its payoff. A card with one use left scores at full power, then its
-- persistent entry visibly becomes Deprecated for future Ships.
function TechModifiers.on_played(cards)
  local result = { updated = 0, deprecations = {}, events = {} }
  for _, card in ipairs(cards or {}) do
    if is_tech(card) and modifier_key(card) == "cutting_edge" then
      card.modifier_state = card.modifier_state or {}
      local state = card.modifier_state
      if not state.cutting_edge_deprecated then
        state.cutting_edge_uses_left = math.max(0, (state.cutting_edge_uses_left or 0) - 1)
        result.updated = result.updated + 1
        if state.cutting_edge_uses_left <= 0 then
          state.cutting_edge_deprecated = true
          result.deprecations[#result.deprecations + 1] = card.uid
          result.events[#result.events + 1] = { kind = "enhancement_deprecated", key = "cutting_edge", uid = card.uid }
        end
        sync_state(card)
      end
    end
  end
  return result
end

local function tech_law_pool()
  return require("game.tech_laws").pool()
end

function TechModifiers.on_discard(cards, opts)
  opts = opts or {}
  local game = opts.game or (G and G.GAME)
  local scope = opts.scope or (game and table.concat({
    tostring(game.ante or 0), tostring(game.blind_idx or 0), tostring(game.pivot_count or 0),
  }, ":"))
  local result = { created = {}, events = {}, scope = scope, duplicate = false }
  if game and scope and game._tech_modifier_last_discard_scope == scope then
    result.duplicate = true
    return result
  end
  if game and scope then game._tech_modifier_last_discard_scope = scope end
  local cap = TechModifiers.SEALS.r_and_d.law_cap_per_discard
  local pool = opts.pool or tech_law_pool()
  local rng = opts.rng or RNG.fn("tech_modifier_rd")
  local grant = opts.grant or function(key)
    return require("game.consumables").grant(key, { source = "r_and_d", sell_basis = 0 })
  end
  for _, card in ipairs(cards or {}) do
    if #result.created >= cap then break end
    if is_tech(card) and card.seal == "r_and_d" and #pool > 0 then
      local center = opts.pool and pool[math.floor(rng() * #pool) + 1]
        or require("game.tech_laws").roll(rng)
      if grant(center.key) then
        result.created[#result.created + 1] = center.key
        result.events[#result.events + 1] = { kind = "tech_law_created", key = center.key, uid = card.uid }
      end
    end
  end
  return result
end

function TechModifiers.on_blind_won(held, opts)
  opts = opts or {}
  local game = opts.game or (G and G.GAME)
  local scope = opts.scope or (game and table.concat({
    tostring(game.ante or 0), tostring(game.blind_idx or 0),
  }, ":"))
  local result = { playbooks = {}, cash = 0, events = {}, scope = scope, duplicate = false }
  if game and scope and game._tech_modifier_last_blind_scope == scope then
    result.duplicate = true
    return result
  end
  if game and scope then game._tech_modifier_last_blind_scope = scope end
  local cap = TechModifiers.SEALS.patent.playbook_cap_per_blind
  local app_key = opts.app_key or (game and game.this_app and game.this_app.key)
  local upgrade = opts.upgrade or function(key) return require("game.playbooks").upgrade(key, 1) end
  for _, card in ipairs(held or {}) do
    if #result.playbooks >= cap then break end
    if is_tech(card) and app_key and card.seal == "patent" and upgrade(app_key) then
      result.playbooks[#result.playbooks + 1] = app_key
      result.events[#result.events + 1] = { kind = "playbook_created", key = app_key, uid = card.uid }
    end
  end
  local cash_def, cash_count = TechModifiers.ENHANCEMENTS.cash_cow, 0
  for _, card in ipairs(held or {}) do
    if is_tech(card) and modifier_key(card) == "cash_cow" then cash_count = cash_count + 1 end
  end
  cash_count = math.min(cash_count, cash_def.held_cap)
  result.cash = math.min(cash_def.max_cash_per_blind, cash_count * cash_def.held_cash)
  if result.cash > 0 then
    local grant_cash = opts.grant_cash or function(amount)
      if game then game.cash = (game.cash or 0) + amount; return true end
      return false
    end
    if grant_cash(result.cash) == false then result.cash = 0 end
    if result.cash > 0 then
      result.events[#result.events + 1] = { kind = "cash_cow_paid", dollars = result.cash, count = cash_count }
    end
  end
  return result
end

local function view(kind, key, state)
  local def = TechModifiers.definition(kind, key)
  if not def then return nil end
  return { kind = kind, key = key, label = def.label, desc = def.desc, state = state and copy(state) or nil }
end

function TechModifiers.describe(subject)
  subject = subject or {}
  return {
    enhancement = view("enhancement", modifier_key(subject), subject.modifier_state),
    seal = view("seal", subject.seal),
  }
end

function TechModifiers.offer_view(option)
  option = option or {}
  local described = TechModifiers.describe(option)
  return {
    key = option.key or option.center_key or (option.center and option.center.key),
    center = option.center,
    enhancement = described.enhancement,
    seal = described.seal,
    modifier_state = option.modifier_state and copy(option.modifier_state) or nil,
  }
end

return TechModifiers
