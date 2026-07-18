-- One-release compatibility facade for the former Collection catalog API.
-- New UI and code should use game.wiki directly.

local Wiki = require("game.wiki")
local Collection = {
  PAGE_SIZE = Wiki.PAGE_SIZE,
  CATEGORIES = Wiki.LEGACY_CATEGORIES,
  deprecated = true,
}

local function sync_legacy_state()
  if type(G.COLLECTION) == "table" and G.COLLECTION ~= G.WIKI then
    local legacy = G.COLLECTION
    Wiki.reset({ category = legacy.category, source = "collection-compat" })
    G.WIKI.facet = legacy.filter or "all"
    G.WIKI.page = legacy.page or 1
    G.COLLECTION = G.WIKI
  end
end

function Collection.categories() return Collection.CATEGORIES end
function Collection.filters(category_id) return Wiki.facets(category_id) end

function Collection.select_category(value)
  sync_legacy_state()
  local category = type(value) == "number" and Collection.CATEGORIES[value] or nil
  return Wiki.select_category(category and category.id or value)
end

function Collection.select_filter(value) sync_legacy_state(); return Wiki.select_facet(value) end
function Collection.change_page(delta, profile) sync_legacy_state(); return Wiki.change_page(delta, profile) end

function Collection.progress(profile)
  local progress, out = Wiki.progress(profile), {}
  for _, category in ipairs(Collection.CATEGORIES) do out[category.id] = progress[category.id] end
  return out
end

function Collection.snapshot(profile)
  sync_legacy_state()
  local view = Wiki.snapshot(profile)
  if view.category.id == "all" or view.category.id == "mechanics" then
    Wiki.select_category("markets")
    view = Wiki.snapshot(profile)
  end
  local legacy_category = Collection.CATEGORIES[view.category.legacy_index]
  return {
    category = legacy_category, category_index = legacy_category.legacy_index,
    filter = view.facet, filter_index = view.facet_index, filters = view.facets,
    page = view.page, page_count = view.page_count, first = view.first, last = view.last,
    discovered = view.discovered, total = view.total,
    filtered_discovered = view.filtered_discovered, filtered_total = view.filtered_total,
    items = view.items, progress = Collection.progress(profile),
  }
end

function Collection.reset()
  Wiki.reset({ category = "markets", source = "collection-compat" })
  G.COLLECTION = G.WIKI
  return G.COLLECTION
end

function Collection.invalidate() Wiki.invalidate() end

return Collection
