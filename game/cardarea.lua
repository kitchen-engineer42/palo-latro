-- game/cardarea.lua — CardArea(Moveable): a container for any group of cards (deck, hand, play).
-- Lays cards out in a centered row (cards ease into place via Moveable). Areas are invisible.

CardArea = Moveable:extend()

function CardArea:init(args)
  args = args or {}
  CardArea.super.init(self, args)
  self.cards = {}
  self.config = { type = args.type or "area", card_limit = args.card_limit or 52 }
  self.states.collide.can = false
  table.insert(G.I.CARDAREA, self)
end

function CardArea:emplace(card, skip_align)
  if card.area then card.area:remove_card(card, true) end
  table.insert(self.cards, card)
  card.area = self
  if not skip_align then self:align_cards() end
end

function CardArea:remove_card(card, skip_align)
  for i, c in ipairs(self.cards) do
    if c == card then table.remove(self.cards, i); break end
  end
  if card.area == self then card.area = nil end
  if not skip_align then self:align_cards() end
end

function CardArea:highlighted()
  local r = {}
  for _, c in ipairs(self.cards) do if c.selected then r[#r + 1] = c end end
  return r
end

function CardArea:clear()
  for i = #self.cards, 1, -1 do self.cards[i].area = nil; self.cards[i] = nil end
end

-- centered row layout; selected cards lift up
function CardArea:align_cards()
  local n = #self.cards
  if n == 0 then return end
  if self.config.type == "deck" then           -- a neat draw pile: only the top few cards show depth
    for i, c in ipairs(self.cards) do
      c._area_index = i
      local d = math.min(i, 6)
      c:set_T(self.T.x + d * 1.3, self.T.y - d * 1.3)
    end
    return
  end
  local cw = self.cards[1].T.w
  local gap = 12
  local step = cw + gap
  if n > 1 and (n * cw + (n - 1) * gap) > self.T.w then  -- too many → overlap to stay WITHIN the area (Balatro)
    step = (self.T.w - cw) / (n - 1)
  end
  local total = (n - 1) * step + cw
  local startx = self.T.x + (self.T.w - total) / 2
  local basey = self.T.y + (self.T.h - self.cards[1].T.h) / 2
  for i, c in ipairs(self.cards) do
    c._area_index = i
    local x = startx + (i - 1) * step
    local y = basey + (c.selected and -26 or 0)
    c:set_T(x, y)
  end
end

return CardArea
