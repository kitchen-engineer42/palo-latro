-- engine/object.lua — minimal class system (clean-room; the well-known rxi "classic"
-- MIT pattern, written fresh). Constructor method is :init (Balatro-style).

Object = {}
Object.__index = Object

function Object:init(...) end

function Object:extend()
  local cls = {}
  for k, v in pairs(self) do
    if tostring(k):find("__") == 1 then cls[k] = v end   -- inherit metamethods
  end
  cls.__index = cls
  cls.super = self
  setmetatable(cls, self)        -- class methods chain to the parent class
  return cls
end

-- instanceof: walk the metatable (class) chain
function Object:is(T)
  local mt = getmetatable(self)
  while mt do
    if mt == T then return true end
    mt = getmetatable(mt)
  end
  return false
end

function Object:__call(...)
  local obj = setmetatable({}, self)   -- self is the class being called
  obj:init(...)
  return obj
end

return Object
