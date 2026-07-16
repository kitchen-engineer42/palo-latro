-- game/game/shop.lua — the between-blinds founder SHOP. Random rarity-weighted founder offers
-- are the P0 access brake the balance-sim identified (the runtime contract): you can only buy what's
-- shown, rerolls cost money, and money = Margin × ARR, so the low-margin lane is genuinely gated.
-- Structure ported from Balatro (2 slots, 70/25/5 poll, Legendary spawn-only, reroll base+1/roll); the $
-- numbers are ANTE-SCALED drafts (sized to expected Cash), to be tuned by the #36 re-sim. Packs/vouchers
-- are P2/P3 (this file exposes the founder core + seams).

local Centers = require("game.centers")
local Audio = require("game.audio")
local RunState = require("game.runstate")
local Interp = require("game.effect_interp")   -- 1.5b: passive run-modifiers applied on hire
local Pricing = require("game.pricing")
local Lifecycle = require("game.founder_lifecycle")
local Packs = require("game.packs")
local TechEvaluation = require("game.tech_evaluation")
local PackPresentation = require("game.pack_presentation")
local Stakes = require("game.stakes")
local MarketRules = require("data.gameplay.market_rules")
local RNG = require("game.rng")
local Profile = require("game.profile")
local Guidance = require("game.guidance")
local Economy = require("game.economy")
local TechLaws = require("game.tech_laws")
local Moonshots = require("game.moonshots")
local FounderNegotiation = require("game.founder_negotiation")
local FounderEvents = require("game.founder_events")
local ShopDirectives = require("game.shop_directives")
local Markets = require("game.markets")
local ShopView = require("game.shop_view")
local random = RNG.fn("shop")
local pack_random = RNG.fn("packs")
local pack_shop_random = RNG.fn("pack_shop")
local law_shop_random = RNG.fn("tech_law_shop")
local law_pack_random = RNG.fn("tech_law_pack")
local moonshot_pack_random = RNG.fn("moonshot_pack")
local moonshot_special_random = RNG.fn("moonshot_special")
local moonshot_payload_random = RNG.fn("moonshot_payload")
local directive_random = RNG.fn("shop_directives")

local Shop = {}
local MAX_FOUNDER_OFFERS, MAX_PACK_OFFERS = 5, 5

local function next_sequence(field)
  G.GAME[field] = (G.GAME[field] or 0) + 1
  return G.GAME[field]
end

local function next_offer_id(kind)
  return table.concat({ kind, tostring(G.GAME.shop and G.GAME.shop.shop_id or 0),
    tostring(next_sequence("_shop_offer_sequence")) }, ":")
end

local function plain_copy(value, seen)
  local kind = type(value)
  if kind ~= "table" then return kind == "function" and nil or value end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local out = {}
  for key, item in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      local copied = plain_copy(item, seen)
      if copied ~= nil then out[key] = copied end
    end
  end
  seen[value] = nil
  return out
end

local function shop_command(action, sh, offer, index, disabled_reason)
  return {
    action = action,
    payload = {
      shop_id = sh.shop_id, shop_revision = sh.revision,
      session_token = ("shop:%s:%s"):format(tostring(sh.shop_id), tostring(sh.revision)),
      offer_id = offer and offer.offer_id or nil, index = index,
    },
    disabled_reason = disabled_reason,
  }
end

local function command_valid(sh, expected_offer_id, expected_revision, expected_shop_id,
    expected_session_token, offer, label)
  if not sh then return false, "Shop is closed" end
  if expected_shop_id ~= nil and expected_shop_id ~= sh.shop_id then
    return false, "Stale Shop identity"
  end
  if expected_revision ~= nil and expected_revision ~= sh.revision then
    return false, "Stale Shop revision"
  end
  local current_token = ("shop:%s:%s"):format(tostring(sh.shop_id), tostring(sh.revision))
  if expected_session_token ~= nil and expected_session_token ~= current_token then
    return false, "Stale Shop session"
  end
  if expected_offer_id ~= nil and (not offer or expected_offer_id ~= offer.offer_id) then
    return false, "Stale " .. tostring(label or "Shop") .. " offer"
  end
  return true
end

function Shop.validate_command(payload, offer)
  payload = payload or {}
  local sh = G.GAME and G.GAME.shop
  return command_valid(sh, payload.offer_id, payload.shop_revision, payload.shop_id,
    payload.session_token, offer, "Shop")
end

local function negotiation_pending()
  return G.GAME and FounderNegotiation.normalize(G.GAME) ~= nil
end

local function mutation_blocked()
  if negotiation_pending() then return true, "Founder negotiation pending" end
  return false
end

local function effective_founder_cap(game)
  local cap = game.founder_slots or 5
  if game.pending_market then
    cap = math.min(cap, Markets.destination_founder_cap(game, game.pending_market) or cap)
  end
  return cap
end

local function valid_remaining_picks(po)
  if not (po and type(po.options) == "table") then return false end
  local maximum = 0
  for key in pairs(po.options) do
    if type(key) ~= "number" or key ~= key or key == math.huge or key == -math.huge
        or key % 1 ~= 0 or key < 1 then return false end
    maximum = math.max(maximum, key)
  end
  local remaining = 0
  for index = 1, maximum do
    if po.options[index] == nil then return false end
    if po.options[index] then remaining = remaining + 1 end
  end
  local picks = po.picks_left
  return type(picks) == "number" and picks == picks and picks ~= math.huge
    and picks ~= -math.huge and picks % 1 == 0 and picks >= 1 and picks <= remaining
end

-- cumulative rarity poll (Balatro 70/25/5); Legendary is excluded (spawn-only, via packs in P3).
local POLL = { { r = "Common", c = 0.70 }, { r = "Uncommon", c = 0.95 }, { r = "Rare", c = 1.00 } }
-- price as a fraction of the ante's expected Cash; sim-tuned. (#36)
local PRICE_FRAC = { Common = 0.15, Uncommon = 0.30, Rare = 0.55, Legendary = 1.0 }
local REROLL_FRAC, REROLL_INC = 0.10, 0.02
-- Default retained for callers that ask for a pack price without identifying an offer.
local PACK = Packs.get("hiring")

local function maybe_edition(jk, edition)
  if not Card then return end
  jk.edition = edition
end

-- the ante's economic scale = expected Cash that ante = ANTE_BASE[ante] × default Margin.
local function ante_scale()
  local a = (G.GAME and G.GAME.ante) or 1
  local base = RunState.ANTE_BASE[a] or RunState.ANTE_BASE[#RunState.ANTE_BASE] or 300
  return base * (RunState.DEFAULT_MARGIN or 0.5)
end

function Shop.price(center)
  if center and center.buy_price then return center.buy_price end
  local actual = center and (center.center or center)
  local disc = 1 - ((G.GAME and G.GAME.shop_discount) or 0)
  return math.max(2, math.floor(Pricing.founder(G.GAME, RunState.ANTE_BASE, actual) * disc + 0.5))
end

function Shop.reroll_cost(rerolls)
  local disc = 1 - ((G.GAME and G.GAME.reroll_discount) or 0)
  return math.max(1, math.floor(Pricing.reroll(G.GAME, RunState.ANTE_BASE, rerolls) * disc + 0.5))
end

function Shop.voucher_price(v)
  if G.GAME and G.GAME.shop and G.GAME.shop.voucher_free then return 0 end
  return Pricing.voucher(G.GAME, RunState.ANTE_BASE)
end

-- a random not-yet-owned, unlocked voucher (1 offered/shop, buyable once each).
local function roll_voucher()
  local owned = (G.GAME and G.GAME.vouchers_owned) or {}
  local cand = {}
  for _, v in ipairs(Centers.pool("Voucher")) do
    if not owned[v.key] and v.unlocked ~= false then cand[#cand + 1] = v end
  end
  if #cand == 0 then return false end
  return cand[random(#cand)]
end

function Shop.sell_value(center)
  return Pricing.sell_value(center, Shop.price(center))
end

-- Tech Laws price in the same canonical funding units as blind rewards. This
-- keeps fixed and bounded Laws meaningful without turning late-Ante offers
-- into four-digit traps.
function Shop.consumable_price(c)
  local center = c and (c.center or c)
  if center and center.price_units then
    return math.max(1, math.floor(center.price_units * Economy.unit(G.GAME, RunState.ANTE_BASE) + 0.5))
  end
  return math.max(2, math.floor(ante_scale() * ((center and center.cost_frac) or 0.2) + 0.5))
end
function Shop.consumable_sell_value(c)
  local center = c and (c.center or c)
  return Pricing.sell_value(c, Shop.consumable_price(center))
end

-- Immutable-with-respect-to-runtime product projection.  Every nested value is copied, so consumers
-- may retain or even modify a snapshot without changing the authoritative Shop or center catalog.
function Shop.snapshot()
  local game, sh = G.GAME, G.GAME and G.GAME.shop
  if not (game and sh) then return nil end
  local founder_cap = effective_founder_cap(game)
  local founder_used = #((G.jokers and G.jokers.cards) or {})
  local roadmap_used = #((G.consumables and G.consumables.cards) or {})
  local roadmap_cap = game.consumable_slots or 2
  local snapshot = {
    shop_id = sh.shop_id, revision = sh.revision,
    session_token = ("shop:%s:%s"):format(tostring(sh.shop_id), tostring(sh.revision)),
    cash = game.cash or 0, ante = game.ante or 1,
    capacity = {
      founders = { used = founder_used, limit = founder_cap,
        offer_slots = math.max(Shop.slots(), #(sh.founders or {})) },
      roadmaps = { used = roadmap_used, limit = roadmap_cap },
      packs = { offer_slots = math.max(Shop.pack_slots(), #(sh.packs or {})), limit = MAX_PACK_OFFERS },
    },
    offers = { founders = {}, packs = {} },
    pack_open = sh.pack_open and {
      open_id = sh.pack_open.open_id, pack_key = sh.pack_open.pack_key,
      kind = sh.pack_open.kind, picks_left = sh.pack_open.picks_left,
      source_index = sh.pack_open.source_index,
      source_offer_id = sh.pack_open.source_offer_id,
    } or nil,
    negotiation_open = negotiation_pending(),
    tech_drawer_open = sh.tech_drawer_open == true,
  }

  for index = 1, snapshot.capacity.founders.offer_slots do
    local offer = sh.founders and sh.founders[index]
    local disabled
    if not offer then disabled = "Sold"
    elseif founder_used >= founder_cap then disabled = "Founder slots are full"
    elseif Shop.price(offer) > 0 and (game.cash or 0) < Shop.price(offer) then disabled = "Not enough Cash" end
    local center = offer and (offer.center or offer)
    snapshot.offers.founders[index] = {
      index = index, available = offer and true or false,
      offer_id = offer and offer.offer_id or nil,
      key = center and center.key or nil, name = center and center.name or nil,
      short = center and center.short or nil, rarity = center and center.rarity or nil,
      face_tag = center and center.face_tag or nil,
      rules_text = center and center.rules_text or nil,
      edition = offer and offer.edition or nil, stake_mod = plain_copy(offer and offer.stake_mod),
      price = offer and Shop.price(offer) or nil, disabled_reason = disabled,
      command = shop_command("buy_founder", sh, offer, index, disabled),
    }
  end

  local roadmap, roadmap_disabled = sh.consumable, nil
  if not roadmap then roadmap_disabled = "Sold"
  elseif roadmap_used >= roadmap_cap then roadmap_disabled = "Roadmap is full"
  elseif Shop.consumable_price(roadmap) > 0
      and (game.cash or 0) < Shop.consumable_price(roadmap) then roadmap_disabled = "Not enough Cash" end
  snapshot.offers.roadmap = {
    available = roadmap and true or false, offer_id = roadmap and roadmap.offer_id or nil,
    key = roadmap and roadmap.key or nil, name = roadmap and roadmap.name or nil,
    kind = roadmap and roadmap.kind or nil, rarity = roadmap and roadmap.rarity or nil,
    description = roadmap and roadmap.desc or nil,
    price = roadmap and Shop.consumable_price(roadmap) or nil,
    disabled_reason = roadmap_disabled,
    command = shop_command("buy_roadmap", sh, roadmap, 1, roadmap_disabled),
  }

  local voucher, voucher_disabled = sh.voucher, nil
  if not voucher then voucher_disabled = "Sold"
  elseif Shop.voucher_price(voucher) > 0
      and (game.cash or 0) < Shop.voucher_price(voucher) then voucher_disabled = "Not enough Cash" end
  snapshot.offers.voucher = {
    available = voucher and true or false, offer_id = voucher and voucher.offer_id or nil,
    key = voucher and voucher.key or nil, name = voucher and voucher.name or nil,
    description = voucher and voucher.desc or nil,
    price = voucher and Shop.voucher_price(voucher) or nil, disabled_reason = voucher_disabled,
    command = shop_command("buy_voucher", sh, voucher, 1, voucher_disabled),
  }

  local pack_slots = snapshot.capacity.packs.offer_slots
  for index = 1, pack_slots do
    local offer, disabled = sh.packs and sh.packs[index], nil
    if not offer then disabled = "Opened"
    elseif sh.pack_open then disabled = "Finish the open pack"
    elseif Shop.pack_price(offer) > 0
        and (game.cash or 0) < Shop.pack_price(offer) then disabled = "Not enough Cash" end
    snapshot.offers.packs[index] = {
      index = index, available = offer and true or false,
      offer_id = offer and offer.offer_id or nil,
      key = offer and offer.key or nil, name = offer and offer.name or nil,
      family = offer and offer.family or nil, size = offer and offer.size or nil,
      art_key = offer and offer.art_key or nil, fallback_art = offer and offer.fallback_art or nil,
      options = offer and Shop.pack_effective_options(offer) or nil,
      picks = offer and offer.picks or nil, price = offer and Shop.pack_price(offer) or nil,
      disabled_reason = disabled,
      command = shop_command("open_pack", sh, offer, index, disabled),
    }
  end

  local reroll_disabled = sh.pack_open and "Finish the open pack"
    or negotiation_pending() and "Finish the negotiation"
    or ((game.cash or 0) < (sh.reroll_cost or 0) and "Not enough Cash" or nil)
  local next_disabled = sh.pack_open and "Finish or skip the open pack"
    or negotiation_pending() and "Finish the negotiation" or nil
  snapshot.commands = {
    reroll = shop_command("reroll_shop", sh, nil, nil, reroll_disabled),
    next_blind = shop_command("next_blind", sh, nil, nil, next_disabled),
  }
  snapshot.commands.reroll.price = sh.reroll_cost or 0
  return snapshot
end

local function roll_consumable()
  return TechLaws.roll(law_shop_random) or false
end

function Shop.buy_consumable(expected_offer_id, expected_revision, expected_shop_id, expected_session_token)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh = G.GAME.shop
  local c = sh and sh.consumable
  local valid, stale_reason = command_valid(sh, expected_offer_id, expected_revision,
    expected_shop_id, expected_session_token, c, "Roadmap")
  if not valid then return false, stale_reason end
  if not c then return false end
  local cost = Shop.consumable_price(c)
  if (G.GAME.cash or 0) < cost then return false end
  local entry = require("game.consumables").grant(c.key, {
    source = "shop", sell_basis = cost,
  })                                                              -- respects the slot cap
  if not entry then return false end                              -- inventory full → don't charge
  if not FounderEvents.spend(G.GAME, cost, "consumable", { center_key = c.key }) then return false end
  sh.consumable = false
  sh.revision = (sh.revision or 1) + 1
  Profile.discover(c.key)
  Audio.play("hire")
  return true
end

local function roll_rarity(rng)
  rng = rng or random
  local x = rng()
  for _, e in ipairs(POLL) do if x <= e.c then return e.r end end
  return "Common"
end

-- founders eligible for an offer of `rarity`: unlocked (seam) · not owned · not signature · in-era (forms).
local function eligible(rarity, excluded)
  local owned = {}
  for _, j in ipairs((G.jokers and G.jokers.cards) or {}) do if j.center_key then owned[j.center_key] = true end end
  local ante = (G.GAME and G.GAME.ante) or 1
  local out = {}
  for _, c in ipairs(Centers.pool("Founder")) do
    if c.rarity == rarity and c.unlocked ~= false and not owned[c.key] and not (excluded and excluded[c.key]) and not c.signature then
      local in_era = true
      if c.is_form and c.era_gate then in_era = ante >= (c.era_gate.min or 1) and ante <= (c.era_gate.max or 8) end
      if in_era then out[#out + 1] = c end
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

local function market_weight(center)
  local tags = MarketRules.for_market(G.GAME and G.GAME.market).founder_tags or {}
  local text = ((center.name or "") .. " " .. (center.ability_name or "") .. " " .. (center.ability_text or "")):lower()
  local weight = 1
  for _, tag in ipairs(tags) do if text:find(tag, 1, true) then weight = weight + 2 end end
  return weight
end

local function roll_one(excluded, rng)
  rng = rng or random
  for _ = 1, 6 do                                   -- retry if a rolled tier is exhausted
    local pool = eligible(roll_rarity(rng), excluded)
    if #pool > 0 then
      local total = 0; for _, c in ipairs(pool) do total = total + market_weight(c) end
      local roll, c = rng() * total
      for _, cand in ipairs(pool) do roll = roll - market_weight(cand); if roll <= 0 then c = cand; break end end
      c = c or pool[#pool]
      c.discovered = true                           -- soft "discovery" flag
      return c
    end
  end
  return false
end

local function make_founder_offer(center, opts)
  opts = opts or {}
  local offer = {}; for key, value in pairs(center) do offer[key] = value end
  offer.center = center
  offer.offer_id = next_offer_id("founder")
  offer.edition = opts.edition
  if opts.roll_modifier ~= false and offer.edition == nil then
    offer.edition = Packs.roll_modifier(RNG.fn("modifier"))
  end
  local price = Shop.price(center) + (offer.edition and Pricing.base_reroll(G.GAME, RunState.ANTE_BASE) or 0)
  if opts.free then price = 0
  elseif opts.discount then price = math.max(0, math.floor(price * (1 - opts.discount) + 0.5)) end
  offer.buy_price = price
  offer.sell_basis = opts.free and 0 or price
  offer.stake_mod = opts.stake_mod
    or (opts.roll_stake == false and nil or Stakes.roll_offer_mod(G.GAME, RNG.fn("modifier")))
  offer.pinned = opts.pinned == true
  offer.directive_id = opts.directive_id
  offer.directive_source = opts.source_key
  return offer
end

function Shop.slots() return G.GAME.shop_founder_slots or 2 end
function Shop.founder_cap() return effective_founder_cap(G.GAME) end

-- (re)roll the whole founder offer row.
local function roll_offers()
  local sh = G.GAME.shop
  local pinned, seen = {}, {}
  for _, offer in ipairs(sh.founders or {}) do
    if offer and offer.pinned then
      pinned[#pinned + 1] = offer
      seen[(offer.center or offer).key] = true
    end
  end
  sh.founders = {}
  for i = 1, Shop.slots() do
    local center = roll_one(seen)
    if center then
      seen[center.key] = true
      sh.founders[i] = make_founder_offer(center)
    else sh.founders[i] = false end
  end
  for _, offer in ipairs(pinned) do
    if #sh.founders < MAX_FOUNDER_OFFERS then sh.founders[#sh.founders + 1] = offer end
  end
end

local function available_founders(rarity, excluded)
  if rarity then return eligible(rarity, excluded) end
  local out = {}
  for _, tier in ipairs({ "Common", "Uncommon", "Rare" }) do
    for _, center in ipairs(eligible(tier, excluded)) do out[#out + 1] = center end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

local function materialize_directive(row)
  local sh = G.GAME.shop
  if row.kind == "pack" then
    local definition = Packs.get(row.pack_key)
    local occupied, slots, highest = 0, {}, 0
    for index = 1, MAX_PACK_OFFERS do
      if sh.packs[index] then occupied = occupied + 1 else slots[#slots + 1] = index end
      if sh.packs[index] ~= nil then highest = index end
    end
    if not definition or occupied + row.count > MAX_PACK_OFFERS then return false end
    local prepared = {}
    for _ = 1, row.count do
      local pack = {}; for key, value in pairs(definition) do pack[key] = value end
      pack.offer_id = next_offer_id("pack")
      pack.directive_id, pack.directive_source = row.id, row.source_key
      pack.pinned = row.pinned
      if row.free then pack.price_override = 0 end
      if row.options then pack.options = row.options end
      prepared[#prepared + 1] = pack
    end
    for _, pack in ipairs(prepared) do
      local index = table.remove(slots, 1) or (highest + 1)
      sh.packs[index], highest = pack, math.max(highest, index)
    end
    return true, { kind="pack", count=#prepared, offer_ids=(function()
      local ids = {}; for _, pack in ipairs(prepared) do ids[#ids + 1] = pack.offer_id end; return ids end)() }
  end

  local seen = {}
  for _, offer in ipairs(sh.founders or {}) do if offer then seen[(offer.center or offer).key] = true end end
  local pool = available_founders(row.rarity, seen)
  local room = MAX_FOUNDER_OFFERS - #sh.founders
  for _, offer in ipairs(sh.founders) do if not offer then room = room + 1 end end
  if #pool < row.count or room < row.count then return false end
  local prepared = {}
  for _ = 1, row.count do
    local index = directive_random(#pool)
    local center = table.remove(pool, index)
    seen[center.key] = true
    prepared[#prepared + 1] = make_founder_offer(center, {
      free=row.free, discount=row.discount, pinned=row.pinned,
      directive_id=row.id, source_key=row.source_key,
    })
  end
  local slots = {}
  for index, offer in ipairs(sh.founders) do if not offer then slots[#slots + 1] = index end end
  for _, offer in ipairs(prepared) do
    local index = table.remove(slots, 1) or (#sh.founders + 1)
    sh.founders[index] = offer
  end
  local ids = {}; for _, offer in ipairs(prepared) do ids[#ids + 1] = offer.offer_id end
  return true, { kind="founder", count=#prepared, offer_ids=ids }
end

function Shop.apply_directives(phase)
  local sh = G.GAME and G.GAME.shop
  if not sh then return {} end
  local applied = ShopDirectives.apply(G.GAME, sh, phase or "current", materialize_directive)
  if #applied > 0 then sh.revision = (sh.revision or 1) + 1 end
  return applied
end

function Shop.enter()
  local voucher = false
  if G.GAME.voucher_offer_ante ~= G.GAME.ante then voucher = roll_voucher(); G.GAME.voucher_offer_ante = G.GAME.ante end
  local voucher_offer
  if voucher then
    voucher_offer = {}; for key, value in pairs(voucher) do voucher_offer[key] = value end
    voucher_offer.center = voucher
  end
  local consumable_center, consumable_offer = roll_consumable(), nil
  if consumable_center then
    consumable_offer = {}; for key, value in pairs(consumable_center) do consumable_offer[key] = value end
    consumable_offer.center = consumable_center
  end
  G.GAME.shop = { shop_id = next_sequence("_shop_sequence"), revision = 1,
                  founders = {}, rerolls = 0, reroll_cost = Shop.reroll_cost(0),
                  voucher = voucher_offer or false, voucher_free = voucher and G.GAME.free_voucher_pending or false,
                  consumable = consumable_offer or false, packs = {}, pack_open = nil,
                  tech_drawer_open = false }
  if G.GAME.shop.voucher_free then G.GAME.free_voucher_pending = false end
  if G.GAME.shop.voucher then G.GAME.shop.voucher.offer_id = next_offer_id("voucher") end
  if G.GAME.shop.consumable then G.GAME.shop.consumable.offer_id = next_offer_id("roadmap") end
  roll_offers()
  local seen = {}
  for i = 1, (G.GAME.shop_pack_slots or 2) do
    local pack = Packs.roll_shop(pack_shop_random, seen)
    if pack then
      seen[pack.key] = true
      local offer = {}; for key, value in pairs(pack) do offer[key] = value end
      offer.offer_id = next_offer_id("pack")
      G.GAME.shop.packs[i] = offer
    end
  end
  require("game.leads").on_shop_enter(G.GAME, G.GAME.shop)
  -- Leads predate offer identities; normalize anything they injected before
  -- Founder directives add their own pinned offers.
  for _, offer in ipairs(G.GAME.shop.founders) do if offer and not offer.offer_id then offer.offer_id = next_offer_id("founder") end end
  for _, pack in ipairs(G.GAME.shop.packs) do if pack and not pack.offer_id then pack.offer_id = next_offer_id("pack") end end
  Shop.apply_directives("enter")
  FounderEvents.fire("shop_entered", { shop = G.GAME.shop })
  local discovered = {}
  for _, offer in ipairs(G.GAME.shop.founders) do
    if offer then discovered[#discovered + 1] = (offer.center or offer).key end
  end
  if G.GAME.shop.consumable then discovered[#discovered + 1] = G.GAME.shop.consumable.key end
  Profile.discover_many(discovered)
  Guidance.emit("shop_entered", { founder_offers = #G.GAME.shop.founders })
  if #G.GAME.shop.packs > 0 then Guidance.emit("pack_available", { count = #G.GAME.shop.packs }) end
  if (G.GAME.cash or 0) < (G.GAME.last_payroll or 0) then
    Guidance.emit("low_cash", { cash = G.GAME.cash, payroll = G.GAME.last_payroll })
  end
end

-- redeem the offered voucher: pay, apply its run-modifier generically, mark owned (one-time).
function Shop.redeem(expected_offer_id, expected_revision, expected_shop_id, expected_session_token)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh = G.GAME.shop
  local v = sh and sh.voucher
  local valid, stale_reason = command_valid(sh, expected_offer_id, expected_revision,
    expected_shop_id, expected_session_token, v, "Investment")
  if not valid then return false, stale_reason end
  if not v then return false end
  local cost = Shop.voucher_price(v)
  if (G.GAME.cash or 0) < cost then return false end
  if not FounderEvents.spend(G.GAME, cost, "voucher", { center_key = v.key }) then return false end
  local m = v.mod or {}
  if m.field then G.GAME[m.field] = (G.GAME[m.field] or 0) + (m.delta or 0) end
  G.GAME.vouchers_owned[v.key] = true
  sh.voucher = false
  sh.revision = (sh.revision or 1) + 1
  Audio.play("hire")
  return true
end

function Shop.reroll(expected_revision, expected_shop_id, expected_session_token)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh = G.GAME.shop
  local valid, stale_reason = command_valid(sh, nil, expected_revision, expected_shop_id,
    expected_session_token, nil, "Reroll")
  if not valid then return false, stale_reason end
  if not sh or (G.GAME.cash or 0) < sh.reroll_cost then return false end
  if not FounderEvents.spend(G.GAME, sh.reroll_cost, "reroll") then return false end
  sh.rerolls = sh.rerolls + 1
  sh.revision = (sh.revision or 1) + 1
  sh.reroll_cost = Shop.reroll_cost(sh.rerolls)
  roll_offers()
  Audio.play("select", nil, 0.5)
  return true
end

function Shop.buy(idx, expected_offer_id, expected_revision, expected_shop_id, expected_session_token)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh = G.GAME.shop
  local offer = sh and sh.founders[idx]
  local valid, stale_reason = command_valid(sh, expected_offer_id, expected_revision,
    expected_shop_id, expected_session_token, offer, "Founder")
  if not valid then return false, stale_reason end
  if not offer then return false end
  if #G.jokers.cards >= Shop.founder_cap() then
    Guidance.emit("founder_slots_full", { slots = Shop.founder_cap() })
    return false
  end
  local offered_key = (offer.center or offer).key
  local c = type(offered_key) == "string" and Centers.get(offered_key)
  if not (c and c.set == "Founder") or (c.rarity == "Legendary" and not c.signature) then
    return false, "Invalid Founder offer"
  end
  local cost = Shop.price(offer)
  if cost > 0 and (G.GAME.cash or 0) < cost then return false end
  if not FounderEvents.spend(G.GAME, cost, "founder", { center_key = (offer.center or offer).key }) then return false end
  local jk = Card({ center = c, T = { x = G.jokers.T.x, y = G.jokers.T.y } })
  G.jokers:emplace(jk)
  if jk.juice_up then jk:juice_up(0.5) end                     -- the new hire pops as it joins the row
  maybe_edition(jk, offer.edition)
  Lifecycle.acquire(jk, { source = "shop", sell_basis = offer.sell_basis, stake_mod = offer.stake_mod })
  sh.founders[idx] = false                                     -- bought slot empties
  sh.revision = (sh.revision or 1) + 1
  Shop.apply_directives("current")
  Profile.discover(c.key)
  Guidance.emit("founder_bought", { founder = c.key, salary = c.salary or 0 })
  Audio.play("hire")
  return true
end

-- ── Pitch packs (P3) ──────────────────────────────────────────────────────────────────────────────
-- Hiring Rounds draft founders; Playbook Workshops upgrade App Types; Roadmap packs
-- add consumables. Every definition carries its own Balatro-like size/choice band.
function Shop.pack_price(definition)
  if type(definition) == "number" then
    definition = G.GAME and G.GAME.shop and G.GAME.shop.packs[definition]
  elseif type(definition) == "string" then
    definition = Packs.get(definition)
  end
  definition = definition or PACK
  if definition.price_override ~= nil then return math.max(0, definition.price_override) end
  local price = Pricing.pack(G.GAME, RunState.ANTE_BASE, definition.size)
  local economy = MarketRules.for_market(G.GAME and G.GAME.market).economy or {}
  if definition.family == "tech_evaluation" then price = price * (economy.tech_eval_pack_discount or 1) end
  return math.max(1, math.floor(price + 0.5))
end
function Shop.pack_slots() return G.GAME.shop_pack_slots or 2 end

function Shop.pack_option_bonus(family)
  local total = 0
  for _, spec in pairs((G.GAME and G.GAME.pack_option_passives) or {}) do
    if spec.family == family then
      local per = spec.per == "founder_count" and #((G.jokers and G.jokers.cards) or {}) or 0
      local value = (spec.base or 0) + (spec.coef or 0) * per
      if spec.round == "floor" then value = math.floor(value) end
      total = total + math.max(0, math.min(spec.cap or 2, value))
    end
  end
  return math.min(2, math.floor(total))
end

function Shop.pack_effective_options(definition)
  if not definition then return 0 end
  return math.min(6, (definition.options or 0) + Shop.pack_option_bonus(definition.family))
end

local function emplace_founder(c, sell_basis, edition, source_i, source_count, acquire_opts)
  local sx, sy = G.jokers.T.x, G.jokers.T.y
  if not G.SETTINGS.reduced_motion and source_i and source_count then
    local po = G.GAME and G.GAME.shop and G.GAME.shop.pack_open
    local geometry = ShopView.pack_layout(po or { options = {} }, G.WINDOW.w, G.WINDOW.h)
    local product = geometry.options[source_i] and geometry.options[source_i].product
    if product then
      sx, sy = product.x + (product.w - Card.FW) / 2, product.y
    end
  end
  local jk = Card({ center = c, T = { x = sx, y = sy } })
  G.jokers:emplace(jk)
  if G.SETTINGS.reduced_motion then
    jk.VT.x, jk.VT.y = jk.T.x, jk.T.y
  end
  if jk.juice_up then jk:juice_up(0.5) end                     -- the new hire pops as it joins the row
  maybe_edition(jk, edition)
  acquire_opts = acquire_opts or {}
  acquire_opts.source = acquire_opts.source or "pack"
  acquire_opts.sell_basis = sell_basis or 0
  Lifecycle.acquire(jk, acquire_opts)
  return jk
end

local function consume_pack_offer(sh, idx)
  sh.packs[idx] = false
  sh.revision = (sh.revision or 1) + 1
end

local function identify_pack_session(sh, pack_open, idx, definition)
  G.GAME.pack_session_next_id = (G.GAME.pack_session_next_id or 0) + 1
  pack_open.open_id = table.concat({ "pack-open", tostring(sh.shop_id),
    tostring(G.GAME.pack_session_next_id) }, ":")
  pack_open.shop_id = sh.shop_id
  pack_open.shop_revision = sh.revision
  pack_open.source_index = idx
  pack_open.source_offer_id = definition.offer_id
  return pack_open
end

function Shop.open_pack(idx, expected_offer_id, expected_revision, expected_shop_id, expected_session_token)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh = G.GAME.shop
  if sh and (type(sh.shop_id) ~= "number" or sh.shop_id < 1) then
    sh.shop_id = next_sequence("_shop_sequence")
  end
  if sh and (type(sh.revision) ~= "number" or sh.revision < 1) then sh.revision = 1 end
  local offered = sh and sh.packs[idx]
  local valid, stale_reason = command_valid(sh, expected_offer_id, expected_revision,
    expected_shop_id, expected_session_token, offered, "pack")
  if not valid then return false, stale_reason end
  if not offered then return false end
  local canonical = type(offered.key) == "string" and Packs.get(offered.key) or nil
  if not canonical or canonical.family ~= offered.family or canonical.size ~= offered.size
      or type(offered.picks) ~= "number" or offered.picks % 1 ~= 0
      or offered.picks < 1 or offered.picks > 2 then
    return false, "Invalid pack offer"
  end
  local definition = {}; for key, value in pairs(offered) do definition[key] = value end
  definition.options = Shop.pack_effective_options(offered)
  if definition.options < definition.picks or definition.options > 6 then
    return false, "Invalid pack option count"
  end
  local cost = Shop.pack_price(definition)
  if cost > 0 and (G.GAME.cash or 0) < cost then return false end
  local tech_options
  local moonshot_options
  if definition.family == "tech_evaluation" then
    if TechEvaluation.available_count(G.GAME) < definition.options then return false end
    tech_options = TechEvaluation.generate_offers(G.GAME, definition.options, pack_random,
      RNG.fn("tech_modifier_offer"))
    if #tech_options < definition.options then return false end -- no charge for an exhausted evaluation
  elseif definition.family == "moonshot" then
    moonshot_options = {}
    local seen, attempts = {}, 0
    local max_attempts = #Moonshots.pool() + definition.options + 2
    while #moonshot_options < definition.options and attempts < max_attempts do
      attempts = attempts + 1
      local center = Moonshots.roll(moonshot_pack_random, {
        special_rng = moonshot_special_random,
        exclude = seen,
      })
      if not center then break end
      seen[center.key] = true
      local instance = Moonshots.materialize(center, {
        game = G.GAME,
        rng = moonshot_payload_random,
      })
      if instance then
        local option = {}
        for key, value in pairs(center) do option[key] = value end
        option.moonshot_payload = deep_copy(instance.payload or instance)
        moonshot_options[#moonshot_options + 1] = option
      end
    end
    if #moonshot_options < definition.options then return false end
  end
  if not FounderEvents.spend(G.GAME, cost, "pack", { pack_key = definition.key, family = definition.family }) then return false end
  if definition.family == "tech_evaluation" then
    consume_pack_offer(sh, idx)
    local targets = TechEvaluation.deprecated_targets(G.GAME)
    sh.pack_open = { kind = "tech_evaluation", name = definition.name, pack_key = definition.key,
      art_key = definition.art_key, fallback_art = definition.fallback_art,
      options = tech_options, picks_left = definition.picks,
      migration_target_uid = targets[1] and targets[1].uid or nil }
    identify_pack_session(sh, sh.pack_open, idx, definition)
    local keys = {}; for _, option in ipairs(tech_options) do keys[#keys + 1] = option.key end
    Profile.discover_many(keys)
    PackPresentation.begin(sh.pack_open, idx, definition)
    Guidance.emit("pack_opened", { family = definition.family, key = definition.key })
    Audio.play("select", nil, 0.6)
    return true
  end
  if definition.family == "playbook" then
    local apps = require("game.apptypes").list
    local opts, seen = {}, {}
    while #opts < definition.options do
      local app = apps[pack_random(#apps)]
      if not seen[app.key] then seen[app.key] = true; opts[#opts + 1] = app end
    end
    consume_pack_offer(sh, idx)
    sh.pack_open = { kind = "playbook", name = definition.name, pack_key = definition.key,
      art_key = definition.art_key, fallback_art = definition.fallback_art,
      options = opts, picks_left = definition.picks }
    identify_pack_session(sh, sh.pack_open, idx, definition)
    local keys = {}; for _, option in ipairs(opts) do keys[#keys + 1] = option.key end
    Profile.discover_many(keys)
    PackPresentation.begin(sh.pack_open, idx, definition)
    Guidance.emit("pack_opened", { family = definition.family, key = definition.key })
    Audio.play("select", nil, 0.6)
    return true
  end
  if definition.family == "tech_law" then
    local pool = TechLaws.pool()
    local opts, seen = {}, {}
    while #opts < definition.options and #opts < #pool do
      local c = TechLaws.roll(law_pack_random, { exclude = seen })
      if not c then break end
      seen[c.key] = true
      opts[#opts + 1] = c
    end
    consume_pack_offer(sh, idx)
    sh.pack_open = { kind = "tech_law", name = definition.name, pack_key = definition.key,
      art_key = definition.art_key, fallback_art = definition.fallback_art,
      options = opts, picks_left = definition.picks }
    identify_pack_session(sh, sh.pack_open, idx, definition)
    local keys = {}; for _, option in ipairs(opts) do keys[#keys + 1] = option.key end
    Profile.discover_many(keys)
    PackPresentation.begin(sh.pack_open, idx, definition)
    Guidance.emit("pack_opened", { family = definition.family, key = definition.key })
    Audio.play("select", nil, 0.6)
    return true
  end
  if definition.family == "moonshot" then
    consume_pack_offer(sh, idx)
    sh.pack_open = { kind = "moonshot", name = definition.name, pack_key = definition.key,
      art_key = definition.art_key, fallback_art = definition.fallback_art,
      options = moonshot_options, picks_left = definition.picks }
    identify_pack_session(sh, sh.pack_open, idx, definition)
    local keys = {}; for _, option in ipairs(moonshot_options) do keys[#keys + 1] = option.key end
    Profile.discover_many(keys)
    PackPresentation.begin(sh.pack_open, idx, definition)
    Guidance.emit("pack_opened", { family = definition.family, key = definition.key })
    Audio.play("select", nil, 0.6)
    return true
  end
  local opts, seen = {}, {}                                    -- exclude owned (via eligible) + no within-pack dups
  for _ = 1, definition.options do
    local c
    for _ = 1, 8 do
      local cand
      if pack_random() < (definition.legendary_chance or 0) then -- Legendary/form breakthrough
        local leg = eligible("Legendary", seen); if #leg > 0 then cand = leg[pack_random(#leg)] end
      end
      if not cand then cand = roll_one(seen, pack_random) end
      if cand and not seen[cand.key] then c = cand; break end
      if not cand then break end
    end
    if c then
      seen[c.key] = true; c.discovered = true
      local option = {}; for k, v in pairs(c) do option[k] = v end
      option.center, option.edition = c, Packs.roll_modifier(RNG.fn("modifier"))
      opts[#opts + 1] = option
    end
  end
  consume_pack_offer(sh, idx)
  sh.pack_open = { kind = "hiring", name = definition.name, pack_key = definition.key,
    art_key = definition.art_key, fallback_art = definition.fallback_art,
    options = opts, picks_left = definition.picks }
  identify_pack_session(sh, sh.pack_open, idx, definition)
  local keys = {}; for _, option in ipairs(opts) do keys[#keys + 1] = (option.center or option).key end
  Profile.discover_many(keys)
  PackPresentation.begin(sh.pack_open, idx, definition)
  Guidance.emit("pack_opened", { family = definition.family, key = definition.key })
  Audio.play("select", nil, 0.6)
  return true
end

local function active_pack(expected_open_id)
  local sh = G.GAME and G.GAME.shop
  local po = sh and sh.pack_open
  if not po then return nil, nil, "No pack is open" end
  if expected_open_id ~= nil and expected_open_id ~= po.open_id then
    return nil, nil, "Stale pack session"
  end
  return sh, po
end

local function consume_pack_option(sh, po, index, option, mode)
  po.options[index] = false
  po.picks_left = po.picks_left - 1
  Profile.discover(option.key)
  Audio.play("hire")
  Guidance.emit("pack_picked", { family = po.kind, key = option.key, mode = mode })
  FounderEvents.pack_selected({ family = po.kind, center_key = option.key, mode = mode })
  if po.picks_left <= 0 then sh.pack_open = nil end
end

function Shop.tech_migration_targets()
  return TechEvaluation.deprecated_targets(G.GAME)
end

function Shop.pack_set_migration_target(uid)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local po = G.GAME and G.GAME.shop and G.GAME.shop.pack_open
  if not (po and po.kind == "tech_evaluation" and uid ~= nil) then return false end
  for _, entry in ipairs(TechEvaluation.deprecated_targets(G.GAME)) do
    if entry.uid == uid then po.migration_target_uid = uid; po.error = nil; return true end
  end
  return false
end

function Shop.pack_cycle_migration_target(delta)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local po = G.GAME and G.GAME.shop and G.GAME.shop.pack_open
  if not (po and po.kind == "tech_evaluation") then return false end
  local targets = TechEvaluation.deprecated_targets(G.GAME)
  if #targets == 0 then po.migration_target_uid = nil; return false end
  local current = 1
  for i, entry in ipairs(targets) do if entry.uid == po.migration_target_uid then current = i; break end end
  current = ((current - 1 + (delta or 1)) % #targets) + 1
  po.migration_target_uid = targets[current].uid
  Audio.play("select", nil, 0.4)
  return targets[current]
end

function Shop.pack_adopt(i, expected_open_id)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh, po, session_reason = active_pack(expected_open_id)
  if not sh then return false, session_reason end
  local option = po and po.kind == "tech_evaluation" and po.options[i]
  if not option then return false end
  local entry, reason = TechEvaluation.adopt(option.key, G.GAME, option)
  if not entry then po.error = reason; return false, reason end
  po.error = nil
  consume_pack_option(sh, po, i, option, "adopt")
  return true
end

function Shop.pack_migrate(i, target_uid, expected_open_id)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh, po, session_reason = active_pack(expected_open_id)
  if not sh then return false, session_reason end
  local option = po and po.kind == "tech_evaluation" and po.options[i]
  if not option then return false end
  target_uid = target_uid or po.migration_target_uid
  local entry, reason = TechEvaluation.migrate(option.key, target_uid, G.GAME)
  if not entry then po.error = reason; return false, reason end  -- failed validation consumes nothing
  po.error = nil
  consume_pack_option(sh, po, i, option, "migrate")
  if sh.pack_open then
    local targets = TechEvaluation.deprecated_targets(G.GAME)
    po.migration_target_uid = targets[1] and targets[1].uid or nil
  end
  return true
end

local function validate_legendary_pick(game, pending)
  local sh = game and game.shop
  local po = sh and sh.pack_open
  if not (po and po.kind == "hiring" and valid_remaining_picks(po)) then
    return nil, nil, "The Hiring Round is no longer available"
  end
  if pending and (po.pack_key ~= pending.pack_key or po.open_id ~= pending.open_id) then
    return nil, nil, "The selected Hiring Round is no longer available"
  end
  local index = pending and pending.option_index
  local option = index and po.options[index]
  if not option then return nil, nil, "The selected Founder option is no longer available" end
  local offered = option.center or option
  if type(offered) ~= "table" or type(offered.key) ~= "string"
      or (option.key ~= nil and option.key ~= offered.key)
      or (pending and pending.center_key ~= offered.key) then
    return nil, nil, "The selected Founder option is malformed"
  end
  local center = Centers.get(offered.key)
  if not (center and center.set == "Founder" and center.key == offered.key
      and center.rarity == "Legendary" and center.unlocked ~= false and not center.signature) then
    return nil, nil, "The selected Legendary Founder is unavailable"
  end
  if center.is_form and center.era_gate then
    local ante = game.ante or 1
    if ante < (center.era_gate.min or 1) or ante > (center.era_gate.max or 8) then
      return nil, nil, "That Founder form is unavailable in this Era"
    end
  end
  local script, resolved_key = FounderNegotiation.script_for(center)
  if not script or (pending and pending.base_key ~= resolved_key) then
    return nil, nil, "That Legendary Founder has no valid negotiation"
  end
  for _, owned in ipairs((G.jokers and G.jokers.cards) or {}) do
    if owned.center_key == center.key then return nil, nil, "That Founder is already hired" end
  end
  if #((G.jokers and G.jokers.cards) or {}) >= effective_founder_cap(game) then
    return nil, nil, "Founder slots are full"
  end
  return option, center
end

local function commit_legendary_pick()
  local game, sh = G.GAME, G.GAME and G.GAME.shop
  local pending = FounderNegotiation.normalize(game)
  if not pending or pending.phase ~= "complete" then return false, "Negotiation is not complete" end
  local option, center, reason = validate_legendary_pick(game, pending)
  if not option then return false, reason end

  local multiplier = pending.standard_terms and 1.0
    or FounderNegotiation.salary_multiplier(pending.rapport)
  local salary = math.max(1, math.floor(((center.salary or 1) * multiplier) + 0.5))
  local audit = FounderNegotiation.audit(pending, salary, multiplier)
  local po, index = sh.pack_open, pending.option_index
  emplace_founder(center, 0, option.edition, index, #po.options, {
    source = "pack",
    salary = salary,
    negotiation = audit,
    stake_mod = option.stake_mod,
  })
  sh.founder_negotiation = nil
  consume_pack_option(sh, po, index, option, "negotiate")
  return true
end

function Shop.pack_pick(i, expected_open_id)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh, po, session_reason = active_pack(expected_open_id)
  if not sh then return false, session_reason end
  local c = po and po.options[i]
  if not c then return false end
  if po.kind == "tech_evaluation" then return Shop.pack_adopt(i, expected_open_id) end
  if po.kind == "playbook" then
    require("game.playbooks").upgrade(c.key, 1)
    Profile.discover(c.key)
    po.options[i] = false; po.picks_left = po.picks_left - 1
    if po.picks_left <= 0 then sh.pack_open = nil end
    Audio.play("hire")
    Guidance.emit("pack_picked", { family = po.kind, key = c.key })
    FounderEvents.pack_selected({ family = po.kind, center_key = c.key, mode = "pick" })
    return true
  end
  if po.kind == "tech_law" then
    local entry = require("game.consumables").grant(c.key, {
      source = "pack", sell_basis = 0,
    })
    if not entry then return false end
    po.options[i] = false; po.picks_left = po.picks_left - 1
    if po.picks_left <= 0 then sh.pack_open = nil end
    Audio.play("hire")
    Profile.discover(c.key)
    Guidance.emit("pack_picked", { family = po.kind, key = c.key })
    FounderEvents.pack_selected({ family = po.kind, center_key = c.key, mode = "pick" })
    return true
  end
  if po.kind == "moonshot" then
    local entry = require("game.consumables").grant(c.key, {
      source = "pack", sell_basis = 0, moonshot_payload = c.moonshot_payload,
    })
    if not entry then return false end
    po.options[i] = false; po.picks_left = po.picks_left - 1
    if po.picks_left <= 0 then sh.pack_open = nil end
    Audio.play("hire")
    Profile.discover(c.key)
    Guidance.emit("pack_picked", { family = po.kind, key = c.key })
    FounderEvents.pack_selected({ family = po.kind, center_key = c.key, mode = "pick" })
    return true
  end
  local offered = c.center or c
  local canonical_offer = type(offered) == "table" and Centers.get(offered.key) or nil
  if po.kind == "hiring" and canonical_offer and canonical_offer.rarity == "Legendary"
      and not canonical_offer.signature then
    local option, center, pick_reason = validate_legendary_pick(G.GAME, {
      option_index = i,
      pack_key = po.pack_key,
      center_key = canonical_offer.key,
      base_key = canonical_offer.base_form or canonical_offer.key,
    })
    if not option then return false, pick_reason end
    local pending, begin_reason = FounderNegotiation.begin(G.GAME, center, i)
    if not pending then return false, begin_reason end
    Audio.play("select", nil, 0.6)
    return true, FounderNegotiation.view(G.GAME)
  end
  if #G.jokers.cards >= Shop.founder_cap() then
    Guidance.emit("founder_slots_full", { slots = Shop.founder_cap() })
    return false
  end
  emplace_founder(c.center or c, 0, c.edition, i, #po.options); Audio.play("hire")
  Profile.discover((c.center or c).key)
  po.options[i] = false
  po.picks_left = po.picks_left - 1
  if po.picks_left <= 0 then sh.pack_open = nil end             -- pack consumed
  Guidance.emit("pack_picked", { family = po.kind, key = (c.center or c).key })
  FounderEvents.pack_selected({ family = po.kind, center_key = (c.center or c).key, mode = "pick" })
  return true
end

function Shop.pack_skip(expected_open_id)
  local blocked, reason = mutation_blocked(); if blocked then return false, reason end
  local sh, _, session_reason = active_pack(expected_open_id)
  if not sh then return false, session_reason end
  sh.pack_open = nil
  return true -- leave remaining picks (Balatro "Skip")
end

function Shop.pack_fast_forward(expected_open_id)
  local _, po, session_reason = active_pack(expected_open_id)
  if not po then return false, session_reason end
  return PackPresentation.fast_forward(po)
end

function Shop.negotiation_view()
  return FounderNegotiation.view(G.GAME)
end

function Shop.negotiation_answer(choice)
  return FounderNegotiation.answer(G.GAME, choice)
end

function Shop.negotiation_continue()
  local pending = FounderNegotiation.normalize(G.GAME)
  local previous_phase = pending and pending.phase
  local ok, result = FounderNegotiation.continue(G.GAME)
  if not ok then return false, result end
  if result == "complete" then
    local committed, reason = commit_legendary_pick()
    if not committed and pending then pending.phase = previous_phase end
    return committed, reason
  end
  Audio.play("select", nil, 0.5)
  return true, result
end

function Shop.negotiation_standard_terms()
  local pending = FounderNegotiation.normalize(G.GAME)
  local previous_phase = pending and pending.phase
  local ok, result = FounderNegotiation.accept_standard(G.GAME)
  if not ok then return false, result end
  local committed, reason = commit_legendary_pick()
  if not committed and pending then
    pending.phase, pending.standard_terms = previous_phase, nil
  end
  return committed, reason
end

function Shop.negotiation_walk_away()
  local sh = G.GAME and G.GAME.shop
  if not (sh and FounderNegotiation.normalize(G.GAME)) then return false, "No Founder negotiation is pending" end
  sh.founder_negotiation = nil
  sh.pack_open = nil -- walking away forfeits the whole paid pack, including Mega's remaining pick
  Audio.play("fire", nil, 0.5)
  return true
end

function Shop.negotiation_pending()
  return negotiation_pending()
end

return Shop
