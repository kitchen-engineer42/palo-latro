-- Era availability is a draft/deck concern, never an implicit scoring modifier.

local Eras = {}

local function era_number(v)
  local n
  if type(v) == "number" then
    n = v
  else
    n = tonumber(tostring(v or ""):match("[Ee]?(%d+)"))
  end
  if not n then return nil end
  return math.max(1, math.min(5, math.floor(n)))
end

function Eras.number(v) return era_number(v) end
function Eras.label(v) return "E" .. tostring(era_number(v) or 1) end

function Eras.available(center, era)
  if not center or center.signature then return false end
  local wanted = era_number(era) or 1
  local eras = center.eras
  if not eras or #eras == 0 then return wanted == 1 end
  for _, e in ipairs(eras) do if era_number(e) == wanted then return true end end
  return false
end

function Eras.first(center)
  local best
  for _, e in ipairs((center and center.eras) or {}) do
    local n = era_number(e)
    if n and (not best or n < best) then best = n end
  end
  return best or 1
end

function Eras.for_ante(market_rule, ante)
  local path = (market_rule and market_rule.era_path) or { 1, 2, 3, 4, 5 }
  local step = math.min(#path, math.max(1, math.ceil(((ante or 1) + 1) / 2)))
  return era_number(path[step]) or 1
end

return Eras
