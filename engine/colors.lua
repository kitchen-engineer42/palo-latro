-- engine/colors.lua — the core palette (returns a table; G.C is assigned from it in g.lua).
-- Colors are {r, g, b, a} floats in 0..1 (LÖVE 11 setColor accepts a table).
local function hex(s, a)
  return {
    tonumber(s:sub(1, 2), 16) / 255,
    tonumber(s:sub(3, 4), 16) / 255,
    tonumber(s:sub(5, 6), 16) / 255,
    a or 1,
  }
end

return {
  -- backdrop / panels
  bg        = hex("1b2330"),
  panel     = hex("2a3445"),
  panel_dim = hex("222b3a"),
  -- the three scoring quantities
  users     = hex("3fa7ff"), -- chips  (blue)
  mult      = hex("ff5a5a"), -- mult   (red)
  arr       = hex("ffcf4d"), -- score  (gold)
  -- ui text
  text      = hex("eef2f7"),
  text_dim  = hex("9aa7ba"),
  -- interaction
  select    = hex("ffe98a"),
  hover     = hex("ffffff"),
  border    = hex("0f1622"),
  -- buttons
  btn       = hex("3d6fb4"),
  btn_hi    = hex("5a8fd6"),
  btn_off   = hex("3a4456"),
  -- outcomes
  win       = hex("57c97a"),
  lose      = hex("ff6b6b"),
  black     = hex("000000"),
  white     = hex("ffffff"),
  shadow    = hex("000000", 0.35),
}
