-- Deterministic first-run guidance state machine. Content is static in data/guidance/cofounder.lua;
-- this module owns progression only. UI and handlers communicate through named events.

local Content = require("data.guidance.cofounder")

local Guidance = {}
Guidance.SCRIPT_VERSION = Content.script.version

local lesson_by_id, hint_by_event = {}, {}
for i, lesson in ipairs(Content.lessons) do
  lesson.index = i
  lesson_by_id[lesson.id] = lesson
end
for _, hint in ipairs(Content.hints) do
  hint_by_event[hint.event] = hint_by_event[hint.event] or {}
  hint_by_event[hint.event][#hint_by_event[hint.event] + 1] = hint
end

local function profile_or_global(profile)
  return profile or (G and G.PROFILE)
end

local function bool(value, default)
  if type(value) == "boolean" then return value end
  return default
end

-- Defensive normalization supports tests, embedders, and profiles constructed before the codec runs.
function Guidance.ensure(profile)
  profile = assert(profile_or_global(profile), "guidance requires a profile")
  profile.preferences = type(profile.preferences) == "table" and profile.preferences or {}
  profile.preferences.guidance = bool(profile.preferences.guidance, true)
  profile.preferences.cofounder_chatter = bool(profile.preferences.cofounder_chatter, true)

  profile.tutorial = type(profile.tutorial) == "table" and profile.tutorial or {}
  local tutorial = profile.tutorial
  tutorial.version = tonumber(tutorial.version) or Guidance.SCRIPT_VERSION
  tutorial.script = type(tutorial.script) == "string" and tutorial.script or Content.script.id
  tutorial.started = bool(tutorial.started, false)
  tutorial.completed = bool(tutorial.completed, false)
  tutorial.first_win = bool(tutorial.first_win, false)
  tutorial.seen = type(tutorial.seen) == "table" and tutorial.seen or {}
  tutorial.milestones = type(tutorial.milestones) == "table" and tutorial.milestones or {}
  tutorial.contextual_seen = type(tutorial.contextual_seen) == "table" and tutorial.contextual_seen or {}
  tutorial.chatter_counts = type(tutorial.chatter_counts) == "table" and tutorial.chatter_counts or {}
  if tutorial.active_lesson ~= nil
      and (type(tutorial.active_lesson) ~= "string" or not lesson_by_id[tutorial.active_lesson]) then
    tutorial.active_lesson = nil
  end
  return profile
end

local function public_copy(item, kind)
  if not item then return nil end
  return {
    id = item.id,
    kind = kind,
    title = item.title,
    body = item.body,
    prompt = item.prompt,
    cofounder = Content.script.cofounder,
  }
end

local function matches(requirement, context)
  for key, expected in pairs(requirement or {}) do
    if context[key] ~= expected then return false end
  end
  return true
end

local function dependency_seen(tutorial, lesson)
  return lesson.after == nil or tutorial.seen[lesson.after] == true
end

local function activate_available(tutorial)
  if tutorial.completed then return nil, false end
  if tutorial.active_lesson and not tutorial.seen[tutorial.active_lesson] then
    return lesson_by_id[tutorial.active_lesson], false
  end
  local changed = tutorial.active_lesson ~= nil
  tutorial.active_lesson = nil
  for _, lesson in ipairs(Content.lessons) do
    if not tutorial.seen[lesson.id] and dependency_seen(tutorial, lesson)
        and tutorial.milestones[lesson.trigger] then
      tutorial.active_lesson = lesson.id
      return lesson, true
    end
  end
  return nil, changed
end

local function complete_active(tutorial, event, context)
  local lesson = lesson_by_id[tutorial.active_lesson]
  if not lesson or lesson.complete ~= event or not matches(lesson.require, context) then return false end
  tutorial.seen[lesson.id] = true
  tutorial.active_lesson = nil
  if lesson.index == #Content.lessons then tutorial.completed = true end
  return true
end

function Guidance.preferences(profile)
  profile = Guidance.ensure(profile)
  return {
    guidance = profile.preferences.guidance,
    cofounder_chatter = profile.preferences.cofounder_chatter,
  }
end

function Guidance.set_preference(key, enabled, profile)
  profile = Guidance.ensure(profile)
  if key ~= "guidance" and key ~= "cofounder_chatter" then
    return false, "unknown guidance preference: " .. tostring(key)
  end
  if type(enabled) ~= "boolean" then return false, "guidance preference must be boolean" end
  profile.preferences[key] = enabled
  return true
end

function Guidance.first_run(profile)
  profile = Guidance.ensure(profile)
  -- A run is not persisted, so an abandoned tutorial must restart with the same seed and Market lock.
  -- `started` is presentation history, not proof that the player reached a safe resume point.
  return profile.preferences.guidance and not profile.tutorial.completed
    and not profile.tutorial.first_win and ((profile.career and profile.career.runs) or 0) == 0
end

function Guidance.first_run_options(profile)
  if not Guidance.first_run(profile) then return nil end
  return {
    script = Content.script.id,
    script_version = Content.script.version,
    seed = Content.script.seed,
    recommended_market_id = Content.script.market_id,
  }
end

function Guidance.current(profile)
  profile = profile_or_global(profile)
  if not profile then return nil end
  profile = Guidance.ensure(profile)
  if not profile.preferences.guidance or profile.tutorial.first_win then return nil end
  return public_copy(lesson_by_id[profile.tutorial.active_lesson], "lesson")
end

function Guidance.snapshot(profile)
  profile = Guidance.ensure(profile)
  return {
    script = profile.tutorial.script,
    version = profile.tutorial.version,
    started = profile.tutorial.started,
    completed = profile.tutorial.completed,
    first_win = profile.tutorial.first_win,
    recommended_market_id = Content.script.market_id,
    cofounder = Content.script.cofounder,
    preferences = Guidance.preferences(profile),
    lesson = Guidance.current(profile),
  }
end

-- Report a named gameplay milestone. The return value contains only presentation-ready static data:
-- {lesson=?, hint=?, chatter=?}. Replaying the same event sequence produces the same state and messages.
function Guidance.notify(event, context, profile)
  assert(type(event) == "string" and event ~= "", "guidance event must be a non-empty string")
  context = context or {}
  profile = Guidance.ensure(profile)
  local tutorial = profile.tutorial
  local changed = false

  -- Turning guidance off pauses the tutorial cleanly. Chatter remains independent below, but stale
  -- milestones must not awaken a half-finished lesson if guidance is re-enabled later in the run.
  if profile.preferences.guidance then
    if event == "run_started" and not tutorial.started then tutorial.started, changed = true, true end
    if tutorial.milestones[event] ~= true then tutorial.milestones[event], changed = true, true end
    if complete_active(tutorial, event, context) then changed = true end
  end

  if event == "run_won" then
    if not tutorial.first_win or not tutorial.completed or tutorial.active_lesson ~= nil then changed = true end
    tutorial.first_win, tutorial.completed, tutorial.active_lesson = true, true, nil
  end

  local out = {}
  if profile.preferences.guidance and not tutorial.first_win then
    local active, activated = activate_available(tutorial)
    if activated then changed = true end
    out.lesson = public_copy(active, "lesson")
    -- The lesson panel wins presentation priority. Do not consume a one-time hint behind it; the
    -- hint remains eligible when the same situation recurs after scripted onboarding.
    if not out.lesson then
      for _, hint in ipairs(hint_by_event[event] or {}) do
        if not tutorial.contextual_seen[hint.id] then
          tutorial.contextual_seen[hint.id], changed = true, true
          out.hint = public_copy(hint, "hint")
          break
        end
      end
    end
  end

  if profile.preferences.cofounder_chatter then
    local lines = Content.chatter[event]
    if lines and #lines > 0 then
      local count = (tutorial.chatter_counts[event] or 0) + 1
      tutorial.chatter_counts[event] = count
      changed = true
      out.chatter = {
        id = event .. ":" .. count,
        kind = "chatter",
        body = lines[((count - 1) % #lines) + 1],
        cofounder = Content.script.cofounder,
      }
    end
  end
  return out, changed
end

function Guidance.acknowledge(profile)
  return Guidance.notify("acknowledged", {}, profile)
end

-- Runtime convenience: publish transient presentation data and persist tutorial progress. The pure
-- `notify` API remains available to tests and deterministic tools; headless mimic episodes never touch
-- the real profile or filesystem.
function Guidance.emit(event, context)
  if not (G and G.PROFILE) or G.MIMIC_HEADLESS then return {} end
  local result, changed = Guidance.notify(event, context, G.PROFILE)
  local message = result.hint or result.chatter
  if message then
    G.GUIDANCE_TOAST = {
      message = message,
      expires = ((G.TIMERS and G.TIMERS.REAL) or 0) + 7,
    }
  end
  if changed and G.GUIDANCE_RUNTIME and not G.MIMIC_HEADLESS then require("game.profile").save() end
  return result
end

return Guidance
