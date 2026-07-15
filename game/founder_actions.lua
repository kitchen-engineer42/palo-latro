-- Optional, explicitly targeted Founder actions. This is intentionally small:
-- the DSL owns availability through its activated clause and direct state/economy
-- operations; this controller only chooses the live Founder instance.

local Interp = require("game.effect_interp")

local Actions = {}

function Actions.descriptor(card_or_center)
  local center = card_or_center and (card_or_center.center or card_or_center)
  local action = center and center.dsl and center.dsl.action
  if type(action) ~= "table" then return nil end
  local out = { label = action.label or "Activate", description = action.description,
    target = action.target }
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

local function target_source(center)
  local specs = center and center.dsl and (center.dsl.clauses or { center.dsl }) or {}
  for _, clause in ipairs(specs) do
    if clause.hook == "activated" then
      for _, op in ipairs(clause.ops or {}) do
        if op.k == "mutate" and op.target == "tech_uid" then return op.from or "master_deck" end
      end
    end
  end
  return "master_deck"
end

local function live_uid(area, uid)
  for _, subject in ipairs((area and area.cards) or {}) do if subject.uid == uid then return true end end
  return false
end

local function eligible_target(card, uid)
  if type(uid) ~= "number" or uid % 1 ~= 0 or uid < 1 then return false end
  local found = false
  for _, entry in ipairs((G.GAME and G.GAME.master_deck) or {}) do
    if entry.uid == uid then found = true; break end
  end
  if not found then return false end
  return target_source(card.center) ~= "hand" or live_uid(G.hand, uid)
end

function Actions.available_targets(card)
  local descriptor = Actions.descriptor(card)
  if not (descriptor and descriptor.target == "tech_uid") then return {} end
  local source = target_source(card.center)
  local out, seen = {}, {}
  if source == "hand" then
    for _, subject in ipairs((G.hand and G.hand.cards) or {}) do
      if subject.uid and eligible_target(card, subject.uid) and not seen[subject.uid] then
        out[#out + 1], seen[subject.uid] = subject.uid, true
      end
    end
  else
    for _, entry in ipairs((G.GAME and G.GAME.master_deck) or {}) do
      if eligible_target(card, entry.uid) then out[#out + 1] = entry.uid end
    end
  end
  table.sort(out)
  return out
end

function Actions.selected_target_uid(card)
  local picked
  for _, subject in ipairs((G.hand and G.hand.cards) or {}) do
    if subject.selected then
      if picked then return nil end
      picked = subject.uid
    end
  end
  return picked and eligible_target(card, picked) and picked or nil
end

local function activation_context(card, target_uid)
  local game = G and G.GAME or {}
  return {
    activated = true,
    other_card = card,
    target_uid = target_uid,
    final_arr = game.last_ship_arr or game._final_arr or game.this_ship_arr or 0,
  }
end

function Actions.can_activate(card, target_uid)
  local descriptor = card and Actions.descriptor(card)
  if not (card and not card.REMOVED and descriptor) then return false end
  if descriptor.target == "tech_uid" and not eligible_target(card, target_uid) then return false end
  return Interp.can_run(card, activation_context(card, target_uid))
end

function Actions.activate(card, target_uid)
  if not (card and not card.REMOVED and Actions.descriptor(card)) then
    return false, "Founder has no activated action"
  end
  if not Actions.can_activate(card, target_uid) then return false, "Founder action is not currently available" end
  local effect = Interp.run(card, activation_context(card, target_uid))
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
