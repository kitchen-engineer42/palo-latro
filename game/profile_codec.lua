-- A deliberately small data codec for persistent profiles.
--
-- The old profile format was a Lua table literal prefixed with `return` and was
-- loaded as executable code.  This module accepts that literal grammar without
-- invoking Lua's compiler, then writes a versioned envelope using the same
-- unambiguous data primitives.  Functions, expressions, identifiers, metatables,
-- and trailing input are never accepted.

local Codec = {}

Codec.VERSION = 2
Codec.MAX_BYTES = 1024 * 1024
Codec.MAX_DEPTH = 24
Codec.MAX_VALUES = 100000

local function finite_number(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function parse_literal(input)
  if type(input) ~= "string" then return nil, "profile data must be a string" end
  if #input > Codec.MAX_BYTES then return nil, "profile data exceeds size limit" end

  local i, n, values = 1, #input, 0
  local function fail(message) return nil, message .. " at byte " .. i end
  local function skip_ws()
    while i <= n and input:sub(i, i):match("%s") do i = i + 1 end
  end
  local function word(w)
    if input:sub(i, i + #w - 1) ~= w then return false end
    local nextc = input:sub(i + #w, i + #w)
    if nextc ~= "" and nextc:match("[%w_]") then return false end
    i = i + #w
    return true
  end

  local parse_value
  local function parse_string()
    local quote = input:sub(i, i)
    if quote ~= '"' and quote ~= "'" then return fail("expected string") end
    i = i + 1
    local out = {}
    while i <= n do
      local c = input:sub(i, i)
      if c == quote then i = i + 1; return table.concat(out) end
      if c == "\n" or c == "\r" then return fail("unescaped newline in string") end
      if c ~= "\\" then
        out[#out + 1] = c
        i = i + 1
      else
        i = i + 1
        if i > n then return fail("unfinished string escape") end
        local e = input:sub(i, i)
        local escapes = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
                          ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }
        if escapes[e] then
          out[#out + 1] = escapes[e]
          i = i + 1
        elseif e:match("%d") then
          local digits = input:sub(i, i + 2):match("^(%d%d?%d?)")
          local byte = tonumber(digits)
          if not byte or byte > 255 then return fail("invalid decimal string escape") end
          out[#out + 1] = string.char(byte)
          i = i + #digits
        elseif e == "z" then
          i = i + 1
          while i <= n and input:sub(i, i):match("%s") do i = i + 1 end
        elseif e == "\n" then
          out[#out + 1] = "\n"
          i = i + 1
        else
          return fail("unsupported string escape")
        end
      end
    end
    return fail("unterminated string")
  end

  local function parse_number()
    local tail = input:sub(i)
    local token = tail:match("^[+-]?%d+%.?%d*[eE][+-]?%d+")
               or tail:match("^[+-]?%d*%.%d+")
               or tail:match("^[+-]?%d+")
    if not token then return fail("invalid number") end
    local value = tonumber(token)
    if not finite_number(value) then return fail("non-finite number") end
    i = i + #token
    return value
  end

  local function parse_table(depth)
    if depth > Codec.MAX_DEPTH then return fail("profile nesting exceeds limit") end
    i = i + 1 -- {
    local result, next_array = {}, 1
    skip_ws()
    while input:sub(i, i) ~= "}" do
      if i > n then return fail("unterminated table") end
      local key, value
      if input:sub(i, i) == "[" then
        i = i + 1; skip_ws()
        local c = input:sub(i, i)
        if c == '"' or c == "'" then key = parse_string()
        elseif c:match("[+%-%d%.]") then key = parse_number()
        else return fail("table key must be a string or number") end
        if key == nil then return nil, "invalid table key" end
        skip_ws()
        if input:sub(i, i) ~= "]" then return fail("expected closing bracket") end
        i = i + 1; skip_ws()
        if input:sub(i, i) ~= "=" then return fail("expected equals after table key") end
        i = i + 1; skip_ws()
        value = parse_value(depth + 1)
      else
        key = next_array
        value = parse_value(depth + 1)
        next_array = next_array + 1
      end
      if value == nil then return fail("nil profile values are not allowed") end
      if result[key] ~= nil then return fail("duplicate table key") end
      result[key] = value
      values = values + 1
      if values > Codec.MAX_VALUES then return fail("profile contains too many values") end
      skip_ws()
      local sep = input:sub(i, i)
      if sep == "," or sep == ";" then i = i + 1; skip_ws()
      elseif sep ~= "}" then return fail("expected table separator") end
    end
    i = i + 1
    return result
  end

  parse_value = function(depth)
    skip_ws()
    local c = input:sub(i, i)
    if c == "{" then return parse_table(depth)
    elseif c == '"' or c == "'" then return parse_string()
    elseif c:match("[+%-%d%.]") then return parse_number()
    elseif word("true") then return true
    elseif word("false") then return false
    end
    return fail("unsupported value")
  end

  skip_ws()
  if word("return") then skip_ws() end -- restricted legacy prefix, not execution
  local value, err = parse_value(1)
  if value == nil then return nil, err end
  skip_ws()
  if i <= n then return fail("trailing profile input") end
  return value
end

local function quote(value)
  return string.format("%q", value)
end

local function key_order(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function encode_value(value, depth, seen)
  if depth > Codec.MAX_DEPTH then error("profile nesting exceeds limit") end
  local kind = type(value)
  if kind == "boolean" then return tostring(value) end
  if kind == "number" then
    if not finite_number(value) then error("profile contains a non-finite number") end
    return tostring(value)
  end
  if kind == "string" then return quote(value) end
  if kind ~= "table" then error("unsupported profile value type: " .. kind) end
  if getmetatable(value) ~= nil then error("profile tables may not have metatables") end
  if seen[value] then error("profile contains a table cycle") end
  seen[value] = true
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then
      error("profile keys must be strings or numbers")
    end
    keys[#keys + 1] = key
  end
  table.sort(keys, key_order)
  local parts = {}
  for _, key in ipairs(keys) do
    local encoded_key = type(key) == "number" and tostring(key) or quote(key)
    parts[#parts + 1] = "[" .. encoded_key .. "]=" .. encode_value(value[key], depth + 1, seen)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

local function plain_copy(value, path, depth, seen)
  if depth > Codec.MAX_DEPTH then return nil, path .. " exceeds nesting limit" end
  local kind = type(value)
  if kind == "boolean" or kind == "string" then return value end
  if kind == "number" then
    if not finite_number(value) then return nil, path .. " must be finite" end
    return value
  end
  if kind ~= "table" then return nil, path .. " contains unsupported " .. kind end
  if getmetatable(value) ~= nil then return nil, path .. " may not have a metatable" end
  if seen[value] then return nil, path .. " contains a cycle" end
  seen[value] = true
  local out = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then
      return nil, path .. " has an unsupported key"
    end
    local copied, err = plain_copy(item, path .. "[" .. tostring(key) .. "]", depth + 1, seen)
    if err then return nil, err end
    out[key] = copied
  end
  seen[value] = nil
  return out
end

local function nonnegative(value, name, default)
  if value == nil then return default end
  if not finite_number(value) or value < 0 then return nil, name .. " must be a non-negative number" end
  return value
end

function Codec.validate(profile)
  if type(profile) ~= "table" then return nil, "profile root must be a table" end
  local out, err = plain_copy(profile, "profile", 1, {})
  if not out then return nil, err end

  for _, field in ipairs({ "unlocked", "discovered", "beaten_stakes" }) do
    if out[field] == nil then out[field] = {} end
    if type(out[field]) ~= "table" then return nil, "profile." .. field .. " must be a table" end
  end
  for _, field in ipairs({ "unlocked", "discovered" }) do
    for key, value in pairs(out[field]) do
      if type(key) ~= "string" or type(value) ~= "boolean" then
        return nil, "profile." .. field .. " must map string keys to booleans"
      end
    end
  end
  for key, value in pairs(out.beaten_stakes) do
    if not finite_number(key) or key % 1 ~= 0 or key < 1 or key > 8 or type(value) ~= "boolean" then
      return nil, "profile.beaten_stakes must map integer stakes 1..8 to booleans"
    end
  end

  if out.career == nil then out.career = {} end
  if type(out.career) ~= "table" then return nil, "profile.career must be a table" end
  local defaults = { runs = 0, wins = 0, best_arr = 0, best_ante = 1 }
  for field, default in pairs(defaults) do
    local checked
    checked, err = nonnegative(out.career[field], "profile.career." .. field, default)
    if err then return nil, err end
    out.career[field] = checked
  end
  if out.career.runs % 1 ~= 0 or out.career.wins % 1 ~= 0 or out.career.best_ante % 1 ~= 0 then
    return nil, "profile career counters must be integers"
  end
  return out
end

function Codec.encode(profile)
  local valid, err = Codec.validate(profile)
  if not valid then return nil, err end
  local ok, encoded = pcall(encode_value, { version = Codec.VERSION, profile = valid }, 1, {})
  if not ok then return nil, encoded end
  if #encoded > Codec.MAX_BYTES then return nil, "encoded profile exceeds size limit" end
  return encoded
end

function Codec.decode(input)
  local root, err = parse_literal(input)
  if not root then return nil, nil, err end
  if type(root) ~= "table" then return nil, nil, "profile root must be a table" end
  local profile, meta
  if root.version ~= nil then
    if not finite_number(root.version) or root.version % 1 ~= 0 then
      return nil, nil, "profile version must be an integer"
    end
    if root.version > Codec.VERSION then return nil, nil, "profile version is newer than this build" end
    if root.version ~= Codec.VERSION then return nil, nil, "unsupported profile version " .. tostring(root.version) end
    if type(root.profile) ~= "table" then return nil, nil, "versioned profile is missing its data table" end
    profile, meta = root.profile, { version = root.version, legacy = false }
  else
    profile, meta = root, { version = 1, legacy = true }
  end
  local valid
  valid, err = Codec.validate(profile)
  if not valid then return nil, nil, err end
  return valid, meta
end

Codec.parse_literal = parse_literal

return Codec
