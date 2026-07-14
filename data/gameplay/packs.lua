-- Booster catalog. The variant counts and size/choice bands intentionally follow
-- Balatro's shipped Arcana/Celestial/Buffoon structure, while the content and art
-- identities are Palo Latro's own.

local packs, order = {}, 0

local function add(key, family, name, size, variant, options, picks, weight, extra)
  order = order + 1
  local p = {
    key = key, family = family, name = name, size = size, variant = variant,
    options = options, picks = picks, weight = weight, order = order,
    art_key = key,
  }
  for k, v in pairs(extra or {}) do p[k] = v end
  packs[key] = p
end

-- Founder/Joker analogue: 2 normal covers, 1 jumbo, 1 mega (4 total).
add("hiring",          "hiring", "Hiring Round",       "normal", 1, 2, 1, 0.60,
  { legendary_chance = 0.0075, edition_chance = 0.05, fallback_art = "hiring_round" })
add("hiring_normal_2", "hiring", "Hiring Round",       "normal", 2, 2, 1, 0.60,
  { legendary_chance = 0.0075, edition_chance = 0.05, fallback_art = "hiring_round" })
add("hiring_jumbo",    "hiring", "Jumbo Hiring Round", "jumbo",  1, 4, 1, 0.60,
  { legendary_chance = 0.0075, edition_chance = 0.05, fallback_art = "hiring_round" })
add("hiring_mega",     "hiring", "Mega Hiring Round",  "mega",   1, 4, 2, 0.15,
  { legendary_chance = 0.0075, edition_chance = 0.05, fallback_art = "hiring_round" })

-- App-Type/Planet analogue: 4 normal covers, 2 jumbo, 2 mega (8 total).
for i = 1, 4 do add(i == 1 and "playbook" or ("playbook_normal_" .. i), "playbook",
  "Playbook Workshop", "normal", i, 3, 1, 1.00, { fallback_art = "playbook_workshop" }) end
for i = 1, 2 do add("playbook_jumbo_" .. i, "playbook", "Jumbo Playbook Workshop",
  "jumbo", i, 5, 1, 1.00, { fallback_art = "playbook_workshop" }) end
for i = 1, 2 do add("playbook_mega_" .. i, "playbook", "Mega Playbook Workshop",
  "mega", i, 5, 2, 0.25, { fallback_art = "playbook_workshop" }) end

-- Tech-Law/Tarot analogue: 4 normal covers, 2 jumbo, 2 mega (8 total).
for i = 1, 4 do add(i == 1 and "tech_law" or ("tech_law_normal_" .. i), "tech_law",
  "Tech Law Pack", "normal", i, 3, 1, 1.00, { fallback_art = "tech_law_pack" }) end
for i = 1, 2 do add("tech_law_jumbo_" .. i, "tech_law", "Jumbo Tech Law Pack",
  "jumbo", i, 5, 1, 1.00, { fallback_art = "tech_law_pack" }) end
for i = 1, 2 do add("tech_law_mega_" .. i, "tech_law", "Mega Tech Law Pack",
  "mega", i, 5, 2, 0.25, { fallback_art = "tech_law_pack" }) end

return packs
