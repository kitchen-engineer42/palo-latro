-- Compact two-level Options model. One row projection and one geometry projection feed
-- both rendering and input, so category navigation cannot leave invisible live targets.

local Guidance = require("game.guidance")

local Options = { PANEL_W = 420, PANEL_H = 520 }
local VALID_PAGE = { root = true, game = true, visual = true, sound = true }

function Options.page()
  if not VALID_PAGE[G.OPTIONS_PAGE] then G.OPTIONS_PAGE = "root" end
  return G.OPTIONS_PAGE
end

function Options.set_page(page)
  if not VALID_PAGE[page] then return false end
  G.OPTIONS_PAGE = page
  return true
end

function Options.reset()
  G.OPTIONS_PAGE = "root"
  return G.OPTIONS_PAGE
end

function Options.title()
  local page = Options.page()
  return page == "root" and "OPTIONS" or ("OPTIONS  /  " .. page:upper())
end

function Options.rows()
  local page = Options.page()
  if page == "game" then
    local prefs = Guidance.preferences()
    return {
      { action = "opt_guidance", label = "Beginner guide:  " .. (prefs.guidance and "ON" or "OFF") },
      { action = "opt_chatter", label = "Cofounder chatter:  " .. (prefs.cofounder_chatter and "ON" or "OFF") },
      { action = "opt_back", label = "‹  Back" },
    }
  elseif page == "visual" then
    return {
      { action = "opt_motion", label = "Motion FX:  " .. (G.SETTINGS.reduced_motion and "OFF" or "ON") },
      { action = "opt_shake", label = "Screen shake:  " .. (G.SETTINGS.shake == false and "OFF" or "ON") },
      { action = "opt_flash", label = "Screen flash:  " .. (G.SETTINGS.flash == false and "OFF" or "ON") },
      { action = "opt_particles", label = "Particles:  " .. (G.SETTINGS.particles == false and "OFF" or "ON") },
      { action = "opt_crt", label = "CRT filter:  " .. (G.SETTINGS.crt and "ON" or "OFF") },
      { action = "opt_back", label = "‹  Back" },
    }
  elseif page == "sound" then
    return {
      { action = "opt_sound", label = "Sound:  " .. (G.SETTINGS.sound == false and "OFF" or "ON") },
      { action = "opt_back", label = "‹  Back" },
    }
  end
  return {
    { action = "opt_page_game", label = "Game  ›" },
    { action = "opt_page_visual", label = "Visual  ›" },
    { action = "opt_page_sound", label = "Sound  ›" },
    { action = "opt_wiki", label = "Open Wiki" },
    { action = "opt_quit", label = "Quit to menu" },
  }
end

function Options.geometry(width, height)
  local panel = {
    x = (width - Options.PANEL_W) / 2,
    y = (height - Options.PANEL_H) / 2,
    w = Options.PANEL_W,
    h = Options.PANEL_H,
  }
  local rows = Options.rows()
  local out = { panel = panel, rows = {}, title = Options.title(), page = Options.page() }
  local y = panel.y + 74
  for index, row in ipairs(rows) do
    out.rows[index] = {
      action = row.action, label = row.label,
      rect = { x = panel.x + 60, y = y, w = panel.w - 120, h = 46 },
    }
    y = y + 58
  end
  return out
end

return Options
