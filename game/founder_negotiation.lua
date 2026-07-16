-- Deterministic, save-safe Legendary Founder negotiation state.
--
-- Gameplay RNG is consumed only by begin(): three question IDs and three
-- choice permutations are materialized into the run. Answers merely reveal
-- authored results that were already fixed by those IDs.

local RNG = require("game.rng")

local FounderNegotiation = {}

local PERMUTATIONS = {
  { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 },
  { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 },
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function whole(value, lo, hi)
  return type(value) == "number" and value == value and value ~= math.huge
    and value ~= -math.huge and value % 1 == 0
    and (lo == nil or value >= lo) and (hi == nil or value <= hi)
end

local function build_catalog()
  local by_key = {}
  for _, script in ipairs(require("data.gameplay.legendary_negotiations")) do
    if type(script) == "table" and type(script.key) == "string" then by_key[script.key] = script end
  end
  return by_key
end

local function catalog()
  FounderNegotiation._catalog = FounderNegotiation._catalog or build_catalog()
  return FounderNegotiation._catalog
end

local function question_map(script)
  local out = {}
  for _, question in ipairs((script and script.questions) or {}) do out[question.id] = question end
  return out
end

local function base_key(center)
  return center and (center.base_form or center.key) or nil
end

function FounderNegotiation.script_for(center_or_key)
  local key = type(center_or_key) == "table" and base_key(center_or_key) or center_or_key
  return catalog()[key], key
end

local function normalize_seen(game)
  local source = type(game.founder_negotiation_seen) == "table" and game.founder_negotiation_seen or {}
  local normalized = {}
  for key, script in pairs(catalog()) do
    local valid, row = question_map(script), {}
    local used = {}
    for _, id in ipairs(type(source[key]) == "table" and source[key] or {}) do
      if type(id) == "string" and valid[id] and not used[id] then
        row[#row + 1], used[id] = id, true
      end
    end
    if #row > 0 then normalized[key] = row end
  end
  game.founder_negotiation_seen = normalized
  return normalized
end

local function choice_for(question, choice_id)
  for _, choice in ipairs((question and question.choices) or {}) do
    if choice.id == choice_id then return choice end
  end
end

local function remaining_options(options)
  if type(options) ~= "table" then return nil end
  local maximum = 0
  for key in pairs(options) do
    if not whole(key, 1) then return nil end
    maximum = math.max(maximum, key)
  end
  local remaining = 0
  for index = 1, maximum do
    if options[index] == nil then return nil end
    if options[index] then remaining = remaining + 1 end
  end
  return remaining
end

local function validate_pending(game, pending)
  if type(pending) ~= "table" or pending.version ~= 1
      or not whole(pending.id, 1) or type(pending.pack_key) ~= "string"
      or type(pending.open_id) ~= "string"
      or type(pending.center_key) ~= "string" or type(pending.base_key) ~= "string"
      or not whole(pending.option_index, 1) or not whole(pending.current, 1, 3)
      or not whole(pending.rapport, 0, 6)
      or (pending.phase ~= "question" and pending.phase ~= "feedback" and pending.phase ~= "complete")
      or type(pending.questions) ~= "table" or #pending.questions ~= 3
      or type(pending.answers) ~= "table" then return false end

  local script = catalog()[pending.base_key]
  if not script then return false end
  local po = game.shop and game.shop.pack_open
  local option = po and po.kind == "hiring" and po.pack_key == pending.pack_key
    and po.open_id == pending.open_id
    and type(po.options) == "table" and po.options[pending.option_index] or nil
  local offered = option and (option.center or option)
  local remaining = po and remaining_options(po.options)
  if not (remaining and whole(po.picks_left, 1, remaining)
      and type(offered) == "table" and offered.key == pending.center_key) then return false end
  local center = require("game.centers").get(pending.center_key)
  if not center or base_key(center) ~= pending.base_key then return false end
  local questions, ids = question_map(script), {}
  for _, materialized in ipairs(pending.questions) do
    if type(materialized) ~= "table" or type(materialized.id) ~= "string"
        or not questions[materialized.id] or ids[materialized.id]
        or not whole(materialized.permutation, 1, #PERMUTATIONS) then return false end
    ids[materialized.id] = true
  end

  local rapport = 0
  for index, answer in ipairs(pending.answers) do
    local materialized = pending.questions[index]
    local question = materialized and questions[materialized.id]
    local choice = type(answer) == "table" and question and choice_for(question, answer.choice_id)
    if not choice or answer.question_id ~= materialized.id then return false end
    rapport = rapport + choice.rapport
  end
  if rapport ~= pending.rapport or rapport < 0 or rapport > 6 then return false end

  local answered = #pending.answers
  if pending.phase == "question" and answered ~= pending.current - 1 then return false end
  if pending.phase == "feedback" and answered ~= pending.current then return false end
  if pending.phase == "complete" then
    if pending.standard_terms ~= true and answered ~= 3 then return false end
    if pending.standard_terms ~= nil and pending.standard_terms ~= true then return false end
  elseif pending.standard_terms ~= nil then return false end
  return true
end

-- Malformed pending data is discarded without touching the selected option or
-- its pick. This is deliberately fail-closed: normalization can never hire.
function FounderNegotiation.normalize(game)
  if type(game) ~= "table" then return nil end
  local next_id = tonumber(game.founder_negotiation_next_id)
  if not whole(next_id, 0) then next_id = 0 end
  game.founder_negotiation_next_id = next_id
  normalize_seen(game)
  local shop = type(game.shop) == "table" and game.shop or nil
  if shop and type(shop.founder_negotiation) == "table"
      and type(shop.founder_negotiation.open_id) ~= "string"
      and type(shop.pack_open) == "table" and type(shop.pack_open.open_id) == "string" then
    shop.founder_negotiation.open_id = shop.pack_open.open_id
  end
  if shop and shop.founder_negotiation ~= nil
      and not validate_pending(game, shop.founder_negotiation) then
    shop.founder_negotiation = nil
  end
  if shop and shop.founder_negotiation then
    game.founder_negotiation_next_id = math.max(
      game.founder_negotiation_next_id, shop.founder_negotiation.id)
  end
  return shop and shop.founder_negotiation or nil
end

local function random_remove(items)
  return table.remove(items, RNG.int("founder_negotiation", #items))
end

local function choose_question_ids(game, script)
  local seen = normalize_seen(game)
  local row = seen[script.key] or {}
  local used = {}
  for _, id in ipairs(row) do used[id] = true end
  local available = {}
  for _, question in ipairs(script.questions) do
    if not used[question.id] then available[#available + 1] = question.id end
  end
  table.sort(available)

  -- Exchanges always come from one half-cycle. If fewer than three unseen
  -- questions remain, start a fresh six-question cycle before drawing.
  if #available < 3 then
    row, available = {}, {}
    for _, question in ipairs(script.questions) do available[#available + 1] = question.id end
    table.sort(available)
  end

  local chosen = {}
  while #chosen < 3 do
    local id = random_remove(available)
    chosen[#chosen + 1] = id
    row[#row + 1], used[id] = id, true
  end
  seen[script.key] = row
  return chosen
end

function FounderNegotiation.begin(game, center, option_index)
  if type(game) ~= "table" or type(game.shop) ~= "table" or game.shop.founder_negotiation then
    return nil, "A Founder negotiation is already pending"
  end
  local script, key = FounderNegotiation.script_for(center)
  if not script or type(script.questions) ~= "table" or #script.questions ~= 6 then
    return nil, "This Legendary Founder has no negotiation script"
  end
  local po = game.shop.pack_open
  if type(po) ~= "table" then return nil, "The Hiring Round is no longer available" end
  if type(po.open_id) ~= "string" or po.open_id == "" then
    game.pack_session_next_id = (game.pack_session_next_id or 0) + 1
    po.open_id = table.concat({ "pack-open", tostring(game.shop.shop_id or 0),
      tostring(game.pack_session_next_id) }, ":")
  end
  local ids = choose_question_ids(game, script)
  local materialized = {}
  for index, id in ipairs(ids) do
    materialized[index] = {
      id = id,
      permutation = RNG.int("founder_negotiation", #PERMUTATIONS),
    }
  end
  game.founder_negotiation_next_id = (game.founder_negotiation_next_id or 0) + 1
  local pending = {
    version = 1,
    id = game.founder_negotiation_next_id,
    pack_key = po.pack_key,
    open_id = po.open_id,
    center_key = center.key,
    base_key = key,
    option_index = option_index,
    phase = "question",
    rapport = 0,
    current = 1,
    questions = materialized,
    answers = {},
  }
  game.shop.founder_negotiation = pending
  return pending
end

local function current_content(pending)
  local script = catalog()[pending.base_key]
  local materialized = pending.questions[pending.current]
  return script, materialized, question_map(script)[materialized.id]
end

function FounderNegotiation.view(game)
  local pending = FounderNegotiation.normalize(game)
  if not pending then return nil end
  local script, materialized, question = current_content(pending)
  local out = {
    id = pending.id,
    center_key = pending.center_key,
    base_key = pending.base_key,
    phase = pending.phase,
    rapport = pending.rapport,
    round = pending.current,
    rounds = 3,
    standard_terms = pending.standard_terms == true,
    answers = {},
  }
  local center = require("game.centers").get(pending.center_key)
  if center then
    local multiplier = pending.standard_terms and 1.0
      or FounderNegotiation.salary_multiplier(pending.rapport)
    out.founder = { key = center.key, name = center.name, ability_name = center.ability_name }
    out.base_salary = center.salary or 1
    out.salary_multiplier = multiplier
    out.projected_salary = math.max(1, math.floor(out.base_salary * multiplier + 0.5))
  end
  local authored = question_map(script)
  for index, answer in ipairs(pending.answers) do
    local answered_question = authored[answer.question_id]
    local chosen = choice_for(answered_question, answer.choice_id)
    out.answers[index] = {
      question_id = answer.question_id,
      choice_id = answer.choice_id,
      text = chosen.text,
      rapport_delta = chosen.rapport,
      reply = chosen.reply,
      fact = chosen.fact,
    }
  end
  if pending.phase == "question" then
    out.question = { id = question.id, prompt = question.prompt, choices = {} }
    for _, index in ipairs(PERMUTATIONS[materialized.permutation]) do
      local choice = question.choices[index]
      out.question.choices[#out.question.choices + 1] = {
        id = question.id .. ":" .. choice.id,
        choice_id = choice.id,
        text = choice.text,
      }
    end
  elseif pending.phase == "feedback" then
    local answer = pending.answers[pending.current]
    local choice = answer and choice_for(question, answer.choice_id)
    out.question = { id = question.id, prompt = question.prompt }
    out.feedback = choice and {
      question_id = question.id,
      choice_id = choice.id,
      reply = choice.reply,
      fact = choice.fact,
      rapport_delta = choice.rapport,
    } or nil
  end
  return out
end

function FounderNegotiation.answer(game, selection)
  local pending = FounderNegotiation.normalize(game)
  if not pending or pending.phase ~= "question" then return false, "No question is awaiting an answer" end
  local _, materialized, question = current_content(pending)
  local choice
  if whole(selection, 1, 3) then
    local source_index = PERMUTATIONS[materialized.permutation][selection]
    choice = question.choices[source_index]
  elseif type(selection) == "string" then
    local qid, cid = selection:match("^(.-):([^:]+)$")
    if qid and qid == question.id then choice = choice_for(question, cid)
    elseif not qid then choice = choice_for(question, selection) end
  end
  if not choice then return false, "That answer is unavailable" end

  pending.rapport = math.min(6, pending.rapport + choice.rapport)
  pending.answers[#pending.answers + 1] = {
    question_id = question.id,
    choice_id = choice.id,
  }
  pending.phase = "feedback"
  return true, FounderNegotiation.view(game)
end

function FounderNegotiation.continue(game)
  local pending = FounderNegotiation.normalize(game)
  if not pending or pending.phase ~= "feedback" then return false, "No feedback is awaiting continuation" end
  if pending.current < 3 then
    pending.current = pending.current + 1
    pending.phase = "question"
    return true, FounderNegotiation.view(game)
  end
  pending.phase = "complete"
  return true, "complete"
end

function FounderNegotiation.accept_standard(game)
  local pending = FounderNegotiation.normalize(game)
  if not pending or pending.phase == "complete" then return false, "No negotiation can accept standard terms" end
  pending.standard_terms = true
  pending.phase = "complete"
  return true, "complete"
end

function FounderNegotiation.salary_multiplier(rapport)
  if rapport >= 6 then return 0.7 end
  if rapport >= 4 then return 0.8 end
  if rapport >= 2 then return 0.9 end
  return 1.0
end

function FounderNegotiation.audit(pending, salary, multiplier)
  local questions, permutations = {}, {}
  for index, materialized in ipairs(pending.questions) do
    questions[index], permutations[index] = materialized.id, materialized.permutation
  end
  return {
    id = pending.id,
    pack_key = pending.pack_key,
    base_key = pending.base_key,
    rapport = pending.rapport,
    salary = salary,
    salary_multiplier = multiplier,
    standard_terms = pending.standard_terms == true,
    question_ids = questions,
    choice_permutations = permutations,
    answers = copy(pending.answers),
  }
end

return FounderNegotiation
