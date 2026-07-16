-- One authoritative card stack order for rendering and pointer hit testing.
--
-- CardArea order is visual order: later/right cards overlay earlier/left cards.  Hover and selection
-- are deliberately absent from this key.  The only temporary lift is the Founder currently being
-- dragged.  Callers that need keyboard/gamepad traversal must keep a separate navigation order.

local CardStack = {}

local AREA_RANK = {
  deck = 1,
  jokers = 2,
  play = 3,
  hand = 4,
  consumables = 5,
}

local function area_type(card)
  return card and card.area and card.area.config and card.area.config.type or ""
end

local function area_index(card)
  local list = card and card.area and card.area.cards
  if list then
    for index, candidate in ipairs(list) do if candidate == card then return index end end
  end
  return tonumber(card and card._area_index) or 0
end

local function stable_id(card)
  if not card then return "" end
  return tostring(card.ID or card.uid or card.instance_id or card.consumable_instance_id
    or card.center_key or (card.center and card.center.key) or "")
end

local function drag_lift(card, kind)
  return kind == "jokers" and card and card.states and card.states.drag
    and card.states.drag.is == true and 1 or 0
end

function CardStack.key(card)
  local kind = area_type(card)
  return {
    lift = drag_lift(card, kind),
    area = AREA_RANK[kind] or 6,
    index = area_index(card),
    id = stable_id(card),
  }
end

function CardStack.less(a, b)
  local ka, kb = CardStack.key(a), CardStack.key(b)
  if ka.lift ~= kb.lift then return ka.lift < kb.lift end
  if ka.area ~= kb.area then return ka.area < kb.area end
  if ka.index ~= kb.index then return ka.index < kb.index end
  return ka.id < kb.id
end

function CardStack.sorted(cards)
  local out = {}
  for _, card in ipairs(cards or {}) do out[#out + 1] = card end
  table.sort(out, CardStack.less)
  return out
end

function CardStack.area_index(card) return area_index(card) end
function CardStack.area_rank(card) return AREA_RANK[area_type(card)] or 6 end

return CardStack
