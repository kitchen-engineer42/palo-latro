-- Serializable named gameplay RNG streams. Cosmetic randomness must not use these.

local RNG = {}
local MOD, MUL = 2147483647, 48271

local function seed_for(seed, name)
  local h = tonumber(seed) or 1
  local text = tostring(seed or "palo") .. ":" .. tostring(name)
  for i = 1, #text do h = (h * 131 + text:byte(i)) % MOD end
  return math.max(1, h)
end

function RNG.value(name)
  if not G.GAME then return love.math.random() end
  G.GAME.rng_streams = G.GAME.rng_streams or {}
  local state = G.GAME.rng_streams[name] or seed_for(G.GAME.seed, name)
  state = (state * MUL) % MOD
  G.GAME.rng_streams[name] = state
  return (state - 1) / (MOD - 1)
end

function RNG.int(name, n)
  assert(n and n >= 1, "RNG.int requires a positive bound")
  return math.floor(RNG.value(name) * n) + 1
end

function RNG.fn(name)
  return function(n) return n and RNG.int(name, n) or RNG.value(name) end
end

return RNG
