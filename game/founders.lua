-- game/founders.lua — executable founder abilities (the joker `calculate` branches). Each is a
-- faithful-but-simplified version of last night's proposal, gated on its scoring context, returning
-- a standard effect table (chips/mult/x_mult/dollars) that scoring.lua's apply_effect consumes.
-- Card:calculate routes Founder cards here via G.FOUNDER_CALC — the scoring engine is untouched.

local Founders = {}
local Interp = require("game.effect_interp")   -- B2: data-driven ability interpreter
local Coverage = require("game.coverage")

-- Per-Founder trigger safety rails. These cap a single emitted effect, not the
-- final hand score (multiple Founders still compose normally). The signature
-- late-bloomer remains the deliberate exception to the generated-card ceiling.
Founders.MAX_X_MULT = 5
Founders.MAX_RETRIGGERS = 2

-- helpers -------------------------------------------------------------
local function others() return math.max(0, #G.jokers.cards - 1) end          -- other founders in row
local function empty_slots() return math.max(0, 5 - #G.jokers.cards) end

local function distinct_layers(ctx)
  return (ctx.coverage or Coverage.analyze(ctx.scoring_hand or {})).distinct
end

local function layer_present(ctx, layer)
  local cards = ctx.scoring_hand or {}
  return Coverage.has_layer(cards, layer, ctx.coverage or Coverage.analyze(cards))
end

local function has_founder(key)
  for _, c in ipairs(G.jokers.cards) do if c.center_key == key then return true end end
  return false
end

local function count_mafia()
  local n = 0
  for _, c in ipairs(G.jokers.cards) do if c.center and c.center.mafia then n = n + 1 end end
  return n
end

local function cfg(card) card.ability.config = card.ability.config or {}; return card.ability.config end

-- the 18 effects ------------------------------------------------------
local FX = {}

FX.f_musk = function(_, ctx)
  if ctx.joker_main then return { x_mult = 1 + 0.3 * distinct_layers(ctx) } end
end

FX.f_thiel = function(_, ctx)
  if not ctx.joker_main then return end
  local x = 1
  if distinct_layers(ctx) <= 2 then x = x * 2.0 end          -- monopoly = focus
  local mafia_others = count_mafia() - 1                      -- exclude self
  if mafia_others > 0 then x = x * (1 + 0.5 * mafia_others) end
  return { x_mult = x }
end

FX.f_levchin = function(_, ctx) if ctx.joker_main then return { chips = 25, mult = 10 } end end
FX.f_hoffman = function(_, ctx) if ctx.joker_main then return { mult = 12 * others() } end end

FX.f_sacks = function(_, ctx)
  if ctx.joker_main and (ctx.scoring_name == "SaaS" or ctx.scoring_name == "AI Feature App" or ctx.scoring_name == "Web App") then
    return { x_mult = 1.6 }
  end
end

FX.f_rabois = function(_, ctx) if ctx.joker_main and others() == 1 then return { x_mult = 1.6 } end end
FX.f_botha  = function(_, ctx) if ctx.after then return { dollars = 6 } end end

FX.f_hurley = function(_, ctx)
  if ctx.individual and ctx.other_card
    and Coverage.card_has_layer(ctx.other_card, "Frontend", ctx.coverage or Coverage.analyze(ctx.scoring_hand or {}))
  then return { chips = 50 } end
end

FX.f_chen = function(_, ctx)
  if ctx.joker_main and layer_present(ctx, "Infra") then return { chips = 25 * distinct_layers(ctx) } end
end

FX.f_stoppelman = function(card, ctx)
  if not ctx.joker_main then return end
  local c = cfg(card)
  local bonus = 20 * (c.reviews or 0)
  c.reviews = (c.reviews or 0) + 1                            -- bank one review per ship (scaling)
  return { chips = bonus }
end

FX.f_altman = function(_, ctx)
  if not ctx.joker_main then return end
  local x, chips = 1 + 0.5 * others(), 0
  if layer_present(ctx, "AI") then x = x * 1.5; chips = 25 * others() end
  return { x_mult = x, chips = chips }
end

FX.f_graham = function(_, ctx)
  if not ctx.joker_main then return end
  local x = 1 + 0.5 * others()
  if has_founder("f_altman") then x = x + 0.5 end             -- mentor edge (YC)
  return { x_mult = x }
end

FX.f_andreessen = function(card, ctx)
  if not ctx.joker_main then return end
  local c = cfg(card); c.eaten = (c.eaten or 0) + 1           -- permanent scaling
  return { mult = 8 * c.eaten }
end

FX.f_zuckerberg = function(_, ctx)
  if ctx.joker_main then return { chips = 15 * #(ctx.scoring_hand or {}) } end
end

FX.f_collison = function(_, ctx)
  if not ctx.joker_main then return end
  local nm = ctx.scoring_name
  local platformy = nm == "Infra/Backend Platform" or nm == "SaaS" or nm == "Platform/Ecosystem"
    or nm == "AI-Native Full Stack" or distinct_layers(ctx) >= 4
  if platformy then return { x_mult = 1 + 0.5 * others(), dollars = 3 } end
  return { dollars = 3 }
end

FX.f_chesky  = function(_, ctx) if ctx.joker_main then return { x_mult = 1 + 0.4 * empty_slots() } end end
FX.f_houston = function(_, ctx) if ctx.joker_main then return { mult = 10 * others() } end end
FX.f_dorsey  = function(_, ctx) if ctx.after then return { mult = 15, dollars = 5 } end end

-- Signature founder: kitchen-engineer42 starts a ×0.9 drag; the ×Mult INCREMENT doubles each ante
-- survived → 0.9, 1.0, 1.2, 1.6, 2.4, 4.0, 7.2, 13.6, ×26.4 by IPO. Closed form: x = 0.8 + 0.1·2^k,
-- k = antes survived since hire. Firing her removes the card (curve auto-resets) + deletes the signature Tech.
FX["f_kitchen-engineer42"] = function(card, ctx)
  if not ctx.joker_main then return end
  local c = cfg(card)
  local k = math.max(0, (G.GAME.ante or 1) - (c._hire_ante or G.GAME.ante or 1))
  return { x_mult = 0.8 + 0.1 * 2 ^ k }
end

Founders.FX = FX

-- B1 fallback: the 262 graph-projected founders have no hand-coded FX yet (those f_<lastname> entries
-- are now restoration fixtures). Until the B2 effect interpreter lands, every founder does SOMETHING —
-- a flat effect keyed off its embedded effect.type + rarity tier — so the full pool is playable.
local RTIER = { Common = 1, Uncommon = 2, Rare = 3, Legendary = 4 }
local function fallback(card, ctx)
  local ce = card.center or {}
  local eff = ce.effect or {}
  local tier = RTIER[ce.rarity] or 1
  local etype = eff.type or "plus_mult"
  if etype == "economy" then
    if ctx.after then return { dollars = 2 * tier } end
    return nil
  end
  if not ctx.joker_main then return nil end
  if etype == "xmult" then return { x_mult = 1 + 0.1 * tier } end
  if etype == "plus_chips" then return { chips = 15 * tier } end
  if etype == "plus_mult" then return { mult = 4 * tier } end
  return { mult = 2 * tier }   -- utility / generation / retrigger (data_only) — token value until B3
end

-- the dispatch seam Card:calculate calls for Founder cards
G.FOUNDER_CALC = function(card, ctx)
  local fn = FX[card.center_key]
  local effect
  if fn then effect = fn(card, ctx)                            -- (legacy hand-coded; now fixtures)
  elseif card.center and card.center.dsl then effect = Interp.run(card, ctx)  -- B2: compiled abilities
  else effect = fallback(card, ctx) end                        -- data-only fallback
  local scale = card.ability and card.ability.config and card.ability.config._effect_scale
  if effect and scale and scale ~= 1 then
    for _, field in ipairs({ "chips", "mult", "dollars", "p_dollars", "x_mult_add", "x_chips_add",
        "chips_floor", "mult_floor", "arr_floor" }) do
      if effect[field] then effect[field] = effect[field] * scale end
    end
    if effect.x_mult then effect.x_mult = 1 + (effect.x_mult - 1) * scale end
    if effect.x_chips then effect.x_chips = 1 + (effect.x_chips - 1) * scale end
  end
  if effect and not (card.center and card.center.signature) and effect.x_mult then
    effect.x_mult = math.min(Founders.MAX_X_MULT, effect.x_mult)
  end
  local repetitions = effect and effect.jokers and effect.jokers.repetitions
  if repetitions then
    repetitions = math.max(0, math.min(Founders.MAX_RETRIGGERS, math.floor(repetitions)))
    if scale and scale < 1 then
      local c = cfg(card)
      local scaled = repetitions * math.max(0, scale) + (tonumber(c._scaled_retrigger_carry) or 0)
      repetitions = math.floor(scaled)
      c._scaled_retrigger_carry = scaled - repetitions
    end
    effect.jokers.repetitions = repetitions
  end
  return effect
end

return Founders
