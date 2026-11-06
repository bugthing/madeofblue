--!nonstrict
-- Minimal JSON for tests only; Noctalia provides noctalia.json at runtime.
-- Unlike noctalia.json.decode, decode throws on malformed input.
local M = {}

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
  return '"' .. string.gsub(s, '[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
  end) .. '"'
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    n += 1
  end
  return n > 0 and n == #t
end

function M.encode(v, _pretty)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    return string.format("%.17g", v)
  elseif t == "string" then
    return encodeString(v)
  elseif t == "table" then
    local parts = {}
    if isArray(v) then
      for i = 1, #v do
        parts[i] = M.encode(v[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      table.insert(parts, encodeString(tostring(k)) .. ":" .. M.encode(v[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot encode a " .. t)
end

local UNESCAPE = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

function M.decode(s)
  local pos = 1
  local function fail(msg)
    error("json: " .. msg .. " at " .. pos, 0)
  end
  local function ws()
    pos = string.find(s, "[^ \t\r\n]", pos) or (#s + 1)
  end
  local function str()
    pos += 1
    local out = {}
    while true do
      local c = string.sub(s, pos, pos)
      if c == "" then
        fail("unterminated string")
      elseif c == '"' then
        pos += 1
        return table.concat(out)
      elseif c == "\\" then
        local e = string.sub(s, pos + 1, pos + 1)
        if e == "u" then
          table.insert(out, utf8.char(tonumber(string.sub(s, pos + 2, pos + 5), 16)))
          pos += 6
        elseif UNESCAPE[e] then
          table.insert(out, UNESCAPE[e])
          pos += 2
        else
          fail("bad escape")
        end
      else
        table.insert(out, c)
        pos += 1
      end
    end
  end
  local value
  value = function()
    ws()
    local c = string.sub(s, pos, pos)
    if c == "{" then
      pos += 1
      local obj = {}
      ws()
      if string.sub(s, pos, pos) == "}" then
        pos += 1
        return obj
      end
      while true do
        ws()
        if string.sub(s, pos, pos) ~= '"' then
          fail("expected a key")
        end
        local k = str()
        ws()
        if string.sub(s, pos, pos) ~= ":" then
          fail("expected ':'")
        end
        pos += 1
        obj[k] = value()
        ws()
        local d = string.sub(s, pos, pos)
        pos += 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          fail("expected ',' or '}'")
        end
      end
    elseif c == "[" then
      pos += 1
      local arr = {}
      ws()
      if string.sub(s, pos, pos) == "]" then
        pos += 1
        return arr
      end
      while true do
        table.insert(arr, value())
        ws()
        local d = string.sub(s, pos, pos)
        pos += 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          fail("expected ',' or ']'")
        end
      end
    elseif c == '"' then
      return str()
    elseif string.sub(s, pos, pos + 3) == "true" then
      pos += 4
      return true
    elseif string.sub(s, pos, pos + 4) == "false" then
      pos += 5
      return false
    elseif string.sub(s, pos, pos + 3) == "null" then
      pos += 4
      return nil
    end
    local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num or num == "" then
      fail("unexpected character")
    end
    pos += #num
    return tonumber(num)
  end
  local result = value()
  ws()
  if pos <= #s then
    fail("trailing characters")
  end
  return result
end

return M
