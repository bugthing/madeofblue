--!nonstrict
-- Bar icon. Shows whether the agent is set up, working, or waiting for the
-- user, and toggles the chat panel on click. The panel publishes "status"
-- through noctalia.state; before the panel's first open we fall back to
-- checking for the saved settings file.

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

local initial = noctalia.state.get("status")
if initial == nil then
  local dir = noctalia.pluginDataDir()
  initial = (dir and noctalia.fileExists(dir .. "/config.json")) and "idle" or "unconfigured"
end
show(initial)

noctalia.state.watch("status", show)

function onClick()
  noctalia.togglePanel(PANEL)
end
