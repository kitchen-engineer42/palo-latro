-- Founder presentation migration. Generated story copy remains available as lore, while every
-- runtime surface receives a bounded rules projection and a compact face label.

local Presentation = {}

local RULE_START = {
  "after ", "at ", "before ", "below ", "each ", "every ", "from ", "gain ",
  "if ", "on ", "once ", "starts ", "the first ", "when ", "whenever ", "while ",
  "with ", "winning ", "losing ",
}

local FACE_BY_EFFECT = {
  xmult = "× Rev", plus_mult = "+ Rev", plus_chips = "+ Users", economy = "Cash",
  utility = "Utility", generation = "Creates", retrigger = "Retrigger",
}

function Presentation.scalar_count(value)
  if type(value) ~= "string" then return 0 end
  local count = 0
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 0x80 or byte >= 0xC0 then count = count + 1 end
  end
  return count
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize(value)
  value = trim(value):gsub("\r\n?", "\n")
  value = value:gsub("[ \t]+", " "):gsub(" *\n *", "\n")
  value = value:gsub("\n\n+", "\n\n")
  return value
end

local function sentences(value)
  value = normalize(value)
  local out, start = {}, 1
  while start <= #value do
    local stop = value:find("[%.!?]%s+", start)
    if not stop then
      local tail = trim(value:sub(start))
      if tail ~= "" then out[#out + 1] = tail end
      break
    end
    local sentence = trim(value:sub(start, stop))
    if sentence ~= "" then out[#out + 1] = sentence end
    start = stop + 1
    while value:sub(start, start):match("%s") do start = start + 1 end
  end
  return out
end

local function mechanical(sentence)
  local lower = trim(sentence):lower()
  for _, prefix in ipairs(RULE_START) do
    if lower:sub(1, #prefix) == prefix then return true end
  end
  return lower:find("%d") ~= nil and (lower:find("gain", 1, true)
    or lower:find("ship", 1, true) or lower:find("round", 1, true)
    or lower:find("blind", 1, true) or lower:find("card", 1, true)) ~= nil
end

local function truncate_word(value, limit)
  if Presentation.scalar_count(value) <= limit then return value end
  local count, last_space, byte_end = 0, nil, #value
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
      if count > limit then byte_end = index - 1; break end
    end
    if value:sub(index, index):match("%s") then last_space = index - 1 end
  end
  if last_space and last_space > math.floor(byte_end * 0.65) then byte_end = last_space end
  return trim(value:sub(1, byte_end)):gsub("[,;:%-–—]+$", "") .. "."
end

local function bounded_rules(center, lore, restored)
  local source = normalize(center.ability_text or center.hint or center.effect_brief or "Special.")
  local rows = sentences(source)
  local first = 1
  if not restored then
    for index, sentence in ipairs(rows) do
      if mechanical(sentence) then first = index; break end
    end
  end
  local selected = {}
  for index = first, #rows do
    local candidate = table.concat(selected, " ")
    candidate = candidate == "" and rows[index] or (candidate .. " " .. rows[index])
    if Presentation.scalar_count(candidate) <= 300 then
      selected[#selected + 1] = rows[index]
    else
      break
    end
  end
  local rules = table.concat(selected, " ")
  if rules == "" then rules = normalize(center.effect_brief or center.hint or source) end
  if Presentation.scalar_count(rules) > 300 then rules = truncate_word(rules, 299) end
  return rules
end

local function face_tag(center)
  if type(center.face_tag) == "string" and center.face_tag ~= "" then return center.face_tag end
  if center.dsl and center.dsl.action then return "Activate" end
  return FACE_BY_EFFECT[center.effect and center.effect.type] or "Special"
end

function Presentation.apply(founders, lore_source)
  local lore_by_key = {}
  for _, source in ipairs(lore_source or {}) do
    lore_by_key[source.key] = source.lore_text or source.ability_text
  end
  for _, center in ipairs(founders or {}) do
    if center.set == "Founder" then
      local lore = lore_by_key[center.key] or center.lore_text or center.ability_text
        or center.hint or center.effect_brief or "Special Founder."
      local restored = center.ability_text ~= nil and center.ability_text ~= lore
      center.lore_text = normalize(lore)
      center.rules_text = bounded_rules(center, center.lore_text, restored)
      center.face_tag = face_tag(center)
    end
  end
  return founders
end

return Presentation
