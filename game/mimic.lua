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
  if area == "founder" then return area .. ":" .. key end
  return area .. ":" .. tostring(index) .. ":" .. key
end

local function card_view(card, area, index)
  local center = card.center or card
  local users = card.get_users and card:get_users() or card.base_users or center.base_users
  local cfg = card.ability and card.ability.config or {}
  return {
    id = card_id(card, area, index),
    key = card.center_key or center.key,
    name = center.name,
    layer = Coverage.display_layer(card),
    sub_role = center.sub_role,
    users = users,
    selected = card.selected == true,
    edition = card.edition,
    seal = card.seal,
    salary = center.salary,
    ability = center.ability_name,
    effect = center.effect_brief or center.ability_text or center.desc,
    sell_value = cfg._sell_basis and math.max(0, math.floor(cfg._sell_basis * 0.5)) or nil,
  }
end

local function area_view(cards, area)
  local out = {}
  for i, card in ipairs(cards or {}) do out[#out + 1] = card_view(card, area, i) end
  return out
end

local function master_deck_view()
  local out = {}
  for _, entry in ipairs((G.GAME and G.GAME.master_deck) or {}) do
    out[#out + 1] = {
      uid = entry.uid,
      key = entry.center_key,
      edition = entry.edition,
      seal = entry.seal,
      layer_override = entry.layer_override,
      stickers = copy_plain(entry.stickers),
    }
  end
  table.sort(out, function(a, b)
    if tostring(a.key) == tostring(b.key) then return (a.uid or 0) < (b.uid or 0) end
    return tostring(a.key) < tostring(b.key)
  end)
  return out
end

local function shop_view()
  local sh = G.GAME and G.GAME.shop
  if not sh then return nil end
  local founders, packs = {}, {}
  for i, offer in ipairs(sh.founders or {}) do
    if offer then
      founders[#founders + 1] = { index = i, key = offer.key, name = offer.name,
        rarity = offer.rarity, edition = offer.edition, price = Shop.price(offer) }
    end
  end
  for i, pack in ipairs(sh.packs or {}) do
    if pack then packs[#packs + 1] = { index = i, key = pack.key, name = pack.name,
      family = pack.family, size = pack.size, price = Shop.pack_price(pack) } end
  end
  local open
  if sh.pack_open then
    local options = {}
    for i, option in ipairs(sh.pack_open.options or {}) do
      if option then options[#options + 1] = { index = i, key = option.key, name = option.name,
        edition = option.edition } end
    end
    open = { key = sh.pack_open.pack_key, name = sh.pack_open.name, kind = sh.pack_open.kind,
      picks_left = sh.pack_open.picks_left, options = options }
  end
  return {
    founders = founders,
    rerolls = sh.rerolls,
    reroll_cost = sh.reroll_cost,
    voucher = sh.voucher and { key = sh.voucher.key, name = sh.voucher.name,
      price = Shop.voucher_price(sh.voucher), free = sh.voucher_free == true } or nil,
    consumable = sh.consumable and { key = sh.consumable.key, name = sh.consumable.name,
      price = Shop.consumable_price(sh.consumable) } or nil,
    packs = packs,
    pack_open = open,
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

function Mimic.legal_actions()
  local out, state = {}, G.STATE
  local g = G.GAME or {}
  if state == G.STATES.MARKET_SELECT then
    local choices = {}
    for i, m in ipairs(g.market_choices or {}) do choices[#choices + 1] = { index = i, id = m.id, name = m.name } end
    add_action(out, "choose_market", { index = "integer" }, choices)
  elseif state == G.STATES.BLIND_SELECT then
    add_action(out, "play_blind")
    if (g.blind_idx or 3) < 3 then add_action(out, "skip_blind") end
  elseif state == G.STATES.SELECTING_HAND then
    local hand_ids = ids(G.hand and G.hand.cards, "hand")
    if (g.ships_left or 0) > 0 and #hand_ids > 0 then
      add_action(out, "ship", { card_ids = { type = "array", min = 1, max = math.min(g.select_max or 5, #hand_ids) } }, hand_ids)
    end
    if (g.pivots_left or 0) > 0 and #hand_ids > 0 then
      add_action(out, "pivot", { card_ids = { type = "array", min = 1, max = #hand_ids } }, hand_ids)
    end
    if (Meters.get("tech_debt") or 0) > 0 and (g.pivots_left or 0) > 0 then add_action(out, "refactor") end
    local equity_cost = Economy.raise_terms(g)
    if g.raise_available and (g.equity_pct or 0) > equity_cost then add_action(out, "raise") end
    local pivot_cost = Pricing.base_reroll(g, RunState.ANTE_BASE)
      * math.min(2, 1 + (g.market_pivots or 0))
    if g.last_market_pivot_ante ~= g.ante and (g.cash or 0) >= pivot_cost then
      add_action(out, "market_pivot", {}, nil, "cost=" .. tostring(pivot_cost))
    end
    local founder_ids = ids(G.jokers and G.jokers.cards, "founder")
    if #founder_ids > 0 then
      local fireable, distillable = {}, {}
      for i, card in ipairs(G.jokers.cards) do
        local cfg = card.ability and card.ability.config or {}
        local id = card_id(card, "founder", i)
        if not g.founders_locked and not cfg._unsellable then fireable[#fireable + 1] = id end
        if not cfg._distilled then distillable[#distillable + 1] = id end
      end
      if #fireable > 0 then add_action(out, "fire_founder", { founder_id = "string" }, fireable) end
      if #distillable > 0 then add_action(out, "distill_founder", { founder_id = "string" }, distillable) end
      add_action(out, "promote_founder", { founder_id = "string" }, founder_ids)
    end
    for i, c in ipairs((G.consumables and G.consumables.cards) or {}) do
      local action = { consumable_id = card_id(c, "consumable", i) }
      local usable = true
      if c.center and c.center.target then
        local count = c.center.target.n or 1
        usable = #hand_ids >= count
        action.target_ids = { type = "array", count = count, choices = hand_ids }
        if c.center.target.layer then action.layer = { "Frontend", "Backend", "Data", "Infra", "AI" } end
      else
        for _, op in ipairs((c.center and c.center.ops) or {}) do
          if (op.k == "destroy" and (op.select == "max_users" or op.select == "min_users"))
              or (op.k == "mint" and (op.source == "max_users" or op.source == "min_users")) then
            usable = #hand_ids + #((G.deck and G.deck.cards) or {}) > 0
          end
        end
      end
      if usable then add_action(out, "use_consumable", action) end
      add_action(out, "sell_consumable", { consumable_id = action.consumable_id })
    end
  elseif state == G.STATES.TARGET_SELECT then
    local pending = G.PENDING_CONSUMABLE
    if pending and pending.need_layer then
      add_action(out, "choose_target_layer", { layer = "string" },
        { "Frontend", "Backend", "Data", "Infra", "AI" })
    elseif pending then
      local picked, choices = {}, {}
      for _, card in ipairs(pending.picks or {}) do picked[card] = true end
      for i, card in ipairs((G.hand and G.hand.cards) or {}) do
        if not picked[card] then choices[#choices + 1] = card_id(card, "hand", i) end
      end
      if #choices > 0 then add_action(out, "pick_target", { card_id = "string" }, choices) end
    end
    add_action(out, "cancel_targeting")
  elseif state == G.STATES.TECH_DRAFT then
    local choices = {}
    for i, key in ipairs((g.tech_draft and g.tech_draft.choices) or {}) do choices[#choices + 1] = { index = i, key = key } end
    add_action(out, "choose_tech", { index = "integer" }, choices)
    local equity_cost = Economy.raise_terms(g)
    if g.raise_available and (g.equity_pct or 0) > equity_cost then add_action(out, "raise") end
  elseif state == G.STATES.SHOP then
    local sh = g.shop
    if sh and sh.pack_open then
      local choices = {}
      local can_pick = sh.pack_open.kind == "playbook"
        or (sh.pack_open.kind == "tech_law" and #(g.consumables or {}) < (g.consumable_slots or 2))
        or (sh.pack_open.kind == "hiring" and #((G.jokers and G.jokers.cards) or {}) < Shop.founder_cap())
      if can_pick then
        for i, option in ipairs(sh.pack_open.options or {}) do if option then choices[#choices + 1] = i end end
      end
      if #choices > 0 then add_action(out, "pick_pack_option", { index = "integer" }, choices) end
      add_action(out, "skip_pack")
    else
      for i, offer in ipairs((sh and sh.founders) or {}) do
        if offer and #((G.jokers and G.jokers.cards) or {}) < Shop.founder_cap()
            and (g.cash or 0) >= Shop.price(offer) then add_action(out, "buy_founder", { index = i }) end
      end
      if sh and (g.cash or 0) >= (sh.reroll_cost or math.huge) then add_action(out, "reroll_shop") end
      if sh and sh.voucher and (g.cash or 0) >= Shop.voucher_price(sh.voucher) then add_action(out, "buy_voucher") end
      if sh and sh.consumable and #((g and g.consumables) or {}) < (g.consumable_slots or 2)
          and (g.cash or 0) >= Shop.consumable_price(sh.consumable) then add_action(out, "buy_consumable") end
      for i, pack in ipairs((sh and sh.packs) or {}) do
        if pack and (g.cash or 0) >= Shop.pack_price(pack) then add_action(out, "open_pack", { index = i }) end
      end
      local equity_cost = Economy.raise_terms(g)
      if g.raise_available and (g.equity_pct or 0) > equity_cost then add_action(out, "raise") end
      if not g.founders_locked then
        local choices = {}
        for i, card in ipairs((G.jokers and G.jokers.cards) or {}) do
          local cfg = card.ability and card.ability.config or {}
          if not cfg._unsellable then choices[#choices + 1] = card_id(card, "founder", i) end
        end
        if #choices > 0 then add_action(out, "fire_founder", { founder_id = "string" }, choices) end
      end
      for i, card in ipairs((G.consumables and G.consumables.cards) or {}) do
        add_action(out, "sell_consumable", { consumable_id = card_id(card, "consumable", i) })
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
  for _, picked in ipairs(pending.picks or {}) do
    for i, card in ipairs((G.hand and G.hand.cards) or {}) do
      if card == picked then picks[#picks + 1] = card_id(card, "hand", i); break end
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
    need_layer = pending.need_layer == true,
  }
end

local function public_state()
  local g = G.GAME or {}
  local markets = {}
  for i, market in ipairs(g.market_choices or {}) do markets[#markets + 1] = {
    index = i, id = market.id, name = market.name, perk = copy_plain(market.perk) } end
  local draft = {}
  for i, key in ipairs((g.tech_draft and g.tech_draft.choices) or {}) do draft[#draft + 1] = { index = i, key = key } end
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
      market = g.market and { id = g.market.id, name = g.market.name } or nil,
      blind = copy_plain(g.blind), meters = { tech_debt = Meters.get("tech_debt") or 0 },
      maturity_rung = g.maturity_rung, app_levels = copy_plain(g.app_levels), last_fit = g.last_fit,
      consumable_slots = g.consumable_slots, founder_slots = g.founder_slots,
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
    legal_actions = Mimic.legal_actions(),
  }
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

local function select_cards(cards, area, requested, min_count, max_count)
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
  for _, card in ipairs(cards or {}) do card.selected = false end
  for _, card in ipairs(selected) do card.selected = true end
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
  elseif id == "skip_blind" then G.FUNCS.skip_blind(); return true
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
  elseif id == "fire_founder" or id == "distill_founder" or id == "promote_founder" then
    local card, err = find_one(G.jokers.cards, "founder", action.founder_id); if not card then return nil, err end
    local cfg = card.ability and card.ability.config or {}
    if id == "fire_founder" and (g.founders_locked or cfg._unsellable) then
      return nil, "founder cannot be fired"
    end
    if id == "distill_founder" and cfg._distilled then return nil, "founder is already distilled" end
    select_one(G.jokers.cards, "founder", action.founder_id)
    local before_count = #G.jokers.cards
    local fn = id == "fire_founder" and "fire" or id == "distill_founder" and "distill" or "promote"
    G.FUNCS[fn]()
    if id == "distill_founder" then return cfg._distilled and true or nil, "founder distillation failed" end
    return #G.jokers.cards < before_count and true or nil, "founder removal failed"
  elseif id == "use_consumable" or id == "sell_consumable" then
    local card, err = find_one(G.consumables.cards, "consumable", action.consumable_id)
    if not card then return nil, err end
    if id == "sell_consumable" then
      select_one(G.consumables.cards, "consumable", action.consumable_id)
      G.FUNCS.sell_consumable(); return true
    end
    if card.center and card.center.target then
      local target_count = card.center.target.n or 1
      if card.center.target.layer then
        local valid = { Frontend = true, Backend = true, Data = true, Infra = true, AI = true }
        if not valid[action.layer] then return nil, "invalid target layer" end
      end
      local targets, target_err = select_cards(G.hand.cards, "hand", action.target_ids, target_count, target_count)
      if not targets then return nil, target_err end
      select_one(G.consumables.cards, "consumable", action.consumable_id)
      G.FUNCS.use_consumable()
      for _, target in ipairs(targets) do G.CONSUMABLE_TARGET_PICK(target) end
      if card.center.target.layer then G.CONSUMABLE_RESOLVE(action.layer) end
    else
      select_one(G.consumables.cards, "consumable", action.consumable_id)
      G.FUNCS.use_consumable()
    end
    return true
  elseif id == "pick_target" then
    local pending = G.PENDING_CONSUMABLE
    if not pending or pending.need_layer then return nil, "target card is not expected" end
    local card, target_err = find_one(G.hand.cards, "hand", action.card_id)
    if not card then return nil, target_err end
    for _, picked in ipairs(pending.picks or {}) do
      if picked == card then return nil, "target card was already picked" end
    end
    G.CONSUMABLE_TARGET_PICK(card)
    return true
  elseif id == "choose_target_layer" then
    local pending = G.PENDING_CONSUMABLE
    local valid = { Frontend = true, Backend = true, Data = true, Infra = true, AI = true }
    if not (pending and pending.need_layer and valid[action.layer]) then return nil, "target layer is not expected" end
    G.CONSUMABLE_RESOLVE(action.layer)
    return true
  elseif id == "cancel_targeting" then
    if not G.PENDING_CONSUMABLE then return nil, "no consumable is being targeted" end
    G.CONSUMABLE_CANCEL(); return true
  elseif id == "choose_tech" then
    local choices = g.tech_draft and g.tech_draft.choices
    local i, err = index_arg(action, choices); if not i then return nil, err end
    return Round.choose_tech(i) and true or nil, "tech selection failed"
  elseif id == "buy_founder" then
    local i, err = index_arg(action, g.shop and g.shop.founders); if not i then return nil, err end
    return Shop.buy(i) and true or nil, "founder purchase failed"
  elseif id == "reroll_shop" then return Shop.reroll() and true or nil, "shop reroll failed"
  elseif id == "buy_voucher" then return Shop.redeem() and true or nil, "voucher purchase failed"
  elseif id == "buy_consumable" then return Shop.buy_consumable() and true or nil, "consumable purchase failed"
  elseif id == "open_pack" then
    local i, err = index_arg(action, g.shop and g.shop.packs); if not i then return nil, err end
    return Shop.open_pack(i) and true or nil, "pack open failed"
  elseif id == "pick_pack_option" then
    local i, err = index_arg(action, g.shop and g.shop.pack_open and g.shop.pack_open.options); if not i then return nil, err end
    return Shop.pack_pick(i) and true or nil, "pack pick failed"
  elseif id == "skip_pack" then Shop.pack_skip(); return true
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
  Mimic._session = { opts = copy_plain(opts), actions = {} }
  return Mimic.observe()
end

return Mimic
