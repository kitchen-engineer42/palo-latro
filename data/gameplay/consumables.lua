-- Authoritative aggregate consumable catalog. Individual families keep their
-- own manifests so their schemas and runtimes can evolve independently.

local out = {}

local function append(list)
  for _, center in ipairs(list or {}) do out[#out + 1] = center end
end

append(require("data.gameplay.tech_laws"))
append(require("data.gameplay.moonshots"))

return out
