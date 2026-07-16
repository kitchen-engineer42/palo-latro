-- Canonical identity and plain-data run state for the paired signature cards.
-- This module deliberately has no content-registry dependency so save
-- normalization can run before centers are loaded.

local Pair = {
  KITCHEN_KEY = "f_kitchen-engineer42",
  JO_KEY = "t_joharness-burg",
  ROLL_STREAM = "signature_secret",
  ROLL_CHANCE = 0.01,
  INJECTION_TOKEN = "kitchen-founder-pair",
}

local function whole(value, minimum)
  return type(value) == "number" and value == value and value ~= math.huge
    and value ~= -math.huge and value == math.floor(value) and value >= (minimum or 0)
end

local function valid_text(value)
  return type(value) == "string" and value ~= ""
end

local function normalize_rolls(value)
  local out, seen = {}, {}
  if type(value) ~= "table" then return out end
  for _, roll in ipairs(value) do
    if type(roll) == "table" then
      local id = roll.offer_id
      if valid_text(id) and not seen[id] and whole(roll.ante, 7)
          and valid_text(roll.pack_key) and type(roll.hit) == "boolean" then
        seen[id] = true
        out[#out + 1] = {
          offer_id = id,
          open_id = valid_text(roll.open_id) and roll.open_id or nil,
          pack_key = roll.pack_key,
          ante = roll.ante,
          hit = roll.hit,
        }
      end
    end
  end
  return out
end

function Pair.normalize(game)
  if type(game) ~= "table" then return nil end
  local source = type(game.signature_secret) == "table" and game.signature_secret or {}
  local rolls = normalize_rolls(source.rolls)
  local offered = source.offered == true or source.offered_once == true
  local hired = source.hired == true
  local pair_state = source.pair_state
  if pair_state ~= "hidden" and pair_state ~= "offered" and pair_state ~= "paired"
      and pair_state ~= "removed" then pair_state = nil end
  if hired then pair_state = "paired"
  elseif offered and pair_state ~= "removed" then pair_state = "offered"
  else pair_state = pair_state or "hidden" end
  game.signature_secret = {
    version = 1,
    offered = offered,
    offered_once = offered,
    hired = hired,
    pair_state = pair_state,
    offered_open_id = valid_text(source.offered_open_id) and source.offered_open_id or nil,
    offered_ante = whole(source.offered_ante, 7) and source.offered_ante or nil,
    offered_pack_key = valid_text(source.offered_pack_key) and source.offered_pack_key or nil,
    jo_uid = whole(source.jo_uid, 1) and source.jo_uid or nil,
    rolls = rolls,
  }
  return game.signature_secret
end

function Pair.identity(center)
  local source = center and center.identity
  if type(source) ~= "table" then return nil end
  return {
    era = source.era,
    game_era = source.game_era,
    product = source.product,
    ai_maturity = source.ai_maturity,
    tech_layer = source.tech_layer,
    role = source.role,
  }
end

function Pair.identity_label(center)
  local identity = Pair.identity(center)
  if not identity then return nil end
  local maturity = identity.ai_maturity == "agent_harnesses" and "Agent Harnesses"
    or tostring(identity.ai_maturity or "")
  return table.concat({ tostring(identity.era), tostring(identity.game_era),
    tostring(identity.product), maturity, tostring(identity.tech_layer) }, " · ")
end

function Pair.is_eligible_pack(game, definition)
  local state = Pair.normalize(game)
  return state ~= nil and not state.offered_once and (game.ante or 1) >= 7
    and definition and definition.family == "hiring" and definition.size == "mega"
end

local function existing_roll(state, offer_id)
  for _, roll in ipairs(state.rolls) do
    if roll.offer_id == offer_id then return roll end
  end
end

-- Returns (hit, rolled). `random` is called exactly once only for a new,
-- eligible pack. The result is recorded before the option is exposed.
function Pair.roll_offer(game, pack_open, definition, random)
  if not Pair.is_eligible_pack(game, definition) then return false, false end
  local state = Pair.normalize(game)
  local offer_id = pack_open and (pack_open.source_offer_id or pack_open.open_id)
  if not valid_text(offer_id) or type(random) ~= "function" then return false, false end
  local previous = existing_roll(state, offer_id)
  if previous then return previous.hit, false end
  local hit = random() < Pair.ROLL_CHANCE
  state.rolls[#state.rolls + 1] = {
    offer_id = offer_id,
    open_id = pack_open.open_id,
    pack_key = definition.key,
    ante = game.ante,
    hit = hit,
  }
  if hit then
    state.offered = true
    state.offered_once = true
    state.pair_state = "offered"
    state.offered_open_id = pack_open.open_id
    state.offered_ante = game.ante
    state.offered_pack_key = definition.key
  end
  return hit, true
end

function Pair.offer_token(game, pack_open)
  local state = Pair.normalize(game)
  return {
    kind = "signature-founder",
    key = Pair.KITCHEN_KEY,
    open_id = pack_open.open_id,
    offer_id = pack_open.source_offer_id,
    ante = state.offered_ante,
  }
end

function Pair.valid_offer(game, pack_open, option, center)
  local state = Pair.normalize(game)
  local token = option and option.secret_offer
  return center and center.key == Pair.KITCHEN_KEY and center.set == "Founder"
    and center.signature == true and type(token) == "table"
    and token.kind == "signature-founder" and token.key == Pair.KITCHEN_KEY
    and token.open_id == pack_open.open_id and state.offered == true
    and state.offered_once == true and state.hired ~= true
    and state.offered_open_id == pack_open.open_id
end

function Pair.find_jo(game)
  for _, entry in ipairs((game and game.master_deck) or {}) do
    if entry.center_key == Pair.JO_KEY then return entry end
  end
end

function Pair.mark_paired(game, entry)
  local state = Pair.normalize(game)
  if not state then return end
  state.hired = true
  state.pair_state = "paired"
  state.jo_uid = entry and entry.uid or (Pair.find_jo(game) or {}).uid
end

function Pair.mark_removed(game)
  local state = Pair.normalize(game)
  if not state then return end
  state.hired = false
  state.pair_state = "removed"
  state.jo_uid = nil
end

return Pair
