-- game/g.lua — the global singleton G (engine pools + session/run state).
-- Mirrors Balatro's "everyone reaches into one well-known global" style (the runtime contract).

G = {}

-- Two-level state machine enums (STAGE × STATE). Only RUN is used in the slice; the
-- MENU/SHOP seam is here so later modules slot in without restructuring.
G.STAGES = { MAIN_MENU = 1, RUN = 2 }
G.STATES = {
  SELECTING_HAND = 1,
  SHIPPING       = 2,
  SCORING        = 3,
  DRAW_TO_HAND   = 4,
  ROUND_EVAL     = 5,
  GAME_OVER      = 6,
  SHOP           = 7,   -- between-blinds founder shop
  MENU           = 8,   -- pre-run stake-select + collection
  BLIND_SELECT   = 9,   -- pre-blind preview/select (P2): kind/target/reward + boss telegraph
  USE_CARD       = 10,  -- Track C B2: a consumable is resolving (transient; gates input)
  TARGET_SELECT  = 11,  -- Track C B4: a targeted consumable awaits the player's card pick(s)
  MARKET_SELECT  = 12,  -- choose one of three authored run identities before the first blind
  TECH_DRAFT     = 13,  -- post-boss persistent Tech choice
}

-- Instance pools — flat lists for batch update/draw/cleanup and O(1)-ish input dispatch
-- (the runtime contract; benchmark: load-bearing for many on-screen objects).
G.I = { NODE = {}, MOVEABLE = {}, CARD = {}, CARDAREA = {}, UIBOX = {} }
G.STAGE_OBJECTS = {}              -- [stage] = { nodes created during that stage } (mass-teardown)
G.CONTROLLER = nil                -- installed by the input adapter after engine.controller is available
G.UI_ROOT = nil                   -- retained UIBox owned by the current stage/state, if any
G.UI_BOXES = {}                   -- additional retained UIBoxes; lifecycle-owned, not a draw-order pool
G.UI_OWNER = { stage = nil, state = nil } -- documents who may retain/rebuild the UI registry
G.FLOATING = {}                   -- transient floating combat-text ("+N Users", "x N Rev", "+$N")
G.PARTICLES = {}                  -- transient sparkle-burst particles
G.SHAKE = 0                       -- screen-shake amplitude (decays each frame)

-- Clocks (the runtime contract). TOTAL (gameplay, speed-scaled/pausable), REAL (wall-clock UI), and
-- BACKGROUND (P4 shader spin-time — wall-clock, never paused; drives the animated bg + edition shimmer).
G.TIMERS = { TOTAL = 0, REAL = 0, BACKGROUND = 0 }
G.exp_times = { xy = 1, r = 1, scale = 1 }   -- per-frame easing constants (computed in update)
G.SPEEDFACTOR = 1
G.ACC = 0                                     -- scoring acceleration ("hold to speed up")
G.FRAMES = { DRAW = 0, MOVE = 0 }

G.SETTINGS = {
  gamespeed = 4, paused = false, reduced_motion = false,
  sound = true, sfx_volume = 1, music_volume = 0.7,
  shaders = true, crt = false, shake = true, flash = true, particles = true,
}

-- Resolved-by-string registries (the "engine never hard-codes behavior/text" seams)
G.FUNCS = {}                      -- button/string-keyed handlers (handlers.lua)
G.TEXT = {}                       -- localization seam (text.lua)
G.P_CENTERS = {}                  -- every content item by key (centers.lua)
G.P_CENTER_POOLS = {}             -- [set] = { centers of that set }

G.C = require("engine.colors")    -- the palette

G.ROOM = nil                      -- scene-graph root (built in prep_stage)
G.GAME = nil                      -- the current run (built on run start)
-- Resolution independence (P2): the whole frame is laid out + drawn at a fixed VIRTUAL resolution
-- (G.WINDOW = G.VW×G.VH), rendered to G.CANVAS, then scaled-to-fit + letterboxed into the real window.
-- All gameplay code keeps using G.WINDOW.w/h (virtual) and is scale-agnostic; G.VIEW holds the fit
-- transform (scale + letterbox offset) and is the only place that knows the real window size.
-- Virtual design resolution mirrors Balatro's room: 20 × 11.5 tiles (P3). G.TILE = px per tile in virtual
-- space; cards/layout are sized in tiles like Balatro (CARD = 2.05 × 2.75 tiles, 35:47). Adaptive scaling
-- (G.VIEW) fits this to any window. Aspect ≈ 1.74 (Balatro's).
G.TILE = 70
G.VW, G.VH = 20 * G.TILE, math.floor(11.5 * G.TILE)   -- 1400 × 805
G.WINDOW = { w = G.VW, h = G.VH }  -- VIRTUAL coords (everything lays out here; scaled to the real window)
G.CANVAS = nil                    -- reserved: a native-res canvas for the P4 post-fx (CRT etc.) shader pass
G.SHADERS = {}                    -- P4: name → compiled love.Shader, auto-loaded at boot from assets/shaders/*.glsl
G.VIEW = { scale = 1, ox = 0, oy = 0 }   -- virtual→window: window_xy = virtual_xy*scale + (ox,oy)

-- monotonic ids for nodes
local _id = 0
function generate_id() _id = _id + 1; return _id end

-- Static shader quality remains available with reduced motion; shader_time() freezes animation.
-- EVERY shader call site guards on this and falls back to its static render when false — so the game runs
-- identically with shaders off, on a no-GPU/headless box, or if a shader failed to compile.
function shaders_enabled()
  return G.SETTINGS.shaders and next(G.SHADERS or {}) ~= nil
end
function shader_time() return G.SETTINGS.reduced_motion and 0 or G.TIMERS.BACKGROUND end

return G
