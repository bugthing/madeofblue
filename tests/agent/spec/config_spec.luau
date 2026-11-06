--!nonstrict
local T = require("../support/t")
local json = require("../support/json")
local Config = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/config")

local function cfg(t)
  return Config.normalize({
    provider = t.provider or "openai",
    host = t.host or "https://api.openai.com/v1",
    model = t.model or "gpt-test",
    token = t.token or "sk-test",
  })
end

T.describe("config", function()
  T.it("trims fields and strips trailing slashes", function()
    local c = cfg({ host = "  https://api.openai.com/v1/  ", model = " m " })
    T.eq(c.host, "https://api.openai.com/v1")
    T.eq(c.model, "m")
    T.eq(#Config.validate(c), 0)
  end)

  T.it("allows plain http only for loopback hosts", function()
    T.eq(#Config.validate(cfg({ host = "http://localhost:11434/v1", token = "" })), 0)
    T.eq(#Config.validate(cfg({ host = "http://127.0.0.1:1234/v1", token = "" })), 0)
    T.eq(#Config.validate(cfg({ host = "http://[::1]:8080/v1", token = "" })), 0)
    T.contains(Config.validate(cfg({ host = "http://example.com/v1" }))[1], "localhost")
  end)

  T.it("rejects other schemes and non-URLs", function()
    T.contains(Config.validate(cfg({ host = "ftp://example.com" }))[1], "https")
    T.contains(Config.validate(cfg({ host = "example.com" }))[1], "URL")
  end)

  T.it("requires a model and a known provider", function()
    T.contains(table.concat(Config.validate(cfg({ model = "" })), "\n"), "model")
    T.contains(table.concat(Config.validate(cfg({ provider = "nope" })), "\n"), "provider")
  end)

  T.it("requires a token for Anthropic but not for OpenAI-compatible", function()
    T.contains(Config.validate(cfg({ provider = "anthropic", host = "https://api.anthropic.com", token = "" }))[1], "token")
    T.eq(#Config.validate(cfg({ token = "" })), 0)
  end)

  T.it("round-trips through JSON", function()
    local c = cfg({ token = "secret-token" })
    local back = Config.decode(Config.encode(c, json), json)
    T.eq(back.provider, "openai")
    T.eq(back.token, "secret-token")
  end)

  T.it("reports unreadable and invalid saved settings", function()
    local none, err1 = Config.decode(nil, json)
    T.eq(none, nil)
    T.eq(err1, "missing")
    local bad, err2 = Config.decode("{not json", json)
    T.eq(bad, nil)
    T.eq(err2, "not valid JSON")
    local invalid, err3 = Config.decode('{"provider":"openai","host":"x","model":"m","token":""}', json)
    T.eq(invalid, nil)
    T.contains(err3, "URL")
  end)

  T.it("labels loopback hosts Local and others Remote", function()
    T.eq(Config.destination(cfg({ host = "http://localhost:11434/v1" })), "Local")
    T.eq(Config.destination(cfg({ host = "https://API.example.com/v1" })), "Remote: api.example.com")
  end)
end)

return true
