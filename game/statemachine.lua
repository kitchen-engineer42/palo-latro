-- game/statemachine.lua — the two-level STAGE×STATE machine. STAGE=RUN is fixed for the slice;
-- the MENU/SHOP/antes seam is prep_stage (mass-teardown of the old stage's objects, leak-free).
-- Per-STATE update handlers are registered by handlers.lua into StateMachine.handlers.

local StateMachine = {}
local Feedback = require("game.feedback")
StateMachine.handlers = {}        -- [G.STATES.*] = function(dt)

local function release_ui_box(box, seen)
  if type(box) ~= "table" or seen[box] then return end
  seen[box] = true
  if box.REMOVED then return end
  -- Declarative UIBoxes are not Nodes, but their retained elements may be
  -- controller targets. Release those handles before dropping the tree.
  if G.CONTROLLER and type(G.CONTROLLER.release_node) == "function"
      and type(box.elements) == "table" then
    for _, element in ipairs(box.elements) do G.CONTROLLER:release_node(element) end
  end
  if type(box.remove) == "function" then box:remove()
  elseif type(box.release) == "function" then box:release()
  elseif type(box.destroy) == "function" then box:destroy() end
end

-- Retained UI belongs to exactly one state. Dispose registered roots before the
-- controller reset so Node/UIBox removal can release target handles normally.
local function clear_retained_ui()
  local seen = {}
  release_ui_box(G.UI_ROOT, seen)
  if type(G.UI_BOXES) == "table" then
    for _, box in pairs(G.UI_BOXES) do release_ui_box(box, seen) end
    for key in pairs(G.UI_BOXES) do G.UI_BOXES[key] = nil end
  else
    G.UI_BOXES = {}
  end
  G.UI_ROOT = nil
  if type(G.UI_OWNER) ~= "table" then G.UI_OWNER = {} end
  G.UI_OWNER.stage, G.UI_OWNER.state = nil, nil
end

local function reset_controller()
  local controller = G.CONTROLLER
  if not controller then return end
  if type(controller.reset) == "function" then
    -- Clear every target immediately so no previous-state button can receive a
    -- click before the adapter reconciles the new state's retained tree.
    controller:reset()
    return
  end

  -- Nil-safe compatibility until engine.controller has initialized. Clear the
  -- legacy reference shape without assuming any controller methods exist.
  for _, key in ipairs({ "hovering", "focused", "clicked", "dragging", "_press" }) do
    controller[key] = nil
  end
  if type(controller.targets) == "table" then
    for _, target in ipairs(controller.targets) do
      if type(target) == "table" then target.released = true end
    end
    controller.targets = {}
  end
  controller.intents = {}
  controller.modal_scope, controller.gameplay_locked = nil, false
end

function StateMachine.teardown_interaction()
  clear_retained_ui()
  reset_controller()
end

-- enter a new stage: tear down the previous stage's pooled objects + clear the event queues.
function StateMachine.prep_stage(stage, state)
  if G.SHOW_WIKI then require("game.wiki").close() end
  if G.STAGE and G.STAGE_OBJECTS[G.STAGE] then
    remove_all(G.STAGE_OBJECTS[G.STAGE])
  end
  StateMachine.teardown_interaction()
  if G.E_MANAGER then G.E_MANAGER:clear() end
  G.STAGE = stage
  G.STAGE_OBJECTS[stage] = G.STAGE_OBJECTS[stage] or {}
  G.STATE = state
  G.UI_OWNER.stage, G.UI_OWNER.state = stage, state
  G.STATE_COMPLETE = false
  G.SHOW_RUN_INFO, G.SHOW_OPTIONS, G.SHOW_DECK_VIEW, G.SHOW_WIKI = nil, nil, nil, nil
  G.OPTIONS_PAGE = nil
  G.DRAG, G.PENDING_CONSUMABLE = nil, nil
  G.GUIDANCE_TOAST = nil
  Feedback.sync_scope(G)
  -- G.ROOM stays identity for the slice (container transform is a later refinement).
end

function StateMachine.set_state(state)
  if state ~= G.STATE then StateMachine.teardown_interaction() end
  if state ~= G.STATES.TARGET_SELECT then G.PENDING_CONSUMABLE = nil end
  if state ~= G.STATES.SELECTING_HAND and state ~= G.STATES.SHOP then G.DRAG = nil end
  G.STATE = state
  G.UI_OWNER.stage, G.UI_OWNER.state = G.STAGE, state
  G.STATE_COMPLETE = false
  Feedback.sync_scope(G)
end

function StateMachine.update(dt)
  local h = StateMachine.handlers[G.STATE]
  if h then h(dt) end
end

return StateMachine
