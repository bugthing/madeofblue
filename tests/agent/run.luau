--!nonstrict
-- Runs every agent-plugin spec. Usage: luau tests/agent/run.luau
local T = require("./support/t")

-- luau's require returns the error message instead of throwing when a module
-- fails to parse, so a broken spec would silently drop out. Each spec returns
-- true; anything else counts as a failure.
local function spec(name, loaded)
  if loaded ~= true then
    T.failed += 1
    table.insert(T.failures, "spec " .. name .. " did not load\n    " .. tostring(loaded))
  end
end

spec("json", require("./spec/json_spec"))
spec("config", require("./spec/config_spec"))
spec("redact_paths", require("./spec/redact_paths_spec"))
spec("redact_scrub", require("./spec/redact_scrub_spec"))
spec("tools", require("./spec/tools_spec"))
spec("openai", require("./spec/openai_spec"))
spec("anthropic", require("./spec/anthropic_spec"))
spec("agent", require("./spec/agent_spec"))

T.report()
