-- Shared Founder event boundary. Transactions publish only after their own
-- validation succeeds, so an event can never describe a rejected purchase or
-- stale pack choice. The scoring interpreter remains the single consumer.

local Events = {}

local function copy_into(base, extra)
  for key, value in pairs(extra or {}) do base[key] = value end
  return base
end

function Events.fire(name, payload)
  if not (G and G.GAME and G.jokers) then return end
  require("game.scoring").fire_hook(name, payload or {})
end

function Events.spend(game, amount, kind, payload)
  game = game or (G and G.GAME)
  amount = tonumber(amount) or 0
  if not game or amount < 0 or amount ~= amount or amount == math.huge then return false end
  -- Explicitly free transactions remain valid even when the run is below zero;
  -- callers use this for earned offers and packs with zero sell basis.
  if amount == 0 then return true end
  if (game.cash or 0) < amount then return false end
  game.cash = (game.cash or 0) - amount
  game.cash_spent_round = (game.cash_spent_round or 0) + amount
  Events.fire("cash_spent", copy_into({ amount = amount, spend_kind = kind }, payload))
  return true
end

function Events.pack_selected(payload)
  Events.fire("pack_selected", payload or {})
end

return Events
