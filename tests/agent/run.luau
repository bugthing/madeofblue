--!nonstrict
-- Runs every agent-plugin spec. Usage: luau tests/agent/run.luau
local T = require("./support/t")

require("./spec/json_spec")
require("./spec/config_spec")

T.report()
