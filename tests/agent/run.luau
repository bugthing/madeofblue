--!nonstrict
-- Runs every agent-plugin spec. Usage: luau tests/agent/run.luau
local T = require("./support/t")

require("./spec/json_spec")

T.report()
