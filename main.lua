-- main.lua — Palo Latro engine slice entry point. Wires the engine + game and runs the loop.

-- load order matters: util/globals -> engine classes -> content -> game logic -> ui
require("engine.util")
require("game.g")
require("engine.object")
require("engine.node")
require("engine.moveable")
require("engine.event")
require("engine.pools")
require("engine.draw")
require("engine.controller")
require("engine.uibox")
require("game.text")
local Centers      = require("game.centers")
require("game.card")
require("game.cardarea")
require("game.scoring")
local Round        = require("game.round")
local StateMachine = require("game.statemachine")
require("game.handlers")
require("game.founders")
local UI           = require("game.ui")
local Audio        = require("game.audio")
local Juice        = require("game.juice")
local Particles    = require("game.particles")
local PackPresentation = require("game.pack_presentation")
local Input         = require("game.input")
local INPUT

local layers = require("data.layers")
local MarketTint = require("data.market_tint")   -- P4: per-market background tint

-- P4: compile every assets/shaders/*.glsl into G.SHADERS[name] (Balatro auto-loads its shader dir the same
-- way). pcall-guarded per file so a bad/unsupported shader just disables THAT effect (its call site falls
-- back to the static render) instead of crashing — and a no-GPU/headless run simply leaves G.SHADERS empty.
local function load_shaders()
  G.SHADERS = {}
  local dir = "assets/shaders"
  if not love.filesystem.getInfo(dir) then return end
  for _, f in ipairs(love.filesystem.getDirectoryItems(dir)) do
    local name = f:match("^(.+)%.glsl$")
    if name then
      local ok, sh = pcall(love.graphics.newShader, dir .. "/" .. f)
      if ok then G.SHADERS[name] = sh
      else print("[shader] " .. f .. " failed to compile: " .. tostring(sh)) end
    end
  end
end

function love.load()
  love.graphics.setDefaultFilter("nearest", "nearest")
  love.graphics.setLineStyle("rough")                 -- no AA on lines → the chunky pixel look
  love.math.setRandomSeed(os.time())
  G.WINDOW.w, G.WINDOW.h = G.VW, G.VH                  -- gameplay lays out in VIRTUAL coords; drawn via a

  -- pixel-art typeface (P3): prefer m6x11 (Balatro's family — taller/clearer; free for commercial use)
  -- if present, else the m5x7 we ship. Fonts are (re)rasterized at the DISPLAY scale by rebuild_fonts()
  -- so text stays crisp at any window size (mirrors Balatro). Base point sizes are VIRTUAL; ×G.FONT_S live.
  G.FONT_FILE = (love.filesystem.getInfo("assets/fonts/m6x11.ttf") and "assets/fonts/m6x11.ttf")
    or "assets/fonts/m5x7.ttf"
  G.FONT_SIZES = { tiny = 20, small = 26, normal = 32, big = 46, huge = 72 }
  update_view(love.graphics.getDimensions())           -- native-res scale transform + builds G.FONTS at scale

  G.E_MANAGER = EventManager()
  local Profile = require("game.profile")
  Profile.load()                                  -- cross-run unlocks/discovery/stakes
  local tutorial_preview = os.getenv("PL_FRESH_TUTORIAL")
  if tutorial_preview then G.PROFILE = Profile.default() end   -- ephemeral QA profile; never overwrite the real save
  G.GUIDANCE_RUNTIME = not tutorial_preview
  Centers.load_all()
  Profile.apply_to_centers(Centers)               -- lock 2nd-forms etc. unless unlocked in the profile
  Centers.load_art()
  Centers.load_consumable_art()                   -- Track C B1: Tech Law card-face art (assets/consumables/)
  Centers.load_misc_art()                         -- Phase 4B: suit icons / pack covers / card back
  Audio.load()
  load_shaders()                                  -- P4: compile assets/shaders/*.glsl → G.SHADERS (guarded)
  StateMachine.prep_stage(G.STAGES.MAIN_MENU, G.STATES.MENU)   -- boot to the stake-select menu
  if tutorial_preview then
    G.FUNCS.start_run_at()
    if tutorial_preview == "play" then                         -- dev: inspect the compact in-run lesson panel
      G.FUNCS.guidance_ack()
      for index, market in ipairs(G.GAME.market_choices or {}) do
        if market.id == "indie-saas" then G.FUNCS["market_pick_" .. index](); break end
      end
      G.FUNCS.play_blind()
    end
  elseif os.getenv("PL_AUTORUN") then                         -- dev: skip the menu, jump into a run at stake N
    Round.start_run({ stake = tonumber(os.getenv("PL_AUTORUN")) or 1,
      market_id = os.getenv("PL_MARKET") or "indie-saas" })
    if os.getenv("PL_ERA") then G.GAME.era = tonumber(os.getenv("PL_ERA")) or G.GAME.era end
    if os.getenv("PL_PLAY") and G.FUNCS.play_blind then G.FUNCS.play_blind() end   -- + deal into the play screen
    if os.getenv("PL_SHOP") then
      local PreviewShop = require("game.shop")
      PreviewShop.enter(); StateMachine.set_state(G.STATES.SHOP)
      if os.getenv("PL_PACK_PREVIEW") then
        local preview_key = os.getenv("PL_PACK_PREVIEW")
        local preview_pack = require("game.packs").get(preview_key)
        if preview_pack then G.GAME.shop.packs[1] = preview_pack end
        G.GAME.cash = math.max(G.GAME.cash or 0, PreviewShop.pack_price(1))
        PreviewShop.open_pack(1)
      end
      local negotiation_preview = os.getenv("PL_NEGOTIATION_PREVIEW")
      if negotiation_preview then
        local founder = Centers.get(negotiation_preview)
        if founder and founder.set == "Founder" and founder.rarity == "Legendary"
            and not founder.signature then
          G.GAME.shop.pack_open = { kind = "hiring", name = "Legendary Hiring Round",
            pack_key = "preview_legendary", options = { founder }, picks_left = 1 }
          PreviewShop.pack_pick(1)
          local preview_answer = tonumber(os.getenv("PL_NEGOTIATION_ANSWER"))
          if preview_answer then PreviewShop.negotiation_answer(preview_answer) end
        end
      end
    end  -- jump to shop; optionally start its pack ceremony for screenshot review
    local law_preview = os.getenv("PL_LAWS")
    if law_preview and G.consumables then                          -- dev: grant comma-separated Laws for GUI review
      local C = require("game.consumables")
      if law_preview == "1" then law_preview = "tl_seed_round,tl_moores_law" end
      for key in law_preview:gmatch("[^,]+") do
        key = key:match("^%s*(.-)%s*$")
        C.grant(key, { source = "preview", sell_basis = 0, discover = false })
      end
      if os.getenv("PL_LAW_TARGET") and G.consumables.cards[1] then
        G.consumables.cards[1].selected = true
        G.FUNCS.use_consumable()
      end
    end
  end
  local collection_preview = os.getenv("PL_COLLECTION")
  if collection_preview then                                  -- dev: open a named read-only catalog for visual checks
    local Collection = require("game.collection")
    Collection.reset()
    if collection_preview ~= "1" then Collection.select_category(collection_preview) end
    StateMachine.set_state(G.STATES.COLLECTION)
  end
  local ov = os.getenv("PL_OVERLAY")                           -- dev: force an overlay open (screenshot checks)
  if ov == "runinfo" then G.SHOW_RUN_INFO = true
  elseif ov == "options" then G.SHOW_OPTIONS = true
  elseif ov == "deck" then G.SHOW_DECK_VIEW = true end
  if os.getenv("PL_EDITIONS") and G.jokers then     -- dev: spawn founders-with-art carrying each edition (preview P4 shimmer)
    local picks = {}
    for _, c in ipairs(Centers.pool("Founder")) do
      if G.FOUNDER_ART and G.FOUNDER_ART[c.key] then picks[#picks + 1] = c; if #picks >= #Card.EDITION_KEYS then break end end
    end
    for i, ed in ipairs(Card.EDITION_KEYS) do
      local c = picks[i]
      if c then local jk = Card({ center = c, T = { x = G.jokers.T.x, y = G.jokers.T.y } }); jk.edition = ed; G.jokers:emplace(jk) end
    end
  end
  local tech_preview = os.getenv("PL_TECH_PREVIEW") -- dev: render an exact art-review hand, comma-separated center keys
  if tech_preview and G.hand then
    -- Preview replacement must destroy the old hand, not merely detach it. Detached cards remain in
    -- G.I.CARD and would be drawn above the requested row with no deterministic area/index ordering.
    for i = #G.hand.cards, 1, -1 do
      local card = G.hand.cards[i]
      G.hand:remove_card(card, true)
      card:remove()
    end
    for key in tech_preview:gmatch("[^,]+") do
      key = key:match("^%s*(.-)%s*$")
      local center = Centers.get(key)
      if center and center.set == "TechCard" then
        G.hand:emplace(Card({ center = center, T = { x = G.hand.T.x, y = G.hand.T.y } }), true)
      end
    end
    G.hand:align_cards()
    StateMachine.set_state(G.STATES.SELECTING_HAND)
  end
  if os.getenv("PL_CRT") then G.SETTINGS.crt = true end        -- dev: force CRT post-fx on at boot (P4.4)
  if os.getenv("PL_FULLSCREEN") then                           -- dev: launch fullscreen (test scaling)
    love.window.setFullscreen(true)
    update_view(love.graphics.getDimensions())
  end
  INPUT = Input.new({ width = G.VW, height = G.VH })
  G.INPUT = INPUT
  local mx, my = vmap(love.mouse.getPosition())
  INPUT:pointer_moved(mx, my, "mouse")
  INPUT:update(0, UI.prepare())
end

function love.update(dt)
  -- clocks
  G.TIMERS.REAL = G.TIMERS.REAL + dt
  G.TIMERS.BACKGROUND = G.TIMERS.BACKGROUND + dt   -- P4 shader spin-time (wall-clock, never paused)
  local accel = 0
  if G.STATE == G.STATES.SCORING then
    G.ACC = math.min((G.ACC or 0) + dt * 0.6, 3)
    accel = G.ACC
  else
    G.ACC = 0
  end
  G.SPEEDFACTOR = G.SETTINGS.paused and 0 or (1 + accel)
  G.TIMERS.TOTAL = G.TIMERS.TOTAL + dt * G.SPEEDFACTOR

  -- event queues (the juice) + visual feel update
  if G.E_MANAGER then G.E_MANAGER:update() end
  Juice.update(dt)
  Particles.update(dt)
  if G.STATE == G.STATES.SHOP and G.GAME and G.GAME.shop then
    PackPresentation.update(G.GAME.shop.pack_open)
  end

  -- ease every moveable toward its target (visual time, clamped for stability)
  local move_dt = math.min(1 / 30, dt)
  for _, m in ipairs(G.I.MOVEABLE) do if m.move and not m.REMOVED then m:move(move_dt) end end
  for _, m in ipairs(G.I.MOVEABLE) do if m.update and not m.REMOVED then m:update(dt) end end

  -- per-state logic
  StateMachine.update(dt)
  if INPUT then INPUT:update(dt, UI.prepare()) end

  if os.getenv("PL_SHOT") then                       -- dev: grab a settled frame to a PNG, then quit
    G._shot = (G._shot or 0) + 1
    local shot_frame = tonumber(os.getenv("PL_SHOT_FRAME")) or 30
    if G._shot == shot_frame then love.graphics.captureScreenshot("pl_shot.png") end
    if G._shot > shot_frame + 3 then love.event.quit(0) end
  end
end

local function area_label(text, area)
  if not area then return end
  draw_text(G.FONTS.tiny, text, area.T.x, area.T.y - 24, G.C.text_dim)
end

function love.draw()
  -- P4.4 (optional, default off): render the whole frame to G.CANVAS, then blit it through the gentle CRT
  -- shader. No geometric warp, so the mouse→virtual mapping is unaffected. Falls straight to the screen when off.
  local use_crt = shaders_enabled() and G.SETTINGS.crt and G.SHADERS.crt
  if use_crt then
    local cw, ch = love.graphics.getDimensions()
    if not (G.CANVAS and G.CANVAS:getWidth() == cw and G.CANVAS:getHeight() == ch) then
      G.CANVAS = love.graphics.newCanvas(cw, ch)
    end
    love.graphics.setCanvas({ G.CANVAS, stencil = true }); love.graphics.clear()   -- stencil buffer → clip_chamfer works under CRT
  end
  -- Resolution independence (P2, revised): draw the virtual 1280×800 layout under a single uniform
  -- SCALE TRANSFORM at the window's native resolution (crisp — no low-res canvas/linear upscale), centred,
  -- with the bg filling the surround (adaptive to any aspect — no hard black letterbox). G.VIEW = scale+offset.
  -- P4: animated, market-tinted backdrop fills the whole window (incl. the centred surround), in WINDOW
  -- space before the scale transform. Falls back to the flat clear when shaders are off/unsupported or a
  -- uniform send errors (pcall) — so the frame always has a clean background.
  local bg_ok = false
  if shaders_enabled() and G.SHADERS.background then
    local sh = G.SHADERS.background
    local w, h = love.graphics.getDimensions()
    local t1, t2, t3, contrast = MarketTint.current()
    bg_ok = pcall(function()
      sh:send("time", shader_time())
      sh:send("spin", (G.GAME and G.GAME._bg_spin) or 0)
      sh:send("resolution", { w, h })
      sh:send("contrast", contrast)
      sh:send("tint1", t1); sh:send("tint2", t2); sh:send("tint3", t3)
      love.graphics.setShader(sh)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", 0, 0, w, h)
    end)
    love.graphics.setShader()
  end
  if not bg_ok then love.graphics.clear(G.C.bg) end    -- fills the whole window incl. the centred surround
  love.graphics.push()
  love.graphics.translate(G.VIEW.ox, G.VIEW.oy)
  love.graphics.scale(G.VIEW.scale, G.VIEW.scale)

  Juice.apply_transform()    -- screen shake wraps the scene only (UI stays steady/clickable)
  if G.STATE ~= G.STATES.SHOP and G.STATE ~= G.STATES.MENU and G.STATE ~= G.STATES.COLLECTION
      and G.STATE ~= G.STATES.BLIND_SELECT then   -- full-screen pages skip the play scene
    draw_all()               -- cards + areas (fixed-order pools); zone labels are drawn by ui.lua (P3 layout)
    Particles.draw()         -- sparkle bursts
    Juice.draw()             -- floating combat text (on top)
  end
  Juice.pop_transform()

  if G.STATE == G.STATES.SHOP and G.jokers then   -- founders stay visible in the shop (label drawn by ui.render_shop)
    for _, c in ipairs(G.jokers.cards) do c:draw() end
    if G.consumables then for _, c in ipairs(G.consumables.cards) do c:draw() end end   -- inventory visible in shop too
  end

  UI.render()                -- HUD / buttons / overlay (no shake)
  Juice.draw_flash()         -- brief crescendo/win-lose flash over the scene + HUD
  UI.draw_guidance()         -- static first-run lessons + independently toggleable Patch chatter
  UI.draw_tooltip()          -- hovered card's full ability text, on top of everything
  UI.draw_overlays()         -- Phase 4B: deck view / run info / options (topmost)

  love.graphics.pop()        -- end the virtual→native scale transform

  if use_crt then            -- P4.4: blit the full-scene canvas to the screen through the CRT post-fx
    love.graphics.setCanvas()
    local ok = pcall(function()
      G.SHADERS.crt:send("time", shader_time())
      G.SHADERS.crt:send("resolution", { G.CANVAS:getWidth(), G.CANVAS:getHeight() })
      love.graphics.setShader(G.SHADERS.crt)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(G.CANVAS, 0, 0)
    end)
    love.graphics.setShader()
    if not ok then love.graphics.draw(G.CANVAS, 0, 0) end
  end
end

function love.mousepressed(x, y, button)
  if not INPUT then return end
  local vx, vy = vmap(x, y)
  INPUT:pointer_pressed(vx, vy, button, "mouse")
end

function love.mousereleased(x, y, button)
  if not INPUT then return end
  local vx, vy = vmap(x, y)
  INPUT:pointer_released(vx, vy, button, "mouse")
end

function love.mousemoved(x, y)
  if not INPUT then return end
  local vx, vy = vmap(x, y)
  INPUT:pointer_moved(vx, vy, "mouse")
end

function love.keypressed(key)
  -- Dev toggles remain explicit; all gameplay, focus, modal, and cancel policy lives in Input.
  if key == "m" then G.SETTINGS.sound = not G.SETTINGS.sound; return             -- dev: toggle sound
  elseif key == "j" then G.SETTINGS.reduced_motion = not G.SETTINGS.reduced_motion; return  -- dev: toggle motion
  elseif key == "h" then G.SETTINGS.shaders = not G.SETTINGS.shaders; return                -- dev: toggle shaders (P4)
  elseif key == "c" then G.SETTINGS.crt = not G.SETTINGS.crt; return                        -- dev: toggle CRT post-fx (P4.4)
  end
  local handled = INPUT and INPUT:key_pressed(key, "keyboard")
  if key == "escape" and not handled then love.event.quit() end
end

function love.keyreleased(key)
  if INPUT then INPUT:key_released(key) end
end

local GAMEPAD_KEY = { a = "a", b = "cancel", dpup = "dpup", dpdown = "dpdown",
  dpleft = "dpleft", dpright = "dpright", start = "enter" }

function love.gamepadpressed(_, button)
  if not INPUT then return end
  local key = GAMEPAD_KEY[button]
  if key then INPUT:key_pressed(key, "gamepad") end
end

function love.gamepadreleased(_, button)
  local key = GAMEPAD_KEY[button]
  if INPUT and key then INPUT:key_released(key) end
end

function love.touchpressed(id, x, y)
  if not INPUT then return end
  local vx, vy = vmap(x, y)
  INPUT:pointer_pressed(vx, vy, 1, "touch:" .. tostring(id))
end

function love.touchmoved(id, x, y)
  if not INPUT then return end
  local vx, vy = vmap(x, y)
  INPUT:pointer_moved(vx, vy, "touch:" .. tostring(id))
end

function love.touchreleased(id, x, y)
  if not INPUT then return end
  local vx, vy = vmap(x, y)
  INPUT:pointer_released(vx, vy, 1, "touch:" .. tostring(id))
end

function love.resize(w, h)
  update_view(w, h)          -- recompute the virtual→window fit; G.WINDOW stays the virtual resolution (P2)
end
