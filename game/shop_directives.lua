-- Serializable Founder-authored additions to a current or future Shop.
--
-- Directives contain only plain data.  The Shop owns materialization because it
-- already owns offer eligibility, pricing and RNG; this module owns validation,
-- FIFO ordering, retry semantics and bounded history.

local Directives = {}

local KINDS = { founder=true, pack=true }
local TIMINGS = { next_shop=true, current_or_next=true }
local DURATIONS = { once=true, run=true }
local RARITIES = { Common=true, Uncommon=true, Rare=true }

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function integer(value, lo, hi)
  return type(value) == "number" and value == value and value % 1 == 0
    and value >= lo and value <= hi
end

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  return out
end

function Directives.validate(spec)
  if type(spec) ~= "table" then return false, "Shop directive must be a table" end
  if not KINDS[spec.kind] then return false, "Unknown Shop directive kind" end
  if not TIMINGS[spec.timing or "next_shop"] then return false, "Unknown Shop directive timing" end
  if not DURATIONS[spec.duration or "once"] then return false, "Unknown Shop directive duration" end
  if not integer(spec.count or 1, 1, 3) then return false, "Shop directive count must be 1 to 3" end
  if spec.rarity ~= nil and not RARITIES[spec.rarity] then return false, "Unknown Founder rarity" end
  if spec.free ~= nil and type(spec.free) ~= "boolean" then return false, "Shop directive free must be boolean" end
  if spec.pinned ~= nil and type(spec.pinned) ~= "boolean" then return false, "Shop directive pinned must be boolean" end
  if spec.discount ~= nil and (not finite(spec.discount) or spec.discount < 0 or spec.discount > 1) then
    return false, "Shop directive discount must be between 0 and 1"
  end
  if spec.free and spec.discount ~= nil then return false, "Free directives cannot also carry a discount" end
  if spec.kind == "pack" then
    if type(spec.pack_key) ~= "string" or spec.pack_key == "" then return false, "Pack directive needs pack_key" end
    if spec.options ~= nil and not integer(spec.options, 2, 6) then return false, "Pack options must be 2 to 6" end
    if spec.rarity ~= nil or spec.discount ~= nil then return false, "Pack directive carries Founder-only fields" end
  elseif spec.pack_key ~= nil or spec.options ~= nil then
    return false, "Founder directive cannot carry pack fields"
  end
  if spec.source_key ~= nil and type(spec.source_key) ~= "string" then return false, "Directive source_key must be text" end
  if spec.source_id ~= nil and type(spec.source_id) ~= "string" and not finite(spec.source_id) then
    return false, "Directive source_id must be text or a number"
  end
  if spec.label ~= nil and type(spec.label) ~= "string" then return false, "Directive label must be text" end
  for _, field in ipairs({ "id", "created_shop_id", "last_shop_id" }) do
    if spec[field] ~= nil and not integer(spec[field], 1, 1000000000) then
      return false, "Directive " .. field .. " must be a positive integer"
    end
  end
  local allowed = {
    kind=true, timing=true, duration=true, count=true, rarity=true, free=true,
    pinned=true, discount=true, pack_key=true, options=true, source_key=true,
    source_id=true, label=true, id=true, created_shop_id=true, last_shop_id=true,
  }
  for key in pairs(spec) do if not allowed[key] then return false, "Unknown Shop directive field " .. tostring(key) end end
  return true
end

local function state(game)
  if type(game.shop_directives) ~= "table" then
    game.shop_directives = { next_id=1, queue={}, history={} }
  end
  local st = game.shop_directives
  st.next_id = integer(st.next_id, 1, 1000000000) and st.next_id or 1
  st.queue = type(st.queue) == "table" and st.queue or {}
  st.history = type(st.history) == "table" and st.history or {}
  return st
end

function Directives.normalize(game)
  if type(game) ~= "table" then return false end
  local st = state(game)
  local queue, maximum, seen = {}, st.next_id - 1, {}
  for _, row in ipairs(st.queue) do
    local ok = Directives.validate(row)
    if ok and integer(row.id, 1, 1000000000) and not seen[row.id] then
      queue[#queue + 1] = copy(row)
      maximum = math.max(maximum, row.id)
      seen[row.id] = true
    end
  end
  table.sort(queue, function(a, b) return a.id < b.id end)
  st.queue, st.next_id = queue, math.max(st.next_id, maximum + 1)
  local history = {}
  for _, row in ipairs(st.history) do
    if type(row) == "table" and integer(row.id, 1, 1000000000)
        and integer(row.shop_id, 1, 1000000000) then history[#history + 1] = copy(row) end
  end
  while #history > 64 do table.remove(history, 1) end
  st.history = history
  return true
end

function Directives.enqueue(game, spec)
  if type(game) ~= "table" then return nil, "Run is unavailable" end
  spec = copy(spec)
  spec.timing, spec.duration, spec.count = spec.timing or "next_shop", spec.duration or "once", spec.count or 1
  if spec.pinned == nil then spec.pinned = true end
  local ok, reason = Directives.validate(spec); if not ok then return nil, reason end
  local st = state(game)
  spec.id, spec.created_shop_id = st.next_id, game.shop and game.shop.shop_id or nil
  st.next_id = st.next_id + 1
  st.queue[#st.queue + 1] = spec
  return copy(spec)
end

local function eligible(row, shop_id, phase)
  if row.duration == "run" and row.last_shop_id == shop_id then return false end
  if phase == "current" then return row.timing == "current_or_next" end
  return phase == "enter"
end

-- `materialize(row)` must be atomic: true means all requested offers were
-- installed; false leaves one-shot work queued for the next eligible Shop.
function Directives.apply(game, shop, phase, materialize)
  if type(game) ~= "table" or type(shop) ~= "table" or type(materialize) ~= "function" then return {} end
  local st, applied = state(game), {}
  local shop_id = shop.shop_id
  if not integer(shop_id, 1, 1000000000) then return applied end
  local index = 1
  while index <= #st.queue do
    local row = st.queue[index]
    if eligible(row, shop_id, phase) then
      local ok, detail = materialize(copy(row))
      if ok then
        applied[#applied + 1] = { id=row.id, detail=copy(detail) }
        st.history[#st.history + 1] = { id=row.id, shop_id=shop_id, kind=row.kind, source_key=row.source_key }
        while #st.history > 64 do table.remove(st.history, 1) end
        if row.duration == "once" then table.remove(st.queue, index)
        else row.last_shop_id = shop_id; index = index + 1 end
      else
        index = index + 1
      end
    else
      index = index + 1
    end
  end
  return applied
end

function Directives.pending(game)
  if type(game) ~= "table" then return {} end
  local out = {}
  for _, row in ipairs(state(game).queue) do out[#out + 1] = copy(row) end
  return out
end

return Directives
