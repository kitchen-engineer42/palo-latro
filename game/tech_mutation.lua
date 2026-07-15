-- UID-first Founder mutations over the persistent Tech deck and its live views.
-- Selection is resolved during planning; commits revalidate through DeckTx (or
-- exact live-area identities for the one transient swap action).

local Coverage = require("game.coverage")
local DeckTx = require("game.deck_transactions")
local TechLifecycle = require("game.tech_lifecycle")

local Mutation = {}

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}; if seen[value] then return seen[value] end
  local out = {}; seen[value] = out
  for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
  return out
end

local function card_uid_list(cards)
  local out = {}
  for _, card in ipairs(cards or {}) do if card.uid then out[#out + 1] = card.uid end end
  return out
end

local function source_uids(from, ctx, target_uid)
  local game = G.GAME
  if from == "scoring_hand" then return card_uid_list(ctx.scoring_hand)
  elseif from == "hand" then return card_uid_list(G.hand and G.hand.cards)
  elseif from == "last_ship" then return copy(game.last_ship_uids or {})
  elseif from == "last_pivot" then return copy(game.last_pivot_uids or {})
  elseif from == "master_deck" then
    if target_uid then return { target_uid } end
    local out = {}; for _, entry in ipairs(game.master_deck or {}) do out[#out + 1] = entry.uid end; return out
  end
  return {}
end

local SELECTOR = {
  highest_users="highest", lowest_users="lowest", lowest_base_users="cheapest",
  random="random", target="lowest", marked="lowest",
}

function Mutation.mark_key(card, target)
  local cfg = card and card.ability and card.ability.config or {}
  return tostring(target or "mark") .. ":" .. tostring(cfg._founder_id or card.ID or card.center_key or "founder")
end

local function marked_entry(game, mark)
  for _, entry in ipairs((game and game.master_deck) or {}) do
    local marks = entry.config and entry.config._founder_marks
    if marks and marks[mark] then return entry, marks[mark] end
  end
end

function Mutation.marked_entry(game, card, target)
  return marked_entry(game or G.GAME, Mutation.mark_key(card, target))
end

function Mutation.card_has_mark(subject, card, target)
  local uid = subject and subject.uid
  local entry = uid and Mutation.marked_entry(G.GAME, card, target)
  return entry ~= nil and entry.uid == uid
end

local function effective_users(entry)
  local center = entry and require("game.centers").get(entry.center_key)
  if not center then return 0 end
  if Card and Card.tech_users then return Card.tech_users(entry, center, G.GAME.era, G.GAME) end
  return TechLifecycle.effective_users(entry, center, G.GAME.era)
end

local function scalable_amount(value)
  value = tonumber(value) or 0
  return math.max(0, math.floor(value))
end

local function seen_layers()
  local out = {}
  for _, layer in ipairs(Coverage.CORE_ORDER) do
    if G.GAME.layers_seen_run and G.GAME.layers_seen_run[layer] then out[#out + 1] = layer end
  end
  return out
end

local function scoring_layers(ctx)
  local analysis = ctx.coverage or Coverage.analyze(ctx.scoring_hand or {})
  local out = {}
  for _, layer in ipairs(Coverage.CORE_ORDER) do
    if analysis.counts[layer] then out[#out + 1] = layer end
  end
  return out
end

local function live_by_uid(area, uid)
  for _, card in ipairs((area and area.cards) or {}) do if card.uid == uid then return card end end
end

local function prepare_swap(op, ctx)
  local target_uid = ctx.target_uid
  local target = target_uid and live_by_uid(G.hand, target_uid)
  local top = G.deck and G.deck.cards and G.deck.cards[#G.deck.cards]
  if not (target and top and target.uid and top.uid and target.uid ~= top.uid) then
    return nil, "Demo needs a hand Tech and a top-deck Tech"
  end
  return {
    kind="live_swap", target_uid=target.uid, top_uid=top.uid,
    target_users=target.get_users and target:get_users() or target.base_users or 0,
    top_users=top.get_users and top:get_users() or top.base_users or 0,
  }
end

function Mutation.prepare(op, ctx, card, amount)
  local mode = op.mode
  if mode == "swap_top" then return prepare_swap(op, ctx) end
  if mode == "score_users" then
    local entries, candidates = {}, {}
    for _, entry in ipairs(G.GAME.master_deck or {}) do entries[entry.uid] = entry end
    for _, uid in ipairs(source_uids(op.from, ctx, ctx.target_uid)) do
      local candidate = entries[uid] or live_by_uid(G.hand, uid) or live_by_uid(G.play, uid)
      if not candidate then
        for _, card_in_hand in ipairs(ctx.scoring_hand or {}) do
          if card_in_hand.uid == uid then candidate = card_in_hand; break end
        end
      end
      if candidate then candidates[#candidates + 1] = candidate end
    end
    table.sort(candidates, function(a, b)
      local au, bu = effective_users(a), effective_users(b)
      if au ~= bu then return au > bu end
      return a.uid < b.uid
    end)
    local chips = 0
    for index = 1, math.min(scalable_amount(amount), #candidates) do chips = chips + effective_users(candidates[index]) end
    return { kind="score_users", chips=chips, count=math.min(scalable_amount(amount), #candidates) }
  end

  local operations = {}
  local candidates = source_uids(op.from, ctx, ctx.target_uid)
  if mode == "copy" then
    operations[1] = { kind="copy_selected", candidate_uids=candidates,
      selector=SELECTOR[op.select] or op.select or "lowest", amount=scalable_amount(amount),
      enhancement=op.enhancement, source="founder_copy", rng_stream="founder_mutation" }
  elseif mode == "generate" then
    if op.select == "each_seen_layer" then
      for _, layer in ipairs(seen_layers()) do
        operations[#operations + 1] = { kind="add_random", layer=layer,
          amount=scalable_amount(amount), source="founder_generated", rng_stream="founder_mutation" }
      end
    else
      local layers = op.select == "random_scoring_layer" and scoring_layers(ctx)
        or (op.select == "random_seen" and seen_layers() or nil)
      operations[1] = { kind="add_random", layers=layers,
        amount=scalable_amount(amount), source="founder_generated", rng_stream="founder_mutation" }
    end
  elseif mode == "buff" then
    operations[1] = { kind="buff_selected", candidate_uids=candidates,
      selector=SELECTOR[op.select] or op.select or "random", amount=scalable_amount(amount),
      users=op.users, source="founder_investment", label="Founder investment", rng_stream="founder_mutation" }
  elseif mode == "mark" then
    operations[1] = { kind="mark_selected", candidate_uids=candidates,
      selector=SELECTOR[op.select] or "lowest", mark=Mutation.mark_key(card, op.compare or op.target),
      source=card.center_key, rng_stream="founder_mutation" }
  elseif mode == "age_mark" then
    operations[1] = { kind="age_mark", mark=Mutation.mark_key(card, op.target), amount=scalable_amount(amount) }
  elseif mode == "clear_mark" then
    operations[1] = { kind="clear_mark", mark=Mutation.mark_key(card, op.target) }
  else
    return nil, "Unsupported Tech mutation"
  end
  if #operations == 0 then return nil, "Tech mutation has no eligible Layer" end
  -- Founder-authored copies are rewards, not market acquisitions; biographies
  -- such as Boyer's explicitly create two copies and may exceed Shop copy caps.
  local respect_copy_cap = mode ~= "copy"
  local plan, reason = DeckTx.plan(G.GAME, { ops=operations, respect_copy_cap=respect_copy_cap },
    { respect_copy_cap=respect_copy_cap, rng_stream="founder_mutation" })
  if not plan then return nil, reason end
  return { kind="deck", plan=plan, destination=op.to }
end

local function move_added(uid, destination)
  if destination ~= "hand" and destination ~= "next_hand" then return end
  if destination == "hand" and G.hand and #G.hand.cards < (G.GAME.hand_size or 8) then
    local card = live_by_uid(G.deck, uid)
    if card then
      G.deck:remove_card(card, true); card.face_down = false; G.hand:emplace(card); return
    end
  end
  G.GAME.next_hand_uids = G.GAME.next_hand_uids or {}
  G.GAME.next_hand_uids[#G.GAME.next_hand_uids + 1] = uid
end

function Mutation.commit(prepared)
  if prepared.kind == "score_users" then return { ok=true, chips=prepared.chips, count=prepared.count } end
  if prepared.kind == "live_swap" then
    local target, top = live_by_uid(G.hand, prepared.target_uid), live_by_uid(G.deck, prepared.top_uid)
    if not (target and top and G.deck.cards[#G.deck.cards] == top) then return { ok=false, reason="Demo target changed" } end
    local target_users = (target.get_users and target:get_users()) or target.base_users or 0
    local top_users = (top.get_users and top:get_users()) or top.base_users or 0
    G.hand:remove_card(target, true); G.deck:remove_card(top, true)
    target.face_down = true; top.face_down = false
    G.deck:emplace(target, true); G.hand:emplace(top)
    return { ok=true, mutation_upgraded=top_users > target_users,
      target_uid=prepared.target_uid, replacement_uid=prepared.top_uid }
  end
  local result = DeckTx.commit(G.GAME, prepared.plan)
  if result.ok then for _, uid in ipairs(result.added_uids or {}) do move_added(uid, prepared.destination) end end
  return result
end

return Mutation
