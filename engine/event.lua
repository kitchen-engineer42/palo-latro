-- engine/event.lua — Event + EventManager. Blocking named queues decouple logic-time from
-- presentation-time: gameplay computes a result instantly, then schedules the *experience*
-- of it as a sequence of timed events (the runtime contract). This is the game-feel backbone.

Event = Object:extend()

function Event:init(args)
  args = args or {}
  self.trigger   = args.trigger or "immediate"     -- immediate | after | ease | condition
  self.delay     = args.delay or 0
  self.func      = args.func or function() return true end
  self.blocking  = (args.blocking ~= false)         -- halts the rest of its queue until done
  self.timer     = args.timer or "TOTAL"            -- TOTAL (gameplay) or REAL (ui)
  self.ease      = args.ease                         -- {ref_table, ref_value, start_val?, end_val}
  self.start_time = nil
  self.complete  = false
end

function Event:handle(now)
  if self.complete then return true end
  if not self.start_time then self.start_time = now end
  local elapsed = now - self.start_time

  if self.trigger == "immediate" then
    self.complete = (self.func() ~= false)

  elseif self.trigger == "after" then
    if elapsed >= self.delay then self.complete = (self.func() ~= false) end

  elseif self.trigger == "ease" then
    local e = self.ease
    if e.start_val == nil then e.start_val = e.ref_table[e.ref_value] or 0 end
    local frac = self.delay > 0 and clamp(elapsed / self.delay, 0, 1) or 1
    e.ref_table[e.ref_value] = lerp(e.start_val, e.end_val, frac)
    if frac >= 1 then
      self.complete = true
      if self.func then self.func() end
    end

  elseif self.trigger == "condition" then
    if self.func() then self.complete = true end
  end
  return self.complete
end

----------------------------------------------------------------------

EventManager = Object:extend()

function EventManager:init()
  self.queues = { base = {}, other = {} }
end

function EventManager:add_event(event, queue)
  table.insert(self.queues[queue or "base"], event)
  return event
end

function EventManager:update()
  for _, q in pairs(self.queues) do
    local i = 1
    while q[i] do
      local e = q[i]
      local now = G.TIMERS[e.timer] or G.TIMERS.TOTAL
      if e:handle(now) then
        table.remove(q, i)               -- completed: drop and continue
      elseif e.blocking then
        break                            -- blocking front halts this queue this frame
      else
        i = i + 1                        -- non-blocking: let later events run in parallel
      end
    end
  end
end

function EventManager:any_pending(queue)
  local q = self.queues[queue or "base"]
  return #q > 0
end

function EventManager:clear()
  self.queues = { base = {}, other = {} }
end

-- Resolve presentation queues without waiting on wall-clock frames. This is used
-- only by deterministic headless clients; the graphical update loop keeps the
-- normal timed behavior above.
function EventManager:drain(max_steps)
  max_steps = max_steps or 10000
  local saved_total, saved_real = G.TIMERS.TOTAL, G.TIMERS.REAL
  local function restore()
    G.TIMERS.TOTAL, G.TIMERS.REAL = saved_total, saved_real
  end
  for _ = 1, max_steps do
    -- Run exactly the events that a graphical frame would run. In particular,
    -- a blocking event later in a queue must not receive a start time until the
    -- earlier blocker has completed.
    self:update()
    local pending, deadlines = false, {}
    for _, q in pairs(self.queues) do
      for _, event in ipairs(q) do
        pending = true
        if event.start_time and (event.trigger == "after" or event.trigger == "ease") then
          local timer = event.timer or "TOTAL"
          local deadline = event.start_time + (event.delay or 0)
          if not deadlines[timer] or deadline < deadlines[timer] then deadlines[timer] = deadline end
        end
      end
    end
    if not pending then
      restore()
      return true
    end
    for timer, deadline in pairs(deadlines) do
      -- Step just beyond the deadline so decimal delays cannot stall on a
      -- floating-point value infinitesimally below `elapsed >= delay`.
      G.TIMERS[timer] = math.max(G.TIMERS[timer] or 0, deadline + 1e-9)
    end
  end
  restore()
  local stuck = {}
  for name, q in pairs(self.queues) do
    for _, event in ipairs(q) do
      stuck[#stuck + 1] = table.concat({ name, event.trigger or "?", event.timer or "TOTAL",
        tostring(event.delay or 0), tostring(event.start_time) }, ":")
    end
  end
  return false, "event drain exceeded its step limit (" .. table.concat(stuck, ",") .. ")"
end

-- helpers ------------------------------------------------------------

-- a blocking pause of `t` seconds in a queue (the universal "beat between steps")
function delay(t, queue)
  G.E_MANAGER:add_event(Event({ trigger = "after", delay = t, blocking = true }), queue)
end

-- tween ref_table[ref_value] -> end_val over dur seconds (start captured when it begins)
function ease_value(ref_table, ref_value, end_val, dur, opts)
  opts = opts or {}
  return G.E_MANAGER:add_event(Event({
    trigger  = "ease",
    delay    = dur,
    blocking = (opts.blocking ~= false),
    timer    = opts.timer,
    func     = opts.func,
    ease     = { ref_table = ref_table, ref_value = ref_value, end_val = end_val },
  }), opts.queue)
end

return Event
