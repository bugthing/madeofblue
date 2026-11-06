--!nonstrict
-- Bar icon. Shows whether the agent is set up, working, or waiting for the
-- user, and toggles the chat panel on click. The panel publishes "status"
-- through noctalia.state; while it has published nothing (before the panel
-- runtime starts, or after it exits) we fall back to the saved settings file.

local Config = require("./lib/config.luau")

local PANEL = "madeofblue/agent:chat"

local LOOKS = {
  unconfigured = { glyph = "robot-off", color = "on_surface", tip = "Agent: click to set up" },
  idle = { glyph = "robot", color = "on_surface", tip = "Agent" },
  busy = { glyph = "robot", color = "primary", tip = "Agent: working…" },
  waiting = { glyph = "robot", color = "error", tip = "Agent: waiting for you" },
}

local function show(status)
  local look = LOOKS[status] or LOOKS.idle
  barWidget.setGlyph(look.glyph)
  barWidget.setGlyphColor(look.color)
  barWidget.setTooltip(look.tip)
end

local function fromSettings()
  local dir = noctalia.pluginDataDir()
  local raw = dir and noctalia.readFile(dir .. "/config.json")
  if raw and Config.decode(raw, noctalia.json) then
    return "idle"
  end
  return "unconfigured"
end

local function update(status)
  show(status or fromSettings())
end

update(noctalia.state.get("status"))

noctalia.state.watch("status", update)

function onClick()
  noctalia.togglePanel(PANEL)
end
