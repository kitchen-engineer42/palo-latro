-- Transactional consumable inventory and Tech Law resolution.  Preflight is
-- pure: an invalid/no-op Law never mutates state, advances RNG, or gets spent.

local Centers = require("game.centers")
local Coverage = require("game.coverage")
local TechLaws = require("game.tech_laws")

local Consumables = {}

-- Kept lazy because the Moonshot runtime also resolves through this shared
-- inventory boundary. Loading either module must not depend on require order.
local function moonshots() return require("game.moonshots") end

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

local function moonshot_payload(value)
  if type(value) ~= "table" then return nil end
  if value.moonshot_payload ~= nil then return value.moonshot_payload end
  if value.payload ~= nil then return value.payload end
  local config = value.ability and value.ability.config
  return config and (config._moonshot_payload or config.moonshot_payload) or nil
end

local function center_of(value)
  if type(value) == "string" then return Centers.get(value) end
  if type(value) ~= "table" then return nil end
  return value.center or (value.key and Centers.get(value.key))
    or (value.center_key and Centers.get(value.center_key)) or value
end

local function entry_by_uid(game, uid)
  for _, entry in ipairs((game and game.master_deck) or {}) do if entry.uid == uid then return entry end end
end

local function live_by_uid(uid)
  if not (G and uid) then return nil end
  for _, area in ipairs({ G.deck, G.hand, G.play }) do
    for _, card in ipairs((area and area.cards) or {}) do if card.uid == uid then return card end end
  end
end

local function target_entry(target, game)
  local entry = target and target.uid and entry_by_uid(game, target.uid)
  local center = entry and Centers.get(entry.center_key)
  if not (entry and center and center.set == "TechCard") then return nil end
  return entry, center
end

local function ctx_users(card, game)
  if card.get_users then return card:get_users(game and game.era) end
  local entry, center = target_entry(card, game)
  if entry then return require("game.card").tech_users(entry, center, game and game.era, game) end
  return card.base_users or 0
end

local function ordered_live(which, game)
  local seen, out = {}, {}
  for _, area in ipairs({ G and G.deck, G and G.hand }) do
    for _, card in ipairs((area and area.cards) or {}) do
      if card.uid and not seen[card.uid] and target_entry(card, game) then
        seen[card.uid], out[#out + 1] = true, card
      end
    end
  end
  table.sort(out, function(a, b)
    local av, bv = ctx_users(a, game), ctx_users(b, game)
    if av ~= bv then
      if which == "max_users" then return av > bv end
      return av < bv
    end
    local abase = tonumber(a.base_users) or (a.center and a.center.base_users) or 0
    local bbase = tonumber(b.base_users) or (b.center and b.center.base_users) or 0
    if abase ~= bbase then
      if which == "max_users" then return abase > bbase end
      return abase < bbase
    end
    if (a.uid or math.huge) ~= (b.uid or math.huge) then return (a.uid or math.huge) < (b.uid or math.huge) end
    return tostring(a.center_key or "") < tostring(b.center_key or "")
  end)
  return out
end

local function funding_unit(game)
  local RunState = require("game.runstate")
  return require("game.economy").unit(game, RunState.ANTE_BASE)
end

local function failed(center, reason)
  return { ok = false, key = center and center.key, reason = reason,
    consumed = false, changes = {}, generated = {} }
end

local function sync_stickers(entry)
  for _, area in ipairs({ G and G.deck, G and G.hand, G and G.play }) do
    for _, card in ipairs((area and area.cards) or {}) do
      if card.uid == entry.uid then
        card.stickers = entry.stickers and copy(entry.stickers) or nil
        card.layer_override = entry.layer_override
      end
    end
  end
end

function Consumables.can_target(card_or_center, target, game)
  local center = center_of(card_or_center)
  game = game_of(game)
  if not (center and center.target) then return false, "This consumable does not take a target" end
  if moonshots().handles(center) then
    return moonshots().can_target(card_or_center, target, game, {
      payload = moonshot_payload(card_or_center),
    })
  end
  local entry = target_entry(target, game)
  if not entry then return false, "Choose an owned Tech card" end
  if TechLaws.handles(center) then return TechLaws.can_target(center, target, game) end
  if center.key == "tl_conways_law" and entry.layer_locked then
    return false, "This Tech's Layer is locked"
  end
  return true
end

-- Target routing is part of the shared consumable contract. Tech Laws use the
-- hand; Moonshots may instead address the Founder row without teaching input,
-- UI, or Mimic about individual card keys.
function Consumables.target_area(card_or_center)
  local center = center_of(card_or_center)
  local area = center and center.target and center.target.area
  if area == "founders" then return G and G.jokers, "founder" end
  if area == "hand" then return G and G.hand, "hand" end
  return nil, area
end

function Consumables.target_candidates(card_or_center, game)
  local area, area_name = Consumables.target_area(card_or_center)
  local out = {}
  for _, candidate in ipairs((area and area.cards) or {}) do
    if Consumables.can_target(card_or_center, candidate, game) then out[#out + 1] = candidate end
  end
  return out, area_name, area
end

local function legacy_preflight(center, targets, opts)
  opts = opts or {}
  local game = game_of(opts.game)
  if not (center and game and center.kind == "TechLaw") then return nil, "Invalid Tech Law" end
  if type(center.ops) ~= "table" or #center.ops == 0 then return nil, "Tech Law has no operations" end
  targets = targets or {}
  if center.target then
    local needed = center.target.n or 1
    if #targets ~= needed then return nil, "Select exactly " .. tostring(needed) .. " eligible Tech target(s)" end
    local seen = {}
    for i = 1, needed do
      local ok, reason = Consumables.can_target(center, targets[i], game)
      if not ok then return nil, reason end
      if seen[targets[i].uid] then return nil, "Choose distinct Tech targets" end
      seen[targets[i].uid] = true
    end
  end

  local plan = { center = center, key = center.key, game = game, targets = targets, opts = opts, ops = {} }
  for _, op in ipairs(center.ops) do
    if op.k == "cash" then
      local amount = op.units and op.units * funding_unit(game) or op.amount or 0
      if op.floor then amount = math.max(op.floor, amount) end
      if op.cap then amount = math.min(op.cap, amount) end
      if op.cap_units then amount = math.min(amount, op.cap_units * funding_unit(game)) end
      if not finite(amount) or amount == 0 then return nil, "Cash operation has no effect" end
      plan.ops[#plan.ops + 1] = { k = "cash", amount = amount }
    elseif op.k == "sticker" then
      local entry = target_entry(targets[1], game)
      if not entry or not ({ users = true, rev = true })[op.field]
          or not ({ add = true, mul = true, override = true })[op.mode]
          or not finite(op.amount) then return nil, "Invalid Tech sticker operation" end
      plan.ops[#plan.ops + 1] = { k = "sticker", uid = entry.uid, sticker = {
        field = op.field, mode = op.mode, amount = op.amount, label = op.label, source = center.key,
      } }
    elseif op.k == "set_layer" then
      local entry, target_center = target_entry(targets[1], game)
      local layer = opts.layer or op.layer
      if not (entry and Coverage.is_core(layer)) then return nil, "Choose a core Layer" end
      layer = Coverage.normalize_layer(layer)
      if entry.layer_locked then return nil, "This Tech's Layer is locked" end
      local current = copy(entry)
      current.center, current.layer = target_center, target_center.layer
      local current_options = Coverage.card_options(current)
      if #current_options == 1 and current_options[1] == layer then
        return nil, "That Tech already uses this Layer"
      end
      plan.ops[#plan.ops + 1] = { k = "set_layer", uid = entry.uid, layer = layer }
    elseif op.k == "destroy" then
      local card = (op.select == "max_users" or op.select == "min_users")
        and ordered_live(op.select, game)[1] or targets[1]
      local entry = card and target_entry(card, game)
      if not entry then return nil, "No eligible Tech can be destroyed" end
      local refund = 0
      if op.refund then
        refund = op.refund.amount or math.floor(ctx_users(card, game) * (op.refund.frac or 0))
        if op.refund.floor then refund = math.max(op.refund.floor, refund) end
        if op.refund.cap then refund = math.min(op.refund.cap, refund) end
      end
      plan.ops[#plan.ops + 1] = { k = "destroy", uid = entry.uid, refund = math.max(0, refund) }
    elseif op.k == "mint" then
      local card, entry, seed, reason
      if op.source == "max_users" or op.source == "min_users" then
        for _, candidate in ipairs(ordered_live(op.source, game)) do
          local candidate_entry, candidate_center = target_entry(candidate, game)
          if candidate_entry and candidate_center and not candidate_center.signature then
            local allowed, why = require("game.deck").candidate_allowed(candidate_center, game.market)
            if allowed then
              card, entry, seed = candidate, candidate_entry, candidate_center
              break
            end
            reason = reason or why
          end
        end
      else
        card = targets[1]
        entry, seed = card and target_entry(card, game)
        if seed and seed.signature then return nil, "Signature Tech cannot be cloned" end
        if seed then
          local allowed, why = require("game.deck").candidate_allowed(seed, game.market)
          if not allowed then return nil, why or "That Tech cannot be cloned in this Market" end
        end
      end
      if not (entry and seed) then return nil, reason or "No eligible Tech can be cloned" end
      plan.ops[#plan.ops + 1] = { k = "mint", center_key = entry.center_key }
    else
      return nil, "Unknown Tech Law operation " .. tostring(op.k)
    end
  end
  return plan
end

local function legacy_apply(plan)
  local game = plan.game
  local result = { ok = true, key = plan.key, consumed = false, changes = {}, generated = {} }
  local Round = require("game.round")
  for _, op in ipairs(plan.ops) do
    if op.k == "cash" then
      game.cash = (game.cash or 0) + op.amount
      result.cash = (result.cash or 0) + op.amount
      result.changes[#result.changes + 1] = { kind = "cash", amount = op.amount }
    elseif op.k == "sticker" then
      local entry = entry_by_uid(game, op.uid)
      entry.stickers = entry.stickers or {}
      entry.stickers[#entry.stickers + 1] = copy(op.sticker)
      sync_stickers(entry)
      result.changes[#result.changes + 1] = { kind = "sticker", uid = op.uid,
        field = op.sticker.field, mode = op.sticker.mode, amount = op.sticker.amount }
    elseif op.k == "set_layer" then
      local entry = entry_by_uid(game, op.uid)
      entry.layer_override = op.layer
      sync_stickers(entry)
      result.changes[#result.changes + 1] = { kind = "set_layer", uid = op.uid, layer = op.layer }
    elseif op.k == "destroy" then
      Round.master_remove_uid(op.uid)
      local card = live_by_uid(op.uid)
      if card and card.area then card.area:remove_card(card, true); if card.remove then card:remove() end end
      if op.refund > 0 then game.cash = (game.cash or 0) + op.refund end
      result.changes[#result.changes + 1] = { kind = "destroy", uid = op.uid, refund = op.refund }
    elseif op.k == "mint" then
      local entry, reason = Round.master_add(op.center_key, { source = "tech_law" }, game)
      if not entry then return failed(plan.center, reason or "Tech clone failed") end
      result.changes[#result.changes + 1] = { kind = "mint", uid = entry.uid, key = entry.center_key }
    end
  end
  if #result.changes == 0 then return failed(plan.center, "Tech Law produced no change") end
  return result
end

function Consumables.apply(center_or_card, targets, opts)
  opts = opts or {}
  local center = center_of(center_or_card)
  if not center then return failed(nil, "Unknown consumable") end
  opts.game = game_of(opts.game)
  opts.card = opts.card or (type(center_or_card) == "table" and center_or_card.center and center_or_card)
  opts.payload = opts.payload or moonshot_payload(center_or_card)
  if moonshots().handles(center) then
    local plan, reason = moonshots().preflight(center_or_card, targets, opts)
    if not plan then return failed(center, reason) end
    return moonshots().apply(center_or_card, targets, opts, plan)
  end
  if TechLaws.handles(center) then
    local plan, reason = TechLaws.preflight(center, targets, opts)
    if not plan then return failed(center, reason) end
    return TechLaws.apply(center, targets, opts, plan)
  end
  local plan, reason = legacy_preflight(center, targets, opts)
  if not plan then return failed(center, reason) end
  return legacy_apply(plan)
end

function Consumables.can_use(card_or_center, game, targets, opts)
  local center = center_of(card_or_center)
  game = game_of(game)
  if not (center and game) then return false, "Unknown consumable" end
  local explicit_targets = targets ~= nil
  local use_opts = {}
  for key, value in pairs(opts or {}) do use_opts[key] = value end
  use_opts.game = game
  use_opts.card = use_opts.card
    or (type(card_or_center) == "table" and card_or_center.center and card_or_center or nil)
  use_opts.payload = use_opts.payload or moonshot_payload(card_or_center)
  if moonshots().handles(center) then
    return moonshots().can_use(card_or_center, game, targets, use_opts)
  end
  if TechLaws.handles(center) then
    return TechLaws.can_use(card_or_center, game, targets, use_opts)
  end
  if center.target and not explicit_targets then
    targets = {}
    for _, candidate in ipairs((G and G.hand and G.hand.cards) or {}) do
      if Consumables.can_target(center, candidate, game) then
        targets[#targets + 1] = candidate
        if #targets >= (center.target.n or 1) then break end
      end
    end
  end
  local plan, reason = legacy_preflight(center, targets, use_opts)
  if not plan and not explicit_targets and center.target and center.target.layer
      and targets and targets[1] then
    for _, layer in ipairs({ "Frontend", "Backend", "Data", "Infra", "AI" }) do
      use_opts.layer = layer
      plan, reason = legacy_preflight(center, targets, use_opts)
      if plan then break end
    end
  end
  return plan ~= nil, reason
end

local function target_id(target, area_name)
  if not target then return nil end
  if area_name == "hand" then return target.uid end
  if area_name == "founder" then
    local cfg = target.ability and target.ability.config or {}
    return cfg._founder_id or target.founder_instance_id or target.ID
  end
  return target.uid or target.ID
end

function Consumables.target_id(target, area_name)
  return target_id(target, area_name)
end

local function same_ids(left, right)
  if #(left or {}) ~= #(right or {}) then return false end
  local counts = {}
  for _, id in ipairs(left or {}) do counts[id] = (counts[id] or 0) + 1 end
  for _, id in ipairs(right or {}) do
    if not counts[id] then return false end
    counts[id] = counts[id] - 1
    if counts[id] == 0 then counts[id] = nil end
  end
  return next(counts) == nil
end

-- Enumerate exact, jointly legal uses in visible area order.  This is pure with respect to gameplay:
-- it delegates to the same preflight used by resolution and never materializes Moonshot payloads.
function Consumables.legal_uses(card_or_center, game)
  local center = center_of(card_or_center)
  game = game_of(game)
  if not (center and game) then return {}, "Unknown consumable" end

  if not center.target then
    local ok, reason = Consumables.can_use(card_or_center, game, nil, nil)
    if not ok then return {}, reason end
    return { { targets = {}, target_ids = {}, target_area = nil, layer = nil } }
  end

  local candidates, area_name = Consumables.target_candidates(card_or_center, game)
  local count = math.max(1, math.floor(tonumber(center.target.n) or 1))
  if #candidates < count then
    return {}, ("Select exactly %d eligible %s target(s)"):format(count,
      area_name == "founder" and "Founder" or "Tech")
  end

  local uses, picked, first_reason = {}, {}
  local function consider(layer)
    local opts = layer and { layer = layer } or nil
    local ok, reason = Consumables.can_use(card_or_center, game, picked, opts)
    if not ok then first_reason = first_reason or reason; return end
    local targets, ids = {}, {}
    for _, target in ipairs(picked) do
      targets[#targets + 1] = target
      ids[#ids + 1] = target_id(target, area_name)
    end
    uses[#uses + 1] = {
      targets = targets, target_ids = ids, target_area = area_name, layer = layer,
    }
  end
  local function combinations(start_at)
    if #picked == count then
      if center.target.layer then
        for _, layer in ipairs(Coverage.CORE_ORDER) do consider(layer) end
      else consider(nil) end
      return
    end
    local remaining = count - #picked
    for index = start_at, #candidates - remaining + 1 do
      picked[#picked + 1] = candidates[index]
      combinations(index + 1)
      picked[#picked] = nil
    end
  end
  combinations(1)
  return uses, first_reason
end

-- Project the currently selected target cards without mutating their selection or the effect.
function Consumables.selected_use_view(card_or_center, game)
  local center = center_of(card_or_center)
  game = game_of(game)
  local view = {
    key = center and center.key or nil,
    target_requirements = nil,
    selected_ids = {},
    selected_targets = {},
    legal = false,
    is_legal = false,
    reason = nil,
    follow_up = nil,
    follow_up_state = nil,
  }
  if not (center and game) then view.reason = "Unknown consumable"; return view end

  if not center.target then
    local ok, reason = Consumables.can_use(card_or_center, game, nil, nil)
    view.legal, view.is_legal, view.reason = ok == true, ok == true, reason
    return view
  end

  local area, area_name = Consumables.target_area(card_or_center)
  local needed = math.max(1, math.floor(tonumber(center.target.n) or 1))
  view.target_requirements = { area = area_name, count = needed, layer = center.target.layer == true }
  view.target_area = area_name
  for _, target in ipairs((area and area.cards) or {}) do
    if target.selected then
      view.selected_targets[#view.selected_targets + 1] = target
      view.selected_ids[#view.selected_ids + 1] = target_id(target, area_name)
    end
  end
  if #view.selected_targets ~= needed then
    view.reason = ("Select exactly %d %s target(s)"):format(needed,
      area_name == "founder" and "Founder" or "Tech")
    return view
  end

  local uses, reason = Consumables.legal_uses(card_or_center, game)
  local layers = {}
  for _, use in ipairs(uses) do
    if same_ids(use.target_ids, view.selected_ids) then
      if use.layer then layers[#layers + 1] = use.layer
      else view.legal, view.is_legal = true, true end
    end
  end
  if #layers > 0 then
    view.legal, view.is_legal = true, true
    view.follow_up = { kind = "layer", options = layers }
    view.follow_up_state = "layer"
  end
  if not view.legal then
    local _, selected_reason = Consumables.can_use(card_or_center, game, view.selected_targets)
    view.reason = selected_reason or reason or "Selected targets are not jointly legal"
  end
  return view
end

local function consumable_is_live(card)
  if not (G and G.consumables and G.consumables.cards) then return true end
  for _, candidate in ipairs(G.consumables.cards) do if candidate == card then return true end end
  return false
end

-- Stable-ID transactional resolver shared by GUI and Mimic.  Every identity is looked up again and
-- the complete tuple is re-preflighted before the existing `use` boundary can mutate or consume.
function Consumables.resolve_use(card, selection, opts)
  selection, opts = selection or {}, opts or {}
  if not (card and card.center) or not consumable_is_live(card) then
    return failed(card and card.center, "Consumable is stale or no longer owned")
  end
  local requested = selection.target_ids or {}
  if type(requested) ~= "table" then return failed(card.center, "Target IDs must be an array") end
  local seen = {}
  for _, id in ipairs(requested) do
    if id == nil or seen[id] then return failed(card.center, "Target IDs must be distinct") end
    seen[id] = true
  end
  local uses, reason = Consumables.legal_uses(card, opts.game)
  for _, use in ipairs(uses) do
    if same_ids(use.target_ids, requested) and use.layer == selection.layer then
      local use_opts = {}
      for key, value in pairs(opts) do use_opts[key] = value end
      use_opts.layer = selection.layer
      return Consumables.use(card, use.targets, use_opts)
    end
  end
  if card.center.target and card.center.target.layer and selection.layer == nil then
    reason = "Choose a core Layer"
  end
  return failed(card.center, reason or "Consumable targets are stale or jointly illegal")
end

Consumables.resolve = Consumables.resolve_use

local function next_instance_id(game)
  game.consumable_next_id = (game.consumable_next_id or 0) + 1
  return game.consumable_next_id
end

local function make_live(entry)
  if not (G and G.consumables and Card) then return nil end
  local center = Centers.get(entry.key)
  if not center then return nil end
  local card = Card({ center = center, T = { x = G.consumables.T.x, y = G.consumables.T.y } })
  card.consumable_instance_id = entry.instance_id
  card.ability.config._consumable_id = entry.instance_id
  card.ability.config._sell_basis = entry.sell_basis or 0
  if entry.moonshot_payload ~= nil then
    card.moonshot_payload = copy(entry.moonshot_payload)
    card.ability.config._moonshot_payload = copy(entry.moonshot_payload)
  end
  card.consumable_source = entry.source
  G.consumables:emplace(card)
  return card
end

function Consumables.normalize(game)
  game = game_of(game)
  if not game then return nil end
  game.consumables = type(game.consumables) == "table" and game.consumables or {}
  game.consumable_slots = math.max(0, math.floor(tonumber(game.consumable_slots) or 2))
  local next_id, seen, normalized = math.max(0, math.floor(tonumber(game.consumable_next_id) or 0)), {}, {}
  for _, entry in ipairs(game.consumables) do
    if #normalized >= game.consumable_slots then break end
    local center = type(entry) == "table" and Centers.get(entry.key)
    if center and center.set == "Consumable" then
      local id = math.floor(tonumber(entry.instance_id) or 0)
      if id < 1 or seen[id] then
        repeat next_id = next_id + 1 until not seen[next_id]
        id = next_id
      end
      next_id, seen[id] = math.max(next_id, id), true
      local clean = {
        instance_id = id, key = center.key,
        source = type(entry.source) == "string" and entry.source or "legacy",
        sell_basis = math.max(0, finite(entry.sell_basis) and entry.sell_basis or 0),
      }
      if moonshots().handles(center) then
        local payload = moonshots().normalize(moonshot_payload(entry), game, center)
        if payload ~= nil then
          clean.moonshot_payload = copy(payload.payload or payload)
          normalized[#normalized + 1] = clean
        end
      else
        normalized[#normalized + 1] = clean
      end
    end
  end
  game.consumables, game.consumable_next_id = normalized, next_id
  return normalized
end

function Consumables.rehydrate(game)
  game = game_of(game)
  if not (game and G and G.consumables) then return false end
  Consumables.normalize(game)
  if G.consumables.config then G.consumables.config.card_limit = game.consumable_slots end
  local live, wanted, used = {}, {}, {}
  for _, entry in ipairs(game.consumables) do wanted[entry.instance_id] = entry end
  for i = #(G.consumables.cards or {}), 1, -1 do
    local card = G.consumables.cards[i]
    local id = card.consumable_instance_id
      or (card.ability and card.ability.config and card.ability.config._consumable_id)
    local entry = id and wanted[id]
    if not (entry and not used[id] and card.center_key == entry.key) then
      G.consumables:remove_card(card, true)
      if card.remove then card:remove() end
    else
      used[id], live[id] = true, card
    end
  end
  for _, entry in ipairs(game.consumables) do
    local card = live[entry.instance_id]
    if card then
      card.consumable_instance_id = entry.instance_id
      card.ability.config._consumable_id = entry.instance_id
      card.ability.config._sell_basis = entry.sell_basis
      card.moonshot_payload = entry.moonshot_payload and copy(entry.moonshot_payload) or nil
      card.ability.config._moonshot_payload = entry.moonshot_payload and copy(entry.moonshot_payload) or nil
    else make_live(entry) end
  end
  return true
end

function Consumables.grant(key, opts)
  opts = opts or {}
  local center, game = Centers.get(key), game_of(opts.game)
  if not (center and center.set == "Consumable" and game) then return nil end
  Consumables.normalize(game)
  if #game.consumables >= (game.consumable_slots or 2) then return nil end
  local payload
  if moonshots().handles(center) then
    local instance = opts.moonshot_payload or opts.payload
    local reason
    if instance == nil then
      instance, reason = moonshots().materialize(center, { game = game, rng = opts.rng })
    end
    if instance == nil then return nil, reason end
    local normalized
    normalized, reason = moonshots().normalize(instance, game, center)
    if normalized == nil then return nil, reason end
    payload = copy(normalized.payload or normalized)
  end
  local entry = {
    instance_id = next_instance_id(game), key = key,
    source = opts.source or "generated",
    sell_basis = math.max(0, finite(opts.sell_basis) and opts.sell_basis or 0),
    moonshot_payload = payload,
  }
  game.consumables[#game.consumables + 1] = entry
  local card = make_live(entry)
  entry.card_id = card and card.ID or nil -- compatibility-only; normalize strips it before persistence
  if opts.discover ~= false then require("game.profile").discover(key) end
  return entry
end

function Consumables.remove(card)
  local game = game_of()
  if not (card and game) then return false end
  local id = card.consumable_instance_id
    or (card.ability and card.ability.config and card.ability.config._consumable_id)
  local removed = false
  for i = #(game.consumables or {}), 1, -1 do
    local entry = game.consumables[i]
    if (id and entry.instance_id == id) or (not id and entry.key == card.center_key) then
      table.remove(game.consumables, i); removed = true; break
    end
  end
  if card.area then card.area:remove_card(card, true) end
  if card.remove then card:remove() end
  return removed
end

function Consumables.use(card, targets, opts)
  opts = opts or {}
  if not (card and card.center) then return failed(nil, "No consumable selected") end
  opts.game, opts.card = game_of(opts.game), card
  local result = Consumables.apply(card, targets, opts)
  if not result.ok then return result end
  local Scoring = require("game.scoring")
  if Scoring.fire_hook then
    Scoring.fire_hook("use_consumable", { consumable = card.center, targets = targets, outcome = result })
  end
  Consumables.remove(card)
  result.consumed = true
  return TechLaws.after_consumed(card.center, result, opts)
end

return Consumables
