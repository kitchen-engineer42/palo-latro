-- game/statemachine.lua — the two-level STAGE×STATE machine. STAGE=RUN is fixed for the slice;
-- the MENU/SHOP/antes seam is prep_stage (mass-teardown of the old stage's objects, leak-free).
-- Per-STATE update handlers are registered by handlers.lua into StateMachine.handlers.

local StateMachine = {}
StateMachine.handlers = {}        -- [G.STATES.*] = function(dt)

-- enter a new stage: tear down the previous stage's pooled objects + clear the event queues.
function StateMachine.prep_stage(stage, state)
  if G.STAGE and G.STAGE_OBJECTS[G.STAGE] then
    remove_all(G.STAGE_OBJECTS[G.STAGE])
  end
  if G.E_MANAGER then G.E_MANAGER:clear() end
  G.STAGE = stage
  G.STAGE_OBJECTS[stage] = G.STAGE_OBJECTS[stage] or {}
  G.STATE = state
  G.STATE_COMPLETE = false
  G.SHOW_RUN_INFO, G.SHOW_OPTIONS, G.SHOW_DECK_VIEW = nil, nil, nil
  G.DRAG, G.PENDING_CONSUMABLE = nil, nil
  -- G.ROOM stays identity for the slice (container transform is a later refinement).
end

function StateMachine.set_state(state)
  if state ~= G.STATES.TARGET_SELECT then G.PENDING_CONSUMABLE = nil end
  if state ~= G.STATES.SELECTING_HAND and state ~= G.STATES.SHOP then G.DRAG = nil end
  G.STATE = state
  G.STATE_COMPLETE = false
end

function StateMachine.update(dt)
  local h = StateMachine.handlers[G.STATE]
  if h then h(dt) end
end

return StateMachine
