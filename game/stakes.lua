local Definitions = require("data.gameplay.stakes")
local Stakes = { list = Definitions }

function Stakes.apply(g, stake)
  stake = math.max(1, math.min(#Definitions, math.floor(tonumber(stake) or 1)))
  local base_pivots_bonus = (g.pivots_bonus or 0) - (g._stake_pivots_delta or 0)
  local stake_pivots_delta = 0
  g.stake, g.target_mult, g.late_target_mult = stake, 1, 1
  g.stake_offer_mods = {}
  g.reliability_stake_delta = 0
  for i = 1, stake do
    local rule = Definitions[i]
    g.target_mult = g.target_mult * (rule.target_mult or 1)
    g.late_target_mult = g.late_target_mult * (rule.late_target_mult or 1)
    stake_pivots_delta = stake_pivots_delta + (rule.pivots_delta or 0)
    g.reliability_stake_delta = g.reliability_stake_delta + (rule.reliability_delta or 0)
    if rule.offer_mod then g.stake_offer_mods[#g.stake_offer_mods + 1] = rule.offer_mod end
  end
  g._stake_pivots_delta = stake_pivots_delta
  g.pivots_bonus = base_pivots_bonus + stake_pivots_delta
end

function Stakes.roll_offer_mod(g, rng)
  rng = rng or love.math.random
  local eligible = {}
  for _, mod in ipairs((g and g.stake_offer_mods) or {}) do if rng() < (mod.chance or 0) then eligible[#eligible + 1] = mod end end
  if #eligible == 0 then return nil end
  return eligible[math.floor(rng() * #eligible) + 1]
end

return Stakes
