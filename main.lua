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
  Centers.load_all()
  Profile.apply_to_centers(Centers)               -- lock 2nd-forms etc. unless unlocked in the profile
  Centers.load_art()
  Centers.load_consumable_art()                   -- Track C B1: Tech Law card-face art (assets/consumables/)
  Centers.load_misc_art()                         -- Phase 4B: suit icons / pack covers / card back
  Audio.load()
  load_shaders()                                  -- P4: compile assets/shaders/*.glsl → G.SHADERS (guarded)
  StateMachine.prep_stage(G.STAGES.MAIN_MENU, G.STATES.MENU)   -- boot to the stake-select menu
  if os.getenv("PL_AUTORUN") then                              -- dev: skip the menu, jump into a run at stake N
    Round.start_run({ stake = tonumber(os.getenv("PL_AUTORUN")) or 1,
      market_id = os.getenv("PL_MARKET") or "indie-saas" })
    if os.getenv("PL_PLAY") and G.FUNCS.play_blind then G.FUNCS.play_blind() end   -- + deal into the play screen
    if os.getenv("PL_SHOP") then
      local PreviewShop = require("game.shop")
      PreviewShop.enter(); StateMachine.set_state(G.STATES.SHOP)
      if os.getenv("PL_PACK_PREVIEW") then
        G.GAME.cash = math.max(G.GAME.cash or 0, PreviewShop.pack_price(1))
        PreviewShop.open_pack(1)
      end
    end  -- jump to shop; optionally start its pack ceremony for screenshot review
    if os.getenv("PL_LAWS") and G.consumables then                -- dev: grant Tech Laws (consumable-GUI testing)
      local C = require("game.consumables")
      C.grant("tl_seed_round"); C.grant("tl_moores_law")
    end
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

  -- hover: topmost hand card under the cursor (virtual coords, P2)
  local mx, my = vmouse()
  if G.hand then
    local top = nil
    for i = #G.hand.cards, 1, -1 do
      local c = G.hand.cards[i]
      c.states.hover.is = false
      if not top and c:collides_with_point(mx, my) then top = c end
    end
    if top then top.states.hover.is = true end
  end
  if G.jokers then
    for _, c in ipairs(G.jokers.cards) do c.states.hover.is = c:collides_with_point(mx, my) end
  end
  if G.consumables then
    for _, c in ipairs(G.consumables.cards) do c.states.hover.is = c:collides_with_point(mx, my) end
  end

  -- founder drag-to-reorder (order = scoring order): the held founder follows the cursor + slots into place
  local d = G.DRAG
  if d and love.mouse.isDown(1) and G.jokers and G.jokers.cards then
    local cards = G.jokers.cards
    local mxd = (vmouse())
    if math.abs(mxd - d.downx) > 6 then d.moved = true end
    if d.moved then
      local i; for k, cc in ipairs(cards) do if cc == d.card then i = k; break end end
      if i then
        local n, cw, gap = #cards, d.card.T.w, 12
        local startx = G.jokers.T.x + (G.jokers.T.w - (n * cw + (n - 1) * gap)) / 2
        local target = n
        for k = 1, n do if mxd < startx + (k - 1) * (cw + gap) + cw / 2 then target = k; break end end
        if target ~= i then table.remove(cards, i); table.insert(cards, target, d.card); G.jokers:align_cards() end
        d.card:set_T(mxd - d.grabx, G.jokers.T.y - 14)     -- lifted, following the cursor
      end
    end
  end

  -- per-state logic
  StateMachine.update(dt)

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
  if G.STATE ~= G.STATES.SHOP and G.STATE ~= G.STATES.MENU and G.STATE ~= G.STATES.BLIND_SELECT then   -- full-screen pages skip the play scene
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

-- input is locked while the scoring count-up animates (Balatro does the same) → no mid-crescendo misfires.
local function input_locked() return G.STATE == G.STATES.SCORING end

function love.mousepressed(x, y, button)
  if button == 2 and G.STATE == G.STATES.TARGET_SELECT then G.CONSUMABLE_CANCEL(); return end   -- B4 cancel
  if button ~= 1 then return end
  x, y = vmap(x, y)                      -- window → virtual coords (P2)
  if G.STATE == G.STATES.GAME_OVER then G.FUNCS.restart(); return end
  if input_locked() then return end

  -- Modal overlays own input. Covered gameplay buttons are never dispatched.
  if G.SHOW_DECK_VIEW or G.SHOW_RUN_INFO or G.SHOW_OPTIONS then
    local b = UI.button_at(x, y)
    if b and G.FUNCS[b] and (b:match("^opt_") or b == "run_info" or b == "options") then G.FUNCS[b](); return end
    G.SHOW_DECK_VIEW, G.SHOW_RUN_INFO, G.SHOW_OPTIONS = nil, nil, nil
    return
  end
  local b = UI.button_at(x, y)
  if b and G.FUNCS[b] then G.FUNCS[b](); return end
  -- click the draw pile → deck-view overlay
  if G.STATE == G.STATES.SELECTING_HAND and G.deck
     and x >= G.deck.T.x and x <= G.deck.T.x + Card.W and y >= G.deck.T.y and y <= G.deck.T.y + Card.H then
    G.SHOW_DECK_VIEW = true
    return
  end

  -- B4: TARGET_SELECT — ONLY eligible hand cards are clickable (hard-gated; buttons above still work
  -- so the Layer picker + cancel reach their FUNCS). Everything else falls through to nothing.
  if G.STATE == G.STATES.TARGET_SELECT then
    local pc = G.PENDING_CONSUMABLE
    if pc and not pc.need_layer and G.hand then
      for i = #G.hand.cards, 1, -1 do
        local c = G.hand.cards[i]
        if c:collides_with_point(x, y) and not c.selected then
          c:juice_up(0.35); Audio.play("select", nil, 0.5)
          G.CONSUMABLE_TARGET_PICK(c)
          break
        end
      end
    end
    return
  end

  -- B2: consumable click-to-select (Use/Sell buttons appear beneath; separate from founder drag)
  if (G.STATE == G.STATES.SELECTING_HAND or G.STATE == G.STATES.SHOP) and G.consumables then
    for i = #G.consumables.cards, 1, -1 do
      local c = G.consumables.cards[i]
      if c:collides_with_point(x, y) then
        c.selected = not c.selected
        for _, o in ipairs(G.consumables.cards) do if o ~= c then o.selected = false end end
        c:juice_up(0.3); Audio.play("select", nil, 0.5)
        return
      end
    end
  end

  if (G.STATE == G.STATES.SELECTING_HAND or G.STATE == G.STATES.SHOP) and G.jokers then  -- grab a founder: drag to reorder, click to select/sell
    for i = #G.jokers.cards, 1, -1 do
      local c = G.jokers.cards[i]
      if c:collides_with_point(x, y) then
        G.DRAG = { card = c, grabx = x - c.T.x, downx = x, moved = false }   -- order = scoring order
        return
      end
    end
  end

  if G.STATE == G.STATES.SELECTING_HAND and G.hand then
    for i = #G.hand.cards, 1, -1 do
      local c = G.hand.cards[i]
      if c:collides_with_point(x, y) then
        if c.selected or #G.hand:highlighted() < G.GAME.select_max then
          c:toggle_select(); c:juice_up(0.35); Audio.play("select", nil, 0.5)
        end
        break
      end
    end
  end
end

function love.mousereleased(x, y, button)
  if button ~= 1 then return end
  local d = G.DRAG
  if not d then return end
  if not d.moved and G.jokers then                 -- a click (not a drag) → toggle selection
    for _, j in ipairs(G.jokers.cards) do if j ~= d.card then j.selected = false end end
    d.card.selected = not d.card.selected
    d.card:juice_up(0.35); Audio.play("select", nil, 0.5)
  end
  if G.jokers then G.jokers:align_cards() end       -- snap the reordered row back into place
  G.DRAG = nil
end

function love.keypressed(key)
  -- always-live keys (quit / restart / dev toggles) — work even mid-animation
  if key == "escape" then
    if G.STATE == G.STATES.TARGET_SELECT then G.CONSUMABLE_CANCEL(); return end
    if G.SHOW_RUN_INFO or G.SHOW_OPTIONS or G.SHOW_DECK_VIEW then
      G.SHOW_RUN_INFO, G.SHOW_OPTIONS, G.SHOW_DECK_VIEW = nil, nil, nil; return
    end
    love.event.quit(); return
  elseif key == "r" then G.FUNCS.restart(); return
  elseif key == "m" then G.SETTINGS.sound = not G.SETTINGS.sound; return          -- dev: toggle sound
  elseif key == "j" then G.SETTINGS.reduced_motion = not G.SETTINGS.reduced_motion; return  -- dev: toggle motion
  elseif key == "h" then G.SETTINGS.shaders = not G.SETTINGS.shaders; return                -- dev: toggle shaders (P4)
  elseif key == "c" then G.SETTINGS.crt = not G.SETTINGS.crt; return                        -- dev: toggle CRT post-fx (P4.4)
  end
  if input_locked() then return end                                              -- lock actions during the count-up
  if key == "space" then if G.FUNCS.ship then G.FUNCS.ship() end
  elseif key == "f" then if G.FUNCS.refactor then G.FUNCS.refactor() end   -- pay down tech-debt (E3)
  elseif key == "d" then if G.FUNCS.distill then G.FUNCS.distill() end      -- distill selected founder (E4)
  elseif key == "p" then if G.FUNCS.promote then G.FUNCS.promote() end      -- automate selected founder (E4)
  elseif key == "e" then if G.FUNCS.raise then G.FUNCS.raise() end          -- raise round / dilute equity (E4)
  elseif key == "v" then if G.FUNCS.market_pivot then G.FUNCS.market_pivot() end  -- pivot markets (E5)
  end
end

function love.resize(w, h)
  update_view(w, h)          -- recompute the virtual→window fit; G.WINDOW stays the virtual resolution (P2)
end
