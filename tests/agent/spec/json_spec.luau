--!nonstrict
local T = require("../support/t")
local json = require("../support/json")

T.describe("test json", function()
  T.it("round-trips nested values", function()
    local back = json.decode(json.encode({ a = { 1, 2 }, b = "x\n\"y\"", c = true }))
    T.eq(back.a[2], 2)
    T.eq(back.b, "x\n\"y\"")
    T.eq(back.c, true)
  end)

  T.it("throws on malformed input", function()
    T.eq(pcall(json.decode, "{nope"), false)
  end)

  T.it("decodes unicode escapes", function()
    T.eq(json.decode('"caf\\u00e9"'), "café")
  end)
end)

return true
