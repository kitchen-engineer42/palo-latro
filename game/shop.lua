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
local random = RNG.fn("shop")
local pack_random = RNG.fn("packs")
local pack_shop_random = RNG.fn("pack_shop")

local Shop = {}

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

-- Track C B3: Tech Law consumables — 1 offered per shop, ante-scaled price, common-weighted roll.
function Shop.consumable_price(c) return math.max(2, math.floor(ante_scale() * (c.cost_frac or 0.2) + 0.5)) end
function Shop.consumable_sell_value(c)
  local basis = c and c.ability and c.ability.config and c.ability.config._sell_basis
  local center = c and (c.center or c)
  return math.max(1, math.floor((basis or Shop.consumable_price(center)) / 2))
end

local function roll_consumable()
  local cand = {}
  for _, c in ipairs(Centers.pool("Consumable")) do
    local w = (c.rarity == "common") and 3 or 1                  -- Tarot-like: commons are the bread and butter
    for _ = 1, w do cand[#cand + 1] = c end
  end
  if #cand == 0 then return false end
  return cand[random(#cand)]
end

function Shop.buy_consumable()
  local sh = G.GAME.shop
  local c = sh and sh.consumable
  if not c then return false end
  local cost = Shop.consumable_price(c)
  if (G.GAME.cash or 0) < cost then return false end
  local entry = require("game.consumables").grant(c.key)         -- respects the slot cap
  if not entry then return false end                              -- inventory full → don't charge
  entry.sell_basis = cost
  for _, card in ipairs((G.consumables and G.consumables.cards) or {}) do
    if card.ID == entry.card_id then card.ability.config._sell_basis = cost; break end
  end
  G.GAME.cash = G.GAME.cash - cost
  sh.consumable = false
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

function Shop.slots() return G.GAME.shop_founder_slots or 2 end
function Shop.founder_cap() return G.GAME.founder_slots or 5 end

-- (re)roll the whole founder offer row.
local function roll_offers()
  local sh = G.GAME.shop
  sh.founders = {}
  local seen = {}
  for i = 1, Shop.slots() do
    local center = roll_one(seen)
    if center then
      seen[center.key] = true
      local offer = {}; for k, v in pairs(center) do offer[k] = v end
      offer.center, offer.offer_id = center, (G.GAME.ante or 1) .. ":" .. (G.GAME.blind_idx or 1) .. ":" .. i .. ":" .. center.key
      offer.edition = Packs.roll_modifier(RNG.fn("modifier"))
      offer.buy_price = Shop.price(center) + (offer.edition and Pricing.base_reroll(G.GAME, RunState.ANTE_BASE) or 0)
      offer.sell_basis = offer.buy_price
      offer.stake_mod = Stakes.roll_offer_mod(G.GAME, RNG.fn("modifier"))
      sh.founders[i] = offer
    else sh.founders[i] = false end
  end
end

function Shop.enter()
  local voucher = false
  if G.GAME.voucher_offer_ante ~= G.GAME.ante then voucher = roll_voucher(); G.GAME.voucher_offer_ante = G.GAME.ante end
  G.GAME.shop = { founders = {}, rerolls = 0, reroll_cost = Shop.reroll_cost(0),
                  voucher = voucher, voucher_free = voucher and G.GAME.free_voucher_pending or false,
                  consumable = roll_consumable(), packs = {}, pack_open = nil }
  if G.GAME.shop.voucher_free then G.GAME.free_voucher_pending = false end
  roll_offers()
  local seen = {}
  for i = 1, (G.GAME.shop_pack_slots or 2) do
    local pack = Packs.roll_shop(pack_shop_random, seen)
    if pack then seen[pack.key] = true; G.GAME.shop.packs[i] = pack end
  end
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
function Shop.redeem()
  local sh = G.GAME.shop
  local v = sh and sh.voucher
  if not v then return false end
  local cost = Shop.voucher_price(v)
  if (G.GAME.cash or 0) < cost then return false end
  G.GAME.cash = G.GAME.cash - cost
  local m = v.mod or {}
  if m.field then G.GAME[m.field] = (G.GAME[m.field] or 0) + (m.delta or 0) end
  G.GAME.vouchers_owned[v.key] = true
  sh.voucher = false
  Audio.play("hire")
  return true
end

function Shop.reroll()
  local sh = G.GAME.shop
  if not sh or (G.GAME.cash or 0) < sh.reroll_cost then return false end
  G.GAME.cash = G.GAME.cash - sh.reroll_cost
  sh.rerolls = sh.rerolls + 1
  sh.reroll_cost = Shop.reroll_cost(sh.rerolls)
  roll_offers()
  Audio.play("select", nil, 0.5)
  return true
end

function Shop.buy(idx)
  local sh = G.GAME.shop
  local offer = sh and sh.founders[idx]
  if not offer then return false end
  if #G.jokers.cards >= Shop.founder_cap() then
    Guidance.emit("founder_slots_full", { slots = Shop.founder_cap() })
    return false
  end
  local cost = Shop.price(offer)
  if (G.GAME.cash or 0) < cost then return false end
  G.GAME.cash = G.GAME.cash - cost
  local c = offer.center or offer
  local jk = Card({ center = c, T = { x = G.jokers.T.x, y = G.jokers.T.y } })
  G.jokers:emplace(jk)
  if jk.juice_up then jk:juice_up(0.5) end                     -- the new hire pops as it joins the row
  maybe_edition(jk, offer.edition)
  Lifecycle.acquire(jk, { source = "shop", sell_basis = offer.sell_basis, stake_mod = offer.stake_mod })
  sh.founders[idx] = false                                     -- bought slot empties
  Profile.discover(c.key)
  Guidance.emit("founder_bought", { founder = c.key, salary = c.salary or 0 })
  Audio.play("hire")
  return true
end

-- ── Pitch packs (P3) ──────────────────────────────────────────────────────────────────────────────
-- Hiring Rounds draft founders; Playbook Workshops upgrade App Types; Tech Law Packs
-- add consumables. Every definition carries its own Balatro-like size/choice band.
function Shop.pack_price(definition)
  if type(definition) == "number" then
    definition = G.GAME and G.GAME.shop and G.GAME.shop.packs[definition]
  elseif type(definition) == "string" then
    definition = Packs.get(definition)
  end
  return Pricing.pack(G.GAME, RunState.ANTE_BASE, (definition or PACK).size)
end
function Shop.pack_slots() return G.GAME.shop_pack_slots or 2 end

local function emplace_founder(c, sell_basis, edition, source_i, source_count)
  local sx, sy = G.jokers.T.x, G.jokers.T.y
  if not G.SETTINGS.reduced_motion and source_i and source_count then
    local pick_w, gap = 160, 30
    local play_cx = 332 + (G.WINDOW.w - 332) / 2
    local x0 = play_cx - (source_count * pick_w + (source_count - 1) * gap) / 2
    sx = x0 + (source_i - 1) * (pick_w + gap) + (pick_w - Card.FW) / 2
    sy = 360
  end
  local jk = Card({ center = c, T = { x = sx, y = sy } })
  G.jokers:emplace(jk)
  if G.SETTINGS.reduced_motion then
    jk.VT.x, jk.VT.y = jk.T.x, jk.T.y
  end
  if jk.juice_up then jk:juice_up(0.5) end                     -- the new hire pops as it joins the row
  maybe_edition(jk, edition)
  Lifecycle.acquire(jk, { source = "pack", sell_basis = sell_basis or 0 })
end

function Shop.open_pack(idx)
  local sh = G.GAME.shop
  if not sh or not sh.packs[idx] then return false end
  local definition = sh.packs[idx]
  local cost = Shop.pack_price(definition)
  if (G.GAME.cash or 0) < cost then return false end
  local tech_options
  if definition.family == "tech_evaluation" then
    if TechEvaluation.available_count(G.GAME) < definition.options then return false end
    tech_options = TechEvaluation.generate(G.GAME, definition.options, pack_random)
    if #tech_options < definition.options then return false end -- no charge for an exhausted evaluation
  end
  G.GAME.cash = G.GAME.cash - cost
  if definition.family == "tech_evaluation" then
    sh.packs[idx] = false
    local targets = TechEvaluation.deprecated_targets(G.GAME)
    sh.pack_open = { kind = "tech_evaluation", name = definition.name, pack_key = definition.key,
      art_key = definition.art_key, fallback_art = definition.fallback_art,
      options = tech_options, picks_left = definition.picks,
      migration_target_uid = targets[1] and targets[1].uid or nil }
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
    sh.packs[idx] = false
    sh.pack_open = { kind = "playbook", name = definition.name, pack_key = definition.key,
      art_key = definition.art_key, fallback_art = definition.fallback_art,
      options = opts, picks_left = definition.picks }
    local keys = {}; for _, option in ipairs(opts) do keys[#keys + 1] = option.key end
    Profile.discover_many(keys)
    PackPresentation.begin(sh.pack_open, idx, definition)
    Guidance.emit("pack_opened", { family = definition.family, key = definition.key })
    Audio.play("select", nil, 0.6)
    return true
  end
  if definition.family == "tech_law" then
    local pool = Centers.pool("Consumable")
    local opts, seen = {}, {}
    while #opts < definition.options and #opts < #pool do
      local c = pool[pack_random(#pool)]
      if not seen[c.key] then seen[c.key] = true; opts[#opts + 1] = c end
    end
    sh.packs[idx] = false
    sh.pack_open = { kind = "tech_law", name = definition.name, pack_key = definition.key,
      art_key = definition.art_key, fallback_art = definition.fallback_art,
      options = opts, picks_left = definition.picks }
    local keys = {}; for _, option in ipairs(opts) do keys[#keys + 1] = option.key end
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
  sh.packs[idx] = false
  sh.pack_open = { kind = "hiring", name = definition.name, pack_key = definition.key,
    art_key = definition.art_key, fallback_art = definition.fallback_art,
    options = opts, picks_left = definition.picks }
  local keys = {}; for _, option in ipairs(opts) do keys[#keys + 1] = (option.center or option).key end
  Profile.discover_many(keys)
  PackPresentation.begin(sh.pack_open, idx, definition)
  Guidance.emit("pack_opened", { family = definition.family, key = definition.key })
  Audio.play("select", nil, 0.6)
  return true
end

local function consume_pack_option(sh, po, index, option, mode)
  po.options[index] = false
  po.picks_left = po.picks_left - 1
  Profile.discover(option.key)
  Audio.play("hire")
  Guidance.emit("pack_picked", { family = po.kind, key = option.key, mode = mode })
  if po.picks_left <= 0 then sh.pack_open = nil end
end

function Shop.tech_migration_targets()
  return TechEvaluation.deprecated_targets(G.GAME)
end

function Shop.pack_set_migration_target(uid)
  local po = G.GAME and G.GAME.shop and G.GAME.shop.pack_open
  if not (po and po.kind == "tech_evaluation" and uid ~= nil) then return false end
  for _, entry in ipairs(TechEvaluation.deprecated_targets(G.GAME)) do
    if entry.uid == uid then po.migration_target_uid = uid; po.error = nil; return true end
  end
  return false
end

function Shop.pack_cycle_migration_target(delta)
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

function Shop.pack_adopt(i)
  local sh = G.GAME and G.GAME.shop
  local po = sh and sh.pack_open
  local option = po and po.kind == "tech_evaluation" and po.options[i]
  if not option then return false end
  local entry, reason = TechEvaluation.adopt(option.key, G.GAME)
  if not entry then po.error = reason; return false, reason end
  po.error = nil
  consume_pack_option(sh, po, i, option, "adopt")
  return true
end

function Shop.pack_migrate(i, target_uid)
  local sh = G.GAME and G.GAME.shop
  local po = sh and sh.pack_open
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

function Shop.pack_pick(i)
  local sh = G.GAME.shop
  local po = sh and sh.pack_open
  local c = po and po.options[i]
  if not c then return false end
  if po.kind == "tech_evaluation" then return Shop.pack_adopt(i) end
  if po.kind == "playbook" then
    require("game.playbooks").upgrade(c.key, 1)
    Profile.discover(c.key)
    po.options[i] = false; po.picks_left = po.picks_left - 1
    if po.picks_left <= 0 then sh.pack_open = nil end
    Audio.play("hire")
    Guidance.emit("pack_picked", { family = po.kind, key = c.key })
    return true
  end
  if po.kind == "tech_law" then
    local entry = require("game.consumables").grant(c.key)
    if not entry then return false end
    po.options[i] = false; po.picks_left = po.picks_left - 1
    if po.picks_left <= 0 then sh.pack_open = nil end
    Audio.play("hire")
    Profile.discover(c.key)
    Guidance.emit("pack_picked", { family = po.kind, key = c.key })
    return true
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
  return true
end

function Shop.pack_skip()
  if G.GAME.shop then G.GAME.shop.pack_open = nil end           -- leave remaining picks (Balatro "Skip")
end

return Shop
