-- market_tint.lua — P4 background tint per Market. Decoupled from the GENERATED markets data (no bridge
-- re-run): keyed by the market's `industry`. Deliberately MUTED + dark — the animated backdrop must never
-- overpower the cards. Each palette = { base, mid, highlight } (the background shader's tint1/2/3).
-- Boss market-events can later darken/desaturate by scaling these down through the same uniforms.
local M = {}

local PALETTE = {
  enterprise = { { 0.09, 0.11, 0.16 }, { 0.14, 0.18, 0.26 }, { 0.20, 0.26, 0.34 } }, -- steel blue-gray
  finance    = { { 0.07, 0.12, 0.10 }, { 0.11, 0.19, 0.15 }, { 0.16, 0.27, 0.20 } }, -- muted green
  social     = { { 0.12, 0.08, 0.15 }, { 0.19, 0.12, 0.24 }, { 0.27, 0.18, 0.32 } }, -- dim magenta
  commerce   = { { 0.14, 0.10, 0.07 }, { 0.22, 0.15, 0.10 }, { 0.30, 0.21, 0.13 } }, -- warm amber
  healthcare = { { 0.06, 0.13, 0.13 }, { 0.10, 0.20, 0.21 }, { 0.15, 0.28, 0.29 } }, -- teal
  legal      = { { 0.09, 0.09, 0.16 }, { 0.14, 0.14, 0.25 }, { 0.20, 0.20, 0.34 } }, -- indigo
}
-- neutral dark blue-gray (≈ G.C.bg hex 1b2330) — used for menu, industry "any", or an unknown market.
local DEFAULT = { { 0.07, 0.09, 0.13 }, { 0.11, 0.14, 0.19 }, { 0.16, 0.20, 0.27 } }

-- tint1, tint2, tint3, contrast for the current run's market (or the neutral default).
function M.current()
  local m = G.GAME and G.GAME.market
  local p = (m and m.industry and PALETTE[m.industry]) or DEFAULT
  return p[1], p[2], p[3], 1.15
end

return M
