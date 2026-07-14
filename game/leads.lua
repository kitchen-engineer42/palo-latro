-- Serializable blind-skip rewards. Small and Big offers are pre-rolled for the
-- whole Ante; claimed Leads wait in a FIFO queue until their authored trigger.

local Definitions = require("data.gameplay.leads")
local Economy = require("game.economy")
local RNG = require("game.rng")

local Leads = { definitions = Definitions }
local EDITIONS = { "open_source", "battle_tested", "viral" }
local VALID_EDITIONS = { open_source = true, battle_tested = true, viral = true }

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function ordered_definitions()
  local out = {}
  for _, definition in pairs(Definitions) do out[#out + 1] = definition end
  table.sort(out, function(a, b) return a.order < b.order end)
  return out
end

local ORDERED = ordered_definitions()

function Leads.get(key) return Definitions[key] end
function Leads.all() return copy(ORDERED) end

local function whole(value, minimum)
  return type(value) == "number" and value == math.floor(value) and value >= (minimum or 0)
end

local function valid_offer(offer, ante, blind_idx)
  if type(offer) ~= "table" or not Definitions[offer.key] then return false end
  if not whole(offer.ante, 1) or not whole(offer.blind_idx, 1) or offer.blind_idx > 2 then return false end
  if ante and offer.ante ~= ante then return false end
  if blind_idx and offer.blind_idx ~= blind_idx then return false end
  if offer.key == "term_sheet" and (not whole(offer.amount_units, 0)
      or not whole(offer.amount_cash, 0)) then return false end
  if offer.key == "press_coverage" and not VALID_EDITIONS[offer.edition] then return false end
  return true
end

local function valid_instance(instance, include_redeemed)
  if type(instance) ~= "table" or not Definitions[instance.key] or not whole(instance.id, 1) then return false end
  if not whole(instance.ante, 1) or not whole(instance.blind_idx, 1) or instance.blind_idx > 3 then return false end
  if not whole(instance.granted_bid, 0) then return false end
  if instance.status ~= "queued" and not (include_redeemed and instance.status == "redeemed") then return false end
  if instance.key == "term_sheet" and (not whole(instance.amount_units, 0)
      or not whole(instance.amount_cash, 0)) then return false end
  if instance.key == "press_coverage" and not VALID_EDITIONS[instance.edition] then return false end
  return true
end

-- Save-boundary repair: malformed rows are discarded, duplicate ids keep their
-- first occurrence, and the monotonic allocator resumes above every valid id.
function Leads.normalize(g)
  if not g then return nil end
  local queue, queue_ids, history, history_ids, maximum = {}, {}, {}, {}, 0
  for _, instance in ipairs(type(g.lead_queue) == "table" and g.lead_queue or {}) do
    if valid_instance(instance) and not queue_ids[instance.id] then
      queue_ids[instance.id] = true
      queue[#queue + 1] = instance
      maximum = math.max(maximum, instance.id)
    end
  end
  for _, instance in ipairs(type(g.lead_history) == "table" and g.lead_history or {}) do
    if valid_instance(instance, true) and not history_ids[instance.id] then
      history_ids[instance.id] = true
      history[#history + 1] = instance
      maximum = math.max(maximum, instance.id)
    end
  end
  if whole(g.lead_next_id, 0) then maximum = math.max(maximum, g.lead_next_id) end
  g.lead_queue, g.lead_history, g.lead_next_id = queue, history, maximum
  return g
end

local function cash_for_units(g, units, ante)
  local RunState = require("game.runstate")
  local projection = { ante = ante or (g and g.ante) or 1 }
  return (units or 0) * Economy.unit(projection, RunState.ANTE_BASE)
end

local function instance_view(instance, g)
  if not instance then return nil end
  local definition = Definitions[instance.key]
  if not definition then return nil end
  local out = copy(definition)
  for key, value in pairs(instance) do out[key] = copy(value) end
  out.description = definition.description
  out.trigger = definition.trigger
  if out.key == "term_sheet" then
    out.amount_cash = out.amount_cash or cash_for_units(g, out.amount_units, out.ante)
    out.amount = out.amount_cash
  end
  return out
end

local function roll_offer(g, ante, blind_idx, excluded)
  local pool = {}
  for _, definition in ipairs(ORDERED) do
    if not (excluded and excluded[definition.key]) then pool[#pool + 1] = definition end
  end
  local definition = pool[RNG.int("lead", #pool)]
  local offer = { key = definition.key, ante = ante, blind_idx = blind_idx, status = "offered" }
  if definition.key == "term_sheet" then
    offer.amount_units = definition.amount_units
    offer.amount_cash = cash_for_units(g, definition.amount_units, ante)
  elseif definition.key == "demo_day" then
    offer.pack_key = definition.pack_key
  elseif definition.key == "press_coverage" then
    offer.edition = EDITIONS[RNG.int("lead_edition", #EDITIONS)]
  end
  return offer
end

function Leads.ensure_ante(g, ante)
  if not g then return nil end
  ante = ante or g.ante or 1
  g.lead_offers = g.lead_offers or {}
  local existing = g.lead_offers[ante]
  if existing and valid_offer(existing[1], ante, 1) and valid_offer(existing[2], ante, 2)
      and existing[1].key ~= existing[2].key then return existing end
  local offers = {}
  offers[1] = roll_offer(g, ante, 1)
  offers[2] = roll_offer(g, ante, 2, { [offers[1].key] = true })
  g.lead_offers[ante] = offers
  return offers
end

function Leads.offer_for(g, blind_idx, ante)
  if not g or blind_idx == 3 then return nil end
  ante = ante or g.ante
  local offers = g.lead_offers and g.lead_offers[ante]
  local offer = offers and offers[blind_idx]
  return valid_offer(offer, ante, blind_idx) and instance_view(offer, g) or nil
end

function Leads.current_offer(g) return Leads.offer_for(g, g and g.blind_idx, g and g.ante) end

function Leads.can_skip(g)
  return g ~= nil and (g.blind_idx == 1 or g.blind_idx == 2) and Leads.current_offer(g) ~= nil
end

local function history_entry(g, id)
  if not whole(id, 1) then return nil end
  for _, row in ipairs(g.lead_history or {}) do
    if valid_instance(row, true) and row.id == id then return row end
  end
end

local function set_status(g, instance, status, details)
  instance.status = status
  local history = history_entry(g, instance.id)
  if history then
    history.status = status
    for key, value in pairs(details or {}) do history[key] = copy(value) end
  end
  for key, value in pairs(details or {}) do instance[key] = copy(value) end
end

local function remove_pending(g, instance)
  for index, queued in ipairs(g.lead_queue or {}) do
    if queued == instance or (whole(instance.id, 1) and valid_instance(queued) and queued.id == instance.id) then
      table.remove(g.lead_queue, index)
      return
    end
  end
end

local function redeem(g, instance, details)
  set_status(g, instance, "redeemed", details)
  remove_pending(g, instance)
end

function Leads.grant(g, key, opts)
  opts = opts or {}
  local definition = Definitions[key]
  if not (g and definition) then return nil, "Unknown Lead" end
  if key == "press_coverage" and opts.offer and opts.offer.edition
      and not VALID_EDITIONS[opts.offer.edition] then return nil, "Unknown Founder edition" end
  Leads.normalize(g)
  g.lead_next_id = (g.lead_next_id or 0) + 1
  local offered = opts.offer or {}
  local instance = {
    id = g.lead_next_id, key = key, status = "queued", source = opts.source or "granted",
    ante = opts.ante or offered.ante or g.ante,
    blind_idx = opts.blind_idx or offered.blind_idx or g.blind_idx,
    granted_bid = g._bid or 0,
  }
  if key == "term_sheet" then
    instance.amount_units = definition.amount_units
    instance.amount_cash = offered.amount_cash or cash_for_units(g, definition.amount_units, instance.ante)
  elseif key == "demo_day" then
    instance.pack_key = definition.pack_key
  elseif key == "press_coverage" then
    instance.edition = offered.edition or EDITIONS[RNG.int("lead_edition", #EDITIONS)]
  end
  g.lead_queue[#g.lead_queue + 1] = instance
  g.lead_history[#g.lead_history + 1] = copy(instance)
  g.last_lead = instance_view(instance, g)
  return instance
end

function Leads.grant_random(g, source)
  local definition = ORDERED[RNG.int("lead_bonus", #ORDERED)]
  return Leads.grant(g, definition.key, { source = source or "bonus" })
end

function Leads.claim_current(g)
  if not Leads.can_skip(g) then return nil, "This blind cannot be skipped" end
  local offer = Leads.current_offer(g)
  return Leads.grant(g, offer.key, {
    source = "skip", offer = offer, ante = g.ante, blind_idx = g.blind_idx,
  })
end

function Leads.on_blind_won(g)
  local total, redeemed = 0, {}
  local snapshot = {}
  for _, instance in ipairs((g and g.lead_queue) or {}) do
    if valid_instance(instance) then snapshot[#snapshot + 1] = instance end
  end
  for _, instance in ipairs(snapshot) do
    if instance.key == "term_sheet" and (g._bid or 0) > (instance.granted_bid or 0) then
      total = total + (instance.amount_cash or 0)
      redeemed[#redeemed + 1] = instance_view(instance, g)
      redeem(g, instance, { redeemed_ante = g.ante, redeemed_blind_idx = g.blind_idx,
        amount_cash = instance.amount_cash or 0 })
    end
  end
  if total > 0 then g.cash = (g.cash or 0) + total end
  g.last_lead_cash = total
  return { cash = total, redeemed = redeemed }
end

local function first_pending(g, key)
  for _, instance in ipairs((g and g.lead_queue) or {}) do
    if valid_instance(instance) and instance.key == key then return instance end
  end
end

function Leads.on_shop_enter(g, shop)
  if not (g and shop) then return {} end
  local applied = {}
  local warm = first_pending(g, "warm_intro")
  if warm then
    for index, offer in ipairs(shop.founders or {}) do
      if offer then
        offer.buy_price, offer.sell_basis = 0, 0
        offer.lead_free, offer.lead_id = true, warm.id
        redeem(g, warm, { redeemed_ante = g.ante, redeemed_blind_idx = g.blind_idx,
          shop_effect = "free_founder", shop_index = index })
        applied[#applied + 1] = instance_view(warm, g)
        break
      end
    end
  end
  local demo = first_pending(g, "demo_day")
  if demo then
    local pack = require("game.packs").get(demo.pack_key or "hiring")
    if pack then
      local offer = copy(pack)
      offer.price_override, offer.lead_free, offer.lead_id = 0, true, demo.id
      shop.packs[#shop.packs + 1] = offer
      redeem(g, demo, { redeemed_ante = g.ante, redeemed_blind_idx = g.blind_idx,
        shop_effect = "free_pack", shop_index = #shop.packs })
      applied[#applied + 1] = instance_view(demo, g)
    end
  end
  g.last_shop_leads = applied
  return applied
end

function Leads.on_founder_acquired(g, card)
  local press = first_pending(g, "press_coverage")
  if not (press and card) then return nil end
  card.edition = press.edition
  redeem(g, press, { redeemed_ante = g.ante, redeemed_blind_idx = g.blind_idx,
    founder_key = card.center_key or (card.center and card.center.key), edition = press.edition })
  return press.edition
end

function Leads.pending(g)
  local out = {}
  for _, instance in ipairs((g and g.lead_queue) or {}) do
    if valid_instance(instance) then out[#out + 1] = instance_view(instance, g) end
  end
  return out
end


function Leads.history(g)
  local out = {}
  for _, instance in ipairs((g and g.lead_history) or {}) do
    if valid_instance(instance, true) then out[#out + 1] = instance_view(instance, g) end
  end
  return out
end

function Leads.view(g)
  return {
    current = Leads.current_offer(g),
    offers = { small = Leads.offer_for(g, 1), big = Leads.offer_for(g, 2) },
    pending = Leads.pending(g), history = Leads.history(g), can_skip = Leads.can_skip(g),
  }
end

return Leads
