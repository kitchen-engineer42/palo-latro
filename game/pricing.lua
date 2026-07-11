local Economy = require("game.economy")

local Pricing = {}

local FOUNDER_REROLLS = { Common = 0.8, Uncommon = 1.4, Rare = 2.0, Legendary = 4.0 }

function Pricing.base_reroll(g, ante_base)
  return 5 * Economy.unit(g, ante_base)
end

function Pricing.reroll(g, ante_base, rerolls)
  return math.max(1, math.floor(Pricing.base_reroll(g, ante_base) * (1 + 0.2 * (rerolls or 0)) + 0.5))
end

function Pricing.founder(g, ante_base, center)
  local rarity = center and center.rarity or "Common"
  local weight = center and center.cost_weight or 1
  return math.max(2, math.floor(Pricing.base_reroll(g, ante_base) * (FOUNDER_REROLLS[rarity] or 1.4) * weight + 0.5))
end

function Pricing.pack(g, ante_base, size)
  local ratios = { normal = 0.8, jumbo = 1.2, mega = 1.6 }
  return math.max(2, math.floor(Pricing.base_reroll(g, ante_base) * (ratios[size or "normal"] or 0.8) + 0.5))
end

function Pricing.voucher(g, ante_base)
  return math.max(2, math.floor(Pricing.base_reroll(g, ante_base) * 2 + 0.5))
end

function Pricing.sell_basis(card_or_entry, fallback_price)
  local cfg = card_or_entry and card_or_entry.ability and card_or_entry.ability.config
  return (cfg and cfg._sell_basis) or (card_or_entry and card_or_entry.sell_basis) or fallback_price or 0
end

function Pricing.sell_value(card_or_entry, fallback_price)
  return math.max(0, math.floor(Pricing.sell_basis(card_or_entry, fallback_price) * 0.5))
end

return Pricing
