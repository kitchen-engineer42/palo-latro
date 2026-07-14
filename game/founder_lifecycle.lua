-- Transaction boundary for every Founder entry/exit route.

local Interp = require("game.effect_interp")

local Lifecycle = {}

local function config(card)
  card.ability.config = card.ability.config or {}
  return card.ability.config
end

function Lifecycle.acquire(card, opts)
  opts = opts or {}
  assert(card and card.center and card.center.set == "Founder", "Founder lifecycle requires a Founder card")
  local cfg = config(card)
  if cfg._acquired then return false end
  cfg._acquired = true
  cfg._hire_round = (G.GAME and G.GAME.round_num) or 0
  cfg._hire_ante = (G.GAME and G.GAME.ante) or 1
  cfg._sell_basis = opts.sell_basis or 0
  cfg._source = opts.source or "unknown"
  if opts.stake_mod then
    cfg._stake_mod = opts.stake_mod.kind
    if opts.stake_mod.kind == "unsellable" then cfg._unsellable = true end
    if opts.stake_mod.kind == "expiring" then cfg._expires_in = opts.stake_mod.blinds or 5 end
    if opts.stake_mod.kind == "rental" then cfg._rental_salary_mult = opts.stake_mod.salary_mult or 1.5 end
  end
  G.GAME.founders_hired_run = (G.GAME.founders_hired_run or 0) + 1
  require("game.leads").on_founder_acquired(G.GAME, card)
  Interp.apply_passive(card)
  if card.center_key == "f_kitchen-engineer42" and G.GENERATE then
    G.GENERATE("specific_tech_card", { key = "t_joharness-burg", amount = 1 })
    cfg._signature_key = "t_joharness-burg"
  end
  return true
end

function Lifecycle.distill(card)
  local cfg = card and config(card)
  if not cfg or cfg._distilled then return false end
  cfg._distilled = true
  cfg._salary = math.max(1, math.floor(((card.center and card.center.salary) or 2) / 2))
  cfg._effect_scale = 0.5
  return true
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

  if cfg._signature_key and G.GENERATE then G.GENERATE("remove_tech_card", { key = cfg._signature_key }) end
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
