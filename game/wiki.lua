-- game/wiki.lua -- spoiler-safe, read-only knowledge index for the in-game Wiki.
--
-- Runtime centers remain authoritative.  This module derives immutable public projections,
-- typed links, and backlinks without writing profiles, unlocks, runs, or center data.

local Wiki = {}
local SignaturePair = require("game.signature_pair")
local Presentation = require("game.founder_presentation")

Wiki.PAGE_SIZE = 12
Wiki.STORY_LIMIT = 600
Wiki.RULES_LIMIT = 600
Wiki.RELATED_LIMIT = 6

Wiki.CATEGORIES = {
  { id = "all", label = "All" },
  { id = "mechanics", label = "Mechanics" },
  { id = "markets", label = "Markets", legacy_index = 1 },
  { id = "founders", label = "Founders", legacy_index = 2 },
  { id = "tech", label = "Tech", legacy_index = 3 },
  { id = "forms", label = "Forms", legacy_index = 4 },
  { id = "playbooks", label = "Playbooks", legacy_index = 5 },
  { id = "tech_laws", label = "Tech Laws", legacy_index = 6 },
  { id = "moonshots", label = "Moonshots", legacy_index = 7 },
  { id = "tech_modifiers", label = "Tech Mods", legacy_index = 8 },
  { id = "leads", label = "Leads", legacy_index = 9 },
}

Wiki.LEGACY_CATEGORIES = {}
local CATEGORY_BY_ID = {}
for index, category in ipairs(Wiki.CATEGORIES) do
  category.index = index
  CATEGORY_BY_ID[category.id] = category
  if category.legacy_index then Wiki.LEGACY_CATEGORIES[category.legacy_index] = category end
end

local RELATION_LABEL = {
  governed_by = "Rules", form_of = "Form of", paired_with = "Paired with",
  shared_group = "Shared circle", complements = "Complements", substitutes = "Substitute",
  clashes = "Clashes", fits_market = "Fits Market",
}
local BACKLINK_LABEL = {
  governed_by = "Explains", form_of = "Forms", paired_with = "Paired with",
  shared_group = "Shared circle", complements = "Complements", substitutes = "Substitute",
  clashes = "Clashes", fits_market = "Fitting Tech",
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize(value)
  return trim(value):gsub("\r\n?", "\n"):gsub("[ \t]+", " ")
    :gsub(" *\n *", "\n"):gsub("\n\n+", "\n\n")
end

local function truncate(value, limit)
  value = normalize(value)
  if Presentation.scalar_count(value) <= limit then return value end
  local count, byte_end, last_space = 0, #value, nil
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
      if count > limit - 1 then byte_end = index - 1; break end
    end
    if value:sub(index, index):match("%s") then last_space = index - 1 end
  end
  if last_space and last_space > byte_end * 0.7 then byte_end = last_space end
  return trim(value:sub(1, byte_end)):gsub("[,;:%-–—]+$", "") .. "…"
end

local function copy_array(values)
  local out = {}
  for _, value in ipairs(values or {}) do out[#out + 1] = value end
  return out
end

local function centers_pool(set)
  return require("game.centers").pool(set)
end

local function value_filter(field, value)
  return function(entry) return tostring(entry.source[field] or ""):lower() == value:lower() end
end

local FACETS = {
  all = { { id = "all", label = "All" } },
  mechanics = {
    { id = "all", label = "All" },
    { id = "scoring", label = "Scoring", matches = function(entry) return entry.facet_set.Scoring end },
    { id = "architecture", label = "Architecture", matches = function(entry) return entry.facet_set.Architecture end },
    { id = "ai", label = "AI", matches = function(entry) return entry.facet_set.AI end },
    { id = "economy", label = "Economy", matches = function(entry) return entry.facet_set.Economy end },
    { id = "cards", label = "Cards & Shop", matches = function(entry)
      return entry.facet_set.Cards or entry.facet_set.Shop or entry.facet_set.Founders or entry.facet_set.Market
    end },
  },
  markets = {
    { id = "all", label = "All" },
    { id = "realistic", label = "Realistic", matches = value_filter("kind", "realistic") },
    { id = "fun", label = "Wild", matches = value_filter("kind", "fun") },
  },
  founders = {
    { id = "all", label = "All" },
    { id = "common", label = "Common", matches = value_filter("rarity", "Common") },
    { id = "uncommon", label = "Uncommon", matches = value_filter("rarity", "Uncommon") },
    { id = "rare", label = "Rare", matches = value_filter("rarity", "Rare") },
    { id = "legendary", label = "Legendary", matches = value_filter("rarity", "Legendary") },
  },
  tech = {
    { id = "all", label = "All" },
    { id = "frontend", label = "Frontend", matches = value_filter("layer", "Frontend") },
    { id = "backend", label = "Backend", matches = value_filter("layer", "Backend") },
    { id = "data", label = "Data", matches = value_filter("layer", "Data") },
    { id = "infra", label = "Infra", matches = value_filter("layer", "Infra") },
    { id = "ai", label = "AI", matches = value_filter("layer", "AI") },
    { id = "knowledge", label = "Knowledge", matches = value_filter("layer", "Knowledge") },
  },
  forms = {
    { id = "all", label = "All" },
    { id = "early", label = "Early", matches = function(entry)
      return ((entry.source.era_gate or {}).min or 1) <= 3
    end },
    { id = "growth", label = "Growth", matches = function(entry)
      local minimum = (entry.source.era_gate or {}).min or 1
      return minimum >= 4 and minimum <= 5
    end },
    { id = "late", label = "Late", matches = function(entry)
      return ((entry.source.era_gate or {}).min or 1) >= 6
    end },
  },
  playbooks = { { id = "all", label = "All" } },
  tech_laws = {
    { id = "all", label = "All" },
    { id = "common", label = "Common", matches = value_filter("rarity", "common") },
    { id = "uncommon", label = "Uncommon", matches = value_filter("rarity", "uncommon") },
    { id = "rare", label = "Rare", matches = value_filter("rarity", "rare") },
  },
  moonshots = {
    { id = "all", label = "All" },
    { id = "ordinary", label = "Ordinary", matches = value_filter("rarity", "ordinary") },
    { id = "special", label = "Special", matches = value_filter("rarity", "special") },
  },
  tech_modifiers = {
    { id = "all", label = "All" },
    { id = "enhancement", label = "Enhancements", matches = value_filter("kind", "enhancement") },
    { id = "seal", label = "Seals", matches = value_filter("kind", "seal") },
  },
  leads = { { id = "all", label = "All" } },
}

local function wrap(list, id_field, predicate)
  local out = {}
  for _, source in ipairs(list or {}) do
    if not predicate or predicate(source) then out[#out + 1] = { id = source[id_field], source = source } end
  end
  return out
end

local function all_mechanics()
  return wrap(require("data.gameplay.wiki_mechanics"), "id")
end

local function all_markets()
  return wrap(require("data.centers.markets_gen").markets, "id")
end

local function all_founders()
  return wrap(centers_pool("Founder"), "key", function(center) return not center.is_form end)
end

local function all_forms()
  return wrap(centers_pool("Founder"), "key", function(center) return center.is_form == true end)
end

local function all_tech()
  return wrap(centers_pool("TechCard"), "key")
end

local function all_playbooks()
  return wrap(require("game.apptypes").list, "key")
end

local function all_tech_laws()
  return wrap(centers_pool("Consumable"), "key", function(center) return center.kind == "TechLaw" end)
end

local function all_moonshots()
  return wrap(centers_pool("Consumable"), "key", function(center) return center.kind == "Moonshot" end)
end

local function all_modifiers()
  local rules, out = require("game.tech_modifiers"), {}
  for _, group in ipairs({
    { kind = "enhancement", definitions = rules.ENHANCEMENTS or {} },
    { kind = "seal", definitions = rules.SEALS or {} },
  }) do
    for key, definition in pairs(group.definitions) do
      out[#out + 1] = {
        id = group.kind .. ":" .. key,
        source = { key = key, name = definition.label or definition.name or key,
          kind = group.kind, desc = definition.desc or definition.description or "" },
      }
    end
  end
  return out
end

local function all_leads()
  local definitions = require("game.leads").all()
  for _, definition in ipairs(definitions) do definition.kind = "lead" end
  return wrap(definitions, "key")
end

local BUILDERS = {
  mechanics = all_mechanics, markets = all_markets, founders = all_founders, tech = all_tech,
  forms = all_forms, playbooks = all_playbooks, tech_laws = all_tech_laws,
  moonshots = all_moonshots, tech_modifiers = all_modifiers, leads = all_leads,
}

local INDEX, BY_CATEGORY, BACKLINKS, HANDLES

local function relation(entry, kind, target_id)
  if not (entry and RELATION_LABEL[kind] and type(target_id) == "string" and target_id ~= entry.id) then return end
  entry._relation_set = entry._relation_set or {}
  local key = kind .. "\0" .. target_id
  if entry._relation_set[key] then return end
  entry._relation_set[key] = true
  entry.relations[#entry.relations + 1] = { kind = kind, target_id = target_id }
end

local function facets_for(category, source)
  local out, seen = { category }, { [category] = true }
  local function add(value)
    value = trim(value)
    if value ~= "" and not seen[value] then seen[value] = true; out[#out + 1] = value end
  end
  if category == "mechanics" then for _, value in ipairs(source.facets or {}) do add(value) end
  elseif category == "markets" then
    add(source.kind); add(source.audience); add(source.industry); add(source.architecture)
  elseif category == "founders" or category == "forms" then
    add(source.rarity); add(source.face_tag)
    for _, group in ipairs(source.groups or {}) do add(group) end
  elseif category == "tech" then
    add(source.layer); add(source.sub_role)
    for _, layer in ipairs(source.layers or {}) do add(layer.layer); add(layer.sub_role) end
    local identity = SignaturePair.identity(source)
    if identity then add(identity.era); add(identity.product); add(identity.ai_maturity); add(identity.role) end
  elseif category == "playbooks" then add("App Type")
  else add(source.rarity); add(source.kind) end
  return out
end

local function text_for(category, source)
  if category == "mechanics" then
    return source.facets and source.facets[1] or "Mechanic", source.rules or "", source.story or ""
  elseif category == "markets" then
    local view = require("game.markets").view(source)
    local subtitle = table.concat({ source.audience or "Any", source.industry or "Any", view.fit.label }, " · ")
    local rules = ((view.perk or {}).name or "Market Perk") .. ": " .. ((view.perk or {}).effect or "")
      .. "\n\nFit demand: " .. (view.fit.label or "Any")
    return subtitle, rules, "This Market rewards a " .. tostring(view.solution or "flexible")
      .. " approach for " .. tostring(view.industry or "any") .. " products."
  elseif category == "founders" or category == "forms" then
    local identity = SignaturePair.identity_label(source)
    local subtitle = (source.rarity or "Founder") .. " · Salary $" .. tostring(source.salary or 0)
      .. (identity and (" · " .. identity) or "")
    return subtitle, source.rules_text or source.effect_brief or source.hint or "", source.lore_text or ""
  elseif category == "tech" then
    local users = source.base_users or source.users or source.chips or 0
    local identity = SignaturePair.identity_label(source)
    local subtitle = identity or ((source.layer or "Tech") .. " · " .. (source.sub_role or "Technology"))
    return subtitle, tostring(users) .. " Users" .. (source.desc and (" · " .. source.desc) or ""), ""
  elseif category == "playbooks" then
    return "App Type Playbook", ("Base %s Users × %s Rev · Margin %d%%"):format(
      tostring(source.base_chips or 0), tostring(source.base_mult or 1),
      math.floor((source.margin or 0) * 100 + 0.5)), ""
  elseif category == "tech_laws" then
    return (source.rarity or "common"):gsub("^%l", string.upper) .. " Tech Law", source.desc or "", ""
  elseif category == "moonshots" then
    return (source.rarity or "ordinary"):gsub("^%l", string.upper) .. " · double-edged Roadmap card",
      source.desc or "", ""
  elseif category == "tech_modifiers" then
    return source.kind:gsub("^%l", string.upper) .. " · persistent Tech modifier", source.desc or "", ""
  elseif category == "leads" then
    return "Blind-skip opportunity · " .. tostring(source.trigger or "deferred reward"),
      source.description or "", ""
  end
  return "", "", ""
end

local function prepare_entry(category, raw, ordinal)
  local subtitle, rules, story = text_for(category, raw.source)
  local aliases = copy_array(raw.source.aliases)
  if raw.source.short and raw.source.short ~= raw.source.name then aliases[#aliases + 1] = raw.source.short end
  local facets = facets_for(category, raw.source)
  local facet_set = {}
  for _, value in ipairs(facets) do facet_set[value] = true end
  local entry = {
    id = raw.id, category = category, source = raw.source, ordinal = ordinal,
    name = raw.source.name or raw.id, aliases = aliases, facets = facets, facet_set = facet_set,
    subtitle = normalize(subtitle), rules = truncate(rules, Wiki.RULES_LIMIT),
    story = truncate(story, Wiki.STORY_LIMIT), relations = {},
    hidden_handle = "hidden:" .. category .. ":" .. tostring(ordinal),
  }
  local searchable = { entry.name, entry.subtitle, entry.rules, entry.story }
  for _, value in ipairs(aliases) do searchable[#searchable + 1] = value end
  for _, value in ipairs(facets) do searchable[#searchable + 1] = value end
  entry.search_text = table.concat(searchable, " "):lower()
  entry.name_lower = entry.name:lower()
  return entry
end

local function connect_mechanics(entry)
  local target
  if entry.category == "markets" then target = "mechanic:market_fit"
  elseif entry.category == "founders" or entry.category == "forms" then target = "mechanic:founders"
  elseif entry.category == "tech" then target = "mechanic:layers"
  elseif entry.category == "playbooks" then target = "mechanic:app_types"
  elseif entry.category == "tech_laws" or entry.category == "moonshots" then target = "mechanic:roadmap"
  elseif entry.category == "tech_modifiers" then target = "mechanic:compatibility"
  elseif entry.category == "leads" then target = "mechanic:packs" end
  relation(entry, "governed_by", target)
  if entry.category == "tech" then
    local source = entry.source
    local identity = SignaturePair.identity(source)
    if source.layer == "AI" or source.layer == "Knowledge" or (identity and identity.ai_maturity) then
      relation(entry, "governed_by", "mechanic:ai_maturity")
    end
    relation(entry, "governed_by", "mechanic:compatibility")
  end
end

local function connect_founders()
  for _, form in ipairs(BY_CATEGORY.forms or {}) do relation(form, "form_of", form.source.base_form) end
  local kitchen, jo = INDEX[SignaturePair.KITCHEN_KEY], INDEX[SignaturePair.JO_KEY]
  if kitchen and jo then relation(kitchen, "paired_with", jo.id); relation(jo, "paired_with", kitchen.id) end

  local by_group = {}
  for _, founder in ipairs(BY_CATEGORY.founders or {}) do
    for _, group in ipairs(founder.source.groups or {}) do
      by_group[group] = by_group[group] or {}; by_group[group][#by_group[group] + 1] = founder
    end
  end
  for _, founder in ipairs(BY_CATEGORY.founders or {}) do
    local candidates, seen = {}, {}
    for _, group in ipairs(founder.source.groups or {}) do
      for _, other in ipairs(by_group[group] or {}) do
        if other ~= founder and not seen[other.id] then seen[other.id] = true; candidates[#candidates + 1] = other end
      end
    end
    table.sort(candidates, function(a, b) return a.name_lower < b.name_lower end)
    for index = 1, math.min(Wiki.RELATED_LIMIT, #candidates) do
      relation(founder, "shared_group", candidates[index].id)
    end
  end
end

local function connect_tech()
  local compat = require("data.centers.compat_gen")
  local function add_pairs(rows, kind)
    for pair in pairs(rows or {}) do
      local left, right = tostring(pair):match("^([^|]+)|([^|]+)$")
      local a, b = left and INDEX["t_" .. left], right and INDEX["t_" .. right]
      if a and b then relation(a, kind, b.id); relation(b, kind, a.id) end
    end
  end
  add_pairs(compat.complements, "complements")
  add_pairs(compat.substitutes, "substitutes")
  add_pairs(compat.clashes, "clashes")

  local market_data = require("data.centers.markets_gen")
  for _, tech in ipairs(BY_CATEGORY.tech or {}) do
    local bare = tech.id:gsub("^t_", "")
    local ratings = market_data.scenario_fit[bare] or {}
    for _, market in ipairs(BY_CATEGORY.markets or {}) do
      local scenario = require("game.markets").scenario(market.source)
      if ratings[scenario] == "great" then relation(tech, "fits_market", market.id) end
    end
  end
end

local function build_index()
  if INDEX then return end
  INDEX, BY_CATEGORY, BACKLINKS, HANDLES = {}, {}, {}, {}
  for _, category in ipairs(Wiki.CATEGORIES) do
    if BUILDERS[category.id] then
      local rows = BUILDERS[category.id]()
      table.sort(rows, function(a, b)
        local an, bn = tostring(a.source.name or a.id):lower(), tostring(b.source.name or b.id):lower()
        return an == bn and a.id < b.id or an < bn
      end)
      BY_CATEGORY[category.id] = {}
      for ordinal, raw in ipairs(rows) do
        assert(type(raw.id) == "string" and raw.id ~= "", "Wiki entity requires a stable id")
        assert(not INDEX[raw.id], "duplicate Wiki entity " .. raw.id)
        local entry = prepare_entry(category.id, raw, ordinal)
        INDEX[entry.id] = entry
        HANDLES[entry.id], HANDLES[entry.hidden_handle] = entry.id, entry.id
        BY_CATEGORY[category.id][#BY_CATEGORY[category.id] + 1] = entry
      end
    end
  end
  for _, entry in pairs(INDEX) do connect_mechanics(entry) end
  connect_founders()
  connect_tech()
  for _, entry in pairs(INDEX) do
    for _, edge in ipairs(entry.relations) do
      if INDEX[edge.target_id] then
        BACKLINKS[edge.target_id] = BACKLINKS[edge.target_id] or {}
        BACKLINKS[edge.target_id][#BACKLINKS[edge.target_id] + 1] = {
          kind = edge.kind, source_id = entry.id,
        }
      end
    end
    entry._relation_set = nil
  end
end

local function profile_or_default(profile)
  profile = profile or G.PROFILE or {}
  return { discovered = profile.discovered or {} }
end

local function discovered(entry, profile)
  if entry.category == "mechanics" or entry.category == "tech_modifiers" or entry.category == "leads" then
    return true
  end
  if profile.discovered[entry.id] == true then return true end
  return entry.source.set == "Founder" and entry.source.discovered == true
end

local function current_state()
  G.WIKI = G.WIKI or {
    category = "all", facet = "all", query = "", letter = nil, page = 1,
    selected = nil, history = {}, history_index = 0, scroll = 0, search_focused = false,
  }
  local state = G.WIKI
  if not CATEGORY_BY_ID[state.category] then state.category = "all" end
  state.facet = state.facet or "all"
  state.query = tostring(state.query or "")
  state.page = math.max(1, math.floor(tonumber(state.page) or 1))
  state.history, state.history_index = state.history or {}, tonumber(state.history_index) or 0
  state.scroll = math.max(0, math.floor(tonumber(state.scroll) or 0))
  return state
end

local function selected_facet(category_id, facet_id)
  local facets = FACETS[category_id] or FACETS.all
  for index, facet in ipairs(facets) do if facet.id == facet_id then return facet, index end end
  return facets[1], 1
end

local function catalog(category_id)
  build_index()
  if category_id ~= "all" then return BY_CATEGORY[category_id] or {} end
  local out = {}
  for _, category in ipairs(Wiki.CATEGORIES) do
    if category.id ~= "all" then
      for _, entry in ipairs(BY_CATEGORY[category.id] or {}) do out[#out + 1] = entry end
    end
  end
  table.sort(out, function(a, b)
    return a.name_lower == b.name_lower and a.id < b.id or a.name_lower < b.name_lower
  end)
  return out
end

local function query_rank(entry, query)
  if query == "" then return 0 end
  if entry.name_lower == query then return 1 end
  if entry.name_lower:sub(1, #query) == query then return 2 end
  if entry.name_lower:find("%f[%w]" .. query:gsub("([^%w])", "%%%1"), 1) then return 3 end
  for _, alias in ipairs(entry.aliases) do
    local lower = alias:lower()
    if lower == query then return 2 end
    if lower:sub(1, #query) == query then return 3 end
  end
  if entry.search_text:find(query, 1, true) then return 4 end
  return nil
end

local function results(profile)
  local state = current_state()
  local facet = selected_facet(state.category, state.facet)
  local query = trim(state.query):lower()
  local out = {}
  for _, entry in ipairs(catalog(state.category)) do
    local is_discovered = discovered(entry, profile)
    local allowed = (not facet.matches or facet.matches(entry))
    if state.letter then allowed = allowed and is_discovered and entry.name_lower:sub(1, 1) == state.letter:lower() end
    local rank = 0
    if query ~= "" then
      rank = is_discovered and query_rank(entry, query) or nil
      allowed = allowed and rank ~= nil
    end
    if allowed then out[#out + 1] = { entry = entry, discovered = is_discovered, rank = rank or 0 } end
  end
  table.sort(out, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.discovered ~= b.discovered then return a.discovered end
    if a.discovered and a.entry.name_lower ~= b.entry.name_lower then
      return a.entry.name_lower < b.entry.name_lower
    end
    return a.entry.hidden_handle < b.entry.hidden_handle
  end)
  return out
end

local function item_projection(entry, is_discovered)
  if not is_discovered then
    return { handle = entry.hidden_handle, discovered = false, name = "???",
      subtitle = "Undiscovered", detail = "Find this during a run to reveal it.", category = entry.category }
  end
  return { id = entry.id, handle = entry.id, discovered = true, name = entry.name,
    subtitle = entry.subtitle, detail = entry.rules, category = entry.category,
    facets = copy_array(entry.facets) }
end

local function safe_links(edges, profile, source_field, label_map)
  local rows, hidden, seen = {}, 0, {}
  for _, edge in ipairs(edges or {}) do
    local target_id = edge[source_field]
    local target = INDEX[target_id]
    if target and target_id ~= nil then
      if discovered(target, profile) then
        local key = edge.kind .. "\0" .. target.id
        if not seen[key] then
          seen[key] = true
          rows[#rows + 1] = { id = target.id, handle = target.id, name = target.name,
            kind = edge.kind, label = label_map[edge.kind] or edge.kind, category = target.category }
        end
      else hidden = hidden + 1 end
    end
  end
  table.sort(rows, function(a, b)
    if a.label ~= b.label then return a.label < b.label end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  local total = #rows
  while #rows > Wiki.RELATED_LIMIT do table.remove(rows) end
  return rows, hidden, math.max(0, total - #rows)
end

function Wiki.categories() return Wiki.CATEGORIES end
function Wiki.legacy_categories() return Wiki.LEGACY_CATEGORIES end
function Wiki.facets(category_id) return FACETS[category_id or current_state().category] or FACETS.all end

function Wiki.progress(profile)
  build_index(); profile = profile_or_default(profile)
  local out = {}
  for _, category in ipairs(Wiki.CATEGORIES) do
    if category.id ~= "all" then
      local count, entries = 0, BY_CATEGORY[category.id] or {}
      for _, entry in ipairs(entries) do if discovered(entry, profile) then count = count + 1 end end
      out[category.id] = { discovered = count, total = #entries }
    end
  end
  local discovered_total, total = 0, 0
  for id, row in pairs(out) do
    if id ~= "mechanics" then discovered_total, total = discovered_total + row.discovered, total + row.total end
  end
  out.all = { discovered = discovered_total, total = total }
  return out
end

function Wiki.page(value, profile)
  build_index(); profile = profile_or_default(profile)
  local id = HANDLES[value or ""] or value
  local entry = INDEX[id]
  if not entry then return nil end
  if not discovered(entry, profile) then
    return { handle = entry.hidden_handle, discovered = false, name = "???", category = entry.category,
      subtitle = "Undiscovered", rules = "Find this during a run to reveal it.", story = "",
      related = {}, backlinks = {}, hidden_related = 0, hidden_backlinks = 0 }
  end
  local related, hidden_related, related_more = safe_links(entry.relations, profile, "target_id", RELATION_LABEL)
  local outgoing, inverse = {}, {}
  for _, edge in ipairs(entry.relations) do outgoing[edge.target_id] = true end
  for _, edge in ipairs(BACKLINKS[entry.id] or {}) do
    if not outgoing[edge.source_id] then inverse[#inverse + 1] = edge end
  end
  local backlinks, hidden_backlinks, backlinks_more = safe_links(inverse, profile, "source_id", BACKLINK_LABEL)
  return {
    id = entry.id, handle = entry.id, discovered = true, category = entry.category,
    name = entry.name, subtitle = entry.subtitle, facets = copy_array(entry.facets),
    rules = entry.rules, story = entry.story, related = related, backlinks = backlinks,
    hidden_related = hidden_related, hidden_backlinks = hidden_backlinks,
    related_more = related_more, backlinks_more = backlinks_more,
  }
end

function Wiki.snapshot(profile)
  build_index(); profile = profile_or_default(profile)
  local state = current_state()
  local category = CATEGORY_BY_ID[state.category]
  local facet, facet_index = selected_facet(category.id, state.facet)
  state.facet = facet.id
  local found = results(profile)
  local page_count = math.max(1, math.ceil(#found / Wiki.PAGE_SIZE))
  state.page = math.min(math.max(1, state.page), page_count)
  local first = (state.page - 1) * Wiki.PAGE_SIZE + 1
  local last = math.min(#found, first + Wiki.PAGE_SIZE - 1)
  local items = {}
  for index = first, last do
    local row = found[index]
    items[#items + 1] = item_projection(row.entry, row.discovered)
  end
  local selected = state.selected and Wiki.page(state.selected, profile) or nil
  if not selected and items[1] then
    state.selected = items[1].handle
    if #state.history == 0 then state.history[1], state.history_index = state.selected, 1 end
    selected = Wiki.page(state.selected, profile)
  end
  local progress = Wiki.progress(profile)
  local category_progress = progress[category.id] or { discovered = 0, total = 0 }
  local filtered_discovered = 0
  for _, row in ipairs(found) do if row.discovered then filtered_discovered = filtered_discovered + 1 end end
  return {
    category = category, category_index = category.index,
    facet = facet, facet_index = facet_index, filter = facet, filter_index = facet_index,
    facets = Wiki.facets(category.id), filters = Wiki.facets(category.id),
    query = state.query, letter = state.letter, search_focused = state.search_focused,
    page = state.page, page_count = page_count, first = #found > 0 and first or 0, last = last,
    discovered = category_progress.discovered, total = category_progress.total,
    filtered_discovered = filtered_discovered, filtered_total = #found,
    items = items, selected = selected, progress = progress, scroll = state.scroll,
  }
end

function Wiki.select_category(value)
  local category = type(value) == "number" and Wiki.CATEGORIES[value] or CATEGORY_BY_ID[value]
  if not category then return false end
  local state = current_state()
  state.category, state.facet, state.letter, state.page, state.selected, state.scroll =
    category.id, "all", nil, 1, nil, 0
  state.history, state.history_index = {}, 0
  return true
end

function Wiki.select_facet(value)
  local state, facets = current_state(), Wiki.facets()
  local facet = type(value) == "number" and facets[value] or nil
  if type(value) == "string" then
    for _, candidate in ipairs(facets) do if candidate.id == value then facet = candidate; break end end
  end
  if not facet then return false end
  state.facet, state.page, state.selected, state.scroll = facet.id, 1, nil, 0
  state.history, state.history_index = {}, 0
  return true
end

function Wiki.select_letter(letter)
  local state = current_state()
  if letter == nil or letter == "" or tostring(letter):lower() == tostring(state.letter):lower() then
    state.letter = nil
  elseif tostring(letter):match("^[A-Za-z]$") then state.letter = tostring(letter):upper()
  else return false end
  state.page, state.selected, state.scroll = 1, nil, 0
  state.history, state.history_index = {}, 0
  return true
end

function Wiki.set_query(value)
  local state = current_state()
  state.query = tostring(value or ""):sub(1, 80)
  state.page, state.selected, state.scroll = 1, nil, 0
  return state.query
end

function Wiki.append_text(value)
  value = tostring(value or ""):gsub("[%c]", "")
  return Wiki.set_query(current_state().query .. value)
end

function Wiki.backspace_query()
  local state = current_state()
  if state.query == "" then return false end
  local index = #state.query
  while index > 1 and state.query:byte(index) >= 0x80 and state.query:byte(index) < 0xC0 do index = index - 1 end
  Wiki.set_query(state.query:sub(1, index - 1))
  return true
end

function Wiki.focus_search(value)
  current_state().search_focused = value ~= false
  return current_state().search_focused
end

function Wiki.select(value, profile, push_history)
  build_index()
  local id = HANDLES[value or ""]
  if not id then return false end
  local state = current_state()
  state.selected, state.scroll = value, 0
  if push_history ~= false then
    while #state.history > state.history_index do table.remove(state.history) end
    if state.history[#state.history] ~= value then state.history[#state.history + 1] = value end
    state.history_index = #state.history
  end
  return Wiki.page(value, profile) ~= nil
end

function Wiki.history_back(profile)
  local state = current_state()
  if state.history_index <= 1 then return false end
  state.history_index = state.history_index - 1
  return Wiki.select(state.history[state.history_index], profile, false)
end

function Wiki.change_page(delta, profile)
  local state, view = current_state(), Wiki.snapshot(profile)
  state.page = math.min(view.page_count, math.max(1, view.page + (delta or 0)))
  state.selected, state.scroll = nil, 0
  return state.page
end

function Wiki.scroll(delta)
  local state = current_state()
  state.scroll = math.max(0, math.min(4, state.scroll + (delta or 0)))
  return state.scroll
end

function Wiki.reset(opts)
  opts = opts or {}
  G.WIKI = {
    category = CATEGORY_BY_ID[opts.category] and opts.category or "all",
    facet = "all", query = "", letter = nil, page = 1, selected = nil,
    history = {}, history_index = 0, scroll = 0, search_focused = false,
    source = opts.source, prior_paused = opts.prior_paused,
  }
  return G.WIKI
end

function Wiki.open(source)
  if G.SHOW_WIKI then return true end
  local prior_paused = G.SETTINGS and G.SETTINGS.paused == true
  Wiki.reset({ source = source or "menu", prior_paused = prior_paused })
  local controller = G.CONTROLLER
  if controller and controller.focused then
    for _, target in ipairs(controller.targets or {}) do
      if target.node == controller.focused then
        G.WIKI.prior_focus_id = target.id == "ui:opt_wiki" and "ui:options" or target.id
        break
      end
    end
  end
  if not G.WIKI.prior_focus_id then
    G.WIKI.prior_focus_id = source == "run" and "ui:options" or "ui:wiki_open"
  end
  G.SHOW_DECK_VIEW, G.SHOW_RUN_INFO, G.SHOW_OPTIONS = nil, nil, nil
  G.SHOW_WIKI = true
  if G.SETTINGS then G.SETTINGS.paused = true end
  return true
end

function Wiki.close()
  if not G.SHOW_WIKI then return false end
  local state = current_state()
  G.SHOW_WIKI = nil
  G.WIKI_RESTORE_FOCUS = state.prior_focus_id
  if G.SETTINGS then G.SETTINGS.paused = state.prior_paused == true end
  return true
end

function Wiki.is_open() return G.SHOW_WIKI == true end

function Wiki.validate()
  build_index()
  local errors = {}
  for _, entry in pairs(INDEX) do
    if Presentation.scalar_count(entry.rules) > Wiki.RULES_LIMIT then errors[#errors + 1] = entry.id .. " rules too long" end
    if Presentation.scalar_count(entry.story) > Wiki.STORY_LIMIT then errors[#errors + 1] = entry.id .. " story too long" end
    for _, edge in ipairs(entry.relations) do
      if not INDEX[edge.target_id] then errors[#errors + 1] = entry.id .. " links missing " .. edge.target_id end
    end
  end
  table.sort(errors)
  return #errors == 0, errors
end

function Wiki.invalidate()
  INDEX, BY_CATEGORY, BACKLINKS, HANDLES = nil, nil, nil, nil
end

return Wiki
