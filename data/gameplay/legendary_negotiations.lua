-- Authored Legendary-Founder negotiation scripts. The two shards keep the
-- biography-heavy content reviewable while callers receive one stable catalog.

local out = {}

local function append(module_name)
  for _, script in ipairs(require(module_name)) do out[#out + 1] = script end
end

append("data.gameplay.legendary_negotiations_1")
append("data.gameplay.legendary_negotiations_2")

table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)

return out
