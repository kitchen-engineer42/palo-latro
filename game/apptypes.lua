-- game/apptypes.lua — the 12 App Types, the tech-native hand vocabulary, as
-- centers, plus the deterministic classifier from Layer Coverage (primary) + Depth (secondary).
-- base_chips = App-Type Users floor; base_mult = Revenue-per-user floor; margin stored (economy
-- seam, unused this slice). "Your stack IS your app" — no poker-style "pick the highest match".

local Coverage = require("game.coverage")

local AppTypes = {}

AppTypes.list = {
  { key = "apt_prototype",   set = "AppType", name = "Prototype",             base_chips = 10,  base_mult = 1.2, margin = 0.90 },
  { key = "apt_specialist",  set = "AppType", name = "Specialist Tool",       base_chips = 20,  base_mult = 1.8, margin = 0.85 },
  { key = "apt_twotier",     set = "AppType", name = "Two-Tier App",          base_chips = 25,  base_mult = 2,   margin = 0.85 },
  { key = "apt_webapp",      set = "AppType", name = "Web App",               base_chips = 35,  base_mult = 1.8, margin = 0.85 },
  { key = "apt_infra",       set = "AppType", name = "Infra/Backend Platform",base_chips = 35,  base_mult = 2.5, margin = 0.75 },
  { key = "apt_saas",        set = "AppType", name = "SaaS",                  base_chips = 35,  base_mult = 1.8, margin = 0.80 },
  { key = "apt_ai_wrapper",  set = "AppType", name = "AI Wrapper",            base_chips = 30,  base_mult = 2,   margin = 0.35 },
  { key = "apt_ai_feature",  set = "AppType", name = "AI Feature App",        base_chips = 50,  base_mult = 3,   margin = 0.40 },
  { key = "apt_ai_product",  set = "AppType", name = "AI Product",            base_chips = 80,  base_mult = 4,   margin = 0.35 },
  { key = "apt_ai_native",   set = "AppType", name = "AI-Native Full Stack",  base_chips = 120, base_mult = 6,   margin = 0.30 },
  { key = "apt_platform",    set = "AppType", name = "Platform/Ecosystem",    base_chips = 40,  base_mult = 2,   margin = 0.55 },
  { key = "apt_moonshot",    set = "AppType", name = "Deep-Tech Moonshot",    base_chips = 90,  base_mult = 5,   margin = 0.25 },
}

local by_key = {}
for _, a in ipairs(AppTypes.list) do by_key[a.key] = a end
AppTypes.by_key = by_key

-- classify a list of played Cards -> the App Type center
function AppTypes.classify(cards)
  --  assignment is centralized in Coverage. Knowledge and role tags
  -- never inflate this five-slot product-layer vocabulary.
  local analysis = Coverage.analyze(cards)
  local counts = analysis.counts
  local distinct, max_depth, dominant = 0, 0, nil
  for _, layer in ipairs(Coverage.CORE_ORDER) do
    local n = counts[layer]
    if n then
      distinct = distinct + 1
      if n > max_depth then max_depth, dominant = n, layer end
    end
  end
  local has_ai = counts.AI ~= nil
  if distinct == 0 then return by_key.apt_prototype end

  -- Deep-Tech Moonshot: heavy depth in a hard layer (AI/Infra)
  if max_depth >= 4 and (dominant == "AI" or dominant == "Infra") then
    return by_key.apt_moonshot
  end

  if has_ai then
    if distinct >= 5 then return by_key.apt_ai_native end      -- all 5 layers (incl AI)
    if distinct == 4 then return by_key.apt_ai_product end     -- AI + 3
    if distinct == 3 then return by_key.apt_ai_feature end     -- AI + 2
    return by_key.apt_ai_wrapper                               -- AI + ≤1
  end

  -- non-AI track
  if distinct >= 4 then
    local platform_role = analysis.subroles["cloud-provider"] or analysis.subroles["containers-orchestration"]
      or analysis.subroles["paas-hosting"] or analysis.subroles["orchestration"]
    return (max_depth >= 2 and platform_role) and by_key.apt_platform or by_key.apt_saas
  end
  if distinct == 3 then
    if counts.Frontend == nil then return by_key.apt_infra end
    if counts.Backend and counts.Data then
      return analysis.subroles["ui-framework"] and by_key.apt_webapp or by_key.apt_saas
    end
    if counts.Data and counts.Infra then return by_key.apt_platform end
    return by_key.apt_webapp
  end
  if distinct == 2 then return counts.Frontend and by_key.apt_webapp or by_key.apt_twotier end
  -- distinct == 1
  return (max_depth >= 2) and by_key.apt_specialist or by_key.apt_prototype
end

return AppTypes
