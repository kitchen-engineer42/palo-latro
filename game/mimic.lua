-- Deterministic, player-visible gameplay protocol for headless players.
-- The protocol exposes only player-visible state and dispatches through the same
-- handlers used by the graphical game. Agents choose actions; the engine remains
-- the sole authority for legality, transitions, RNG, and scoring.

local Mimic = { VERSION = "palo-latro.mimic.v1" }

local StateMachine = require("game.statemachine")
local Round = require("game.round")
local Shop = require("game.shop")
local Meters = require("game.meters")
local Coverage = require("game.coverage")
local Economy = require("game.economy")
local Pricing = require("game.pricing")
local RunState = require("game.runstate")
local Centers = require("game.centers")
local Deck = require("game.deck")
local TechEvaluation = require("game.tech_evaluation")
local Markets = require("game.markets")
local CardModel = require("game.card")
local Leads = require("game.leads")
local Consumables = require("game.consumables")
local Moonshots = require("game.moonshots")
local FounderActions = require("game.founder_actions")
local CompatSuppression = require("game.compat_suppression")
local Preview = require("game.preview")
local SignaturePair = require("game.signature_pair")

local MAX_SHIP_PREVIEWS = 5
local MAX_SHIP_PREVIEW_EVALUATIONS = 8192
local MAX_AUDIT_EVENTS = 512
local MAX_PUBLIC_AUDIT_EVENTS = 4

local function roadmap_pack(kind)
  return kind == "tech_law" or kind == "moonshot"
end

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function array_shape(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return nil end
    if k > n then n = k end
  end
  for i = 1, n do if t[i] == nil then return nil end end
  return n
end

local function canonical(value, seen)
  local kind = type(value)
  if kind == "nil" then return "n" end
  if kind == "boolean" then return value and "b1" or "b0" end
  if kind == "number" then
    assert(finite(value), "cannot digest a non-finite number")
    return "d" .. string.format("%.17g", value)
  end
  if kind == "string" then return "s" .. #value .. ":" .. value end
  assert(kind == "table" and getmetatable(value) == nil, "digest accepts plain data only")
  seen = seen or {}
  assert(not seen[value], "cannot digest cyclic data")
  seen[value] = true
  local n = array_shape(value)
  local out = { n and "a" or "m" }
  if n then
    for i = 1, n do out[#out + 1] = canonical(value[i], seen) end
  else
    local keys = {}
    for k in pairs(value) do
      assert(type(k) == "string" or type(k) == "number", "unsupported digest key")
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      if type(a) ~= type(b) then return type(a) == "number" end
      return a < b
    end)
    for _, k in ipairs(keys) do
      out[#out + 1] = canonical(k, seen)
      out[#out + 1] = canonical(value[k], seen)
    end
  end
  seen[value] = nil
  return table.concat(out)
end

function Mimic.digest(value)
  local raw = love.data.hash("sha256", canonical(value))
  return love.data.encode("string", "hex", raw)
end

local function state_name()
  for name, id in pairs(G.STATES or {}) do if id == G.STATE then return name end end
  return "UNKNOWN"
end

local function copy_plain(value, seen)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "string" then return value end
  if kind == "number" then return finite(value) and value or nil end
  if kind ~= "table" or getmetatable(value) ~= nil then return nil end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    if type(k) == "string" or type(k) == "number" then
      local item = copy_plain(v, seen)
      if item ~= nil then out[k] = item end
    end
  end
  seen[value] = nil
  return out
end

local function card_id(card, area, index)
  if card.uid then return area .. ":" .. tostring(card.uid) end
  local key = card.center_key or (card.center and card.center.key) or "card"
  if area == "founder" then
    local cfg = card.ability and card.ability.config or {}
    local id = cfg._founder_id
    if type(id) == "number" and id % 1 == 0 and id >= 1 then
      return area .. ":" .. key .. ":" .. tostring(id)
    end
    -- Headless fixtures and legacy live cards may predate lifecycle acquire;
    -- row position is deterministic and collision-free within an observation.
    return area .. ":" .. key .. ":row" .. tostring(index)
  end
  return area .. ":" .. tostring(index) .. ":" .. key
end

local function modifier_view(subject)
  local out = {}
  for _, row in ipairs(CardModel.tech_modifier_rows(subject)) do
    out[#out + 1] = {
      kind = row.kind, key = row.key, label = row.label, description = row.desc,
    }
  end
  return out
end

local function card_view(card, area, index)
  local center = card.center or card
  local users = card.get_users and card:get_users() or card.base_users or center.base_users
  local cfg = card.ability and card.ability.config or {}
  local out = {
    id = card_id(card, area, index),
    key = card.center_key or center.key,
    name = center.name,
    layer = Coverage.display_layer(card),
    sub_role = center.sub_role,
    users = users,
    selected = card.selected == true,
    salary = center.salary,
    ability = center.ability_name,
    face_tag = center.face_tag,
    rules_text = center.rules_text,
    identity = copy_plain(SignaturePair.identity(center)),
    effect = center.rules_text or center.effect_brief or center.desc,
    sell_value = cfg._sell_basis and math.max(0, math.floor(cfg._sell_basis * 0.5)) or nil,
  }
  if center.set == "Founder" then
    out.edition = card.edition
    local terms = CardModel.founder_terms(card, center)
    out.base_salary = terms.base_salary
    out.effective_salary = terms.effective_salary
    out.effect_scale = terms.effect_scale
    out.distilled = terms.distilled
    out.rental_salary_mult = terms.rental_salary_mult
    out.state = CardModel.founder_state_rows(center, card)
    out.action = FounderActions.descriptor(card)
    if out.action then
      out.action.target_uids = FounderActions.available_targets(card)
      local target = out.action.target and out.action.target_uids[1] or nil
      out.action.available = FounderActions.can_activate(card, target)
    end
  elseif center.set == "TechCard" then
    out.layer = CardModel.tech_layer_label(card, center)
    out.edition = card.edition -- compatibility-only; not a Block 6 Tech modifier
    out.enhancement = card.enhancement or card.enh
    out.seal = card.seal
    out.modifier_state = copy_plain(card.modifier_state)
    out.modifiers = modifier_view(card)
    out.law_marks = copy_plain(card.law_marks)
    out.layer_locked = card.layer_locked == true
  elseif center.set == "Consumable" then
    local usable, reason = Consumables.can_use(card)
    out.kind = center.kind
    out.rarity = center.rarity
    out.description = center.desc
    out.target = copy_plain(center.target)
    out.price_units = center.price_units
    out.moonshot_payload = copy_plain(card.moonshot_payload
      or (card.ability and card.ability.config and card.ability.config._moonshot_payload))
    if center.kind == "Moonshot" then
      out.payload_preview = copy_plain(Moonshots.payload_preview(card, nil, G.GAME))
    end
    out.usable = usable == true
    out.unavailable_reason = usable and nil or reason
  end
  return out
end

local function area_view(cards, area)
  local out = {}
  for i, card in ipairs(cards or {}) do out[#out + 1] = card_view(card, area, i) end
  return out
end

local function master_deck_view()
  local out = {}
  for _, entry in ipairs((G.GAME and G.GAME.master_deck) or {}) do
    local center = Centers.get(entry.center_key)
    local effective, status, before_deprecation
    if center then
      effective, status, before_deprecation = CardModel.tech_users(entry, center, G.GAME and G.GAME.era)
    end
    out[#out + 1] = {
      uid = entry.uid,
      key = entry.center_key,
      name = center and center.name,
      layer = center and CardModel.tech_layer_label(entry, center),
      base_users = entry.base_users or (center and center.base_users),
      users_before_deprecation = before_deprecation,
      effective_users = effective,
      deprecated = status and status.state == "deprecated" or false,
      deprecation = status and {
        state = status.state,
        eras_behind = status.eras_behind,
        penalty = status.penalty,
        factor = status.factor,
        latest_supported = status.latest_supported,
        next_supported = status.next_supported,
      } or nil,
      source = entry.source,
      acquired_ante = entry.acquired_ante,
      migrated_from = entry.migrated_from,
      edition = entry.edition, -- compatibility-only; live rules are enhancement + seal
      seal = entry.seal,
      enhancement = entry.enhancement or entry.enh,
      modifier_state = copy_plain(entry.modifier_state),
      modifiers = modifier_view(entry),
      layer_override = entry.layer_override,
      layer_locked = entry.layer_locked == true,
      law_marks = copy_plain(entry.law_marks),
      stickers = copy_plain(entry.stickers),
      identity = copy_plain(SignaturePair.identity(center)),
    }
  end
  table.sort(out, function(a, b)
    if tostring(a.key) == tostring(b.key) then return (a.uid or 0) < (b.uid or 0) end
    return tostring(a.key) < tostring(b.key)
  end)
  return out
end

local function tech_option_view(option, index)
  local center = type(option) == "string" and Centers.get(option)
    or (option and (option.center or Centers.get(option.key or option.center_key)))
  if not center then return nil end
  local subject = type(option) == "table" and option or {}
  local effective, status = CardModel.tech_users(subject, center, G.GAME and G.GAME.era)
  return {
    index = index,
    key = center.key,
    name = center.name,
    layer = CardModel.tech_layer_label(subject, center),
    base_users = center.base_users,
    effective_users = effective,
    enhancement = subject.enhancement or subject.enh,
    seal = subject.seal,
    modifier_state = copy_plain(subject.modifier_state),
    modifiers = modifier_view(subject),
    deprecation = {
      state = status.state,
      eras_behind = status.eras_behind,
      penalty = status.penalty,
      factor = status.factor,
      latest_supported = status.latest_supported,
      next_supported = status.next_supported,
    },
  }
end

local function shop_view()
  local sh = G.GAME and G.GAME.shop
  if not sh then return nil end
  local founders, packs = {}, {}
  for i, offer in ipairs(sh.founders or {}) do
    if offer then
      local founder = offer.center or offer
      founders[#founders + 1] = { index = i, key = founder.key, name = founder.name,
        rarity = offer.rarity, edition = offer.edition, price = Shop.price(offer),
        face_tag = founder.face_tag, rules_text = founder.rules_text,
        identity = copy_plain(SignaturePair.identity(founder)),
        offer_id = offer.offer_id, pinned = offer.pinned == true,
        free = Shop.price(offer) == 0, directive_source = offer.directive_source }
    end
  end
  for i, pack in ipairs(sh.packs or {}) do
    if pack then packs[#packs + 1] = { index = i, key = pack.key, name = pack.name,
      family = pack.family, size = pack.size, price = Shop.pack_price(pack),
      offer_id = pack.offer_id, pinned = pack.pinned == true,
      effective_options = Shop.pack_effective_options(pack),
      free = Shop.pack_price(pack) == 0, directive_source = pack.directive_source } end
  end
  local open
  if sh.pack_open then
    local options = {}
    for i, option in ipairs(sh.pack_open.options or {}) do
      if option then
        if sh.pack_open.kind == "tech_evaluation" then
          options[#options + 1] = tech_option_view(option, i)
        else
          local option_center = option.center or option
          local option_view = { index = i, key = option_center.key, name = option_center.name,
            edition = option.edition, rarity = option.rarity, description = option.desc,
            face_tag = option_center.face_tag, rules_text = option_center.rules_text,
            identity = copy_plain(SignaturePair.identity(option_center)),
            target = copy_plain(option.target), price_units = option.price_units,
            moonshot_payload = copy_plain(option.moonshot_payload) }
          if option.kind == "Moonshot" then
            option_view.payload_preview = copy_plain(Moonshots.payload_preview(
              option, option.moonshot_payload, G.GAME))
          end
          options[#options + 1] = option_view
        end
      end
    end
    open = { open_id = sh.pack_open.open_id, key = sh.pack_open.pack_key,
      name = sh.pack_open.name, kind = sh.pack_open.kind,
      picks_left = sh.pack_open.picks_left, options = options }
    if sh.pack_open.kind == "tech_evaluation" then
      local by_uid = {}
      for _, entry in ipairs(master_deck_view()) do by_uid[entry.uid] = entry end
      local targets = {}
      for _, entry in ipairs(Shop.tech_migration_targets()) do
        if by_uid[entry.uid] then targets[#targets + 1] = by_uid[entry.uid] end
      end
      open.migration_target_uid = sh.pack_open.migration_target_uid
      open.migration_targets = targets
      open.error = sh.pack_open.error
    end
  end
  return {
    shop_id = sh.shop_id,
    revision = sh.revision,
    founders = founders,
    rerolls = sh.rerolls,
    reroll_cost = sh.reroll_cost,
    voucher = sh.voucher and { key = sh.voucher.key, name = sh.voucher.name,
      price = Shop.voucher_price(sh.voucher), free = sh.voucher_free == true } or nil,
    consumable = sh.consumable and { key = sh.consumable.key, name = sh.consumable.name,
      rarity = sh.consumable.rarity, description = sh.consumable.desc,
      target = copy_plain(sh.consumable.target), price_units = sh.consumable.price_units,
      price = Shop.consumable_price(sh.consumable) } or nil,
    packs = packs,
    pack_open = open,
    founder_negotiation = copy_plain(Shop.negotiation_view()),
  }
end

local function add_action(out, id, params, choices, note)
  out[#out + 1] = { id = id, params = params or {}, choices = choices, note = note }
end

local function ids(cards, area)
  local out = {}
  for i, c in ipairs(cards or {}) do out[#out + 1] = card_id(c, area, i) end
  return out
end

local function raise_terms(g)
  local equity_cost, cash_fraction = Economy.raise_terms(g)
  local market = Markets.view(g and g.market)
  local raise_cash_mult = market and market.economy and market.economy.raise_cash_mult or 1
  local cash = math.floor(((g and g.run_best_arr) or 0) * cash_fraction * raise_cash_mult)
  return equity_cost, cash_fraction, raise_cash_mult, cash
end

local function add_raise_action(out, g)
  local equity_cost, cash_fraction, raise_cash_mult, cash = raise_terms(g)
  if cash > 0 and g.raise_available and (g.equity_pct or 0) > equity_cost then
    add_action(out, "raise", {}, nil,
      ("cash=+$%d; equity=-%d%%; valuation=%d; cash_fraction=%.2f; market_mult=%.2f")
        :format(cash, equity_cost, g.run_best_arr or 0, cash_fraction, raise_cash_mult))
  end
end

local function add_consumable_actions(out, g)
  for i, c in ipairs((G.consumables and G.consumables.cards) or {}) do
    local consumable_id = card_id(c, "consumable", i)
    local legal_uses = Consumables.legal_uses(c, g)
    if c.center and c.center.target then
      local count = c.center.target.n or 1
      local exact_choices = {}
      for _, use in ipairs(legal_uses) do
        local choice = { consumable_id = consumable_id, target_ids = {} }
        local area = select(1, Consumables.target_area(c))
        for _, target in ipairs(use.targets) do
          for j, candidate in ipairs((area and area.cards) or {}) do
            if candidate == target then
              choice.target_ids[#choice.target_ids + 1] = card_id(target, use.target_area, j)
              break
            end
          end
        end
        if use.layer then choice.layer = use.layer end
        exact_choices[#exact_choices + 1] = choice
      end
      if #exact_choices > 0 then
        local params = { consumable_id = consumable_id,
          target_ids = { type = "array", count = count },
          target_area = select(2, Consumables.target_area(c)) }
        if c.center.target.layer then params.layer = "string" end
        add_action(out, "use_consumable", params, exact_choices)
      end
    else
      if #legal_uses > 0 then add_action(out, "use_consumable", { consumable_id = consumable_id }) end
    end
    add_action(out, "sell_consumable", { consumable_id = consumable_id })
  end
end

local function founder_activation_choices(cards)
  local plain, targeted = {}, {}
  for i, card in ipairs(cards or {}) do
    local founder_id = card_id(card, "founder", i)
    local descriptor = FounderActions.descriptor(card)
    if descriptor and descriptor.target == "tech_uid" then
      for _, target_uid in ipairs(FounderActions.available_targets(card)) do
        if FounderActions.can_activate(card, target_uid) then
          targeted[#targeted + 1] = { founder_id=founder_id, target_uid=target_uid }
        end
      end
    elseif FounderActions.can_activate(card) then
      plain[#plain + 1] = { founder_id=founder_id }
    end
  end
  return plain, targeted
end

local function add_founder_activation_action(out, cards)
  local plain, targeted = founder_activation_choices(cards)
  if #plain > 0 then add_action(out, "activate_founder", { founder_id="string" }, plain) end
  if #targeted > 0 then
    add_action(out, "activate_founder", { founder_id="string", target_uid="integer" }, targeted)
  end
end

local function lead_action_effect(lead)
  if not lead then return "claim Lead" end
  local name = tostring(lead.name or lead.key or "Lead")
  if lead.key == "warm_intro" then return name .. ": first Founder in next shop costs $0" end
  if lead.amount_cash ~= nil or lead.amount ~= nil then
    return name .. ": +$" .. tostring(lead.amount_cash or lead.amount) .. " on next played blind clear"
  end
  if lead.pack_key then return name .. ": free Hiring Round in next shop" end
  if lead.edition then
    local edition = CardModel.EDITIONS and CardModel.EDITIONS[lead.edition]
    return name .. ": next Founder gains " .. tostring((edition and edition.label) or lead.edition)
  end
  return name .. ": " .. tostring(lead.description or lead.trigger or "queued reward")
end

function Mimic.legal_actions()
  local out, state = {}, G.STATE
  local g = G.GAME or {}
  if state == G.STATES.MARKET_SELECT then
    local choices = {}
    for i, m in ipairs(g.market_choices or {}) do choices[#choices + 1] = { index = i, id = m.id, name = m.name } end
    add_action(out, "choose_market", { index = "integer" }, choices)
  elseif state == G.STATES.BLIND_SELECT then
    add_action(out, "play_blind")
    if Leads.can_skip(g) then
      local lead = Leads.current_offer(g)
      add_action(out, "skip_blind", {}, nil,
        lead_action_effect(lead) .. "; forgo this blind's income, close reward, and shop")
    end
  elseif state == G.STATES.SELECTING_HAND then
    local hand_ids = ids(G.hand and G.hand.cards, "hand")
    if (g.ships_left or 0) > 0 and #hand_ids > 0 then
      add_action(out, "ship", { card_ids = { type = "array", min = 1, max = math.min(g.select_max or 5, #hand_ids) } }, hand_ids)
    end
    if (g.pivots_left or 0) > 0 and #hand_ids > 0 then
      add_action(out, "pivot", { card_ids = { type = "array", min = 1, max = #hand_ids } }, hand_ids)
    end
    if (Meters.get("tech_debt") or 0) > 0 and (g.pivots_left or 0) > 0 then add_action(out, "refactor") end
    add_raise_action(out, g)
    local pivot_cost = Pricing.base_reroll(g, RunState.ANTE_BASE)
      * math.min(2, 1 + (g.market_pivots or 0))
    local has_queueable_market = false
    for _, market in ipairs(Markets.list) do
      if (not g.market or market.id ~= g.market.id) and Markets.can_queue(g, market) then
        has_queueable_market = true
        break
      end
    end
    if has_queueable_market and g.last_market_pivot_ante ~= g.ante and (g.cash or 0) >= pivot_cost then
      add_action(out, "market_pivot", {}, nil,
        "cost=$" .. tostring(pivot_cost) .. "; queues a legal non-current Market for the next blind")
    end
    local founder_ids = ids(G.jokers and G.jokers.cards, "founder")
    if #founder_ids > 0 then
      local fireable, distillable = {}, {}
      for i, card in ipairs(G.jokers.cards) do
        local cfg = card.ability and card.ability.config or {}
        local id = card_id(card, "founder", i)
        if not g.founders_locked and not cfg._unsellable then fireable[#fireable + 1] = id end
        if require("game.founder_lifecycle").can_distill(card) then distillable[#distillable + 1] = id end
      end
      if #fireable > 0 then add_action(out, "fire_founder", { founder_id = "string" }, fireable) end
      if #distillable > 0 then add_action(out, "distill_founder", { founder_id = "string" }, distillable,
        Markets.can_free_distill(g) and "Market upgrade: $0 Salary" or "Generic Distill: half Salary and effect") end
      local promotable = {}
      for i, card in ipairs(G.jokers.cards) do
        if require("game.founder_lifecycle").can_promote(card) then
          promotable[#promotable + 1] = card_id(card, "founder", i)
        end
      end
      if #promotable > 0 then add_action(out, "promote_founder", { founder_id = "string" }, promotable) end
      add_founder_activation_action(out, G.jokers.cards)
    end
    add_consumable_actions(out, g)
  elseif state == G.STATES.TARGET_SELECT then
    local pending = G.PENDING_CONSUMABLE
    if pending and pending.need_layer then
      add_action(out, "choose_target_layer", { layer = "string" },
        { "Frontend", "Backend", "Data", "Infra", "AI" })
    elseif pending then
      local picked, choices = {}, {}
      for _, card in ipairs(pending.picks or {}) do picked[card] = true end
      local area = pending.target_area or select(1, Consumables.target_area(pending.card))
      local area_name = pending.target_area_name or select(2, Consumables.target_area(pending.card))
      for i, card in ipairs((area and area.cards) or {}) do
        if not picked[card] and Consumables.can_target(pending.card, card, g) then
          choices[#choices + 1] = card_id(card, area_name, i)
        end
      end
      if #choices > 0 then add_action(out, "pick_target", { card_id = "string" }, choices) end
    end
    add_action(out, "cancel_targeting")
  elseif state == G.STATES.TECH_DRAFT then
    local choices = {}
    local offers = (g.tech_draft and g.tech_draft.offers) or {}
    for i, key in ipairs((g.tech_draft and g.tech_draft.choices) or {}) do
      choices[#choices + 1] = offers[i] and tech_option_view(offers[i], i) or { index = i, key = key }
    end
    add_action(out, "choose_tech", { index = "integer" }, choices)
    add_raise_action(out, g)
  elseif state == G.STATES.SHOP then
    local sh = g.shop
    local negotiation = Shop.negotiation_view()
    if negotiation then
      if negotiation.phase == "question" then
        local choices = {}
        for _, choice in ipairs((negotiation.question and negotiation.question.choices) or {}) do
          choices[#choices + 1] = { id = choice.id, text = choice.text }
        end
        add_action(out, "answer_founder_negotiation", { choice_id = "string" }, choices)
      elseif negotiation.phase == "feedback" then
        add_action(out, "continue_founder_negotiation")
      end
      add_action(out, "accept_standard_terms", {}, nil,
        "hire now at base Salary $" .. tostring(negotiation.base_salary or 0))
      add_action(out, "walk_away_from_negotiation", {}, nil,
        "forfeit the entire open Hiring Round")
    elseif sh and sh.pack_open then
      add_consumable_actions(out, g)
      if sh.pack_open.kind == "tech_evaluation" then
        local adopt_choices, migrate_choices = {}, {}
        local targets = Shop.tech_migration_targets()
        for i, option in ipairs(sh.pack_open.options or {}) do
          if option then
            if Deck.can_add(g.master_deck, option, g.market) then adopt_choices[#adopt_choices + 1] = i end
            for _, target in ipairs(targets) do
              if TechEvaluation.count(g, option.key, target.uid)
                  < TechEvaluation.copy_cap(option, g) then
                migrate_choices[#migrate_choices + 1] = {
                  index = i, target_uid = target.uid,
                  option_key = option.key, target_key = target.center_key,
                }
              end
            end
          end
        end
        if #adopt_choices > 0 then
          add_action(out, "adopt_pack_option",
            { index = "integer", open_id = sh.pack_open.open_id }, adopt_choices)
          add_action(out, "pick_pack_option",
            { index = "integer", open_id = sh.pack_open.open_id }, adopt_choices,
            "legacy alias for Adopt")
        end
        if #migrate_choices > 0 then
          add_action(out, "migrate_pack_option",
            { index = "integer", target_uid = "integer", open_id = sh.pack_open.open_id }, migrate_choices)
        end
      else
        local choices = {}
        local can_pick = sh.pack_open.kind == "playbook"
          or (roadmap_pack(sh.pack_open.kind) and #(g.consumables or {}) < (g.consumable_slots or 2))
          or (sh.pack_open.kind == "hiring" and #((G.jokers and G.jokers.cards) or {}) < Shop.founder_cap())
        if can_pick then
          for i, option in ipairs(sh.pack_open.options or {}) do if option then choices[#choices + 1] = i end end
        end
        if #choices > 0 then add_action(out, "pick_pack_option",
          { index = "integer", open_id = sh.pack_open.open_id }, choices) end
      end
      add_action(out, "skip_pack", { open_id = sh.pack_open.open_id })
      local fireable = {}
      for i, card in ipairs((G.jokers and G.jokers.cards) or {}) do
        local cfg = card.ability and card.ability.config or {}
        local id = card_id(card, "founder", i)
        if not g.founders_locked and not cfg._unsellable then fireable[#fireable + 1] = id end
      end
      if #fireable > 0 then add_action(out, "fire_founder", { founder_id = "string" }, fireable) end
      add_founder_activation_action(out, G.jokers.cards)
    else
      add_consumable_actions(out, g)
      for i, offer in ipairs((sh and sh.founders) or {}) do
        local price = offer and Shop.price(offer)
        if offer and #((G.jokers and G.jokers.cards) or {}) < Shop.founder_cap()
            and (price == 0 or (g.cash or 0) >= price) then
          add_action(out, "buy_founder", { index=i, shop_id=sh.shop_id,
            shop_revision=sh.revision, offer_id=offer.offer_id })
        end
      end
      if sh and (g.cash or 0) >= (sh.reroll_cost or math.huge) then add_action(out, "reroll_shop") end
      if sh and sh.voucher and (g.cash or 0) >= Shop.voucher_price(sh.voucher) then add_action(out, "buy_voucher") end
      if sh and sh.consumable and #((g and g.consumables) or {}) < (g.consumable_slots or 2)
          and (g.cash or 0) >= Shop.consumable_price(sh.consumable) then add_action(out, "buy_consumable") end
      for i, pack in ipairs((sh and sh.packs) or {}) do
        local price = pack and Shop.pack_price(pack)
        if pack and (price == 0 or (g.cash or 0) >= price) then
          add_action(out, "open_pack", { index=i, shop_id=sh.shop_id,
            shop_revision=sh.revision, offer_id=pack.offer_id })
        end
      end
      add_raise_action(out, g)
      add_founder_activation_action(out, G.jokers and G.jokers.cards)
      if not g.founders_locked then
        local choices = {}
        for i, card in ipairs((G.jokers and G.jokers.cards) or {}) do
          local cfg = card.ability and card.ability.config or {}
          if not cfg._unsellable then choices[#choices + 1] = card_id(card, "founder", i) end
        end
        if #choices > 0 then add_action(out, "fire_founder", { founder_id = "string" }, choices) end
      end
      add_action(out, "leave_shop")
    end
  end
  table.sort(out, function(a, b)
    if a.id ~= b.id then return a.id < b.id end
    return canonical(a) < canonical(b)
  end)
  return out
end

local function targeting_view()
  local pending = G.PENDING_CONSUMABLE
  if not pending then return nil end
  local picks = {}
  local area = pending.target_area or select(1, Consumables.target_area(pending.card))
  local area_name = pending.target_area_name or select(2, Consumables.target_area(pending.card))
  for _, picked in ipairs(pending.picks or {}) do
    for i, card in ipairs((area and area.cards) or {}) do
      if card == picked then picks[#picks + 1] = card_id(card, area_name, i); break end
    end
  end
  local consumable_id
  for i, card in ipairs((G.consumables and G.consumables.cards) or {}) do
    if card == pending.card then consumable_id = card_id(card, "consumable", i); break end
  end
  return {
    consumable_id = consumable_id,
    key = pending.center and pending.center.key,
    picks = picks,
    picks_required = (pending.center and pending.center.target and pending.center.target.n) or 1,
    target_area = area_name,
    need_layer = pending.need_layer == true,
  }
end

local function new_audit()
  return {
    schema_version = 2, -- counters + monotonic event_count + bounded recent_events projection
    counters = {
      events_dropped = 0,
      lead = { eligible_states = 0, skipped = 0 },
      consumable = { usable_states = 0, usable_options = 0, used = 0, sold = 0,
        acquired = 0 },
      tech_evaluation = { decision_states = 0, adopt_options = 0, migrate_options = 0,
        adopted = 0, migrated = 0 },
      founder_activation = { eligible_states = 0, options = 0, activated = 0 },
      negotiation = { answer_states = 0, answer_options = 0, answers = 0,
        continued = 0, standard_terms = 0, walked_away = 0, completed = 0 },
      market = { choice_states = 0, choice_options = 0, selected = 0,
        pivot_eligible_states = 0, pivoted = 0 },
      shop = { decision_states = 0, buyable_founder_options = 0,
        openable_pack_options = 0, founders_bought = 0, packs_opened = 0,
        pack_options_picked = 0, packs_skipped = 0, rerolled = 0,
        vouchers_bought = 0, consumables_bought = 0, left = 0 },
    },
    events = {},
    event_count = 0,
    _captured_steps = {},
  }
end

local function audit_state()
  return Mimic._session and Mimic._session.audit
end

local function audit_view()
  local audit = audit_state()
  if not audit then return nil end
  local recent = {}
  local first = math.max(1, #audit.events - MAX_PUBLIC_AUDIT_EVENTS + 1)
  for index = first, #audit.events do recent[#recent + 1] = copy_plain(audit.events[index]) end
  return {
    schema_version = audit.schema_version,
    counters = copy_plain(audit.counters),
    event_count = audit.event_count,
    recent_events = recent,
  }
end

local function audit_append(event)
  local audit = audit_state()
  if not audit then return end
  audit.event_count = audit.event_count + 1
  if #audit.events >= MAX_AUDIT_EVENTS then
    table.remove(audit.events, 1)
    audit.counters.events_dropped = audit.counters.events_dropped + 1
  end
  audit.events[#audit.events + 1] = event
end

local function compact_ship_preview(cards, preview)
  local layers = {}
  for _, layer in ipairs(Coverage.CORE_ORDER) do
    if preview.coverage.counts[layer] then layers[#layers + 1] = layer end
  end
  return {
    card_ids = cards.ids,
    size = #cards.ids,
    arr = preview.arr,
    app = { key = preview.app and preview.app.key, name = preview.app and preview.app.name },
    coverage = { distinct = preview.coverage.distinct, layers = layers },
    fit = preview.fit,
    reliability = {
      score = preview.reliability.score,
      max = preview.reliability.max,
      multiplier = preview.reliability.multiplier,
    },
  }
end

local function preview_precedes(a, b)
  if a.arr ~= b.arr then return a.arr > b.arr end
  if a.reliability.score ~= b.reliability.score then
    return a.reliability.score > b.reliability.score
  end
  if a.coverage.distinct ~= b.coverage.distinct then
    return a.coverage.distinct > b.coverage.distinct
  end
  if a.size ~= b.size then return a.size < b.size end
  return table.concat(a.card_ids, "\0") < table.concat(b.card_ids, "\0")
end

local function ship_preview_view()
  local g, hand = G.GAME or {}, (G.hand and G.hand.cards) or {}
  if G.STATE ~= G.STATES.SELECTING_HAND or (g.ships_left or 0) <= 0 or #hand == 0 then
    return nil
  end
  local max_cards = math.min(g.select_max or 5, #hand)
  local candidates, evaluated, truncated = {}, 0, false
  local chosen, chosen_index = {}, {}

  local function evaluate_choice()
    if evaluated >= MAX_SHIP_PREVIEW_EVALUATIONS then truncated = true; return false end
    evaluated = evaluated + 1
    local selected, held, selected_ids = {}, {}, {}
    for i, card in ipairs(hand) do
      if chosen_index[i] then
        selected[#selected + 1] = card
        selected_ids[#selected_ids + 1] = card_id(card, "hand", i)
      else
        held[#held + 1] = card
      end
    end
    local preview = Preview.evaluate(selected, { held_cards = held })
    candidates[#candidates + 1] = compact_ship_preview({ ids = selected_ids }, preview)
    return true
  end

  local function combinations(wanted, start_at)
    if #chosen == wanted then return evaluate_choice() end
    local remaining = wanted - #chosen
    for i = start_at, #hand - remaining + 1 do
      chosen[#chosen + 1], chosen_index[i] = i, true
      local keep_going = combinations(wanted, i + 1)
      chosen_index[i], chosen[#chosen] = nil, nil
      if not keep_going then return false end
    end
    return true
  end

  for size = 1, max_cards do
    if not combinations(size, 1) then break end
  end
  table.sort(candidates, preview_precedes)
  local items = {}
  for i = 1, math.min(MAX_SHIP_PREVIEWS, #candidates) do
    candidates[i].rank = i
    items[i] = candidates[i]
  end
  return { limit = MAX_SHIP_PREVIEWS, evaluated = evaluated, truncated = truncated, items = items }
end

local function public_state()
  local g = G.GAME or {}
  local markets = {}
  for i, market in ipairs(g.market_choices or {}) do
    local view = Markets.view(market)
    markets[#markets + 1] = { index = i, id = market.id, name = market.name,
      perk = copy_plain(view.perk), rule = copy_plain(view) }
  end
  local draft = {}
  local draft_offers = (g.tech_draft and g.tech_draft.offers) or {}
  for i, key in ipairs((g.tech_draft and g.tech_draft.choices) or {}) do
    local offer = draft_offers[i]
    draft[#draft + 1] = offer and tech_option_view(offer, i) or { index = i, key = key }
  end
  return {
    protocol = Mimic.VERSION,
    step = g._mimic_step or 0,
    phase = state_name(),
    seed = tostring(g.seed or ""),
    ruleset_version = g.ruleset_version,
    terminal = { done = G.STATE == G.STATES.GAME_OVER, result = g.result, won = g.won == true },
    run = {
      ante = g.ante, blind_index = g.blind_idx, stake = g.stake, cash = g.cash,
      equity_pct = g.equity_pct, runway = g.runway, ships_left = g.ships_left,
      pivots_left = g.pivots_left, cumulative_arr = g.cumulative_arr,
      this_blind_arr = g.this_blind_arr, this_ship_arr = g.this_ship_arr,
      market = copy_plain(Markets.view(g.market)),
      market_state = copy_plain(Markets.active_state(g)),
      pending_market = copy_plain(Markets.view(g.pending_market)),
      blind = copy_plain(g.blind), meters = { tech_debt = Meters.get("tech_debt") or 0 },
      maturity_rung = g.maturity_rung, app_levels = copy_plain(g.app_levels), last_fit = g.last_fit,
      last_ai_maturity = copy_plain(g.last_ai_maturity), product_identity = g.product_identity,
      consumable_slots = g.consumable_slots, founder_slots = g.founder_slots,
      tech_law_state = copy_plain(g.tech_law_state),
      moonshot_state = copy_plain(g.moonshot_state),
      compatibility = copy_plain(CompatSuppression.view(g)),
      last_ship_app_key = g.last_ship_app_key,
      last_ship_coverage = g.last_ship_coverage,
      market_best_fit = g.market_best_fit, last_market_reward = g.last_market_reward,
      skips_run = g.skips_run or 0,
      leads = copy_plain(Leads.view(g)),
      settlement = {
        income = g.last_income or 0,
        efficiency = g.last_efficiency or 0,
        blind_reward = g.last_blind_reward or 0,
        interest = g.last_interest or 0,
        payroll = g.last_payroll or 0,
        market_reward = g.last_market_reward or 0,
      },
    },
    hand = area_view(G.hand and G.hand.cards, "hand"),
    founders = area_view(G.jokers and G.jokers.cards, "founder"),
    consumables = area_view(G.consumables and G.consumables.cards, "consumable"),
    deck = { count = #(g.master_deck or {}), cards = master_deck_view() },
    market_choices = markets,
    tech_draft = draft,
    targeting = targeting_view(),
    shop = shop_view(),
    score_trace = copy_plain(g.score_trace),
    ship_previews = ship_preview_view(),
    audit = audit_view(),
    legal_actions = Mimic.legal_actions(),
  }
end

local function action_specs(observation, id)
  local out = {}
  for _, spec in ipairs(observation.legal_actions or {}) do
    if spec.id == id then out[#out + 1] = spec end
  end
  return out
end

local function action_option_count(observation, id)
  local total = 0
  for _, spec in ipairs(action_specs(observation, id)) do
    total = total + (spec.choices and #spec.choices or 1)
  end
  return total
end

local function audit_capture_opportunity(observation)
  local audit = audit_state()
  if not audit or audit._captured_steps[observation.step] then return end
  audit._captured_steps[observation.step] = true
  local counters, event = audit.counters, {
    kind = "opportunity", step = observation.step, phase = observation.phase,
    ante = observation.run and observation.run.ante,
    blind_index = observation.run and observation.run.blind_index,
  }
  local relevant = false

  local market_choices = action_option_count(observation, "choose_market")
  if market_choices > 0 then
    counters.market.choice_states = counters.market.choice_states + 1
    counters.market.choice_options = counters.market.choice_options + market_choices
    event.market = { choices = market_choices }
    relevant = true
  end
  if action_option_count(observation, "market_pivot") > 0 then
    counters.market.pivot_eligible_states = counters.market.pivot_eligible_states + 1
    event.market = event.market or {}
    event.market.pivot = true
    relevant = true
  end

  if action_option_count(observation, "skip_blind") > 0 then
    counters.lead.eligible_states = counters.lead.eligible_states + 1
    local lead = observation.run and observation.run.leads and observation.run.leads.current
    event.lead = lead and { key = lead.key, name = lead.name } or { available = true }
    relevant = true
  end

  local usable = action_option_count(observation, "use_consumable")
  if usable > 0 then
    counters.consumable.usable_states = counters.consumable.usable_states + 1
    counters.consumable.usable_options = counters.consumable.usable_options + usable
    event.consumable = { usable = usable, owned = #(observation.consumables or {}) }
    relevant = true
  end

  local adopt = action_option_count(observation, "adopt_pack_option")
  local migrate = action_option_count(observation, "migrate_pack_option")
  if adopt + migrate > 0 then
    counters.tech_evaluation.decision_states = counters.tech_evaluation.decision_states + 1
    counters.tech_evaluation.adopt_options = counters.tech_evaluation.adopt_options + adopt
    counters.tech_evaluation.migrate_options = counters.tech_evaluation.migrate_options + migrate
    event.tech_evaluation = { adopt = adopt, migrate = migrate }
    relevant = true
  end

  local activations = action_option_count(observation, "activate_founder")
  if activations > 0 then
    counters.founder_activation.eligible_states = counters.founder_activation.eligible_states + 1
    counters.founder_activation.options = counters.founder_activation.options + activations
    event.founder_activation = { options = activations }
    relevant = true
  end

  local answers = action_option_count(observation, "answer_founder_negotiation")
  if answers > 0 then
    counters.negotiation.answer_states = counters.negotiation.answer_states + 1
    counters.negotiation.answer_options = counters.negotiation.answer_options + answers
    local negotiation = observation.shop and observation.shop.founder_negotiation
    event.negotiation = {
      choices = answers,
      round = negotiation and negotiation.round,
      rounds = negotiation and negotiation.rounds,
      question_id = negotiation and negotiation.question and negotiation.question.id,
    }
    relevant = true
  end

  if observation.phase == "SHOP" then
    local founder_buys = action_option_count(observation, "buy_founder")
    local pack_opens = action_option_count(observation, "open_pack")
    counters.shop.decision_states = counters.shop.decision_states + 1
    counters.shop.buyable_founder_options = counters.shop.buyable_founder_options + founder_buys
    counters.shop.openable_pack_options = counters.shop.openable_pack_options + pack_opens
    event.shop = {
      founder_buys = founder_buys,
      pack_opens = pack_opens,
      reroll = action_option_count(observation, "reroll_shop") > 0,
      voucher = action_option_count(observation, "buy_voucher") > 0,
      consumable = action_option_count(observation, "buy_consumable") > 0,
      leave = action_option_count(observation, "leave_shop") > 0,
    }
    relevant = true
  end
  if relevant then audit_append(event) end
end

local function find_by(array, field, value)
  for _, item in ipairs(array or {}) do if item[field] == value then return item end end
end

local function action_event(before, after, action, category)
  return {
    kind = "action", category = category, action = action.id, step = after.step,
    from_phase = before.phase, to_phase = after.phase,
    ante = before.run and before.run.ante,
    blind_index = before.run and before.run.blind_index,
  }
end

local function audit_record_action(action, before, after)
  local audit = audit_state()
  if not audit then return end
  local counters, id, event = audit.counters, action.id
  local before_consumables, after_consumables = #(before.consumables or {}), #(after.consumables or {})
  if after_consumables > before_consumables then
    counters.consumable.acquired = counters.consumable.acquired
      + (after_consumables - before_consumables)
  end

  if id == "choose_market" then
    counters.market.selected = counters.market.selected + 1
    event = action_event(before, after, action, "market")
    local choice = before.market_choices and before.market_choices[action.index]
    event.market = choice and { id = choice.id, name = choice.name } or nil
  elseif id == "market_pivot" then
    counters.market.pivoted = counters.market.pivoted + 1
    event = action_event(before, after, action, "market")
    local pending = after.run and after.run.pending_market
    event.market = pending and { id = pending.id, name = pending.name } or nil
    event.cash_before, event.cash_after = before.run.cash, after.run.cash
  elseif id == "skip_blind" then
    counters.lead.skipped = counters.lead.skipped + 1
    event = action_event(before, after, action, "lead")
    local lead = before.run and before.run.leads and before.run.leads.current
    event.lead = lead and { key = lead.key, name = lead.name } or nil
    event.skips_before = before.run and before.run.skips_run
    event.skips_after = after.run and after.run.skips_run
  elseif id == "use_consumable" or id == "sell_consumable" then
    local used = id == "use_consumable"
    counters.consumable[used and "used" or "sold"] =
      counters.consumable[used and "used" or "sold"] + 1
    event = action_event(before, after, action, "consumable")
    local card = find_by(before.consumables, "id", action.consumable_id)
    event.consumable = card and { id = card.id, key = card.key, kind = card.kind } or nil
    event.target_ids = copy_plain(action.target_ids)
    event.layer = action.layer
    event.inventory_before, event.inventory_after = before_consumables, after_consumables
  elseif id == "adopt_pack_option" or id == "migrate_pack_option"
      or (id == "pick_pack_option" and before.shop and before.shop.pack_open
        and before.shop.pack_open.kind == "tech_evaluation") then
    local migrated = id == "migrate_pack_option"
    counters.tech_evaluation[migrated and "migrated" or "adopted"] =
      counters.tech_evaluation[migrated and "migrated" or "adopted"] + 1
    event = action_event(before, after, action, "tech_evaluation")
    local pack = before.shop and before.shop.pack_open
    local option = pack and find_by(pack.options, "index", action.index)
    event.option = option and { index = option.index, key = option.key, name = option.name } or nil
    event.target_uid = action.target_uid
    event.deck_before, event.deck_after = before.deck.count, after.deck.count
  elseif id == "activate_founder" then
    counters.founder_activation.activated = counters.founder_activation.activated + 1
    event = action_event(before, after, action, "founder_activation")
    local founder = find_by(before.founders, "id", action.founder_id)
    event.founder = founder and { id = founder.id, key = founder.key, name = founder.name } or nil
    event.target_uid = action.target_uid
    event.cash_before, event.cash_after = before.run.cash, after.run.cash
  elseif id == "answer_founder_negotiation" then
    counters.negotiation.answers = counters.negotiation.answers + 1
    event = action_event(before, after, action, "negotiation")
    local prior = before.shop and before.shop.founder_negotiation
    local current = after.shop and after.shop.founder_negotiation
    event.round = prior and prior.round
    event.question_id = prior and prior.question and prior.question.id
    event.choice_id = action.choice_id
    event.rapport_before, event.rapport_after = prior and prior.rapport, current and current.rapport
    event.projected_salary_after = current and current.projected_salary
  elseif id == "continue_founder_negotiation" or id == "accept_standard_terms"
      or id == "walk_away_from_negotiation" then
    local field = id == "continue_founder_negotiation" and "continued"
      or id == "accept_standard_terms" and "standard_terms" or "walked_away"
    counters.negotiation[field] = counters.negotiation[field] + 1
    local prior = before.shop and before.shop.founder_negotiation
    local current = after.shop and after.shop.founder_negotiation
    if prior and not current and id ~= "walk_away_from_negotiation" then
      counters.negotiation.completed = counters.negotiation.completed + 1
    end
    event = action_event(before, after, action, "negotiation")
    event.round = prior and prior.round
    event.rapport = prior and prior.rapport
    event.projected_salary = prior and prior.projected_salary
    event.completed = prior ~= nil and current == nil and id ~= "walk_away_from_negotiation"
  elseif id == "buy_founder" then
    counters.shop.founders_bought = counters.shop.founders_bought + 1
    event = action_event(before, after, action, "shop")
    local offer = before.shop and find_by(before.shop.founders, "index", action.index)
    event.offer = offer and { index = offer.index, offer_id = offer.offer_id,
      key = offer.key, name = offer.name, price = offer.price } or nil
    event.cash_before, event.cash_after = before.run.cash, after.run.cash
  elseif id == "open_pack" then
    counters.shop.packs_opened = counters.shop.packs_opened + 1
    event = action_event(before, after, action, "shop")
    local pack = before.shop and find_by(before.shop.packs, "index", action.index)
    event.pack = pack and { index = pack.index, offer_id = pack.offer_id, key = pack.key,
      name = pack.name, family = pack.family, price = pack.price } or nil
    event.cash_before, event.cash_after = before.run.cash, after.run.cash
  elseif id == "pick_pack_option" then
    counters.shop.pack_options_picked = counters.shop.pack_options_picked + 1
    event = action_event(before, after, action, "shop")
    local pack = before.shop and before.shop.pack_open
    local option = pack and find_by(pack.options, "index", action.index)
    event.pack = pack and { key = pack.key, name = pack.name, kind = pack.kind } or nil
    event.option = option and { index = option.index, key = option.key, name = option.name } or nil
    event.inventory_before, event.inventory_after = before_consumables, after_consumables
  elseif id == "skip_pack" then
    counters.shop.packs_skipped = counters.shop.packs_skipped + 1
    event = action_event(before, after, action, "shop")
    local pack = before.shop and before.shop.pack_open
    event.pack = pack and { key = pack.key, name = pack.name, kind = pack.kind } or nil
  elseif id == "reroll_shop" then
    counters.shop.rerolled = counters.shop.rerolled + 1
    event = action_event(before, after, action, "shop")
    event.cost = before.shop and before.shop.reroll_cost
    event.revision_before = before.shop and before.shop.revision
    event.revision_after = after.shop and after.shop.revision
    event.cash_before, event.cash_after = before.run.cash, after.run.cash
  elseif id == "buy_voucher" then
    counters.shop.vouchers_bought = counters.shop.vouchers_bought + 1
    event = action_event(before, after, action, "shop")
    event.voucher = before.shop and copy_plain(before.shop.voucher)
    event.cash_before, event.cash_after = before.run.cash, after.run.cash
  elseif id == "buy_consumable" then
    counters.shop.consumables_bought = counters.shop.consumables_bought + 1
    event = action_event(before, after, action, "shop")
    local offer = before.shop and before.shop.consumable
    event.consumable = offer and { key = offer.key, name = offer.name, price = offer.price } or nil
    event.inventory_before, event.inventory_after = before_consumables, after_consumables
    event.cash_before, event.cash_after = before.run.cash, after.run.cash
  elseif id == "leave_shop" then
    counters.shop.left = counters.shop.left + 1
    event = action_event(before, after, action, "shop")
  end
  if event then audit_append(event) end
end

function Mimic.observe()
  local out = public_state()
  out.digest = Mimic.digest(out)
  return out
end

local function action_is_legal(id)
  for _, spec in ipairs(Mimic.legal_actions()) do if spec.id == id then return true end end
  return false
end

local function select_cards(cards, area, requested, min_count, max_count, mutate_selection)
  if type(requested) ~= "table" then return nil, "card_ids must be an array" end
  local count = array_shape(requested)
  if not count then return nil, "card_ids must be a dense array" end
  local by_id, selected, seen = {}, {}, {}
  for i, card in ipairs(cards or {}) do by_id[card_id(card, area, i)] = card end
  for i = 1, count do
    local id = requested[i]
    if type(id) ~= "string" or seen[id] or not by_id[id] then return nil, "card_ids contains an invalid or duplicate id" end
    seen[id], selected[#selected + 1] = true, by_id[id]
  end
  if #selected < min_count or #selected > max_count then return nil, "card_ids count is outside the legal range" end
  if mutate_selection ~= false then
    for _, card in ipairs(cards or {}) do card.selected = false end
    for _, card in ipairs(selected) do card.selected = true end
  end
  return selected
end

local function select_one(cards, area, requested)
  if type(requested) ~= "string" then return nil, "card id must be a string" end
  for i, card in ipairs(cards or {}) do
    if card_id(card, area, i) == requested then
      for _, other in ipairs(cards or {}) do other.selected = false end
      card.selected = true
      return card
    end
  end
  return nil, "unknown card id"
end

local function find_one(cards, area, requested)
  if type(requested) ~= "string" then return nil, "card id must be a string" end
  for i, card in ipairs(cards or {}) do if card_id(card, area, i) == requested then return card end end
  return nil, "unknown card id"
end

local function index_arg(action, list)
  local index = action.index
  if type(index) ~= "number" or index % 1 ~= 0 or not list or not list[index] then return nil, "invalid index" end
  return index
end

local function dispatch(action)
  local id, g = action.id, G.GAME
  if id == "choose_market" then
    local i, err = index_arg(action, g.market_choices); if not i then return nil, err end
    return Round.select_market(g.market_choices[i]) and true or nil, "market selection failed"
  elseif id == "play_blind" then G.FUNCS.play_blind(); return true
  elseif id == "skip_blind" then
    local before_idx, before_skips = g.blind_idx, g.skips_run or 0
    G.FUNCS.skip_blind()
    return ((g.skips_run or 0) == before_skips + 1 and g.blind_idx ~= before_idx)
      and true or nil, "blind skip failed"
  elseif id == "ship" or id == "pivot" then
    local max_count = id == "ship" and math.min(g.select_max or 5, #(G.hand.cards or {})) or #(G.hand.cards or {})
    local _, err = select_cards(G.hand.cards, "hand", action.card_ids, 1, max_count)
    if err then return nil, err end
    G.FUNCS[id](); return true
  elseif id == "refactor" then
    local before_debt, before_pivots = Meters.get("tech_debt") or 0, g.pivots_left or 0
    G.FUNCS.refactor()
    return ((Meters.get("tech_debt") or 0) < before_debt and (g.pivots_left or 0) < before_pivots)
      and true or nil, "refactor failed"
  elseif id == "raise" then
    G.FUNCS.raise()
    return g.raise_available == false and true or nil, "raise failed"
  elseif id == "market_pivot" then
    G.FUNCS.market_pivot()
    return g.last_market_pivot_ante == g.ante and true or nil, "market pivot failed"
  elseif id == "fire_founder" or id == "distill_founder" or id == "promote_founder" or id == "activate_founder" then
    local card, err = find_one(G.jokers.cards, "founder", action.founder_id); if not card then return nil, err end
    local cfg = card.ability and card.ability.config or {}
    if id == "fire_founder" and (g.founders_locked or cfg._unsellable) then
      return nil, "founder cannot be fired"
    end
    if id == "distill_founder" and cfg._distilled then return nil, "founder is already distilled" end
    select_one(G.jokers.cards, "founder", action.founder_id)
    local before_count = #G.jokers.cards
    local fn = id == "fire_founder" and "fire" or id == "distill_founder" and "distill"
      or id == "activate_founder" and "activate_founder" or "promote"
    local activated = G.FUNCS[fn](id == "activate_founder" and action.target_uid or nil)
    if id == "activate_founder" then return activated and true or nil, "founder activation failed" end
    if id == "distill_founder" then return cfg._distilled and true or nil, "founder distillation failed" end
    return #G.jokers.cards < before_count and true or nil, "founder removal failed"
  elseif id == "use_consumable" or id == "sell_consumable" then
    local card, err = find_one(G.consumables.cards, "consumable", action.consumable_id)
    if not card then return nil, err end
    if id == "sell_consumable" then
      select_one(G.consumables.cards, "consumable", action.consumable_id)
      G.FUNCS.sell_consumable(); return true
    end
    local result
    if card.center and card.center.target then
      local target_count = card.center.target.n or 1
      if card.center.target.layer then
        local valid = { Frontend = true, Backend = true, Data = true, Infra = true, AI = true }
        if not valid[action.layer] then return nil, "invalid target layer" end
      end
      local target_area, target_area_name = Consumables.target_area(card)
      local targets, target_err = select_cards((target_area and target_area.cards) or {},
        target_area_name, action.target_ids, target_count, target_count, false)
      if not targets then return nil, target_err end
      local stable_ids = {}
      for _, target in ipairs(targets) do
        stable_ids[#stable_ids + 1] = Consumables.target_id(target, target_area_name)
      end
      result = Consumables.resolve_use(card, { target_ids = stable_ids, layer = action.layer }, { game = g })
    else
      result = Consumables.resolve_use(card, { target_ids = {} }, { game = g })
    end
    return result and result.ok and true or nil, (result and result.reason) or "consumable use failed"
  elseif id == "pick_target" then
    local pending = G.PENDING_CONSUMABLE
    if not pending or pending.need_layer then return nil, "target card is not expected" end
    local target_area = pending.target_area or select(1, Consumables.target_area(pending.card))
    local target_area_name = pending.target_area_name or select(2, Consumables.target_area(pending.card))
    local card, target_err = find_one((target_area and target_area.cards) or {}, target_area_name, action.card_id)
    if not card then return nil, target_err end
    for _, picked in ipairs(pending.picks or {}) do
      if picked == card then return nil, "target card was already picked" end
    end
    local target_ok, target_reason = Consumables.can_target(pending.card, card, g)
    if not target_ok then return nil, target_reason or "invalid consumable target" end
    G.CONSUMABLE_TARGET_PICK(card)
    return true
  elseif id == "choose_target_layer" then
    local pending = G.PENDING_CONSUMABLE
    local valid = { Frontend = true, Backend = true, Data = true, Infra = true, AI = true }
    if not (pending and pending.need_layer and valid[action.layer]) then return nil, "target layer is not expected" end
    local result = G.CONSUMABLE_RESOLVE(action.layer)
    return result and result.ok and true or nil,
      (result and result.reason) or "target layer did not resolve"
  elseif id == "cancel_targeting" then
    if not G.PENDING_CONSUMABLE then return nil, "no consumable is being targeted" end
    G.CONSUMABLE_CANCEL(); return true
  elseif id == "choose_tech" then
    local choices = g.tech_draft and g.tech_draft.choices
    local i, err = index_arg(action, choices); if not i then return nil, err end
    return Round.choose_tech(i) and true or nil, "tech selection failed"
  elseif id == "buy_founder" then
    local i, err = index_arg(action, g.shop and g.shop.founders); if not i then return nil, err end
    if type(action.offer_id) ~= "string" or type(action.shop_id) ~= "number"
        or type(action.shop_revision) ~= "number" then return nil, "Founder offer tokens are required" end
    return Shop.buy(i, action.offer_id, action.shop_revision, action.shop_id)
      and true or nil, "founder purchase failed"
  elseif id == "reroll_shop" then return Shop.reroll() and true or nil, "shop reroll failed"
  elseif id == "buy_voucher" then return Shop.redeem() and true or nil, "voucher purchase failed"
  elseif id == "buy_consumable" then return Shop.buy_consumable() and true or nil, "consumable purchase failed"
  elseif id == "open_pack" then
    local i, err = index_arg(action, g.shop and g.shop.packs); if not i then return nil, err end
    if type(action.offer_id) ~= "string" or type(action.shop_id) ~= "number"
        or type(action.shop_revision) ~= "number" then return nil, "Pack offer tokens are required" end
    return Shop.open_pack(i, action.offer_id, action.shop_revision, action.shop_id)
      and true or nil, "pack open failed"
  elseif id == "pick_pack_option" then
    local i, err = index_arg(action, g.shop and g.shop.pack_open and g.shop.pack_open.options); if not i then return nil, err end
    return Shop.pack_pick(i, action.open_id) and true or nil, "pack pick failed"
  elseif id == "answer_founder_negotiation" then
    if type(action.choice_id) ~= "string" then return nil, "choice_id must be a string" end
    local accepted, reason = Shop.negotiation_answer(action.choice_id)
    return accepted and true or nil, reason or "Founder negotiation answer failed"
  elseif id == "continue_founder_negotiation" then
    local accepted, reason = Shop.negotiation_continue()
    return accepted and true or nil, reason or "Founder negotiation continuation failed"
  elseif id == "accept_standard_terms" then
    local accepted, reason = Shop.negotiation_standard_terms()
    return accepted and true or nil, reason or "Standard terms failed"
  elseif id == "walk_away_from_negotiation" then
    local accepted, reason = Shop.negotiation_walk_away()
    return accepted and true or nil, reason or "Walk away failed"
  elseif id == "adopt_pack_option" then
    local po = g.shop and g.shop.pack_open
    if not (po and po.kind == "tech_evaluation") then return nil, "Tech Evaluation is not open" end
    local i, err = index_arg(action, po.options); if not i then return nil, err end
    local accepted, reason = Shop.pack_adopt(i, action.open_id)
    return accepted and true or nil, reason or "Tech adoption failed"
  elseif id == "migrate_pack_option" then
    local po = g.shop and g.shop.pack_open
    if not (po and po.kind == "tech_evaluation") then return nil, "Tech Evaluation is not open" end
    local i, err = index_arg(action, po.options); if not i then return nil, err end
    if type(action.target_uid) ~= "number" or action.target_uid % 1 ~= 0 then
      return nil, "invalid migration target uid"
    end
    local accepted, reason = Shop.pack_migrate(i, action.target_uid, action.open_id)
    return accepted and true or nil, reason or "Tech migration failed"
  elseif id == "skip_pack" then
    local skipped, reason = Shop.pack_skip(action.open_id)
    return skipped and true or nil, reason or "pack skip failed"
  elseif id == "leave_shop" then G.FUNCS.shop_continue(); return true end
  return nil, "unknown action"
end

local DECISION_STATE = {
  [G.STATES.MARKET_SELECT] = true, [G.STATES.BLIND_SELECT] = true,
  [G.STATES.SELECTING_HAND] = true, [G.STATES.TECH_DRAFT] = true,
  [G.STATES.SHOP] = true, [G.STATES.TARGET_SELECT] = true,
  [G.STATES.GAME_OVER] = true, [G.STATES.MENU] = true,
}

local function settle_headless()
  if not G.MIMIC_HEADLESS then return true end
  for _ = 1, 64 do
    if G.E_MANAGER and G.E_MANAGER.drain then
      local ok, err = G.E_MANAGER:drain()
      if not ok then return nil, err end
    end
    if DECISION_STATE[G.STATE] then return true end
    StateMachine.update(0)
  end
  return nil, "automatic state transition limit exceeded"
end

local apply_internal

local function restore_session(session)
  if not session then return nil, "no deterministic session is available" end
  Mimic.start(copy_plain(session.opts))
  for i, accepted in ipairs(session.actions or {}) do
    local replay = copy_plain(accepted)
    local observation = Mimic.observe()
    replay.expected_step, replay.expected_digest = observation.step, observation.digest
    local restored, err = apply_internal(replay, false)
    if not restored then return nil, "accepted action " .. tostring(i) .. " did not replay: " .. tostring(err) end
  end
  return true
end

apply_internal = function(action, recover)
  if type(action) ~= "table" or type(action.id) ~= "string" then return nil, "action must contain a string id" end
  local before = Mimic.observe()
  if action.expected_step ~= nil and action.expected_step ~= before.step then return nil, "stale action step" end
  if action.expected_digest ~= nil and action.expected_digest ~= before.digest then return nil, "stale action digest" end
  if not action_is_legal(action.id) then return nil, "action is not legal in phase " .. before.phase end
  local ok, result, err = pcall(dispatch, action)
  local failure
  if not ok then failure = "action failed: " .. tostring(result)
  elseif not result then failure = err or "action rejected" end
  if not failure then
    local settle_ok, settled, settle_err = pcall(settle_headless)
    if not settle_ok then failure = "settlement failed: " .. tostring(settled)
    elseif not settled then failure = settle_err end
  end
  if failure then
    if recover ~= false then
      local restored, restore_err = restore_session(Mimic._session)
      if not restored then error(failure .. "; deterministic recovery failed: " .. tostring(restore_err)) end
    end
    return nil, failure
  end
  G.GAME._mimic_step = (G.GAME._mimic_step or 0) + 1
  if Mimic._session then Mimic._session.actions[#Mimic._session.actions + 1] = copy_plain(action) end
  local after = public_state()
  audit_record_action(action, before, after)
  audit_capture_opportunity(after)
  return Mimic.observe()
end

function Mimic.apply(action)
  return apply_internal(action, true)
end

function Mimic.start(opts)
  opts = opts or {}
  StateMachine.prep_stage(G.STAGES.RUN, G.STATES.SELECTING_HAND)
  G.MIMIC_HEADLESS = opts.headless ~= false
  Round.start_run({ seed = assert(opts.seed, "mimic start requires a seed"), stake = opts.stake or 1,
    market_id = opts.market_id })
  G.GAME._mimic_step = 0
  Mimic._session = { opts = copy_plain(opts), actions = {}, audit = new_audit() }
  audit_capture_opportunity(public_state())
  return Mimic.observe()
end

return Mimic
