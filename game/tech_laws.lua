-- Runtime rules for the expanded Tech Law set.  Centers remain immutable; every
-- persistent mark lives on a master-deck entry and is mirrored to its live Card.
-- All tie-breaks are effective Users, then base Users, stable uid, then center key.

local Centers = require("game.centers")
local Coverage = require("game.coverage")
local RNG = require("game.rng")

local TechLaws = {}

local KEYS = {
  tl_postels_law = true,
  tl_parkinsons_law = true,
  tl_metcalfes_law = true,
  tl_amdahls_law = true,
  tl_gustafsons_law = true,
  tl_wirths_law = true,
  tl_dunbars_number = true,
  tl_linuss_law = true,
  tl_zawinskis_law = true,
  tl_kerckhoffs_principle = true,
  tl_hyrums_law = true,
  tl_sturgeons_law = true,
}

local RARITY_WEIGHT = { common = 6, uncommon = 3, rare = 1 }
local USER_MARK = {
  tl_metcalfes_law = "metcalfe_users",
  tl_gustafsons_law = "gustafson_users",
  tl_sturgeons_law = "sturgeon_users",
}
local USER_SOURCES = { "tl_metcalfes_law", "tl_gustafsons_law", "tl_sturgeons_law" }
local USER_LABEL = {
  tl_metcalfes_law = "Metcalfe",
  tl_gustafsons_law = "Gustafson",
  tl_sturgeons_law = "Sturgeon",
}

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  return out
end

local function center_of(value)
  if type(value) == "string" then return Centers.get(value) end
  if type(value) ~= "table" then return nil end
  return value.center or (value.key and Centers.get(value.key))
    or (value.center_key and Centers.get(value.center_key)) or value
end

local function game_of(game)
  return game or (G and G.GAME)
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function law_marks(entry)
  entry.law_marks = type(entry.law_marks) == "table" and entry.law_marks or {}
  return entry.law_marks
end

local function entry_by_uid(game, uid)
  if not (game and uid) then return nil end
  for _, entry in ipairs(game.master_deck or {}) do
    if entry.uid == uid then return entry end
  end
end

local function entry_for_target(target, game)
  if type(target) ~= "table" then return nil end
  local entry = target.uid and entry_by_uid(game, target.uid)
  local center = entry and Centers.get(entry.center_key)
  if not (entry and center and center.set == "TechCard") then return nil end
  return entry, center
end

local function subject(entry, center)
  local out = {}
  for key, value in pairs(entry or {}) do out[key] = value end
  out.center, out.layer = center, center and center.layer
  return out
end

local function effective_users(entry, game)
  local center = entry and Centers.get(entry.center_key)
  if not center then return -math.huge end
  local CardModel = require("game.card")
  return CardModel.tech_users(entry, center, game and game.era, game)
end

local function uid_less(a, b)
  local au, bu = tonumber(a.uid) or math.huge, tonumber(b.uid) or math.huge
  if au ~= bu then return au < bu end
  return tostring(a.center_key or "") < tostring(b.center_key or "")
end

local function ordered_entries(game, descending)
  local out = {}
  for _, entry in ipairs((game and game.master_deck) or {}) do
    local center = Centers.get(entry.center_key)
    if center and center.set == "TechCard" then out[#out + 1] = entry end
  end
  table.sort(out, function(a, b)
    local av, bv = effective_users(a, game), effective_users(b, game)
    if av ~= bv then
      if descending then return av > bv end
      return av < bv
    end
    local ac, bc = Centers.get(a.center_key), Centers.get(b.center_key)
    local abase, bbase = tonumber(a.base_users) or (ac and ac.base_users) or 0,
      tonumber(b.base_users) or (bc and bc.base_users) or 0
    if abase ~= bbase then
      if descending then return abase > bbase end
      return abase < bbase
    end
    return uid_less(a, b)
  end)
  return out
end

local function core_options(entry)
  local center = entry and Centers.get(entry.center_key)
  return center and Coverage.card_options(subject(entry, center)) or {}
end

local function has_layer(entry, wanted)
  for _, layer in ipairs(core_options(entry)) do if layer == wanted then return true end end
  return false
end

local function live_cards(uid)
  local out = {}
  if not (G and uid) then return out end
  for _, area in ipairs({ G.deck, G.hand, G.play }) do
    for _, card in ipairs((area and area.cards) or {}) do
      if card.uid == uid then out[#out + 1] = card end
    end
  end
  return out
end

local function sync_entry(entry)
  for _, card in ipairs(live_cards(entry.uid)) do
    card.enhancement = entry.enhancement
    card.enh = nil
    card.seal = entry.seal
    card.modifier_state = entry.modifier_state and copy(entry.modifier_state) or nil
    card.stickers = entry.stickers and copy(entry.stickers) or nil
    card.layer_override = entry.layer_override
    card.layer_locked = entry.layer_locked == true
    card.law_marks = entry.law_marks and copy(entry.law_marks) or nil
  end
end

local function named_sticker(entry, source, label, delta, cap)
  if not finite(delta) or delta <= 0 then return 0 end
  local marks, field = law_marks(entry), USER_MARK[source]
  local before = tonumber(marks[field]) or 0
  local after = math.min(cap or math.huge, before + delta)
  local applied = after - before
  if applied <= 0 then return 0 end
  marks[field] = after
  entry.stickers = entry.stickers or {}
  local sticker
  for _, candidate in ipairs(entry.stickers) do
    if candidate.source == source and candidate.field == "users" then sticker = candidate; break end
  end
  if sticker then sticker.amount = after
  else
    entry.stickers[#entry.stickers + 1] = {
      field = "users", mode = "add", amount = after, label = label, source = source,
    }
  end
  sync_entry(entry)
  return applied
end

local function remove_uid(game, uid)
  local removed = false
  for i = #(game.master_deck or {}), 1, -1 do
    if game.master_deck[i].uid == uid then table.remove(game.master_deck, i); removed = true end
  end
  if G then
    for _, area in ipairs({ G.deck, G.hand, G.play }) do
      for i = #((area and area.cards) or {}), 1, -1 do
        local card = area.cards[i]
        if card.uid == uid then
          area:remove_card(card, true)
          if card.remove then card:remove() end
        end
      end
    end
  end
  return removed
end

local function funding_unit(game)
  local RunState = require("game.runstate")
  return require("game.economy").unit(game, RunState.ANTE_BASE)
end

local function last_coverage(game)
  local value = tonumber(game.last_shipped_distinct_layers or game.last_ship_coverage or game._last_hand_ndl)
  if not finite(value) then value = 0 end
  return math.min(5, math.max(0, math.floor(value)))
end

local function fail(reason)
  return nil, reason
end

function TechLaws.handles(center_or_key)
  local center = center_of(center_or_key)
  return center ~= nil and KEYS[center.key] == true
end

function TechLaws.pool()
  local out = {}
  for _, center in ipairs(Centers.pool("Consumable")) do
    if center.kind == "TechLaw" then out[#out + 1] = center end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

local function excluded(opts, key)
  local set = opts and opts.exclude
  if type(set) ~= "table" then return false end
  if set[key] then return true end
  for _, value in ipairs(set) do if value == key or (type(value) == "table" and value.key == key) then return true end end
  return false
end

function TechLaws.weighted_pool(opts)
  local out = {}
  for _, center in ipairs(TechLaws.pool()) do
    if not excluded(opts, center.key) and (not opts or not opts.kind or center.kind == opts.kind) then
      for _ = 1, RARITY_WEIGHT[center.rarity] or 0 do out[#out + 1] = center end
    end
  end
  return out
end

function TechLaws.roll(rng, opts)
  local pool = TechLaws.weighted_pool(opts)
  if #pool == 0 then return nil end
  rng = rng or RNG.fn("tech_law")
  local rolled = rng(#pool)
  local index
  if type(rolled) == "number" and rolled >= 0 and rolled < 1 then
    index = math.floor(rolled * #pool) + 1
  else
    index = math.floor(tonumber(rolled) or 1)
  end
  return pool[math.max(1, math.min(#pool, index))]
end

local function wirth_stage(mark, ante)
  local current, applied = tonumber(ante), tonumber(mark.applied_ante)
  if not finite(current) then current = 1 end
  if not finite(applied) then applied = 1 end
  local offset = math.max(0, current - applied)
  return math.min(2, offset)
end

local function normalize_wirth(mark, ante)
  if type(mark) ~= "table" then return nil end
  local applied = tonumber(mark.applied_ante)
  if not finite(applied) then applied = tonumber(ante) end
  if not finite(applied) then applied = 1 end
  local current = tonumber(ante)
  if not finite(current) then current = applied end
  mark.applied_ante = math.max(1, math.floor(applied))
  mark.factors = { 0.85, 0.70, 0.50 }
  mark.stage = math.floor(wirth_stage(mark, current))
  mark.current_factor = mark.factors[mark.stage + 1]
  mark.last_tick_ante = math.max(1, math.floor(current))
  return mark
end

local function bounded_number(value, low, high)
  value = tonumber(value)
  if not finite(value) then value = low end
  return math.min(high, math.max(low, value))
end

function TechLaws.normalize(game)
  game = game_of(game)
  if not game then return nil end
  game.tech_law_state = type(game.tech_law_state) == "table" and game.tech_law_state or {}
  local shipped_coverage = math.floor(bounded_number(game.last_shipped_distinct_layers
    or game.last_ship_coverage or game._last_hand_ndl, 0, 5))
  game.last_shipped_distinct_layers, game.last_ship_coverage = shipped_coverage, shipped_coverage
  local shipped_app = game.last_shipped_app_key or game.last_ship_app_key
  game.last_shipped_app_key, game.last_ship_app_key = shipped_app, shipped_app
  if game.last_ship_app_key ~= nil and not require("game.apptypes").by_key[game.last_ship_app_key] then
    game.last_ship_app_key, game.last_shipped_app_key = nil, nil
  end
  local anchors = {}
  for _, entry in ipairs(game.master_deck or {}) do
    local source = type(entry.law_marks) == "table" and entry.law_marks or {}
    local marks = {
      metcalfe_users = bounded_number(source.metcalfe_users, 0, 20),
      gustafson_users = bounded_number(source.gustafson_users, 0, 24),
      sturgeon_users = bounded_number(source.sturgeon_users, 0, 10),
      amdahl_bottleneck = source.amdahl_bottleneck == true or nil,
      well_formed = source.well_formed == true or nil,
      hyrum_layer = (source.hyrum_layer == true and Coverage.is_core(entry.layer_override)) and true or nil,
      wirth_bloat = normalize_wirth(source.wirth_bloat, game.ante),
    }
    for _, source_key in ipairs(USER_SOURCES) do
      local field = USER_MARK[source_key]
      if marks[field] == 0 then marks[field] = nil end
    end
    entry.law_marks = next(marks) and marks or nil
    entry.layer_locked = marks.hyrum_layer and true or nil
    if marks.amdahl_bottleneck then anchors[#anchors + 1] = entry end
  end
  table.sort(anchors, uid_less)
  for i = 2, #anchors do anchors[i].law_marks.amdahl_bottleneck = nil end
  for _, entry in ipairs(game.master_deck or {}) do
    local cleaned, named = {}, {}
    for _, sticker in ipairs(entry.stickers or {}) do
      if type(sticker) == "table" then
        local field = USER_MARK[sticker.source]
        if not field then
          cleaned[#cleaned + 1] = sticker
        elseif not named[sticker.source] then
          named[sticker.source] = sticker
        end
      end
    end
    entry.stickers = cleaned
    for _, source_key in ipairs(USER_SOURCES) do
      local field = USER_MARK[source_key]
      local amount = entry.law_marks and entry.law_marks[field]
      if amount and amount > 0 then
        local sticker = named[source_key] or {}
        sticker.field, sticker.mode, sticker.amount = "users", "add", amount
        sticker.label, sticker.source = USER_LABEL[source_key], source_key
        entry.stickers[#entry.stickers + 1] = sticker
      end
    end
    if #entry.stickers == 0 then entry.stickers = nil end
    if entry.law_marks and next(entry.law_marks) == nil then entry.law_marks = nil end
    sync_entry(entry)
  end
  return game
end

function TechLaws.on_ante_start(game, ante)
  game = game_of(game)
  if not game then return { updated = 0, ante = ante } end
  local result = { updated = 0, ante = ante or game.ante }
  for _, entry in ipairs(game.master_deck or {}) do
    local mark = entry.law_marks and entry.law_marks.wirth_bloat
    if mark then
      local before = mark.current_factor
      normalize_wirth(mark, result.ante)
      if mark.current_factor ~= before then result.updated = result.updated + 1 end
      sync_entry(entry)
    end
  end
  game.tech_law_state = game.tech_law_state or {}
  game.tech_law_state.last_ante_tick = result.ante
  game.tech_law_state.last_ante_updates = result.updated
  return result
end

-- Called after normal lifecycle/enhancement Users resolve. Amdahl is a live aura;
-- Wirth is a per-instance multiplier and therefore survives migration naturally.
function TechLaws.users(subject_value, value, game)
  local entry = subject_value or {}
  game = game_of(game)
  value = tonumber(value) or 0
  if game and entry.uid then
    local anchors = 0
    for _, candidate in ipairs(game.master_deck or {}) do
      if candidate.uid ~= entry.uid and candidate.law_marks and candidate.law_marks.amdahl_bottleneck then
        anchors = anchors + 1
      end
    end
    value = value + anchors * 10
  end
  local wirth = entry.law_marks and entry.law_marks.wirth_bloat
  if wirth then value = value * (tonumber(wirth.current_factor) or 0.85) end
  return math.max(0, math.floor(value + 0.5))
end

local function hyrum_others(game, target_uid)
  local out = {}
  for _, entry in ipairs(ordered_entries(game, true)) do
    if entry.uid ~= target_uid and not entry.layer_locked then out[#out + 1] = entry end
  end
  return out
end

function TechLaws.can_target(center_or_card, target, game)
  local center = center_of(center_or_card)
  game = game_of(game)
  local entry = entry_for_target(target, game)
  if not (center and entry) then return false, "Choose an owned Tech card" end

  if center.key == "tl_postels_law" then
    if entry.layer_locked then return false, "This Tech's Layer is locked" end
    if entry.enhancement or entry.enh then return false, "Postel's Law needs an unenhanced Tech" end
  elseif center.key == "tl_wirths_law" then
    if entry.law_marks and entry.law_marks.wirth_bloat then return false, "This Tech already carries Wirth bloat" end
  elseif center.key == "tl_kerckhoffs_principle" then
    if entry.law_marks and entry.law_marks.well_formed then return false, "This Tech is already Well-Formed" end
  elseif center.key == "tl_hyrums_law" then
    if #core_options(entry) ~= 1 then return false, "Hyrum's Law needs a single-Layer Tech" end
    if #hyrum_others(game, entry.uid) < 2 then return false, "Hyrum's Law needs two unlocked Tech cards" end
  elseif center.key == "tl_conways_law" then
    if entry.layer_locked then return false, "This Tech's Layer is locked" end
  end
  return true
end

local function find_targetable(center, game)
  for _, card in ipairs((G and G.hand and G.hand.cards) or {}) do
    if TechLaws.can_target(center, card, game) then return card end
  end
end

function TechLaws.preflight(center_or_card, targets, opts)
  opts = opts or {}
  local center = center_of(center_or_card)
  local game = game_of(opts.game)
  if not (center and game and KEYS[center.key]) then return fail("Unknown expanded Tech Law") end
  targets = targets or {}
  local plan = { key = center.key, center = center, game = game, targets = targets, opts = opts }
  local target, entry
  if center.target then
    local needed = center.target.n or 1
    if #targets ~= needed then return fail("Select exactly " .. tostring(needed) .. " eligible Tech target(s)") end
    target = targets[1]
    local ok, reason = TechLaws.can_target(center, target, game)
    if not ok then return fail(reason) end
    entry = entry_for_target(target, game)
    plan.target_uid = entry.uid
  end

  if center.key == "tl_postels_law" then
    plan.enhancement = "polyglot"
  elseif center.key == "tl_parkinsons_law" then
    local cash = tonumber(game.cash) or 0
    if cash <= 0 then return fail("Parkinson's Law needs positive Cash") end
    plan.cash = math.min(cash, 4 * funding_unit(game))
    if plan.cash <= 0 then return fail("Parkinson's Law has no Cash to match") end
  elseif center.key == "tl_metcalfes_law" then
    plan.coverage = last_coverage(game)
    plan.amount = plan.coverage * (plan.coverage - 1) / 2
    if plan.amount <= 0 then return fail("Ship at least two Layers before using Metcalfe's Law") end
    plan.entries = {}
    for _, candidate in ipairs(ordered_entries(game)) do
      local before = ((candidate.law_marks or {}).metcalfe_users or 0)
      if before < 20 then plan.entries[#plan.entries + 1] = candidate.uid end
    end
    if #plan.entries == 0 then return fail("Every Tech has reached Metcalfe's +20 cap") end
  elseif center.key == "tl_amdahls_law" then
    local entries = ordered_entries(game)
    if not entries[1] then return fail("Amdahl's Law needs an owned Tech") end
    if entries[1].law_marks and entries[1].law_marks.amdahl_bottleneck then
      return fail("The weakest Tech is already the Amdahl Bottleneck")
    end
    plan.target_uid = entries[1].uid
  elseif center.key == "tl_gustafsons_law" then
    plan.entries = {}
    for _, candidate in ipairs(ordered_entries(game)) do
      local marks = candidate.law_marks or {}
      if (has_layer(candidate, "Data") or has_layer(candidate, "Infra"))
          and (marks.gustafson_users or 0) < 24 then
        plan.entries[#plan.entries + 1] = candidate.uid
      end
    end
    if #plan.entries == 0 then return fail("No Data or Infra Tech can gain Gustafson Users") end
  elseif center.key == "tl_wirths_law" then
    plan.cash = 2 * funding_unit(game)
    plan.applied_ante = game.ante or 1
  elseif center.key == "tl_dunbars_number" then
    plan.app_key = game.last_shipped_app_key or game.last_ship_app_key or (game.this_app and game.this_app.key)
    if not (plan.app_key and require("game.apptypes").by_key[plan.app_key]) then
      return fail("Ship an App Type before using Dunbar's Number")
    end
    local level = math.max(1, (game.app_levels and game.app_levels[plan.app_key]) or 1)
    if level >= 15 then return fail("That Playbook is already level 15") end
    plan.coverage = last_coverage(game)
    if plan.coverage < 1 then return fail("Ship at least one Layer before using Dunbar's Number") end
    plan.amount = math.min(3, math.ceil(plan.coverage / 2), 15 - level)
  elseif center.key == "tl_linuss_law" then
    plan.coverage = last_coverage(game)
    plan.count = math.min(2, math.floor(plan.coverage / 2))
    if plan.count < 1 then return fail("Ship at least two Layers before using Linus's Law") end
    plan.entries = {}
    for _, candidate in ipairs(ordered_entries(game)) do
      if not candidate.enhancement and not candidate.enh then
        plan.entries[#plan.entries + 1] = candidate.uid
        if #plan.entries >= plan.count then break end
      end
    end
    if #plan.entries == 0 then return fail("Linus's Law needs an unenhanced Tech") end
  elseif center.key == "tl_zawinskis_law" then
    local inventory = game.consumables or {}
    local card = opts.card or (type(center_or_card) == "table" and center_or_card.center and center_or_card)
    local owns_self = false
    for _, item in ipairs(inventory) do
      if (card and card.consumable_instance_id and item.instance_id == card.consumable_instance_id)
          or (card and card.ability and card.ability.config
            and item.instance_id == card.ability.config._consumable_id) then owns_self = true; break end
    end
    local available = math.max(0, (game.consumable_slots or 2) - #inventory + (owns_self and 1 or 0))
    plan.create_count = math.min(2, available)
    if plan.create_count < 1 then return fail("No Roadmap slot will be open after using Zawinski's Law") end
    if #TechLaws.weighted_pool({ exclude = { [center.key] = true } }) == 0 then return fail("No other Tech Law is available") end
    plan.stream = "tech_law_create"
  elseif center.key == "tl_kerckhoffs_principle" then
    -- Target validity is the complete preflight.
  elseif center.key == "tl_hyrums_law" then
    local target_entry = entry_by_uid(game, plan.target_uid)
    plan.layer = core_options(target_entry)[1]
    local others = hyrum_others(game, plan.target_uid)
    plan.entries = { others[1].uid, others[2].uid }
  elseif center.key == "tl_sturgeons_law" then
    local entries = ordered_entries(game)
    if #entries < 12 then return fail("Sturgeon's Law needs at least 12 owned Tech cards") end
    plan.destroy = { entries[1].uid, entries[2].uid }
    plan.survivors = {}
    for i = 3, #entries do plan.survivors[#plan.survivors + 1] = entries[i].uid end
  end
  return plan
end

function TechLaws.can_use(center_or_card, game, targets, opts)
  local center = center_of(center_or_card)
  game = game_of(game)
  if not (center and KEYS[center.key]) then return false, "Not an expanded Tech Law" end
  opts = opts or {}; opts.game = game; opts.card = opts.card or (type(center_or_card) == "table" and center_or_card.center and center_or_card)
  if center.target and not (targets and targets[1]) then
    local target = find_targetable(center, game)
    if not target then return false, "No eligible Tech target is in hand" end
    targets = { target }
  end
  local _, reason = TechLaws.preflight(center, targets, opts)
  return reason == nil, reason
end

local function outcome(plan)
  return { ok = true, key = plan.key, consumed = false, changes = {}, generated = {} }
end

function TechLaws.apply(center_or_card, targets, opts, prepared)
  opts = opts or {}
  local plan, reason = prepared, nil
  if not plan then plan, reason = TechLaws.preflight(center_or_card, targets, opts) end
  if not plan then return { ok = false, key = center_of(center_or_card) and center_of(center_or_card).key,
    reason = reason, consumed = false, changes = {}, generated = {} } end
  local game, result = plan.game, outcome(plan)

  if plan.key == "tl_postels_law" then
    local entry = entry_by_uid(game, plan.target_uid)
    entry.enhancement, entry.enh, entry.modifier_state = plan.enhancement, nil, nil
    entry.layer_override = nil
    sync_entry(entry)
    result.changes[#result.changes + 1] = { kind = "enhancement", uid = entry.uid, key = plan.enhancement }
  elseif plan.key == "tl_parkinsons_law" then
    game.cash = (game.cash or 0) + plan.cash
    result.cash = plan.cash
    result.changes[#result.changes + 1] = { kind = "cash", amount = plan.cash }
  elseif plan.key == "tl_metcalfes_law" then
    for _, uid in ipairs(plan.entries) do
      local entry = entry_by_uid(game, uid)
      local amount = entry and named_sticker(entry, plan.key, "Metcalfe", plan.amount, 20) or 0
      if amount > 0 then result.changes[#result.changes + 1] = { kind = "users", uid = uid, amount = amount } end
    end
  elseif plan.key == "tl_amdahls_law" then
    for _, candidate in ipairs(game.master_deck or {}) do
      if candidate.law_marks then candidate.law_marks.amdahl_bottleneck = nil; sync_entry(candidate) end
    end
    local entry = entry_by_uid(game, plan.target_uid)
    law_marks(entry).amdahl_bottleneck = true
    sync_entry(entry)
    result.changes[#result.changes + 1] = { kind = "bottleneck", uid = entry.uid, other_users_add = 10 }
  elseif plan.key == "tl_gustafsons_law" then
    for _, uid in ipairs(plan.entries) do
      local entry = entry_by_uid(game, uid)
      local amount = entry and named_sticker(entry, plan.key, "Gustafson", 8, 24) or 0
      if amount > 0 then result.changes[#result.changes + 1] = { kind = "users", uid = uid, amount = amount } end
    end
  elseif plan.key == "tl_wirths_law" then
    local entry = entry_by_uid(game, plan.target_uid)
    law_marks(entry).wirth_bloat = normalize_wirth({ applied_ante = plan.applied_ante }, plan.applied_ante)
    sync_entry(entry)
    game.cash = (game.cash or 0) + plan.cash
    result.cash = plan.cash
    result.changes[#result.changes + 1] = { kind = "wirth_bloat", uid = entry.uid,
      state = copy(entry.law_marks.wirth_bloat), cash = plan.cash }
  elseif plan.key == "tl_dunbars_number" then
    game.app_levels = game.app_levels or {}
    local before = math.max(1, game.app_levels[plan.app_key] or 1)
    game.app_levels[plan.app_key] = math.min(15, before + plan.amount)
    result.changes[#result.changes + 1] = { kind = "playbook", key = plan.app_key,
      before = before, after = game.app_levels[plan.app_key], amount = game.app_levels[plan.app_key] - before }
  elseif plan.key == "tl_linuss_law" then
    for _, uid in ipairs(plan.entries) do
      local entry = entry_by_uid(game, uid)
      if entry and not entry.enhancement and not entry.enh then
        entry.enhancement, entry.enh, entry.modifier_state = "scalable", nil, nil
        sync_entry(entry)
        result.changes[#result.changes + 1] = { kind = "enhancement", uid = uid, key = "scalable" }
      end
    end
  elseif plan.key == "tl_zawinskis_law" then
    result.post_consume = { kind = "create_tech_laws", count = plan.create_count, stream = plan.stream }
  elseif plan.key == "tl_kerckhoffs_principle" then
    local entry = entry_by_uid(game, plan.target_uid)
    law_marks(entry).well_formed = true
    sync_entry(entry)
    result.changes[#result.changes + 1] = { kind = "well_formed", uid = entry.uid }
  elseif plan.key == "tl_hyrums_law" then
    for _, uid in ipairs(plan.entries) do
      local entry = entry_by_uid(game, uid)
      entry.layer_override, entry.layer_locked = plan.layer, true
      law_marks(entry).hyrum_layer = true
      entry.stickers = entry.stickers or {}
      entry.stickers[#entry.stickers + 1] = {
        field = "rev", mode = "add", amount = 1, label = "Hyrum", source = plan.key,
      }
      sync_entry(entry)
      result.changes[#result.changes + 1] = { kind = "layer_lock", uid = uid, layer = plan.layer, rev_add = 1 }
    end
  elseif plan.key == "tl_sturgeons_law" then
    for _, uid in ipairs(plan.destroy) do
      if remove_uid(game, uid) then result.changes[#result.changes + 1] = { kind = "destroy", uid = uid } end
    end
    for _, uid in ipairs(plan.survivors) do
      local entry = entry_by_uid(game, uid)
      local amount = entry and named_sticker(entry, plan.key, "Sturgeon", 5, 10) or 0
      if amount > 0 then result.changes[#result.changes + 1] = { kind = "users", uid = uid, amount = amount } end
    end
  end

  if #result.changes == 0 and not result.post_consume then
    result.ok, result.reason = false, "Tech Law produced no change"
  end
  return result
end

function TechLaws.after_consumed(center_or_key, result, opts)
  if not (result and result.ok and result.post_consume and result.post_consume.kind == "create_tech_laws") then return result end
  opts = opts or {}
  local center = center_of(center_or_key)
  local rng = opts.rng or RNG.fn(result.post_consume.stream or "tech_law_create")
  local Consumables = require("game.consumables")
  local exclude = { [center.key] = true }
  for _ = 1, result.post_consume.count or 0 do
    local generated = TechLaws.roll(rng, { exclude = exclude })
    if not generated then break end
    exclude[generated.key] = true
    local entry = Consumables.grant(generated.key, { source = "zawinski", sell_basis = 0 })
    if not entry then break end
    result.generated[#result.generated + 1] = generated.key
    result.changes[#result.changes + 1] = { kind = "create_consumable", key = generated.key,
      instance_id = entry.instance_id, sell_basis = 0 }
  end
  result.post_consume = nil
  return result
end

function TechLaws.view(center_or_key, game)
  local center = center_of(center_or_key)
  if not center then return nil end
  game = game_of(game)
  local usable, reason = TechLaws.handles(center) and TechLaws.can_use(center, game) or true, nil
  if TechLaws.handles(center) then usable, reason = TechLaws.can_use(center, game) end
  return {
    key = center.key, name = center.name, kind = center.kind, rarity = center.rarity,
    description = center.desc, target = copy(center.target), price_units = center.price_units,
    usable = usable == true, unavailable_reason = usable and nil or reason,
    last_ship_app_key = game and game.last_ship_app_key,
    last_ship_coverage = game and last_coverage(game) or 0,
    state = game and copy(game.tech_law_state) or {},
  }
end

return TechLaws
