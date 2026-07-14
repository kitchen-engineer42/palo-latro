-- engine/pools.lua — instance-pool helpers. Pools (G.I.*) enable batch update/draw/cleanup
-- and flat input dispatch instead of scene-graph traversal (the runtime contract; benchmark: load-bearing
-- for many on-screen objects). Registration happens in Node/Moveable:init; removal here.

function remove_from_pool(pool, obj)
  if not pool then return end
  for i = #pool, 1, -1 do
    if pool[i] == obj then
      table.remove(pool, i)
      return
    end
  end
end

-- mass-teardown: remove every object in a pool (used by prep_stage on stage transitions).
-- Snapshot first because :remove mutates the pools mid-iteration.
function remove_all(pool)
  if not pool then return end
  local snapshot = {}
  for _, o in ipairs(pool) do snapshot[#snapshot + 1] = o end
  for _, o in ipairs(snapshot) do
    if o.remove and not o.REMOVED then o:remove() end
  end
end
