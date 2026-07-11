local AppTypes = require("game.apptypes")

local Playbooks = {}

function Playbooks.level(key)
  return math.max(1, (((G.GAME or {}).app_levels or {})[key] or 1))
end

function Playbooks.upgrade(key, amount)
  if not AppTypes.by_key[key] then return false end
  G.GAME.app_levels = G.GAME.app_levels or {}
  G.GAME.app_levels[key] = math.max(1, Playbooks.level(key) + (amount or 1))
  return G.GAME.app_levels[key]
end

function Playbooks.values(app)
  local level = Playbooks.level(app.key)
  local steps = level - 1
  return (app.base_chips or 0) + steps * 8, (app.base_mult or 1) + steps * 0.25, level
end

return Playbooks
