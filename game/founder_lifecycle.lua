-- Transaction boundary for every Founder entry/exit route.

local Interp = require("game.effect_interp")
local SignaturePair = require("game.signature_pair")

local Lifecycle = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function config(card)
  card.ability.config = card.ability.config or {}
  return card.ability.config
end

local function valid_id(value)
  return type(value) == "number" and value == value and value ~= math.huge
    and value ~= -math.huge and value % 1 == 0 and value >= 1
end

-- Founder centers are not instances: Spinout can deliberately leave two live
-- cards pointing at the same center. Keep a monotonic live-run identity on card
-- config so protocol actions survive reorder and remain unique. The counter is
-- plain RunState data; active Founder cards themselves are not save-serialized yet.
function Lifecycle.normalize_ids(game, cards)
  game = game or (G and G.GAME)
  if not game then return 0 end
  local next_id = tonumber(game.founder_next_id)
  if not next_id or next_id ~= next_id or next_id == math.huge or next_id == -math.huge then next_id = 0 end
  next_id = math.max(0, math.floor(next_id))

  local used, pending = {}, {}
  for _, record in ipairs(game.automated_founders or {}) do
    local id = record.config and record.config._founder_id
    if valid_id(id) then used[id], next_id = true, math.max(next_id, id) end
  end
  for _, card in ipairs(cards or ((G and G.jokers and G.jokers.cards) or {})) do
    local cfg, id = config(card), nil
    id = cfg._founder_id
    if valid_id(id) and not used[id] then
      used[id], next_id = true, math.max(next_id, id)
    else
      cfg._founder_id = nil
      pending[#pending + 1] = cfg
    end
  end
  for _, cfg in ipairs(pending) do
    repeat next_id = next_id + 1 until not used[next_id]
    cfg._founder_id, used[next_id] = next_id, true
  end
  game.founder_next_id = next_id
  return next_id
end

local function assign_id(card)
  local game = G and G.GAME
  if not game then return nil end
  Lifecycle.normalize_ids(game)
  local cfg = config(card)
  if valid_id(cfg._founder_id) then return cfg._founder_id end
  local next_id = (game.founder_next_id or 0) + 1
  game.founder_next_id, cfg._founder_id = next_id, next_id
  return next_id
end

function Lifecycle.acquire(card, opts)
  opts = opts or {}
  assert(card and card.center and card.center.set == "Founder", "Founder lifecycle requires a Founder card")
  local cfg = config(card)
  assign_id(card)
  if cfg._acquired then return false end
  cfg._acquired = true
  cfg._hire_round = (G.GAME and G.GAME.round_num) or 0
  cfg._hire_ante = (G.GAME and G.GAME.ante) or 1
  cfg._sell_basis = opts.sell_basis or 0
  cfg._source = opts.source or "unknown"
  if opts.salary ~= nil then cfg._salary = math.max(1, math.floor(opts.salary + 0.5)) end
  if opts.negotiation then cfg._negotiation = copy(opts.negotiation) end
  if opts.stake_mod then
    cfg._stake_mod = opts.stake_mod.kind
    if opts.stake_mod.kind == "unsellable" then cfg._unsellable = true end
    if opts.stake_mod.kind == "expiring" then cfg._expires_in = opts.stake_mod.blinds or 5 end
    if opts.stake_mod.kind == "rental" then cfg._rental_salary_mult = opts.stake_mod.salary_mult or 1.5 end
  end
  G.GAME.founders_hired_run = (G.GAME.founders_hired_run or 0) + 1
  G.GAME.founders_hired_round = (G.GAME.founders_hired_round or 0) + 1
  require("game.leads").on_founder_acquired(G.GAME, card)
  Interp.apply_passive(card)
  if card.center_key == SignaturePair.KITCHEN_KEY and G.GENERATE then
    local existing = SignaturePair.find_jo(G.GAME)
    local result = existing and { ok = true, added_uids = { existing.uid } } or G.GENERATE(
      "specific_tech_card", {
        key = SignaturePair.JO_KEY, amount = 1, source = "signature_pair",
        signature_injection = SignaturePair.INJECTION_TOKEN,
      })
    local added = result and result.added_uids and result.added_uids[1]
    local entry = SignaturePair.find_jo(G.GAME) or (added and { uid = added })
    if result == nil or result.ok then
      cfg._signature_key = SignaturePair.JO_KEY
      SignaturePair.mark_paired(G.GAME, entry)
    end
  end
  require("game.founder_events").fire("founder_hired", {
    founder = card, other_card = card, founder_key = card.center_key,
    source = cfg._source, founders_hired_round = G.GAME.founders_hired_round,
  })
  return true
end

function Lifecycle.distill(card)
  local cfg = card and config(card)
  if not cfg or cfg._distilled or (card.center and card.center.dsl and card.center.dsl.passive) then return false end
  local current_salary = cfg._salary
  if current_salary == nil then current_salary = (card.center and card.center.salary) or 2 end
  cfg._distilled = true
  cfg._salary = math.max(1, math.floor(current_salary / 2))
  cfg._effect_scale = 0.5
  return true
end

function Lifecycle.can_distill(card)
  local cfg = card and card.ability and card.ability.config
  return card ~= nil and not (cfg and cfg._distilled)
    and not (card.center and card.center.dsl and card.center.dsl.passive)
end

function Lifecycle.can_promote(card)
  return card ~= nil and not (card.center and card.center.dsl and card.center.dsl.action)
end

function Lifecycle.tick_blind(card)
  local cfg = card and card.ability and card.ability.config
  if not (cfg and cfg._expires_in) then return false end
  cfg._expires_in = cfg._expires_in - 1
  return cfg._expires_in <= 0
end

function Lifecycle.remove(card, opts)
  opts = opts or {}
  if not (card and card.center) then return false end
  local cfg = config(card)
  if cfg._removed then return false end
  cfg._removed = true

  if cfg._signature_key and G.GENERATE then
    G.GENERATE("remove_tech_card", {
      key = cfg._signature_key, source = "signature_pair",
      signature_injection = SignaturePair.INJECTION_TOKEN,
    })
    SignaturePair.mark_removed(G.GAME)
  end
  Interp.revert_passive(card)
  if opts.promote then
    G.GAME.automated_founders = G.GAME.automated_founders or {}
    local retained = {}
    for k, v in pairs(cfg) do retained[k] = v end
    retained._effect_scale = 0.5
    G.GAME.automated_founders[#G.GAME.automated_founders + 1] = {
      center_key = card.center_key,
      effect_scale = 0.5,
      config = retained,
    }
  end
  if opts.before_remove then opts.before_remove(card) end
  if card.area then card.area:remove_card(card, false)
  elseif G.jokers and G.jokers.cards then
    for _, owned in ipairs(G.jokers.cards) do
      if owned == card then G.jokers:remove_card(card, false); break end
    end
  end
  if card.remove then card:remove() end
  return true
end

return Lifecycle
