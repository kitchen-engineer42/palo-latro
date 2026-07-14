-- game/consumables.lua — the Tech Law (Tarot) consumable engine (Track C B). Applies a Consumable center's
-- declarative `ops` against the persistent master_deck + economy. The 5 MVP ops:
--   sticker  — append a persistent card-stat modifier (field=users|rev, mode=add|mul|override) to a target
--   cash     — grant Cash (clamped to floor/cap)
--   destroy  — remove a deck card (player-picked or live-deck extremum) + optional Cash refund
--   mint     — append a fresh copy of a seed card (extremum/player) to the deck
--   set_layer— override a target card's Layer for the run
-- Targeted ops resolve against the LIVE card (by uid) AND write the master_deck entry, so the change both
-- takes effect this blind and persists across blinds. NOTE: the interactive USE_CARD/TARGET_SELECT input flow,
-- shop acquisition, and sell are NOT here yet (they need a GUI playtest) — see the runtime contract
local Centers = require("game.centers")
local Coverage = require("game.coverage")

local Consumables = {}

local function live_by_uid(uid)
  if not uid then return nil end
  for _, area in ipairs({ G.deck, G.hand, G.play }) do
    if area and area.cards then
      for _, c in ipairs(area.cards) do if c.uid == uid then return c end end
    end
  end
end

local function master_entry(uid)
  for _, e in ipairs((G.GAME and G.GAME.master_deck) or {}) do if e.uid == uid then return e end end
end

local function ctx_users(c) return (c.get_users and c:get_users()) or c.base_users or 0 end

-- live deck+hand pool, by contextual Users extremum
local function pick_extremum(which)
  local t
  for _, area in ipairs({ G.hand, G.deck }) do
    if area and area.cards then
      for _, c in ipairs(area.cards) do
        if not t then t = c
        elseif which == "max_users" and ctx_users(c) > ctx_users(t) then t = c
        elseif which == "min_users" and ctx_users(c) < ctx_users(t) then t = c end
      end
    end
  end
  return t
end

local function add_sticker(c, st)
  local e = c.uid and master_entry(c.uid)
  if e then e.stickers = e.stickers or {}; e.stickers[#e.stickers + 1] = st end   -- persist
  c.stickers = c.stickers or {}; c.stickers[#c.stickers + 1] = st                 -- live (this blind)
end

-- apply a consumable. `targets` = list of resolved target Cards (for player-pick ops); `opts.layer` for set_layer.
function Consumables.apply(center, targets, opts)
  local Round = require("game.round")   -- deferred (avoid load cycle): master_add/master_remove_uid
  targets = targets or {}
  opts = opts or {}
  local g = G.GAME
  for _, op in ipairs(center.ops or {}) do
    if op.k == "cash" then
      local v = op.amount or 0
      if op.floor then v = math.max(op.floor, v) end
      if op.cap then v = math.min(op.cap, v) end
      g.cash = (g.cash or 0) + v

    elseif op.k == "sticker" then
      local c = targets[1]
      if c then add_sticker(c, { field = op.field, mode = op.mode, amount = op.amount, label = op.label }) end

    elseif op.k == "set_layer" then
      local c, L = targets[1], opts.layer or op.layer
      if c and Coverage.is_core(L) then
        L = Coverage.normalize_layer(L)
        local e = c.uid and master_entry(c.uid); if e then e.layer_override = L end
        c.layer_override = L
      end

    elseif op.k == "destroy" then
      local c = (op.select == "max_users" or op.select == "min_users") and pick_extremum(op.select) or targets[1]
      if c then
        local refund = 0
        if op.refund then
          refund = op.refund.amount or math.floor(ctx_users(c) * (op.refund.frac or 0))
          if op.refund.floor then refund = math.max(op.refund.floor, refund) end
          if op.refund.cap then refund = math.min(op.refund.cap, refund) end
        end
        Round.master_remove_uid(c.uid)
        if c.area then c.area:remove_card(c, true) end
        if c.remove then c:remove() end
        if refund > 0 then g.cash = (g.cash or 0) + refund end
      end

    elseif op.k == "mint" then
      local seed = (op.source == "max_users" or op.source == "min_users") and pick_extremum(op.source) or targets[1]
      local key = seed and (seed.center_key or (seed.center and seed.center.key))
      if key then Round.master_add(key, {}) end   -- fresh copy, no editions/seals/stickers
    end
  end
end

-- inventory: plain-data mirror in G.GAME.consumables + a live Card in the G.consumables area (Track C B1)
function Consumables.grant(key)
  local center = Centers.get(key)
  if not (center and G.GAME) then return nil end
  G.GAME.consumables = G.GAME.consumables or {}
  if #G.GAME.consumables >= (G.GAME.consumable_slots or 2) then return nil end   -- slot cap
  local entry = { key = key }
  G.GAME.consumables[#G.GAME.consumables + 1] = entry
  if G.consumables and Card then                                                 -- live card (GUI contexts)
    local c = Card({ center = center, T = { x = G.consumables.T.x, y = G.consumables.T.y } })
    G.consumables:emplace(c)
    entry.card_id = c.ID
  end
  return entry
end

function Consumables.remove(card)                       -- drop from the inventory mirror + the live area
  local g = G.GAME
  if g and g.consumables then
    for i = #g.consumables, 1, -1 do
      local e = g.consumables[i]
      if (card.ID and e.card_id == card.ID) or (not e.card_id and e.key == card.center_key) then
        table.remove(g.consumables, i); break
      end
    end
  end
  if card.area then card.area:remove_card(card, true) end
  if card.remove then card:remove() end
end

-- the full USE path (B2/B4): fire the founder hook, apply, consume. `targets`/`opts` as in apply().
function Consumables.use(card, targets, opts)
  if not (card and card.center) then return false end
  local Scoring = require("game.scoring")
  if Scoring.fire_hook then Scoring.fire_hook("use_consumable", { consumable = card.center, targets = targets }) end
  Consumables.apply(card.center, targets, opts)
  Consumables.remove(card)
  return true
end

return Consumables
