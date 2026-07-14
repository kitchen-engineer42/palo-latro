-- Optional, explicitly targeted Founder actions. This is intentionally small:
-- the DSL owns availability through its activated clause and direct state/economy
-- operations; this controller only chooses the live Founder instance.

local Interp = require("game.effect_interp")

local Actions = {}

function Actions.descriptor(card_or_center)
  local center = card_or_center and (card_or_center.center or card_or_center)
  local action = center and center.dsl and center.dsl.action
  if type(action) ~= "table" then return nil end
  local out = { label = action.label or "Activate", description = action.description }
  local card = card_or_center and card_or_center.center and card_or_center
  for _, clause in ipairs(center.dsl.clauses or { center.dsl }) do
    local gate = clause.hook == "activated" and clause.gate
    if gate and gate.g == "state" then
      local value = card and card.ability and card.ability.config
        and card.ability.config["_state_" .. gate.state] or 0
      out.state = {
        key = gate.state,
        label = tostring(gate.state):gsub("_", " "):gsub("^%l", string.upper),
        value = value,
        required = gate.val,
      }
      break
    end
  end
  return out
end

local function activation_context(card)
  local game = G and G.GAME or {}
  return {
    activated = true,
    other_card = card,
    final_arr = game.last_ship_arr or game._final_arr or game.this_ship_arr or 0,
  }
end

function Actions.can_activate(card)
  return card and not card.REMOVED and Actions.descriptor(card) ~= nil
    and Interp.can_run(card, activation_context(card))
end

function Actions.activate(card)
  if not (card and not card.REMOVED and Actions.descriptor(card)) then
    return false, "Founder has no activated action"
  end
  if not Actions.can_activate(card) then return false, "Founder action is not currently available" end
  local effect = Interp.run(card, activation_context(card))
  if effect == nil then return false, "Founder action is not currently available" end
  if effect.chips or effect.mult or effect.x_mult or effect.x_chips
      or effect.x_mult_add or effect.x_chips_add or effect.arr_floor then
    return false, "Activated actions cannot mutate an absent score"
  end
  local cash = (effect.dollars or 0) + (effect.p_dollars or 0)
  if cash ~= 0 then G.GAME.cash = (G.GAME.cash or 0) + cash end
  return true, { cash = cash }
end

return Actions
