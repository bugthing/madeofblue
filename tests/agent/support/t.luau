--!nonstrict
-- Tiny test harness for the luau CLI: describe/it blocks plus assertions.
local T = { passed = 0, failed = 0, failures = {} }
local scope = ""

local function fmt(v)
  if type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end

function T.describe(name, fn)
  local previous = scope
  scope = previous == "" and name or (previous .. " > " .. name)
  fn()
  scope = previous
end

function T.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    T.passed += 1
  else
    T.failed += 1
    table.insert(T.failures, scope .. " > " .. name .. "\n    " .. tostring(err))
  end
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "values differ") .. ": expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

function T.truthy(value, msg)
  if not value then
    error(msg or "expected a truthy value", 2)
  end
end

function T.contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not string.find(haystack, needle, 1, true) then
    error((msg or "missing substring") .. ": " .. fmt(needle) .. " not in " .. fmt(haystack), 2)
  end
end

function T.notContains(haystack, needle, msg)
  if type(haystack) == "string" and string.find(haystack, needle, 1, true) then
    error((msg or "unexpected substring") .. ": " .. fmt(needle) .. " in " .. fmt(haystack), 2)
  end
end

function T.report()
  for _, failure in ipairs(T.failures) do
    print("FAIL " .. failure)
  end
  print(T.passed .. " passed, " .. T.failed .. " failed")
  if T.failed > 0 then
    error("tests failed", 0)
  end
end

return T
