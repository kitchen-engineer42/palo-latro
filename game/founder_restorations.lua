-- Player-facing Founder restorations are kept as small data manifests so the
-- generated catalog remains reproducible. Apply them onto shallow center copies
-- before validation/registration; callers never mutate the generated source.

local Restorations = {}

local MANIFESTS = {
  "data.gameplay.founder_restorations",
  "data.gameplay.founder_restorations_cards",
}

function Restorations.apply(founders)
  local out, by_key = {}, {}
  for index, center in ipairs(founders or {}) do
    local copy = {}
    for key, value in pairs(center) do copy[key] = value end
    out[index], by_key[copy.key] = copy, copy
  end

  local claimed = {}
  for _, module_name in ipairs(MANIFESTS) do
    for key, override in pairs(require(module_name)) do
      local center = assert(by_key[key], module_name .. " references unknown Founder " .. tostring(key))
      assert(not claimed[key], "duplicate Founder restoration for " .. tostring(key))
      claimed[key] = true
      for field, value in pairs(override) do center[field] = value end
    end
  end
  return out
end

return Restorations
