local ScoreTrace = {}

function ScoreTrace.new()
  return { stages = {}, order = {} }
end

function ScoreTrace.capture(trace, name, values)
  assert(trace and name, "score trace and stage name required")
  if not trace.stages[name] then trace.order[#trace.order + 1] = name end
  local snap = {}
  for k, v in pairs(values or {}) do snap[k] = v end
  trace.stages[name] = snap
  return snap
end

function ScoreTrace.get(trace, name, field)
  local stage = trace and trace.stages and trace.stages[name]
  return stage and (field and stage[field] or stage)
end

function ScoreTrace.finalize(trace, values)
  return ScoreTrace.capture(trace, "final", values)
end

return ScoreTrace
