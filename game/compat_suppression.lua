-- Run-persistent, deterministic suppression of authored Tech clash edges.
--
-- The generated compatibility graph remains immutable. A run records only the
-- clash edges it has learned to bridge; complements and substitutes never read
-- this state. Plans are plain data and fail closed when the suppression revision
-- changes, so retries cannot partially publish graph rewrites.

local Graph = require("data.centers.compat_gen")
local Coverage = require("game.coverage")

local Suppression = {}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
  return finite(value) and value == math.floor(value)
    and value >= (minimum or 0) and (maximum == nil or value <= maximum)
end

local function valid_source_id(value)
  if type(value) == "string" then return value ~= "" and value or nil end
  return integer(value, 1, 1000000000) and value or nil
end

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  return out
end

local function tech_key(subject)
  local key
  if type(subject) == "string" then key = subject
  elseif type(subject) == "table" then
    key = subject.center_key or subject.key or (subject.center and subject.center.key)
  end
  if type(key) ~= "string" or key == "" then return nil end
  return (key:gsub("^t_", ""))
end

local function well_formed(subject)
  return type(subject) == "table" and type(subject.law_marks) == "table"
    and subject.law_marks.well_formed == true
end

function Suppression.edge_key(left, right)
  left, right = tech_key(left), tech_key(right)
  if not left or not right or left == right then return nil end
  if left > right then left, right = right, left end
  return left .. "|" .. right
end

local function split_edge(edge)
  if type(edge) ~= "string" then return nil end
  local left, right = edge:match("^([^|]+)|([^|]+)$")
  if not left or not right or left == right then return nil end
  local canonical = Suppression.edge_key(left, right)
  if canonical ~= edge or not Graph.clashes[edge] then return nil end
  return left, right
end

local function fresh_state()
  return { revision=0, edges={}, sources={}, journal={} }
end

local function state(game)
  if type(game.compat_suppressions) ~= "table" then game.compat_suppressions = fresh_state() end
  local st = game.compat_suppressions
  if not integer(st.revision, 0, 1000000000) then st.revision = 0 end
  if type(st.edges) ~= "table" then st.edges = {} end
  if type(st.sources) ~= "table" then st.sources = {} end
  if type(st.journal) ~= "table" then st.journal = {} end
  return st
end

function Suppression.normalize(game)
  if type(game) ~= "table" then return false end
  local st = state(game)
  local edges = {}
  for edge, record in pairs(st.edges) do
    local left, right = split_edge(edge)
    if left and type(record) == "table" then
      local row = {
        edge=edge, left=left, right=right,
        source_key=type(record.source_key) == "string" and record.source_key or nil,
        source_id=valid_source_id(record.source_id),
        ante=integer(record.ante, 1, 1000000) and record.ante or nil,
        round=integer(record.round, 0, 1000000000) and record.round or nil,
        revision=integer(record.revision, 1, 1000000000) and record.revision or nil,
      }
      edges[edge] = row
    end
  end
  st.edges = edges
  local sources = {}
  for _, record in pairs(st.sources) do
    local id = type(record) == "table" and valid_source_id(record.source_id) or nil
    if type(record) == "table" and type(record.source_key) == "string"
        and record.source_key ~= "" and id ~= nil then
      local token = record.source_key .. "#" .. type(id) .. ":" .. tostring(id)
      local seen_uids = {}
      for uid, value in pairs(type(record.seen_uids) == "table" and record.seen_uids or {}) do
        local number = tonumber(uid)
        if integer(number, 1, 1000000000) and value == true then seen_uids[tostring(number)] = true end
      end
      local existing = sources[token]
      if existing then
        for uid in pairs(seen_uids) do existing.seen_uids[uid] = true end
        existing.fired_run = existing.fired_run or record.fired_run == true
      else
        sources[token] = {
          source_key=record.source_key, source_id=id, seen_uids=seen_uids,
          fired_run=record.fired_run == true,
        }
      end
    end
  end
  st.sources = sources
  local journal = {}
  for _, row in ipairs(st.journal) do
    if type(row) == "table" and integer(row.revision, 1, 1000000000)
        and type(row.edges) == "table" then
      local valid, seen_edges = {}, {}
      for _, edge in ipairs(row.edges) do if split_edge(edge) then valid[#valid + 1] = edge end end
      table.sort(valid)
      local unique = {}
      for _, edge in ipairs(valid) do
        if not seen_edges[edge] then unique[#unique + 1], seen_edges[edge] = edge, true end
      end
      local seen_uids, seen = {}, {}
      for _, uid in ipairs(type(row.seen_uids) == "table" and row.seen_uids or {}) do
        if integer(uid, 1, 1000000000) and not seen[uid] then
          seen_uids[#seen_uids + 1], seen[uid] = uid, true
        end
      end
      table.sort(seen_uids)
      if #unique > 0 or #seen_uids > 0 or row.fired_run == true then
        journal[#journal + 1] = {
          revision=row.revision, edges=unique, seen_uids=seen_uids,
          fired_run=row.fired_run == true,
          source_key=type(row.source_key) == "string" and row.source_key or nil,
          source_id=valid_source_id(row.source_id),
        }
      end
    end
  end
  while #journal > 64 do table.remove(journal, 1) end
  st.journal = journal
  for key in pairs(st) do
    if key ~= "revision" and key ~= "edges" and key ~= "sources" and key ~= "journal" then st[key] = nil end
  end
  return true
end

local function source_token(source_key, source_id)
  if type(source_key) ~= "string" or source_key == ""
      or valid_source_id(source_id) == nil then return nil end
  return source_key .. "#" .. type(source_id) .. ":" .. tostring(source_id)
end

local function source_record(game, source_key, source_id, create)
  if type(game) ~= "table" then return nil end
  local token = source_token(source_key, source_id)
  if not token then return nil end
  local st = state(game)
  local record = st.sources[token]
  if not record and create then
    record = { source_key=source_key, source_id=source_id, seen_uids={}, fired_run=false }
    st.sources[token] = record
  end
  return record, token
end

function Suppression.source_seen(game, source_key, source_id, uid)
  if not integer(uid, 1, 1000000000) then return false end
  local record = source_record(game, source_key, source_id, false)
  return record ~= nil and record.seen_uids[tostring(uid)] == true
end

function Suppression.source_fired(game, source_key, source_id)
  local record = source_record(game, source_key, source_id, false)
  return record ~= nil and record.fired_run == true
end

function Suppression.source_count(game, source_key, source_id)
  if type(game) ~= "table" then return 0 end
  local count = 0
  for _, record in pairs(state(game).edges) do
    if record.source_key == source_key and record.source_id == source_id then count = count + 1 end
  end
  return count
end

function Suppression.is_suppressed(game, left, right)
  if type(game) ~= "table" then return false end
  local edge = right == nil and left or Suppression.edge_key(left, right)
  return edge ~= nil and state(game).edges[edge] ~= nil
end

local function sorted_unique(values)
  local out, seen = {}, {}
  for _, value in ipairs(values or {}) do
    if split_edge(value) and not seen[value] then out[#out + 1], seen[value] = value, true end
  end
  table.sort(out)
  return out
end

function Suppression.deck_candidates(game)
  if type(game) ~= "table" then return {} end
  local deck = type(game.master_deck) == "table" and game.master_deck or {}
  local out, seen = {}, {}
  for i = 1, #deck do
    for j = i + 1, #deck do
      local edge = Suppression.edge_key(deck[i], deck[j])
      if not well_formed(deck[i]) and not well_formed(deck[j]) and edge
          and Graph.clashes[edge] and not Suppression.is_suppressed(game, edge) and not seen[edge] then
        out[#out + 1], seen[edge] = edge, true
      end
    end
  end
  table.sort(out)
  return out
end

local function different_layer(left, right, analysis)
  local left_layers, right_layers = Coverage.layers_for(left, analysis), Coverage.layers_for(right, analysis)
  if #left_layers == 0 or #right_layers == 0 then return false end
  for _, a in ipairs(left_layers) do
    for _, b in ipairs(right_layers) do if a == b then return false end end
  end
  return true
end

-- Candidate clash edges in current scoring order. `trigger_uid` restricts the
-- edge to the trigger card and cards placed before it; `cross_layer` is Patrick
-- Esser's stricter bridge condition.
function Suppression.played_candidates(game, played, opts)
  if type(game) ~= "table" then return {} end
  played, opts = played or {}, opts or {}
  local analysis = Coverage.analyze(played)
  local out, seen = {}, {}
  local trigger_index
  if opts.trigger_uid then
    for index, card in ipairs(played) do if card.uid == opts.trigger_uid then trigger_index = index; break end end
    if not trigger_index then return out end
  end
  for i = 1, #played do
    for j = i + 1, #played do
      local eligible = not trigger_index or j == trigger_index
      if eligible and not well_formed(played[i]) and not well_formed(played[j])
          and (not opts.cross_layer or different_layer(played[i], played[j], analysis)) then
        local edge = Suppression.edge_key(played[i], played[j])
        if edge and Graph.clashes[edge] and not Suppression.is_suppressed(game, edge) and not seen[edge] then
          out[#out + 1], seen[edge] = edge, true
        end
      end
    end
  end
  table.sort(out)
  return out
end

local function dense_array(value)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count, highest = count + 1, math.max(highest, key)
  end
  return count == highest
end

local function state_fingerprint(st)
  local edges = {}
  for edge, record in pairs(st.edges or {}) do
    if type(edge) == "string" and type(record) == "table" then
      edges[#edges + 1] = table.concat({ edge, tostring(record.source_key or ""),
        type(record.source_id) .. ":" .. tostring(record.source_id or ""),
        tostring(record.revision or "") }, "\29")
    else
      edges[#edges + 1] = "invalid:" .. type(edge) .. ":" .. tostring(edge)
    end
  end
  table.sort(edges)
  local sources = {}
  for token, record in pairs(st.sources or {}) do
    if type(token) == "string" and type(record) == "table" then
      local seen = {}
      for uid, value in pairs(record.seen_uids or {}) do
        if value == true then seen[#seen + 1] = tostring(uid) end
      end
      table.sort(seen)
      sources[#sources + 1] = table.concat({ token, tostring(record.source_key or ""),
        type(record.source_id) .. ":" .. tostring(record.source_id or ""),
        tostring(record.fired_run == true), table.concat(seen, ",") }, "\29")
    else
      sources[#sources + 1] = "invalid:" .. type(token) .. ":" .. tostring(token)
    end
  end
  table.sort(sources)
  return table.concat(edges, "\28") .. "\27" .. table.concat(sources, "\28")
end

local function plan_payload(plan)
  local seen = {}
  for index, uid in ipairs(plan.seen_uids or {}) do seen[index] = tostring(uid) end
  return table.concat({ tostring(plan.base_revision), table.concat(plan.edges, ","),
    table.concat(seen, ","), tostring(plan.fire_run == true),
    tostring(plan.source_key or ""), tostring(plan.source_id or ""),
    tostring(plan.source_token or ""), tostring(plan.deck_revision),
    tostring(plan.base_fingerprint or "") }, "\30")
end

function Suppression.plan(game, request)
  if type(game) ~= "table" or type(request) ~= "table" then return nil, "Compatibility run is unavailable" end
  if not dense_array(request.candidate_edges) then return nil, "Compatibility candidates must be a dense array" end
  local token = source_token(request.source_key, request.source_id)
  if not token then return nil, "Compatibility source identity is required" end
  if request.fire_run ~= nil and type(request.fire_run) ~= "boolean" then
    return nil, "Compatibility fired state must be boolean"
  end
  local amount = request.amount == nil and 1 or request.amount
  if not integer(amount, 1, 24) then return nil, "Compatibility suppression amount must be 1 to 24" end
  local st, candidates = state(game), sorted_unique(request.candidate_edges)
  local source = source_record(game, request.source_key, request.source_id, false)
  if request.fire_run == true and source and source.fired_run then return nil, "Compatibility source already fired" end
  if request.cap ~= nil then
    if not integer(request.cap, 1, 24) then return nil, "Compatibility source cap must be 1 to 24" end
    if Suppression.source_count(game, request.source_key, request.source_id) >= request.cap then
      return nil, "Compatibility source cap reached"
    end
    amount = math.min(amount, request.cap - Suppression.source_count(game, request.source_key, request.source_id))
  end
  local seen_uids = {}
  if request.seen_uids ~= nil then
    if not dense_array(request.seen_uids) then return nil, "Compatibility seen UIDs must be a dense array" end
    local seen = {}
    for _, uid in ipairs(request.seen_uids) do
      if not integer(uid, 1, 1000000000) then return nil, "Compatibility seen UID must be positive" end
      local key = tostring(uid)
      if not seen[key] and not (source and source.seen_uids[key]) then
        seen_uids[#seen_uids + 1], seen[key] = uid, true
      end
    end
    table.sort(seen_uids)
  end
  local edges = {}
  for _, edge in ipairs(candidates) do
    if not st.edges[edge] then edges[#edges + 1] = edge end
    if #edges >= amount then break end
  end
  if #edges == 0 and #seen_uids == 0 then return nil, "No outstanding compatibility clash" end
  local plan = {
    kind="compat_suppression_plan", base_revision=st.revision, edges=edges,
    seen_uids=seen_uids, fire_run=request.fire_run == true,
    source_key=request.source_key, source_id=valid_source_id(request.source_id),
    source_token=token, base_fingerprint=state_fingerprint(st),
    deck_revision=integer(game._deck_revision, 0, 1000000000) and game._deck_revision or 0,
  }
  plan.integrity = plan_payload(plan)
  return plan
end

function Suppression.revalidate(game, plan)
  if type(game) ~= "table" or type(plan) ~= "table" or plan.kind ~= "compat_suppression_plan"
      or not dense_array(plan.edges) or not dense_array(plan.seen_uids)
      or not source_token(plan.source_key, plan.source_id)
      or not integer(plan.deck_revision, 0, 1000000000)
      or type(plan.base_fingerprint) ~= "string"
      or type(plan.fire_run) ~= "boolean" then
    return false, "Invalid compatibility suppression plan"
  end
  for _, edge in ipairs(plan.edges) do
    if type(edge) ~= "string" then return false, "Invalid compatibility suppression plan" end
  end
  for _, uid in ipairs(plan.seen_uids) do
    if not integer(uid, 1, 1000000000) then return false, "Invalid compatibility suppression plan" end
  end
  if plan.integrity ~= plan_payload(plan) then return false, "Invalid compatibility suppression plan" end
  local st = state(game)
  if st.revision ~= plan.base_revision then return false, "Compatibility suppression is stale" end
  if state_fingerprint(st) ~= plan.base_fingerprint then return false, "Compatibility suppression state is stale" end
  local deck_revision = integer(game._deck_revision, 0, 1000000000) and game._deck_revision or 0
  if deck_revision ~= plan.deck_revision then return false, "Compatibility deck is stale" end
  local seen = {}
  for _, edge in ipairs(plan.edges) do
    if not split_edge(edge) or seen[edge] or st.edges[edge] then
      return false, "Compatibility suppression edge is unavailable"
    end
    seen[edge] = true
  end
  local source, token = source_record(game, plan.source_key, plan.source_id, false)
  if token ~= plan.source_token then return false, "Compatibility source identity changed" end
  if plan.fire_run == true and source and source.fired_run then return false, "Compatibility source already fired" end
  for _, uid in ipairs(plan.seen_uids or {}) do
    if not integer(uid, 1, 1000000000) or (source and source.seen_uids[tostring(uid)]) then
      return false, "Compatibility source progression changed"
    end
  end
  return true
end

local function failed(reason)
  return { ok=false, reason=reason or "Compatibility suppression failed", applied=0, edges={} }
end

function Suppression.commit(game, plan)
  local valid, reason = Suppression.revalidate(game, plan)
  if not valid then return failed(reason) end
  local st = state(game)
  local revision = st.revision + 1
  local source = source_record(game, plan.source_key, plan.source_id, true)
  for _, uid in ipairs(plan.seen_uids or {}) do source.seen_uids[tostring(uid)] = true end
  if plan.fire_run == true then source.fired_run = true end
  for _, edge in ipairs(plan.edges) do
    local left, right = split_edge(edge)
    st.edges[edge] = {
      edge=edge, left=left, right=right, source_key=plan.source_key, source_id=plan.source_id,
      ante=game.ante, round=game.round_num, revision=revision,
    }
  end
  st.revision = revision
  st.journal[#st.journal + 1] = {
    revision=revision, edges=copy(plan.edges), seen_uids=copy(plan.seen_uids or {}),
    fired_run=plan.fire_run == true, source_key=plan.source_key, source_id=plan.source_id,
  }
  while #st.journal > 64 do table.remove(st.journal, 1) end
  return { ok=true, applied=#plan.edges, edges=copy(plan.edges),
    seen_uids=copy(plan.seen_uids or {}), fired_run=plan.fire_run, revision=revision }
end

function Suppression.execute(game, request)
  local plan, reason = Suppression.plan(game, request)
  if not plan then return failed(reason) end
  return Suppression.commit(game, plan)
end

function Suppression.view(game)
  if type(game) ~= "table" then return { revision=0, count=0, edges={} } end
  local st, edges = state(game), {}
  for edge, record in pairs(st.edges) do
    edges[#edges + 1] = {
      edge=edge, left=record.left, right=record.right,
      source_key=record.source_key, ante=record.ante, round=record.round,
    }
  end
  table.sort(edges, function(a, b) return a.edge < b.edge end)
  local sources = {}
  for token, record in pairs(st.sources) do
    local seen_count = 0; for _ in pairs(record.seen_uids or {}) do seen_count = seen_count + 1 end
    sources[#sources + 1] = { id=token, source_key=record.source_key,
      seen_tech_count=seen_count, fired_run=record.fired_run == true }
  end
  table.sort(sources, function(a, b) return a.id < b.id end)
  return { revision=st.revision, count=#edges, edges=edges, sources=sources }
end

return Suppression
