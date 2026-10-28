-- A small JSON codec for the test harness only (the real platforms provide their own: BeamMP's
-- Util.JsonEncode/JsonDecode and FiveM's json.encode/decode). Keys are sorted so output is stable.
local json = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function isArray(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

function json.encode(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return tostring(value)
  elseif kind == "number" then
    return string.format("%.14g", value)
  elseif kind == "string" then
    return encodeString(value)
  elseif kind == "table" then
    local out = {}
    if isArray(value) then
      for i = 1, #value do
        out[i] = json.encode(value[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      out[#out + 1] = encodeString(k) .. ":" .. json.encode(value[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. kind)
end

function json.decode(text)
  local pos = 1
  local function skip()
    pos = text:find("%S", pos) or #text + 1
  end
  local value
  local function fail(message)
    error(message .. " at " .. pos, 0)
  end
  local function parseString()
    local out = {}
    pos = pos + 1
    while true do
      local c = text:sub(pos, pos)
      if c == "" then
        fail("unterminated string")
      elseif c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local n = text:sub(pos + 1, pos + 1)
        local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if n == "u" then
          out[#out + 1] = utf8.char(tonumber(text:sub(pos + 2, pos + 5), 16))
          pos = pos + 6
        elseif map[n] then
          out[#out + 1] = map[n]
          pos = pos + 2
        else
          fail("bad escape")
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end
  function value()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skip()
        local key = parseString()
        skip()
        if text:sub(pos, pos) ~= ":" then
          fail("expected :")
        end
        pos = pos + 1
        obj[key] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          fail("expected , or }")
        end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          fail("expected , or ]")
        end
      end
    elseif c == '"' then
      return parseString()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end
    local number = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not number or number == "" then
      fail("unexpected character")
    end
    pos = pos + #number
    return tonumber(number)
  end
  local result = value()
  skip()
  if pos <= #text then
    fail("trailing characters")
  end
  return result
end

return json
