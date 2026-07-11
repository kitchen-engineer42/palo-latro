-- data/layers.lua — the 5 tech Layers (the "suit" analogue): display + placeholder color.
-- Single source of truth for Layer identity. Colors are placeholder (art pipeline finalizes).
local function rgb(r, g, b) return { r / 255, g / 255, b / 255, 1 } end

return {
  order = { "Frontend", "Backend", "Data", "Infra", "AI" },
  Frontend = { display = "Frontend", color = rgb(56, 200, 219) }, -- cyan
  Backend  = { display = "Backend",  color = rgb(94, 196, 120) }, -- green
  Data     = { display = "Data",     color = rgb(160, 122, 230) }, -- violet
  Infra    = { display = "Infra",    color = rgb(232, 152, 74) }, -- orange
  AI       = { display = "AI",       color = rgb(224, 96, 168) }, -- magenta
}
