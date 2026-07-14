-- game/centers.lua — the content registry. Every content item is registered as an immutable
-- plain-data CENTER into G.P_CENTERS (by key) + G.P_CENTER_POOLS[set]. A live Card points at a
-- center by key; behavior/text resolve by string (so save/load + modding work). This is THE
-- architecture that scales to hundreds of entries (benchmark / the runtime contract).

local Centers = {}
local ContentValidate = require("game.content_validate")

function Centers.register(c)
  assert(c.key and c.set, "center needs key + set")
  G.P_CENTERS[c.key] = c
  G.P_CENTER_POOLS[c.set] = G.P_CENTER_POOLS[c.set] or {}
  table.insert(G.P_CENTER_POOLS[c.set], c)
  return c
end

function Centers.get(key) return G.P_CENTERS[key] end
function Centers.pool(set) return G.P_CENTER_POOLS[set] or {} end

-- Register all content. Sets used in the slice: TechCard (deck) + AppType. Later sets
-- (Founder, Voucher, Tag, Edition, Seal, Enhancement, Blind, Back, …) register the same way.
function Centers.load_all()
  local content = {
    techcards = require("data.centers.techcards_gen"),
    founders = require("data.centers.founders_gen"),
    forms = require("data.centers.forms_gen"),
    signature_cards = require("data.centers.signature_cards"),
    vouchers = require("data.centers.vouchers"),
    consumables = require("data.gameplay.tech_laws"),
    compat = require("data.centers.compat_gen"),
    markets = require("data.centers.markets_gen"),
  }
  Centers.content_report = ContentValidate.assert_catalog(content, {
    minimums = { techcards = 226, founders = 262, forms = 17, tech_laws = 22 },
  })

  for _, c in ipairs(content.techcards) do Centers.register(c) end   -- 226 (bridge B1)
  for _, a in ipairs(require("game.apptypes").list) do Centers.register(a) end
  for _, f in ipairs(content.founders) do Centers.register(f) end    -- 262 (bridge B1)
  for _, s in ipairs(content.signature_cards) do Centers.register(s) end -- signature pair
  for _, fm in ipairs(content.forms) do Centers.register(fm) end          -- legendary 2nd forms
  for _, v in ipairs(content.vouchers) do Centers.register(v) end         -- investment vouchers
  for _, c in ipairs(content.consumables) do Centers.register(c) end       -- authored Tech Law consumables
end

-- preload founder art into G.FOUNDER_ART (call from love.load — needs love.graphics).
-- Filename derives from the center key: f_<id> → assets/founders/<id>.png (no per-center `art` field needed);
-- an explicit `f.art` still wins. Missing files fall back to the initials placeholder (card.lua). Mipmaps +
-- linear keep the 512px source clean when downscaled to the small card portrait.
function Centers.load_art()
  G.FOUNDER_ART = {}
  local function try(file)
    if not file then return nil end
    local ok, img = pcall(love.graphics.newImage, "assets/founders/" .. file, { mipmaps = true })
    if ok then pcall(img.setFilter, img, "linear", "linear"); return img end
  end
  for _, f in ipairs(Centers.pool("Founder")) do
    local img = try(f.art or (f.key and (f.key:gsub("^f_", "") .. ".png")))
    if not img and f.key and f.key:find("__") then           -- legendary 2nd-form → fall back to the base founder portrait
      img = try(f.key:gsub("^f_", ""):gsub("__.*$", "") .. ".png")
    end
    if img then G.FOUNDER_ART[f.key] = img end
  end
end

-- Track C B1: consumable (Tech Law) card-face art — the codex art is the COMPLETE card front.
-- assets/consumables/<key>.png, keyed by the Consumable center key. Missing files → the text fallback face.
function Centers.load_consumable_art()
  G.CONSUMABLE_ART = {}
  for _, c in ipairs(Centers.pool("Consumable")) do
    local ok, img = pcall(love.graphics.newImage, "assets/consumables/" .. c.key .. ".png", { mipmaps = true })
    if ok then pcall(img.setFilter, img, "linear", "linear"); G.CONSUMABLE_ART[c.key] = img end
  end
end

-- Phase 4B: misc art — Layer suit icons (white-on-alpha, engine-tinted), pack covers, the card back.
function Centers.load_misc_art()
  G.SUIT_ART, G.PACK_ART, G.TECH_ART = {}, {}, {}
  for _, L in ipairs({ "Frontend", "Backend", "Data", "Infra", "AI" }) do
    local ok, img = pcall(love.graphics.newImage, "assets/suits/" .. L:lower() .. ".png", { mipmaps = true })
    if ok then pcall(img.setFilter, img, "linear", "linear"); G.SUIT_ART[L] = img end
  end
  local pack_cache = {}
  local function pack_image(key)
    if pack_cache[key] ~= nil then return pack_cache[key] or nil end
    local ok, img = pcall(love.graphics.newImage, "assets/packs/" .. key .. ".png", { mipmaps = true })
    if ok then pcall(img.setFilter, img, "linear", "linear"); pack_cache[key] = img; return img end
    pack_cache[key] = false
  end
  for _, p in ipairs(require("game.packs").all()) do
    local img = pack_image(p.art_key) or (p.fallback_art and pack_image(p.fallback_art))
    if img then G.PACK_ART[p.art_key] = img end
  end
  -- Compatibility key for the existing approved Hiring Round cover.
  G.PACK_ART.hiring_round = pack_image("hiring_round")
  local okb, bimg = pcall(love.graphics.newImage, "assets/card_back.png", { mipmaps = true })
  if okb then pcall(bimg.setFilter, bimg, "linear", "linear"); G.CARD_BACK = bimg end   -- nil until the art lands
  for _, c in ipairs(Centers.pool("TechCard")) do
    local id = c.key and c.key:gsub("^t_", "")
    if id then
      local ok, img = pcall(love.graphics.newImage, "assets/tech_marks/" .. id .. ".png", { mipmaps = true })
      if ok then pcall(img.setFilter, img, "linear", "linear"); G.TECH_ART[c.key] = img end
    end
  end
end

return Centers
