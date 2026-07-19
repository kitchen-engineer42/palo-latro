-- game/feedback.lua -- semantic, presentation-only event registry.
--
-- Gameplay and input code emit named outcomes here; adapters translate them into sound, Juice,
-- particles, shader envelopes, or other presentation. The registry never calls gameplay handlers,
-- consumes RNG, or writes save state. Stable scope tokens make stale visual/audio work self-cancelling.

local Feedback = {
  VERSION = "palo-latro.feedback.v1",
  _clock = 0,
  _next_id = 0,
  _scope = "boot",
  _active = {},
  _last = {},
  _adapters = {},
}

local RECIPES = {
  silent       = { silent = true, duration = 0 },
  hover        = { audio = "hover", duration = .12, throttle = .06, visual = "hover" },
  focus        = { audio = "hover", duration = .12, throttle = .06, visual = "focus" },
  press        = { audio = "press", duration = .16, visual = "press" },
  release      = { duration = .12, visual = "release" },
  select       = { audio = "select_card", duration = .22, visual = "select" },
  deselect     = { audio = "deselect_card", duration = .18, visual = "deselect" },
  cancel       = { audio = "cancel", duration = .22, visual = "cancel" },
  denied       = { audio = "denied", duration = .28, visual = "denied", shake = .22,
                   flash = .06, reduced = "border" },
  transition   = { audio = "transition", duration = .28, visual = "transition",
                   reduced = "opacity" },
  acquire      = { audio = "acquire", duration = .34, visual = "acquire" },
  remove       = { audio = "remove", duration = .30, visual = "remove" },
  purchase     = { audio = "purchase", duration = .34, visual = "purchase" },
  reroll       = { audio = "reroll", duration = .32, visual = "reroll" },
  cash_gain    = { audio = "cash_gain", duration = .30, visual = "cash_gain" },
  cash_spend   = { audio = "cash_spend", duration = .28, visual = "cash_spend" },
  deal         = { audio = "deal", duration = .24, visual = "deal" },
  return_card  = { audio = "return_card", duration = .24, visual = "return_card" },
  reorder      = { audio = "reorder", duration = .20, visual = "reorder" },
  pack_open    = { audio = "pack_open", duration = .55, visual = "pack_open" },
  pack_ready   = { audio = "pack_ready", duration = .30, visual = "pack_ready" },
  pack_reveal  = { audio = "reveal", duration = .30, visual = "pack_reveal" },
  pack_pick    = { audio = "acquire", duration = .34, visual = "pack_pick" },
  negotiation_open   = { audio = "transition", duration = .30, visual = "negotiation_open" },
  negotiation_choice = { audio = "select_card", duration = .22, visual = "negotiation_choice" },
  negotiation_result = { audio = "purchase", duration = .34, visual = "negotiation_result" },
  score_users   = { audio = "score_users", duration = .24, visual = "score_users" },
  score_mult    = { audio = "score_mult", duration = .26, visual = "score_mult" },
  score_xmult   = { audio = "score_xmult", duration = .30, visual = "score_xmult" },
  score_system  = { audio = "score_system", duration = .26, visual = "score_system" },
  score_penalty = { audio = "score_penalty", duration = .30, visual = "score_penalty" },
  score_final   = { audio = "score_final", duration = .60, visual = "score_final" },
  win           = { audio = "win", duration = .70, visual = "win" },
  lose          = { audio = "lose", duration = .70, visual = "lose" },
}

-- Success mappings are intentionally semantic. Press/release feedback is emitted from classified
-- controller intents, while these values describe the committed outcome of the action.
local EXACT_ACTIONS = {
  activate_founder = "select", collection_back = "cancel", collection_next = "select",
  collection_open = "transition", collection_prev = "select", fire = "remove",
  founder_negotiation_continue = "negotiation_choice",
  founder_negotiation_standard_terms = "negotiation_result",
  founder_negotiation_walk_away = "cancel", guidance_ack = "select",
  market_pivot = "transition", modal_backdrop = "cancel", options = "transition",
  pack_fast_forward = "press", pack_skip = "cancel", pack_target_next = "select",
  pack_target_prev = "select", pivot = "transition", play_blind = "transition",
  raise = "cash_gain", restart = "transition", run_info = "transition",
  sell_consumable = "remove", ship = "transition", shop_buy_consumable = "purchase",
  shop_continue = "transition", shop_redeem = "purchase", shop_reroll = "reroll",
  shop_tech_drawer = "transition", skip_blind = "transition", sort_layer = "reorder",
  sort_users = "reorder", start_run_at = "transition", use_consumable = "transition",
  wiki_clear = "cancel", wiki_close = "cancel", wiki_next = "select", wiki_open = "transition",
  wiki_prev = "select", wiki_scroll_down = "select", wiki_scroll_up = "select",
  wiki_search = "select", opt_back = "cancel", opt_chatter = "select", opt_crt = "select",
  opt_flash = "select", opt_guidance = "select", opt_motion = "select",
  opt_page_game = "select", opt_page_sound = "select", opt_page_visual = "select",
  opt_particles = "select", opt_quit = "transition", opt_shake = "select",
  opt_sound = "select", opt_wiki = "transition",
}

local PREFIX_ACTIONS = {
  { "shop_open_pack_", "transition" }, { "shop_buy_", "purchase" },
  { "pack_adopt_", "pack_pick" }, { "pack_migrate_", "pack_pick" },
  { "pack_pick_", "pack_pick" }, { "founder_negotiation_answer_", "negotiation_choice" },
  { "market_pick_", "select" }, { "pick_layer_", "select" }, { "tech_pick_", "acquire" },
  { "stake_", "select" }, { "collection_category_", "select" },
  { "collection_filter_", "select" }, { "wiki_backlink_", "select" },
  { "wiki_category_", "select" }, { "wiki_facet_", "select" },
  { "wiki_item_", "select" }, { "wiki_letter_", "select" }, { "wiki_related_", "select" },
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function finite(value, fallback)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
    and value or fallback
end

local function now(context)
  if context and finite(context.now) then return context.now end
  local game = rawget(_G, "G")
  return game and game.TIMERS and finite(game.TIMERS.REAL) or Feedback._clock
end

local function target_key(name, context)
  context = context or {}
  return table.concat({ name, tostring(context.source_id or ""), tostring(context.target_id or "") }, ":")
end

function Feedback.recipe(name)
  local recipe = RECIPES[name]
  return recipe and copy(recipe) or nil
end

function Feedback.event_names()
  local names = {}
  for name in pairs(RECIPES) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function Feedback.mapping(action, metadata)
  if type(metadata) == "table" and metadata.feedback ~= nil then
    local configured = metadata.feedback
    if configured == false or configured == "silent" then return { success = "silent", explicit = true } end
    if type(configured) == "string" and RECIPES[configured] then
      return { success = configured, explicit = true }
    end
    if type(configured) == "table" then
      local success = configured.success or configured.event
      if success and RECIPES[success] then
        return { success = success, denied = configured.denied or "denied", explicit = true }
      end
    end
    return nil, "invalid feedback metadata for " .. tostring(action)
  end
  if type(action) ~= "string" or action == "" then return nil, "feedback action must be a non-empty string" end
  local exact = EXACT_ACTIONS[action]
  if exact then return { success = exact, denied = "denied", explicit = true } end
  for _, rule in ipairs(PREFIX_ACTIONS) do
    if action:sub(1, #rule[1]) == rule[1] then
      return { success = rule[2], denied = "denied", explicit = true }
    end
  end
  return nil, "unmapped feedback action: " .. action
end

function Feedback.validate_actions(actions)
  local missing = {}
  for _, action in ipairs(actions or {}) do
    local mapping = Feedback.mapping(action)
    if not mapping then missing[#missing + 1] = action end
  end
  table.sort(missing)
  return #missing == 0, missing
end

function Feedback.bind(adapters)
  Feedback._adapters = adapters or {}
end

function Feedback.reset(scope)
  Feedback._clock, Feedback._next_id = 0, 0
  Feedback._scope = tostring(scope or "boot")
  Feedback._active, Feedback._last = {}, {}
end

function Feedback.scope()
  return Feedback._scope
end

function Feedback.set_scope(scope)
  scope = tostring(scope or "none")
  if scope == Feedback._scope then return false end
  Feedback._scope = scope
  for i = #Feedback._active, 1, -1 do
    if Feedback._active[i].scope ~= scope then table.remove(Feedback._active, i) end
  end
  return true
end

local function dispatch(recipe, event)
  local adapters = Feedback._adapters or {}
  if recipe.audio and adapters.audio then adapters.audio(recipe.audio, event) end
  if recipe.shake and event.motion ~= false and adapters.shake then adapters.shake(recipe.shake, event) end
  if recipe.flash and adapters.flash then adapters.flash(recipe.flash, event) end
  if adapters.event then adapters.event(event, recipe) end
end

function Feedback.emit(name, context)
  local recipe = RECIPES[name]
  if not recipe then return nil, "unknown feedback event: " .. tostring(name) end
  if recipe.silent then return nil end
  context = context or {}
  local at = now(context)
  local key = target_key(name, context)
  if recipe.throttle and Feedback._last[key] and at - Feedback._last[key] < recipe.throttle then return nil end
  Feedback._last[key] = at
  Feedback._next_id = Feedback._next_id + 1
  local game = rawget(_G, "G")
  local reduced = context.reduced_motion
  if reduced == nil and game and game.SETTINGS then reduced = game.SETTINGS.reduced_motion == true end
  local event = {
    id = Feedback._next_id, name = name, born = at,
    duration = math.max(0, finite(context.duration, recipe.duration or 0)),
    scope = tostring(context.scope or Feedback._scope),
    source_id = context.source_id, target_id = context.target_id,
    action = context.action, reason = context.reason,
    intensity = math.max(0, finite(context.intensity, 1)),
    motion = reduced ~= true, substitute = reduced and recipe.reduced or nil,
    position = context.position and copy(context.position) or nil,
  }
  Feedback._active[#Feedback._active + 1] = event
  dispatch(recipe, event)
  return copy(event)
end

function Feedback.result(action, ok, reason, context)
  local mapping, err = Feedback.mapping(action, context and context.metadata)
  if not mapping then return nil, err end
  context = copy(context or {})
  context.action, context.reason = action, reason
  if ok == false then return Feedback.emit(mapping.denied or "denied", context) end
  return Feedback.emit(mapping.success or "silent", context)
end

function Feedback.update(dt)
  Feedback._clock = Feedback._clock + math.max(0, finite(dt, 0))
  local at = now()
  for i = #Feedback._active, 1, -1 do
    local event = Feedback._active[i]
    if event.scope ~= Feedback._scope or at - event.born >= event.duration then
      table.remove(Feedback._active, i)
    end
  end
end

function Feedback.snapshot()
  local out = { scope = Feedback._scope, active = {} }
  for i, event in ipairs(Feedback._active) do out.active[i] = copy(event) end
  return out
end

function Feedback.level(name, target_id)
  local at, best = now(), 0
  for _, event in ipairs(Feedback._active) do
    if event.name == name and (target_id == nil or event.target_id == target_id) and event.duration > 0 then
      best = math.max(best, math.max(0, 1 - (at - event.born) / event.duration))
    end
  end
  return best
end

return Feedback
