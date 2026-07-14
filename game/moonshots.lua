-- Deterministic runtime for Moonshot consumables.  Centers are immutable and
-- random outcomes live exclusively in an instance payload created by
-- `materialize`; can-use/preflight/apply never advance gameplay RNG streams.

local Centers = require("game.centers")
local RNG = require("game.rng")
local Deck = require("game.deck")
local Eras = require("game.eras")
local Coverage = require("game.coverage")
local TechModifiers = require("game.tech_modifiers")
local TechLifecycle = require("game.tech_lifecycle")

local Moonshots = {}
local SPECIAL = { ms_acquihire = true, ms_disruption = true }
local PAYLOAD_FIELD = {
  ms_market_pivot = "market_id",
  ms_stack_rewrite = "tech_keys",
  ms_cambrian_explosion = "tech_offers",
  ms_patent_blitz = "seal",
  ms_open_core = "enhancement",
  ms_talent_raid = "founder_key",
  ms_acquihire = "founder_key",
}

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

local function game_of(game) return game or (G and G.GAME) end

local function center_of(value)
  if type(value) == "string" then return Centers.get(value) end
  if type(value) ~= "table" then return nil end
  if value.center and value.center.kind == "Moonshot" then return value.center end
  local key = value.key or value.center_key
  return key and Centers.get(key) or (value.kind == "Moonshot" and value or nil)
end

local function payload_of(value, opts, game)
  opts = opts or {}
  if opts.payload ~= nil then return opts.payload end
  if type(value) ~= "table" then return nil end
  local payload = value.moonshot_payload or value.payload
    or (value.ability and value.ability.config and value.ability.config._moonshot_payload)
  if payload ~= nil then return payload end
  local id = value.consumable_instance_id
    or (value.ability and value.ability.config and value.ability.config._consumable_id)
  if id then
    for _, entry in ipairs((game and game.consumables) or {}) do
      if entry.instance_id == id then return entry.moonshot_payload or entry.payload end
    end
  end
  return nil
end

local function excluded(opts, key)
  local set = opts and opts.exclude
  if type(set) ~= "table" then return false end
  if set[key] then return true end
  for _, value in ipairs(set) do
    if value == key or (type(value) == "table" and (value.key == key or value.center_key == key)) then return true end
  end
  return false
end

local function random_index(rng, n)
  local value = rng(n)
  if type(value) == "number" and value >= 0 and value < 1 then
    return math.floor(value * n) + 1
  end
  return math.max(1, math.min(n, math.floor(tonumber(value) or 1)))
end

function Moonshots.handles(center_or_key)
  local center = center_of(center_or_key)
  return center ~= nil and center.set == "Consumable" and center.kind == "Moonshot"
end

function Moonshots.pool(opts)
  opts = opts or {}
  local out = {}
  for _, center in ipairs(Centers.pool("Consumable")) do
    if center.kind == "Moonshot"
        and (opts.special == nil or (center.special == true) == opts.special)
        and not excluded(opts, center.key) then
      out[#out + 1] = center
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- Each pack option first makes one chase draw with two disjoint 0.3% windows,
-- then samples the equal-weight ordinary pool. Excluding a chase result falls
-- through rather than transferring its probability to another card.
function Moonshots.roll(rng, opts)
  opts = opts or {}
  rng = rng or RNG.fn("moonshot_pack")
  if opts.allow_special ~= false then
    local special_rng = opts.special_rng or RNG.fn("moonshot_special")
    local x = special_rng()
    if x < 0.003 and not excluded(opts, "ms_acquihire") then return Centers.get("ms_acquihire") end
    if x >= 0.003 and x < 0.006 and not excluded(opts, "ms_disruption") then return Centers.get("ms_disruption") end
  end
  local pool = Moonshots.pool({ special = false, exclude = opts.exclude })
  if #pool == 0 then return nil end
  return pool[random_index(rng, #pool)]
end

local function known_market(id)
  return id and require("game.markets").by_id(id) or nil
end

local function known_founder(key, rarity)
  local center = key and Centers.get(key)
  if not (center and center.set == "Founder" and center.rarity == rarity and not center.signature) then return nil end
  return center
end

local function founder_available(center, game)
  if not center or center.unlocked == false then return false, "That Founder is currently locked" end
  local gate, ante = center.era_gate, (game and game.ante) or 1
  if gate and (ante < (gate.min or 1) or ante > (gate.max or math.huge)) then
    return false, "That Founder is stale for this Era"
  end
  return true
end

local function dense_exact(value, n)
  if type(value) ~= "table" or #value ~= n then return false end
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > n then return false end
  end
  return true
end

local function allowed_payload_fields(payload, allowed)
  for key in pairs(payload or {}) do if not allowed[key] then return false, "Unknown Moonshot payload field " .. tostring(key) end end
  return true
end

-- Return a validated copy of a payload. `value` may be a complete instance or
-- the payload itself when `center_or_key` is supplied explicitly.
function Moonshots.normalize(value, game, center_or_key)
  game = game_of(game)
  local center = center_of(center_or_key) or center_of(value)
  if not Moonshots.handles(center) then return nil, "Unknown Moonshot" end
  local payload
  if center_of(value) then payload = payload_of(value, {}, game) else payload = value end
  payload = payload == nil and {} or payload
  if type(payload) ~= "table" then return nil, "Moonshot payload must be a table" end
  local field = PAYLOAD_FIELD[center.key]
  if not field then
    local ok, reason = allowed_payload_fields(payload, {})
    return ok and {} or nil, reason
  end
  local ok, reason = allowed_payload_fields(payload, { [field] = true })
  if not ok then return nil, reason end
  if field == "market_id" then
    if type(payload.market_id) ~= "string" or not known_market(payload.market_id) then
      return nil, "Moonshot payload has an unknown Market"
    end
    return { market_id = payload.market_id }
  elseif field == "tech_keys" then
    if not dense_exact(payload.tech_keys, 3) then return nil, "Moonshot payload requires exactly 3 Tech keys" end
    local out, seen = {}, {}
    for _, key in ipairs(payload.tech_keys) do
      local tech = type(key) == "string" and Centers.get(key)
      if not (tech and tech.set == "TechCard" and not tech.signature) then return nil, "Moonshot payload has an invalid Tech key" end
      if seen[key] then return nil, "Moonshot payload Tech keys must be distinct" end
      seen[key], out[#out + 1] = true, key
    end
    return { tech_keys = out }
  elseif field == "tech_offers" then
    if not dense_exact(payload.tech_offers, 3) then return nil, "Moonshot payload requires exactly 3 Tech offers" end
    local out, seen = {}, {}
    for i, offer in ipairs(payload.tech_offers) do
      if type(offer) ~= "table" then return nil, "Moonshot Tech offer " .. i .. " must be a table" end
      local key = offer.key or offer.center_key
      local tech = type(key) == "string" and Centers.get(key)
      if not (tech and tech.set == "TechCard" and not tech.signature) then return nil, "Moonshot payload has an invalid Tech offer" end
      if seen[key] then return nil, "Moonshot payload Tech offers must be distinct" end
      local clean = { key = key, center_key = key, enhancement = offer.enhancement or offer.enh,
        seal = offer.seal, modifier_state = offer.modifier_state and copy(offer.modifier_state) or nil }
      local valid, why = TechModifiers.validate(clean, "Moonshot payload.tech_offers[" .. i .. "]")
      if not valid then return nil, why end
      TechModifiers.normalize(clean)
      seen[key], out[#out + 1] = true, clean
    end
    return { tech_offers = out }
  elseif field == "seal" then
    if not TechModifiers.SEALS[payload.seal] then return nil, "Moonshot payload has an unknown Seal" end
    return { seal = payload.seal }
  elseif field == "enhancement" then
    if not TechModifiers.ENHANCEMENTS[payload.enhancement] then return nil, "Moonshot payload has an unknown Enhancement" end
    return { enhancement = payload.enhancement }
  elseif field == "founder_key" then
    local rarity = center.key == "ms_acquihire" and "Legendary" or "Rare"
    if not known_founder(payload.founder_key, rarity) then return nil, "Moonshot payload has an invalid " .. rarity .. " Founder" end
    return { founder_key = payload.founder_key }
  end
  return nil, "Unsupported Moonshot payload"
end

local function modifier_projection(kind, key)
  local definition = TechModifiers.definition(kind, key)
  return key and {
    key = key,
    name = (definition and definition.label) or key,
  } or nil
end

local function tech_projection(key, offer)
  local center = Centers.get(key)
  local row = {
    key = key,
    name = (center and center.name) or key,
  }
  if offer then
    row.enhancement = modifier_projection("enhancement", offer.enhancement or offer.enh)
    row.seal = modifier_projection("seal", offer.seal)
    row.modifier_state = offer.modifier_state and copy(offer.modifier_state) or nil
  end
  return row
end

local function tech_text(row)
  local modifiers = {}
  if row.enhancement then modifiers[#modifiers + 1] = row.enhancement.name end
  if row.seal then modifiers[#modifiers + 1] = row.seal.name .. " Seal" end
  local state = row.modifier_state
  if state and state.cutting_edge_uses_left ~= nil then
    modifiers[#modifiers + 1] = tostring(state.cutting_edge_uses_left) .. " Ships"
  end
  local suffix = #modifiers > 0 and (" (" .. table.concat(modifiers, ", ") .. ")") or ""
  return row.name .. " [" .. row.key .. "]" .. suffix
end

-- Stable, serializable projection of every pre-rolled outcome. Consumers use
-- this instead of interpreting payload internals, keeping pack, held-card, and
-- Mimic previews exact as content labels evolve.
function Moonshots.payload_preview(center_or_instance, payload, game)
  local center = center_of(center_or_instance)
  game = game_of(game)
  if not Moonshots.handles(center) then return nil, "Unknown Moonshot" end
  local source = payload
  if source == nil then source = center_or_instance end
  local normalized, reason = Moonshots.normalize(source, game, center)
  if not normalized then return nil, reason end

  local out = { key = center.key, kind = "none", text = "No pre-rolled outcome" }
  if normalized.market_id then
    local market = known_market(normalized.market_id)
    out.kind, out.market = "market", {
      id = normalized.market_id,
      name = market and market.name or normalized.market_id,
    }
    out.text = "Market: " .. out.market.name .. " [" .. out.market.id .. "]"
  elseif normalized.founder_key then
    local founder = Centers.get(normalized.founder_key)
    out.kind, out.founder = "founder", {
      key = normalized.founder_key,
      name = founder and founder.name or normalized.founder_key,
      rarity = founder and founder.rarity or nil,
    }
    out.text = "Founder: " .. out.founder.name .. " [" .. out.founder.key .. "]"
  elseif normalized.tech_keys then
    out.kind, out.techs = "techs", {}
    local labels = {}
    for _, tech_key in ipairs(normalized.tech_keys) do
      local row = tech_projection(tech_key)
      out.techs[#out.techs + 1], labels[#labels + 1] = row, tech_text(row)
    end
    out.text = "Tech: " .. table.concat(labels, "; ")
  elseif normalized.tech_offers then
    out.kind, out.techs = "tech_offers", {}
    local labels = {}
    for _, offer in ipairs(normalized.tech_offers) do
      local row = tech_projection(offer.key or offer.center_key, offer)
      out.techs[#out.techs + 1], labels[#labels + 1] = row, tech_text(row)
    end
    out.text = "Tech offers: " .. table.concat(labels, "; ")
  elseif normalized.seal then
    out.kind, out.seal = "seal", modifier_projection("seal", normalized.seal)
    out.text = "Seal: " .. out.seal.name .. " [" .. out.seal.key .. "]"
  elseif normalized.enhancement then
    out.kind, out.enhancement = "enhancement",
      modifier_projection("enhancement", normalized.enhancement)
    out.text = "Enhancement: " .. out.enhancement.name .. " [" .. out.enhancement.key .. "]"
  end
  return out
end

function Moonshots.payload_summary(center_or_instance, payload, game)
  local projection, reason = Moonshots.payload_preview(center_or_instance, payload, game)
  if not projection then return nil, reason end
  return projection.text, nil, projection
end

local function owned_founder_keys()
  local out = {}
  for _, card in ipairs((G and G.jokers and G.jokers.cards) or {}) do out[card.center_key] = true end
  return out
end

local function founder_candidates(rarity, game)
  local owned, out = owned_founder_keys(), {}
  for _, center in ipairs(Centers.pool("Founder")) do
    if center.rarity == rarity and not center.signature and not owned[center.key]
        and founder_available(center, game) then out[#out + 1] = center end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

local function market_candidates(game)
  local Markets, out = require("game.markets"), {}
  local count = #((G and G.jokers and G.jokers.cards) or {})
  for _, market in ipairs(Markets.list or {}) do
    if (not game.market or market.id ~= game.market.id)
        and (not game.pending_market or market.id ~= game.pending_market.id)
        and Markets.can_queue(game, market, count) then out[#out + 1] = market end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function Moonshots.materialize(center_or_key, opts)
  opts = opts or {}
  local center, game = center_of(center_or_key), game_of(opts.game)
  if not (Moonshots.handles(center) and game) then return nil, "Unknown Moonshot or run" end
  local rng = opts.rng or RNG.fn("moonshot_payload")
  local payload = {}
  if center.key == "ms_market_pivot" then
    local candidates = market_candidates(game)
    if #candidates == 0 then return nil, "No admissible alternate Market" end
    payload.market_id = candidates[random_index(rng, #candidates)].id
  elseif center.key == "ms_stack_rewrite" or center.key == "ms_cambrian_explosion" then
    local candidates = Deck.draft_candidates(Centers.pool("TechCard"), game.market, game.era,
      game.master_deck or {}, 3, rng)
    if #candidates ~= 3 then return nil, "Not enough eligible Tech outcomes" end
    if center.key == "ms_stack_rewrite" then
      payload.tech_keys = {}; for _, tech in ipairs(candidates) do payload.tech_keys[#payload.tech_keys + 1] = tech.key end
    else
      payload.tech_offers = {}
      for _, tech in ipairs(candidates) do
        local offer = TechModifiers.make_offer(tech, rng); offer.center = nil
        payload.tech_offers[#payload.tech_offers + 1] = offer
      end
    end
  elseif center.key == "ms_patent_blitz" then
    payload.seal = TechModifiers.SEAL_KEYS[random_index(rng, #TechModifiers.SEAL_KEYS)]
  elseif center.key == "ms_open_core" then
    payload.enhancement = TechModifiers.ENHANCEMENT_KEYS[random_index(rng, #TechModifiers.ENHANCEMENT_KEYS)]
  elseif center.key == "ms_talent_raid" or center.key == "ms_acquihire" then
    local rarity = center.key == "ms_acquihire" and "Legendary" or "Rare"
    local candidates = founder_candidates(rarity, game)
    if #candidates == 0 then return nil, "No eligible " .. rarity .. " Founder" end
    payload.founder_key = candidates[random_index(rng, #candidates)].key
  end
  local normalized, reason = Moonshots.normalize(payload, game, center)
  if not normalized then return nil, reason end
  return { key = center.key, payload = normalized }
end

local function entry_by_uid(game, uid)
  for _, entry in ipairs((game and game.master_deck) or {}) do if entry.uid == uid then return entry end end
end

local function tech_target(target, game)
  if type(target) ~= "table" then return nil end
  local entry = target.uid and entry_by_uid(game, target.uid)
  local center = entry and Centers.get(entry.center_key)
  if not (entry and center and center.set == "TechCard") then return nil end
  return entry, center
end

local function founder_target(target)
  if type(target) ~= "table" then return nil end
  for _, card in ipairs((G and G.jokers and G.jokers.cards) or {}) do
    if card == target or (target.ID and card.ID == target.ID) then return card, card.center end
  end
end

local function tech_subject(entry, center)
  local out = copy(entry); out.center, out.layer = center, center.layer
  return out
end

local function effective_users(entry, game)
  local center = Centers.get(entry.center_key)
  if not center then return -math.huge end
  return require("game.card").tech_users(entry, center, game.era, game)
end

local function ordered_entries(game, predicate)
  local out = {}
  for _, entry in ipairs(game.master_deck or {}) do
    local center = Centers.get(entry.center_key)
    if center and center.set == "TechCard" and (not predicate or predicate(entry, center)) then out[#out + 1] = entry end
  end
  table.sort(out, function(a, b)
    local av, bv = effective_users(a, game), effective_users(b, game)
    if av ~= bv then return av < bv end
    local ac, bc = Centers.get(a.center_key), Centers.get(b.center_key)
    local abase = a.base_users
    if abase == nil then abase = (ac and ac.base_users) or 0 end
    local bbase = b.base_users
    if bbase == nil then bbase = (bc and bc.base_users) or 0 end
    if abase ~= bbase then return abase < bbase end
    if (a.uid or math.huge) ~= (b.uid or math.huge) then return (a.uid or math.huge) < (b.uid or math.huge) end
    return tostring(a.center_key) < tostring(b.center_key)
  end)
  return out
end

function Moonshots.can_target(center_or_instance, target, game, opts)
  local center = center_of(center_or_instance); game = game_of(game)
  if not (Moonshots.handles(center) and center.target and game) then return false, "This Moonshot does not take a target" end
  if center.target.area == "hand" then
    local entry, tech = tech_target(target, game)
    if not entry then return false, "Choose an owned Tech card" end
    if center.key == "ms_platform_shift" then
      if entry.layer_locked then return false, "This Tech's Layer is locked" end
      local layers = Coverage.card_options(tech_subject(entry, tech))
      if #layers ~= 1 then return false, "Choose an unlocked single-Layer Tech" end
    elseif (center.key == "ms_hard_fork" or center.key == "ms_cambrian_explosion") and tech.signature then
      return false, "Signature Tech cannot be used for this Moonshot"
    elseif center.key == "ms_hard_fork" then
      local allowed, reason = Deck.candidate_allowed(tech, game.market)
      if not allowed then return false, reason end
      if not Eras.available(tech, game.era) then return false, "That Tech is stale for this Era" end
    end
    return true
  elseif center.target.area == "founders" then
    local card = founder_target(target)
    if not card then return false, "Choose an owned Founder" end
    if center.key == "ms_hypergrowth_mandate" and card.edition == "viral" then return false, "That Founder is already Viral" end
    if center.key == "ms_spinout" then
      local cfg = card.ability and card.ability.config or {}
      local base = card.center and card.center.base_form and Centers.get(card.center.base_form)
      if (card.center and card.center.signature) or cfg._signature_key or (base and base.signature) then
        return false, "A signature-paired Founder cannot be copied by Spinout"
      end
    end
    return true
  end
  return false, "Unsupported Moonshot target area"
end

local function funding_unit(game)
  local RunState = require("game.runstate")
  return require("game.economy").unit(game, RunState.ANTE_BASE)
end

local function debt_value(game)
  local meter = game and game.meters and game.meters.tech_debt
  return meter and tonumber(meter.value) or 0
end

local function founder_cap(game)
  local cap = game.founder_slots or 5
  if game.pending_market then
    cap = math.min(cap, require("game.markets").destination_founder_cap(game, game.pending_market) or cap)
  end
  return cap
end

local function preview(center, fields)
  local out = { key = center.key, name = center.name, upside = {}, downside = {} }
  for key, value in pairs(fields or {}) do out[key] = copy(value) end
  return out
end

local function validate_tech_outcomes(game, removed_uids, additions)
  local removed, counts = {}, {}
  for _, uid in ipairs(removed_uids or {}) do removed[uid] = true end
  for _, entry in ipairs(game.master_deck or {}) do
    if not removed[entry.uid] then
      counts[entry.center_key] = (counts[entry.center_key] or 0) + 1
    end
  end
  for _, value in ipairs(additions or {}) do
    local key = type(value) == "table" and (value.key or value.center_key) or value
    local center = type(key) == "string" and Centers.get(key)
    if not (center and center.set == "TechCard" and not center.signature) then
      return false, "A Moonshot Tech outcome is no longer valid"
    end
    local allowed, reason = Deck.candidate_allowed(center, game.market)
    if not allowed then return false, reason end
    if not Eras.available(center, game.era) then
      return false, "A Moonshot Tech outcome is stale for this Era"
    end
    counts[key] = (counts[key] or 0) + 1
    local cap = Deck.copy_cap(center, game.market)
    if counts[key] > cap then
      return false, center.name .. " would exceed its copy cap of " .. cap
    end
  end
  return true
end

function Moonshots.preflight(center_or_instance, targets, opts)
  opts = opts or {}
  local center, game = center_of(center_or_instance), game_of(opts.game)
  if not (Moonshots.handles(center) and game and type(game.master_deck) == "table") then return nil, "Invalid Moonshot or run" end
  local payload, reason = Moonshots.normalize(opts.payload or payload_of(center_or_instance, opts, game), game, center)
  if not payload then return nil, reason end
  targets = targets or {}
  local needed = center.target and (center.target.n or 1) or 0
  if #targets ~= needed then return nil, needed == 0 and "This Moonshot takes no targets" or ("Select exactly " .. needed .. " target(s)") end
  local seen = {}
  for _, target in ipairs(targets) do
    local ok; ok, reason = Moonshots.can_target(center, target, game, opts)
    if not ok then return nil, reason end
    local id = target.uid or target.ID or target
    if seen[id] then return nil, "Choose distinct targets" end
    seen[id] = true
  end
  local plan = { center = center, key = center.key, game = game, payload = payload,
    target_uids = {}, founder_targets = {}, preview = nil }
  for _, target in ipairs(targets) do
    if center.target.area == "hand" then plan.target_uids[#plan.target_uids + 1] = target.uid
    else
      local card = founder_target(target)
      plan.founder_targets[#plan.founder_targets + 1] = card
    end
  end
  local state = game.moonshot_state or {}
  local unit, key = funding_unit(game), center.key
  if key == "ms_viral_moment" then
    if (state.viral_moment_uses or 0) >= 2 then return nil, "Viral Moment has reached its run cap" end
    if (game.cash or 0) <= 0 then return nil, "Viral Moment requires positive Cash" end
    if #game.master_deck == 0 then return nil, "No Tech can go viral" end
    plan.preview = preview(center, { users_each = 15, cards = #game.master_deck, cash_loss = game.cash })
  elseif key == "ms_blitzscale" then
    if (state.blitzscale_uses or 0) >= 2 then return nil, "Blitzscale has reached its run cap" end
    plan.preview = preview(center, { cash_gain = 6 * unit, margin_delta = -0.10 })
  elseif key == "ms_debt_equity_swap" then
    local equity_room = math.max(0, math.floor(((game.equity_pct or 0) - 1) / 2))
    local cleared = math.min(10, math.floor(debt_value(game)), equity_room)
    if debt_value(game) < 1 then return nil, "No Tech Debt to convert" end
    if cleared <= 0 then return nil, "Not enough equity for this swap" end
    local cost = cleared * 2
    plan.debt_clear, plan.equity_cost = cleared, cost
    plan.preview = preview(center, { debt_clear = cleared, equity_loss = cost })
  elseif key == "ms_market_pivot" then
    local market = known_market(payload.market_id)
    if game.market and market.id == game.market.id then return nil, "That Market is already active" end
    if game.pending_market and market.id == game.pending_market.id then
      return nil, "That Market is already queued"
    end
    if (game.equity_pct or 0) - 8 < 1 then return nil, "Not enough equity for this Pivot" end
    local count = #((G and G.jokers and G.jokers.cards) or {})
    local ok; ok, reason = require("game.markets").can_queue(game, market, count)
    if not ok then return nil, reason end
    plan.market, plan.market_founder_count, plan.equity_cost = market, count, 8
    plan.preview = preview(center, { market = require("game.markets").view(market), equity_loss = 8 })
  elseif key == "ms_platform_shift" then
    local anchor, anchor_center = tech_target(targets[1], game)
    local layer = Coverage.card_options(tech_subject(anchor, anchor_center))[1]
    local candidates = ordered_entries(game, function(entry, tech)
      if entry.uid == anchor.uid or entry.layer_locked then return false end
      local layers = Coverage.card_options(tech_subject(entry, tech))
      return not (#layers == 1 and layers[1] == layer)
    end)
    if #candidates < 4 then return nil, "Platform Shift needs 4 other changeable Tech" end
    plan.layer, plan.affected_uids = layer, {}
    for i = 1, 4 do plan.affected_uids[i] = candidates[i].uid end
    plan.preview = preview(center, { layer = layer, changed = 4, debt_add = 4 })
  elseif key == "ms_stack_rewrite" then
    local valid; valid, reason = validate_tech_outcomes(game, plan.target_uids, payload.tech_keys)
    if not valid then return nil, reason end
    plan.replacements = copy(payload.tech_keys)
    plan.preview = preview(center, { replacements = plan.replacements, cleared_investments = 3 })
  elseif key == "ms_hard_fork" then
    if (game.hand_size or 8) <= 5 then return nil, "Hand size is already at the Moonshot floor" end
    local entry, tech = tech_target(targets[1], game)
    local allowed; allowed, reason = Deck.candidate_allowed(tech, game.market)
    if not allowed then return nil, reason end
    if not Eras.available(tech, game.era) then return nil, "That Tech is stale for this Era" end
    plan.clone_key = entry.center_key
    plan.preview = preview(center, { clones = 2, tech_key = entry.center_key, hand_size_loss = 1 })
  elseif key == "ms_cambrian_explosion" then
    local valid; valid, reason = validate_tech_outcomes(game, plan.target_uids, payload.tech_offers)
    if not valid then return nil, reason end
    plan.offers = copy(payload.tech_offers)
    plan.preview = preview(center, { destroy_uid = targets[1].uid, offers = plan.offers, debt_add = 3 })
  elseif key == "ms_fire_sale" then
    if #game.master_deck < 12 then return nil, "Fire Sale requires at least 12 Tech" end
    local ordered = ordered_entries(game, function(_, tech) return not tech.signature end)
    if #ordered < 3 then return nil, "Fire Sale needs 3 non-signature Tech" end
    plan.affected_uids = { ordered[1].uid, ordered[2].uid, ordered[3].uid }
    plan.preview = preview(center, { destroy_uids = plan.affected_uids, cash_gain = 5 * unit })
  elseif key == "ms_patent_blitz" then
    local cost = 2 * unit
    if (game.cash or 0) < cost then return nil, "Patent Blitz requires " .. cost .. " Cash" end
    local eligible = ordered_entries(game, function(entry) return entry.seal == nil end)
    if #eligible == 0 then return nil, "No seal-less Tech" end
    plan.affected_uids = {}; for i = 1, math.min(3, #eligible) do plan.affected_uids[i] = eligible[i].uid end
    plan.cash_cost = cost
    plan.preview = preview(center, { seal = payload.seal, changed = #plan.affected_uids, cash_loss = cost })
  elseif key == "ms_open_core" then
    local eligible = ordered_entries(game, function(entry) return (entry.enhancement or entry.enh) == nil end)
    if #eligible == 0 then return nil, "No unenhanced Tech" end
    plan.affected_uids = {}; for i = 1, math.min(3, #eligible) do plan.affected_uids[i] = eligible[i].uid end
    plan.preview = preview(center, { enhancement = payload.enhancement, changed = #plan.affected_uids, debt_add = #plan.affected_uids })
  elseif key == "ms_talent_raid" then
    if not (G and G.jokers and Card) then return nil, "Founder area is unavailable" end
    if (game.cash or 0) <= 0 then return nil, "Talent Raid requires positive Cash" end
    if #G.jokers.cards >= founder_cap(game) then return nil, "No Founder room" end
    if owned_founder_keys()[payload.founder_key] then return nil, "That Founder is already owned" end
    plan.founder = known_founder(payload.founder_key, "Rare")
    local available; available, reason = founder_available(plan.founder, game)
    if not available then return nil, reason end
    plan.preview = preview(center, { founder_key = payload.founder_key, cash_loss = game.cash })
  elseif key == "ms_spinout" then
    if not (G and G.jokers and Card) or #G.jokers.cards < 2 then return nil, "Spinout requires at least 2 Founders" end
    if founder_cap(game) < 2 then return nil, "This run cannot hold the two Spinout Founders" end
    plan.founder = plan.founder_targets[1]
    local base_key = (plan.founder.center and plan.founder.center.base_form) or plan.founder.center_key
    local base = Centers.get(base_key)
    if not (base and base.set == "Founder") then return nil, "Spinout base Founder is unavailable" end
    plan.spinout_center = base
    plan.preview = preview(center, { founder_key = plan.founder.center_key,
      copy_key = base.key, removed = #G.jokers.cards - 1, fresh_copy = true })
  elseif key == "ms_hypergrowth_mandate" then
    plan.founder = plan.founder_targets[1]
    plan.preview = preview(center, { founder_key = plan.founder.center_key, edition = "viral", salary_mult = 1.5 })
  elseif key == "ms_acquihire" then
    if not (G and G.jokers and Card) then return nil, "Founder area is unavailable" end
    local new_cap = (game.founder_slots or 5) - 1
    local new_effective_cap = founder_cap(game) - 1
    if new_cap < 1 or new_effective_cap < 1 or #G.jokers.cards + 1 > new_effective_cap then
      return nil, "Acquihire requires two effective open Founder slots"
    end
    if owned_founder_keys()[payload.founder_key] then return nil, "That Founder is already owned" end
    plan.founder = known_founder(payload.founder_key, "Legendary")
    local available; available, reason = founder_available(plan.founder, game)
    if not available then return nil, reason end
    plan.preview = preview(center, { founder_key = payload.founder_key, founder_slot_loss = 1 })
  elseif key == "ms_disruption" then
    local changed = 0
    for _, app in ipairs(require("game.apptypes").list) do if ((game.app_levels or {})[app.key] or 1) < 15 then changed = changed + 1 end end
    if changed == 0 then return nil, "All App Types are already at level 15" end
    plan.preview = preview(center, { app_levels = changed, amount = 1, debt_add = 5 })
  else return nil, "Unsupported Moonshot " .. tostring(key) end
  return plan
end

function Moonshots.can_use(center_or_instance, game, targets, opts)
  opts = opts or {}; opts.game = game_of(game)
  if targets ~= nil then local plan, reason = Moonshots.preflight(center_or_instance, targets, opts); return plan ~= nil, reason, plan end
  local center = center_of(center_or_instance)
  if not (center and center.target) then local plan, reason = Moonshots.preflight(center_or_instance, {}, opts); return plan ~= nil, reason, plan end
  local candidates = center.target.area == "hand" and ((G and G.hand and G.hand.cards) or {})
    or ((G and G.jokers and G.jokers.cards) or {})
  local eligible, target_reason = {}, nil
  for _, target in ipairs(candidates) do
    local allowed, why = Moonshots.can_target(center_or_instance, target, opts.game, opts)
    if allowed then eligible[#eligible + 1] = target elseif not target_reason then target_reason = why end
  end
  local needed = center.target.n or 1
  if #eligible < needed then return false, target_reason or "Not enough eligible targets" end

  -- Individual target eligibility is not enough for effects whose legality
  -- depends on the selected set (copy-cap projection, relayer candidates, and
  -- similar constraints). Search the small hand/Founder row deterministically.
  local picked, found_plan, last_reason = {}, nil, nil
  local function search(start)
    if #picked == needed then
      local plan, reason = Moonshots.preflight(center_or_instance, picked, opts)
      if plan then found_plan = plan; return true end
      last_reason = reason
      return false
    end
    local remaining = needed - #picked
    for i = start, #eligible - remaining + 1 do
      picked[#picked + 1] = eligible[i]
      if search(i + 1) then return true end
      picked[#picked] = nil
    end
    return false
  end
  search(1)
  if found_plan then return true, nil, found_plan end
  return false, last_reason or target_reason or "No legal target combination"
end

local function sync_tech(entry)
  if not (G and entry) then return end
  local center = Centers.get(entry.center_key)
  for _, area in ipairs({ G.deck, G.hand, G.play }) do
    for _, card in ipairs((area and area.cards) or {}) do
      if card.uid == entry.uid then
        card.center, card.center_key, card.layer = center, center.key, center.layer
        card.base_users = center.base_users or 0
        card.enhancement, card.enh, card.seal = entry.enhancement, nil, entry.seal
        card.modifier_state = entry.modifier_state and copy(entry.modifier_state) or nil
        card.stickers = entry.stickers and copy(entry.stickers) or nil
        card.layer_override, card.layer_locked = entry.layer_override, entry.layer_locked == true
        card.law_marks = entry.law_marks and copy(entry.law_marks) or nil
        card.source, card.acquired_ante, card.migrated_from = entry.source, entry.acquired_ante, entry.migrated_from
        card.ability = { name = center.name, set = center.set, config = copy(center.config or {}) }
      end
    end
  end
end

local function remove_uid(game, uid)
  for i = #(game.master_deck or {}), 1, -1 do if game.master_deck[i].uid == uid then table.remove(game.master_deck, i) end end
  if G then
    for _, area in ipairs({ G.deck, G.hand, G.play }) do
      for i = #((area and area.cards) or {}), 1, -1 do
        local card = area.cards[i]
        if card.uid == uid then area:remove_card(card, true); if card.remove then card:remove() end end
      end
    end
  end
end

local function debt_add(game, amount)
  game.meters = game.meters or {}
  local meter = game.meters.tech_debt or { value = 0, min = 0, thresholds = { 3, 6, 10, 15 }, tier = 0 }
  game.meters.tech_debt = meter
  meter.value = math.max(meter.min or 0, (meter.value or 0) + amount)
  meter.tier = 0; for i, cut in ipairs(meter.thresholds or {}) do if meter.value >= cut then meter.tier = i else break end end
end

local function prepare_fresh_tech(game, specs)
  local next_uid = tonumber(game._deck_uid) or 0
  for _, entry in ipairs(game.master_deck or {}) do
    if type(entry.uid) == "number" then next_uid = math.max(next_uid, entry.uid) end
  end
  local out = {}
  for i, spec in ipairs(specs or {}) do
    local center = Centers.get(spec.key)
    if not (center and center.set == "TechCard" and not center.signature) then
      return nil, "Fresh Tech " .. i .. " is invalid"
    end
    local modifiers = {
      enhancement = spec.enhancement or spec.enh,
      seal = spec.seal,
      modifier_state = spec.modifier_state and copy(spec.modifier_state) or nil,
    }
    local valid, reason = TechModifiers.validate(modifiers, "Fresh Tech " .. i)
    if not valid then return nil, reason end
    TechModifiers.normalize(modifiers)
    next_uid = next_uid + 1
    local entry = {
      uid = next_uid,
      center_key = spec.key,
      edition = spec.edition,
      enhancement = modifiers.enhancement,
      seal = modifiers.seal,
      modifier_state = modifiers.modifier_state,
      stickers = spec.stickers and copy(spec.stickers) or nil,
      layer_override = spec.layer_override,
      config = spec.config and copy(spec.config) or {},
    }
    TechLifecycle.acquire(entry, {
      source = spec.source,
      acquired_ante = game.ante,
      migrated_from = spec.migrated_from,
    })
    out[#out + 1] = entry
  end
  return out, next_uid
end

local function commit_fresh_tech(game, entries, next_uid)
  -- Hard Fork deliberately exceeds the ordinary acquisition copy cap. Its two
  -- entries are built above before any mutation, then committed as one effect.
  for _, entry in ipairs(entries) do game.master_deck[#game.master_deck + 1] = entry end
  game._deck_uid = next_uid
end

local function add_founder(center, source)
  local card = Card({ center = center, T = { x = G.jokers.T.x, y = G.jokers.T.y } })
  G.jokers:emplace(card)
  require("game.founder_lifecycle").acquire(card, { source = source, sell_basis = 0 })
  return card
end

local function result_change(result, kind, fields)
  local row = { kind = kind }; for key, value in pairs(fields or {}) do row[key] = copy(value) end
  result.changes[#result.changes + 1] = row
end

function Moonshots.apply(center_or_instance, targets, opts, supplied_plan)
  opts = opts or {}
  -- Re-run the deterministic preflight even when the caller supplies a plan.
  -- This closes the gap between UI preview and click: stale Era/Market/capacity
  -- state cannot turn an earlier plan into a partial mutation.
  local plan, reason = Moonshots.preflight(center_or_instance, targets, opts)
  if not plan then return { ok = false, key = center_of(center_or_instance) and center_of(center_or_instance).key,
    reason = reason, consumed = false, changes = {}, generated = {} } end
  local game, key = plan.game, plan.key
  game.moonshot_state = game.moonshot_state or { viral_moment_uses = 0, blitzscale_uses = 0 }
  local result = { ok = true, key = key, consumed = false, changes = {}, generated = {}, preview = copy(plan.preview) }

  -- Preflight resolves every fallible choice. The mutation phase performs no
  -- randomness and records every touched identity in the result journal.
  if key == "ms_viral_moment" then
    for _, entry in ipairs(game.master_deck) do
      entry.stickers = entry.stickers or {}
      local sticker
      for _, row in ipairs(entry.stickers) do if row.source == key and row.field == "users" then sticker = row end end
      local amount = math.min(30, (sticker and sticker.amount or 0) + 15)
      if sticker then sticker.amount = amount else entry.stickers[#entry.stickers + 1] = {
        field = "users", mode = "add", amount = amount, label = "Viral Moment", source = key } end
      sync_tech(entry)
    end
    local lost = game.cash; game.cash = 0
    game.moonshot_state.viral_moment_uses = (game.moonshot_state.viral_moment_uses or 0) + 1
    result_change(result, "mass_users", { amount = 15, count = #game.master_deck }); result_change(result, "cash", { amount = -lost })
  elseif key == "ms_blitzscale" then
    local gain = 6 * funding_unit(game); game.cash = (game.cash or 0) + gain
    game.margin_bonus = (game.margin_bonus or 0) - 0.10
    game.moonshot_state.blitzscale_uses = (game.moonshot_state.blitzscale_uses or 0) + 1
    result_change(result, "cash", { amount = gain }); result_change(result, "margin", { amount = -0.10 })
  elseif key == "ms_debt_equity_swap" then
    debt_add(game, -plan.debt_clear); game.equity_pct = game.equity_pct - plan.equity_cost
    result_change(result, "debt", { amount = -plan.debt_clear }); result_change(result, "equity", { amount = -plan.equity_cost })
  elseif key == "ms_market_pivot" then
    assert(require("game.markets").queue(game, plan.market, plan.market_founder_count))
    game.equity_pct = game.equity_pct - plan.equity_cost
    result_change(result, "market_queued", { market_id = plan.market.id }); result_change(result, "equity", { amount = -plan.equity_cost })
  elseif key == "ms_platform_shift" then
    for _, uid in ipairs(plan.affected_uids) do local entry = entry_by_uid(game, uid); entry.layer_override = plan.layer; sync_tech(entry) end
    debt_add(game, #plan.affected_uids)
    result_change(result, "relayer", { layer = plan.layer, uids = plan.affected_uids }); result_change(result, "debt", { amount = #plan.affected_uids })
  elseif key == "ms_stack_rewrite" then
    for i, uid in ipairs(plan.target_uids) do
      local entry, old = entry_by_uid(game, uid), nil; old = entry.center_key
      entry.center_key, entry.edition, entry.enhancement, entry.enh, entry.seal = plan.replacements[i], nil, nil, nil, nil
      entry.modifier_state, entry.stickers, entry.layer_override, entry.layer_locked, entry.law_marks = nil, nil, nil, nil, nil
      entry.config, entry.migrated_from, entry.source, entry.acquired_ante = {}, old, "moonshot_stack_rewrite", game.ante
      sync_tech(entry); result_change(result, "replace_tech", { uid = uid, from = old, to = entry.center_key })
    end
  elseif key == "ms_hard_fork" then
    local entries, next_uid = prepare_fresh_tech(game, {
      { key = plan.clone_key, source = "moonshot_hard_fork" },
      { key = plan.clone_key, source = "moonshot_hard_fork" },
    })
    if not entries then return { ok = false, key = key, reason = next_uid,
      consumed = false, changes = {}, generated = {} } end
    commit_fresh_tech(game, entries, next_uid)
    for _, entry in ipairs(entries) do
      result.generated[#result.generated + 1] = { kind = "tech", uid = entry.uid, key = entry.center_key }
    end
    game.hand_size = (game.hand_size or 8) - 1; result_change(result, "hand_size", { amount = -1 })
  elseif key == "ms_cambrian_explosion" then
    local specs = {}
    for _, offer in ipairs(plan.offers) do
      specs[#specs + 1] = { key = offer.key, source = "moonshot_cambrian",
        enhancement = offer.enhancement, seal = offer.seal,
        modifier_state = offer.modifier_state }
    end
    local entries, next_uid = prepare_fresh_tech(game, specs)
    if not entries then return { ok = false, key = key, reason = next_uid,
      consumed = false, changes = {}, generated = {} } end
    remove_uid(game, plan.target_uids[1]); result_change(result, "destroy_tech", { uid = plan.target_uids[1] })
    commit_fresh_tech(game, entries, next_uid)
    for _, entry in ipairs(entries) do
      result.generated[#result.generated + 1] = { kind = "tech", uid = entry.uid, key = entry.center_key,
        enhancement = entry.enhancement, seal = entry.seal }
    end
    debt_add(game, 3); result_change(result, "debt", { amount = 3 })
  elseif key == "ms_fire_sale" then
    for _, uid in ipairs(plan.affected_uids) do remove_uid(game, uid); result_change(result, "destroy_tech", { uid = uid }) end
    local gain = 5 * funding_unit(game); game.cash = (game.cash or 0) + gain; result_change(result, "cash", { amount = gain })
  elseif key == "ms_patent_blitz" then
    game.cash = game.cash - plan.cash_cost
    for _, uid in ipairs(plan.affected_uids) do local entry = entry_by_uid(game, uid); entry.seal = plan.payload.seal; sync_tech(entry) end
    result_change(result, "cash", { amount = -plan.cash_cost }); result_change(result, "seal", { key = plan.payload.seal, uids = plan.affected_uids })
  elseif key == "ms_open_core" then
    for _, uid in ipairs(plan.affected_uids) do
      local entry = entry_by_uid(game, uid); entry.enhancement = plan.payload.enhancement
      if entry.enhancement == "cutting_edge" then
        local def = TechModifiers.ENHANCEMENTS.cutting_edge
        entry.modifier_state = { cutting_edge_uses_left = def.min_uses, cutting_edge_deprecated = false }
      end
      sync_tech(entry)
    end
    debt_add(game, #plan.affected_uids)
    result_change(result, "enhancement", { key = plan.payload.enhancement, uids = plan.affected_uids }); result_change(result, "debt", { amount = #plan.affected_uids })
  elseif key == "ms_talent_raid" then
    local card = add_founder(plan.founder, "moonshot_talent_raid"); result.generated[#result.generated + 1] = { kind = "founder", key = card.center_key }
    local lost = game.cash; game.cash = 0; result_change(result, "cash", { amount = -lost })
  elseif key == "ms_spinout" then
    local copied = add_founder(plan.spinout_center, "moonshot_spinout")
    for i = #G.jokers.cards, 1, -1 do
      local card = G.jokers.cards[i]
      if card ~= plan.founder and card ~= copied then require("game.founder_lifecycle").remove(card, { source = "moonshot_spinout" }) end
    end
    result.generated[#result.generated + 1] = { kind = "founder", key = copied.center_key }
    result_change(result, "purge_founders", { kept = plan.founder.center_key })
  elseif key == "ms_hypergrowth_mandate" then
    local cfg = plan.founder.ability.config
    local current_salary = cfg._salary
    if current_salary == nil then
      current_salary = (plan.founder.center and plan.founder.center.salary) or 0
      if cfg._distilled then current_salary = current_salary * 0.5 end
    end
    plan.founder.edition = "viral"
    cfg._salary = current_salary * 1.5
    cfg._moonshot_salary_mult = nil
    result_change(result, "founder_edition", { key = plan.founder.center_key, edition = "viral", salary_mult = 1.5 })
  elseif key == "ms_acquihire" then
    local card = add_founder(plan.founder, "moonshot_acquihire")
    -- Lifecycle acquisition may apply a Founder-slot passive. The Moonshot's
    -- permanent -1 is composed after that delta instead of overwriting it with
    -- a pre-acquisition snapshot.
    game.founder_slots = math.max(1, (game.founder_slots or 5) - 1)
    result.generated[#result.generated + 1] = { kind = "founder", key = card.center_key }
    result_change(result, "founder_slots", { amount = -1 })
  elseif key == "ms_disruption" then
    game.app_levels = game.app_levels or {}
    local changed = 0
    for _, app in ipairs(require("game.apptypes").list) do
      local before = game.app_levels[app.key] or 1; local after = math.min(15, before + 1)
      game.app_levels[app.key] = after; if after > before then changed = changed + 1 end
    end
    debt_add(game, 5); result_change(result, "app_levels", { amount = 1, changed = changed }); result_change(result, "debt", { amount = 5 })
  end
  return result
end

return Moonshots
