-- Palo Latro — LÖVE configuration (loaded by LÖVE before main.lua)
function love.conf(t)
  t.identity = "palo-latro"          -- save directory name (save/load is a later module)
  t.version = "11.4"                 -- target LÖVE version
  t.window.title = "Palo Latro"
  t.window.width = 1280
  t.window.height = 800
  t.window.minwidth = 960
  t.window.minheight = 600
  t.window.resizable = true
  t.window.vsync = 1
  t.window.highdpi = true
  -- Modules the lightweight runtime does not use:
  t.modules.physics = false
  t.modules.joystick = false
  t.modules.touch = false
end
