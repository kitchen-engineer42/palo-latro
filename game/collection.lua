-- game/collection.lua -- read-only catalog model for the pre-run Collection screen.
--
-- Discovery changes presentation only. Every catalog entry remains in its normal gameplay pool;
-- this module never writes the profile, unlocks content, or mutates a center. Undiscovered entries
-- are projected as silhouettes so callers cannot accidentally reveal their names or rules.

local Collection = {}

Collection.PAGE_SIZE = 12
Collection.CATEGORIES = {
  { id = "markets", label = "Markets" },
  { id = "founders", label = "Founders" },
  { id = "tech", label = "Tech" },
  { id = "forms", label = "Forms" },
  { id = "playbooks", label = "Playbooks" },
  { id = "tech_laws", label = "Tech Laws" },
}

local CATEGORY_BY_ID = {}
for index, category in ipairs(Collection.CATEGORIES) do
  category.index = index
  CATEGORY_BY_ID[category.id] = category
end

local function centers_pool(set)
  return require("game.centers").pool(set)
end

local function wrap(list, id_field, predicate)
  local out = {}
  for _, source in ipairs(list or {}) do
    if not predicate or predicate(source) then
      out[#out + 1] = { id = source[id_field], source = source }
    end
  end
  table.sort(out, function(a, b)
    local an, bn = a.source.name or a.id or "", b.source.name or b.id or ""
    if an == bn then return (a.id or "") < (b.id or "") end
    return an < bn
  end)
  return out
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

local function value_filter(field, value)
  return function(entry) return tostring(entry.source[field] or ""):lower() == value:lower() end
end

local FILTERS = {
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
  },
}

local CATALOGS = {
  markets = all_markets,
  founders = all_founders,
  tech = all_tech,
  forms = all_forms,
  playbooks = all_playbooks,
  tech_laws = all_tech_laws,
}
local CATALOG_CACHE = {}

local function current_state()
  G.COLLECTION = G.COLLECTION or { category = "markets", filter = "all", page = 1 }
  if not CATEGORY_BY_ID[G.COLLECTION.category] then G.COLLECTION.category = "markets" end
  G.COLLECTION.filter = G.COLLECTION.filter or "all"
  G.COLLECTION.page = math.max(1, math.floor(tonumber(G.COLLECTION.page) or 1))
  return G.COLLECTION
end

local function profile_or_default(profile)
  profile = profile or G.PROFILE or {}
  return { discovered = profile.discovered or {} }
end

local function discovered(entry, profile)
  if profile.discovered[entry.id] == true then return true end
  -- Founders may be discovered during the current run before the profile is persisted.
  return entry.source.set == "Founder" and entry.source.discovered == true
end

local function summary(category, source)
  if category == "markets" then
    local view = require("game.markets").view(source)
    return (source.audience or "Any") .. " · " .. (source.industry or "Any") .. " · " .. view.fit.label,
      ((view.perk or {}).name or "Market Perk") .. ": " .. ((view.perk or {}).effect or "")
  elseif category == "founders" or category == "forms" then
    return (source.rarity or "Founder") .. " · Salary $" .. tostring(source.salary or 0),
      source.effect_brief or source.ability_name or source.hint or ""
  elseif category == "tech" then
    local users = source.base_users or source.users or source.chips or 0
    return (source.layer or "Tech") .. " · " .. (source.sub_role or "Technology"),
      tostring(users) .. " Users" .. (source.desc and (" · " .. source.desc) or "")
  elseif category == "playbooks" then
    return tostring(source.base_chips or 0) .. " Users × " .. tostring(source.base_mult or 1) .. " Rev",
      "Margin " .. tostring(math.floor((source.margin or 0) * 100 + 0.5)) .. "%"
  elseif category == "tech_laws" then
    return (source.rarity or "common"):gsub("^%l", string.upper), source.desc or ""
  end
  return "", ""
end

local function projection(category, entry, profile)
  local is_discovered = discovered(entry, profile)
  if not is_discovered then
    return { id = entry.id, discovered = false, name = "???", subtitle = "Undiscovered",
      detail = "Find this during a run to reveal it." }
  end
  local subtitle, detail = summary(category, entry.source)
  return { id = entry.id, discovered = true, name = entry.source.name or entry.id,
    subtitle = subtitle, detail = detail }
end

function Collection.categories() return Collection.CATEGORIES end

function Collection.filters(category_id)
  return FILTERS[category_id or current_state().category] or FILTERS.markets
end

function Collection.select_category(value)
  local category = type(value) == "number" and Collection.CATEGORIES[value] or CATEGORY_BY_ID[value]
  if not category then return false end
  local state = current_state()
  state.category, state.filter, state.page = category.id, "all", 1
  return true
end

function Collection.select_filter(value)
  local state, filters = current_state(), Collection.filters()
  local filter = type(value) == "number" and filters[value] or nil
  if type(value) == "string" then
    for _, candidate in ipairs(filters) do if candidate.id == value then filter = candidate; break end end
  end
  if not filter then return false end
  state.filter, state.page = filter.id, 1
  return true
end

local function selected_filter(category_id, filter_id)
  local filters = Collection.filters(category_id)
  for index, filter in ipairs(filters) do
    if filter.id == filter_id then return filter, index end
  end
  return filters[1], 1
end

local function catalog(category_id)
  category_id = CATALOGS[category_id] and category_id or "markets"
  if not CATALOG_CACHE[category_id] then CATALOG_CACHE[category_id] = CATALOGS[category_id]() end
  return CATALOG_CACHE[category_id]
end

function Collection.progress(profile)
  profile = profile_or_default(profile)
  local out = {}
  for _, category in ipairs(Collection.CATEGORIES) do
    local entries, count = catalog(category.id), 0
    for _, entry in ipairs(entries) do if discovered(entry, profile) then count = count + 1 end end
    out[category.id] = { discovered = count, total = #entries }
  end
  return out
end

function Collection.snapshot(profile)
  profile = profile_or_default(profile)
  local state = current_state()
  local category = CATEGORY_BY_ID[state.category]
  local filter, filter_index = selected_filter(category.id, state.filter)
  state.filter = filter.id
  local all, filtered = catalog(category.id), {}
  local total_discovered = 0
  for _, entry in ipairs(all) do
    if discovered(entry, profile) then total_discovered = total_discovered + 1 end
    if not filter.matches or filter.matches(entry) then filtered[#filtered + 1] = entry end
  end
  local filtered_discovered = 0
  for _, entry in ipairs(filtered) do if discovered(entry, profile) then filtered_discovered = filtered_discovered + 1 end end
  local page_count = math.max(1, math.ceil(#filtered / Collection.PAGE_SIZE))
  state.page = math.min(math.max(1, state.page), page_count)
  local first = (state.page - 1) * Collection.PAGE_SIZE + 1
  local last = math.min(#filtered, first + Collection.PAGE_SIZE - 1)
  local items = {}
  for index = first, last do items[#items + 1] = projection(category.id, filtered[index], profile) end
  return {
    category = category, category_index = category.index,
    filter = filter, filter_index = filter_index, filters = Collection.filters(category.id),
    page = state.page, page_count = page_count, first = #filtered > 0 and first or 0, last = last,
    discovered = total_discovered, total = #all,
    filtered_discovered = filtered_discovered, filtered_total = #filtered,
    items = items, progress = Collection.progress(profile),
  }
end

function Collection.change_page(delta, profile)
  local state = current_state()
  local view = Collection.snapshot(profile)
  state.page = math.min(view.page_count, math.max(1, view.page + (delta or 0)))
  return state.page
end

function Collection.reset()
  G.COLLECTION = { category = "markets", filter = "all", page = 1 }
  return G.COLLECTION
end

-- Tests/mod loaders that rebuild center pools in-process can explicitly invalidate the read-only index.
function Collection.invalidate()
  CATALOG_CACHE = {}
end

return Collection
