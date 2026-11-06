--!nonstrict
-- Agent panel: a setup form until settings are saved, then the chat.
-- The panel runtime persists across close/open, so a running request keeps
-- going while the panel is hidden; the bar icon shows its status.

local Config = require("./lib/config.luau")
local Redact = require("./lib/redact.luau")
local Tools = require("./lib/tools.luau")
local Agent = require("./lib/agent.luau")
local PROVIDERS = {
  openai = require("./lib/providers/openai.luau"),
  anthropic = require("./lib/providers/anthropic.luau"),
}

local DATA_DIR = assert(noctalia.pluginDataDir(), "agent: no plugin data directory")
local CONFIG_PATH = DATA_DIR .. "/config.json"
local HOME = noctalia.expandPath("~")
local SYSTEM_PROMPT = noctalia.readFile("prompt.md") or "You are a careful assistant for this Linux computer."

local STOP_TOOLTIP = "Stop the agent. A command that already started keeps running."

local LIMITS_TEXT = "The agent sends command output and file contents to this provider. Known secret formats "
  .. "and sensitive paths are redacted or held for your review, but this is best effort. Use a local "
  .. "model for anything you must not share."

local STATE_LABELS = {
  pending = "Waiting for approval",
  running = "Running…",
  review = "Review output",
  done = "Sent",
  withheld = "Withheld",
  skipped = "Skipped",
  ["handed-off"] = "Opened in terminal",
  refused = "Refused",
  invalid = "Invalid",
  cancelled = "Cancelled",
}

local view = "setup" -- "setup" | "chat"
local config = nil
local configNotice = nil
local agent = nil
local form = { providerIndex = 0, host = "", model = "", token = "", rev = 0, error = nil, saving = false, saveGen = 0 }
local draft = ""
local composerRev = 0
local scrollRev = 0
local lastStatus = "idle" -- agent status at the previous change
local expanded = {} -- item id -> "what was sent" shown
local fullShown = {} -- item id -> full output shown on a review card

local render -- forward declaration

local function publishStatus()
  local status = "unconfigured"
  if config then
    status = "idle"
    if agent and agent:isBusy() then
      status = "busy"
    elseif agent and agent:needsUser() then
      status = "waiting"
    end
  end
  noctalia.state.set("status", status)
end

local function loadConfig()
  local raw = noctalia.readFile(CONFIG_PATH)
  if raw == nil then
    config, configNotice = nil, nil
    return
  end
  local cfg, err = Config.decode(raw, noctalia.json)
  config = cfg
  if cfg then
    configNotice = nil
  else
    configNotice = "Your saved settings could not be used (" .. tostring(err) .. "). Save new ones to replace them."
  end
end

local function makeAgent()
  lastStatus = "idle"
  agent = Agent.new({
    provider = PROVIDERS[config.provider],
    tools = Tools,
    redact = Redact,
    json = noctalia.json,
    config = config,
    system = SYSTEM_PROMPT,
    home = HOME,
    protected = { DATA_DIR },
    io = {
      home = HOME,
      run = noctalia.runAsync,
      readFile = noctalia.readFile,
      writeFile = noctalia.writeFile,
      expandPath = noctalia.expandPath,
    },
    transport = function(req, onLine, onClose)
      return noctalia.httpStream(req, onLine, onClose)
    end,
    onChange = function(a)
      -- Back to idle: re-create the composer (it was disabled) so it takes focus.
      if lastStatus ~= "idle" and a.status == "idle" then
        composerRev += 1
      end
      lastStatus = a.status
      render()
      publishStatus()
    end,
  })
end

local function providerKey()
  return Config.PROVIDERS[form.providerIndex + 1]
end

local function openSetup()
  view = "setup"
  local current = config or { provider = "openai", host = Config.DEFAULT_HOSTS.openai, model = "", token = "" }
  form.providerIndex = current.provider == "anthropic" and 1 or 0
  form.host, form.model, form.token = current.host, current.model, current.token
  form.error, form.saving = nil, false
  form.saveGen += 1 -- a test request still in flight belongs to an earlier visit
  form.rev += 1
end

local function onProvider(index)
  local old = providerKey()
  form.providerIndex = tonumber(index) or 0
  local new = providerKey()
  if form.host == "" or form.host == Config.DEFAULT_HOSTS[old] then
    form.host = Config.DEFAULT_HOSTS[new]
    form.rev += 1 -- re-key the inputs so they pick up the new host
  end
  render()
end

local function save()
  if form.saving then
    return
  end
  local cfg = Config.normalize({ provider = providerKey(), host = form.host, model = form.model, token = form.token })
  local errors = Config.validate(cfg)
  if #errors > 0 then
    form.error = table.concat(errors, "\n")
    render()
    return
  end
  form.saving, form.error = true, nil
  form.saveGen += 1
  local gen = form.saveGen
  render()
  local started = noctalia.http(PROVIDERS[cfg.provider].testRequest(cfg, noctalia.json), function(res)
    -- The user cancelled (or left and reopened setup): drop the result.
    if gen ~= form.saveGen or view ~= "setup" then
      return
    end
    form.saving = false
    local status = res.status or 0
    if not res.ok or status >= 400 then
      -- Some providers echo the request back; never show the token.
      form.error = "Test request failed. "
        .. Redact.scrubLiterals(Agent.errorMessage(status, res.body or "", noctalia.json), { cfg.token })
      render()
      return
    end
    local ok, err = noctalia.writeFile(CONFIG_PATH, Config.encode(cfg, noctalia.json))
    if not ok then
      form.error = "Could not save settings: " .. tostring(err)
      render()
      return
    end
    if agent then
      agent:stop()
    end
    config, configNotice = cfg, nil
    makeAgent()
    expanded, fullShown = {}, {}
    view = "chat"
    composerRev += 1
    render()
    publishStatus()
  end)
  if not started then
    form.saving = false
    form.error = "Could not start the test request."
    render()
  end
end

-- Tool text (what the user approves, reviews or sent) is shown verbatim in
-- plain monospace labels, never shortened. Noctalia's text renderer caps a
-- wrapped label at 500 lines and ellipsizes the rest (kHardMaxLines in
-- cairo_text_renderer.cpp), so the text is split across labels that each stay
-- well under that cap. The column budget is conservative (about 57 monospace
-- columns fit at 14px in MONO_WIDTH), leaving room for word wrapping and a
-- larger font scale.
local MONO_WIDTH = 480
local RENDER_LINE_CAP = 500
local CHUNK_COLS = 40
local CHUNK_ROWS = 300

-- Display cells of a byte at the start of a character: tabs count 8, ASCII 1,
-- other characters 2 (wide scripts); UTF-8 continuation bytes count 0.
local function byteCells(b)
  if b == 9 then
    return 8
  elseif b < 0x80 then
    return 1
  elseif b >= 0xC0 then
    return 2
  end
  return 0
end

local function textChunks(s)
  local out, cur, rows = {}, {}, 0
  local maxCells = CHUNK_ROWS * CHUNK_COLS
  local function flush()
    if #cur > 0 then
      table.insert(out, table.concat(cur, "\n"))
      cur, rows = {}, 0
    end
  end
  for line in string.gmatch(s .. "\n", "(.-)\n") do
    local n = 0
    for i = 1, #line do
      n += byteCells(string.byte(line, i))
    end
    if n > maxCells then
      -- One line too long for a label: split it at character boundaries.
      flush()
      local start, acc = 1, 0
      for i = 1, #line do
        local w = byteCells(string.byte(line, i))
        if w > 0 and acc + w > maxCells then
          table.insert(out, string.sub(line, start, i - 1))
          start, acc = i, 0
        end
        acc += w
      end
      table.insert(cur, string.sub(line, start))
      rows = math.max(1, math.ceil(acc / CHUNK_COLS))
    else
      local r = math.max(1, math.ceil(n / CHUNK_COLS))
      if rows + r > CHUNK_ROWS then
        flush()
      end
      table.insert(cur, line)
      rows += r
    end
  end
  flush()
  return out
end

local function monoText(s)
  local labels = {}
  for i, part in ipairs(textChunks(s or "")) do
    labels[i] = ui.label({ text = part, fontFamily = "monospace", maxWidth = MONO_WIDTH, maxLines = RENDER_LINE_CAP })
  end
  return ui.column({ gap = 0 }, labels)
end

local function field(label, child)
  return ui.column({ gap = 4 }, {
    ui.label({ text = label, fontSize = 12, color = "on_surface_variant" }),
    child,
  })
end

local function renderSetup()
  local provider = providerKey()
  local children = {
    ui.label({ text = "Set up your agent", fontSize = 16, fontWeight = "bold", color = "primary" }),
    ui.markdown({ text = "Connect an LLM. These settings stay on this computer, readable only by you." }),
  }
  if configNotice then
    table.insert(children, ui.label({ text = configNotice, color = "error", maxWidth = 500 }))
  end
  table.insert(children, field("Provider", ui.select({
    options = { Config.LABELS.openai, Config.LABELS.anthropic },
    selectedIndex = form.providerIndex,
    onChange = onProvider,
  })))
  table.insert(children, field("Host URL", ui.input({
    key = "host-" .. form.rev,
    value = form.host,
    placeholder = Config.DEFAULT_HOSTS[provider],
    onChange = function(v)
      form.host = v
    end,
  })))
  table.insert(children, field("Model", ui.input({
    key = "model-" .. form.rev,
    value = form.model,
    placeholder = Config.MODEL_HINTS[provider],
    onChange = function(v)
      form.model = v
    end,
  })))
  table.insert(children, field(provider == "anthropic" and "API token" or "API token (optional for local servers)", ui.input({
    key = "token-" .. form.rev,
    value = form.token,
    password = true,
    onChange = function(v)
      form.token = v
    end,
    onSubmit = save,
  })))
  table.insert(children, ui.markdown({ text = "_" .. LIMITS_TEXT .. "_" }))
  if form.error then
    table.insert(children, ui.label({ text = form.error, color = "error", maxWidth = 500 }))
  end
  local buttons = { ui.spacer({ flexGrow = 1 }) }
  if config then
    table.insert(buttons, ui.button({
      text = "Cancel",
      variant = "ghost",
      onClick = function()
        form.saving = false
        form.saveGen += 1
        view = "chat"
        render()
      end,
    }))
  end
  table.insert(buttons, ui.button({
    text = form.saving and "Testing…" or "Save",
    variant = "primary",
    enabled = not form.saving,
    onClick = save,
  }))
  table.insert(children, ui.row({ gap = 8, align = "center" }, buttons))
  return ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 12, padding = 16 }, children) })
end

local function toolCard(item)
  local flagged = item.rule ~= nil
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = item.glyph or "tool", size = 16, color = flagged and "error" or "primary" }),
      ui.label({ text = item.title or item.name, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = STATE_LABELS[item.state] or item.state, fontSize = 12, color = "on_surface_variant" }),
    }),
    monoText(item.body),
  }
  if item.state == "refused" then
    table.insert(rows, ui.label({ text = "Refused automatically: protected location (" .. item.rule .. ").", color = "error", maxWidth = 480 }))
  elseif item.state == "invalid" then
    table.insert(rows, ui.label({ text = item.sent, color = "error", maxWidth = 480 }))
  elseif flagged then
    table.insert(rows, ui.label({ text = "Sensitive location: " .. item.rule .. ". Its output will be held for your review.", color = "error", maxWidth = 480 }))
  end

  if item.state == "pending" then
    local buttons = {
      ui.button({ text = "Run", glyph = "player-play", variant = "primary", onClick = function() agent:approve(item.id) end }),
      ui.button({ text = "Skip", variant = "outline", onClick = function() agent:skip(item.id) end }),
    }
    if item.canTerminal then
      table.insert(buttons, ui.button({
        text = "Open in terminal",
        variant = "ghost",
        onClick = function()
          if noctalia.runInTerminal(item.args.command) then
            agent:handOff(item.id)
          else
            noctalia.notifyError("Could not open a terminal", "Set $TERMINAL or install a terminal emulator. The command was not run.")
          end
        end,
      }))
    end
    table.insert(rows, ui.row({ gap = 8 }, buttons))
  elseif item.state == "review" then
    local reason = #item.kinds > 0 and ("Possible secrets found: " .. table.concat(item.kinds, ", ") .. ".") or "Output from a sensitive location."
    table.insert(rows, ui.label({ text = reason .. " Choose what the model receives. Redacted version:", maxWidth = 480 }))
    table.insert(rows, monoText(item.scrubbed))
    local showFull = fullShown[item.id] == true
    table.insert(rows, ui.button({
      text = showFull and "Hide full output" or "Show full output",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        fullShown[item.id] = not showFull
        render()
      end,
    }))
    if showFull then
      table.insert(rows, ui.label({ text = "Full output (what Send full sends):", maxWidth = MONO_WIDTH }))
      table.insert(rows, monoText(item.output))
    end
    table.insert(rows, ui.row({ gap = 8 }, {
      ui.button({ text = "Send redacted", variant = "primary", onClick = function() agent:decide(item.id, "redacted") end }),
      ui.button({ text = "Send full", variant = "destructive", onClick = function() agent:decide(item.id, "full") end }),
      ui.button({ text = "Don't send", variant = "outline", onClick = function() agent:decide(item.id, "withhold") end }),
    }))
  elseif item.sent and item.state ~= "invalid" and item.state ~= "refused" then
    local open = expanded[item.id] == true
    table.insert(rows, ui.button({
      text = open and "Hide what was sent" or "Show what was sent",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        expanded[item.id] = not open
        render()
      end,
    }))
    if open then
      table.insert(rows, monoText(item.sent))
    end
  end

  return ui.column({
    key = "item-" .. item.id,
    gap = 8,
    padding = 10,
    radius = 10,
    fill = "surface_container_high",
    border = flagged and "error" or nil,
    borderWidth = flagged and 1 or nil,
  }, rows)
end

local function messageNode(item, isLast)
  if item.kind == "user" then
    return ui.column({ key = "item-" .. item.id, padding = 10, radius = 10, fill = "primary_container" }, {
      ui.markdown({ text = item.text }),
    })
  elseif item.kind == "assistant" then
    return ui.column({ key = "item-" .. item.id, paddingH = 2 }, {
      ui.markdown({ text = item.text ~= "" and item.text or "…" }),
    })
  elseif item.kind == "tool" then
    return toolCard(item)
  elseif item.kind == "error" then
    local buttons = {}
    if isLast and item.retry and agent.status == "idle" then
      table.insert(buttons, ui.button({ text = "Retry", variant = "primary", onClick = function() agent:retry() end }))
    end
    if item.auth then
      table.insert(buttons, ui.button({ text = "Check settings", variant = "outline", onClick = function()
        openSetup()
        render()
      end }))
    end
    return ui.column({ key = "item-" .. item.id, gap = 8, padding = 10, radius = 10, fill = "error_container" }, {
      ui.label({ text = Redact.scrubLiterals(item.text, { config.token }), color = "on_error_container", maxWidth = 480 }),
      ui.row({ gap = 8 }, buttons),
    })
  end
  local children = { ui.label({ text = item.text, fontSize = 12, color = "on_surface_variant", maxWidth = 480 }) }
  if isLast and agent.status == "limit" then
    table.insert(children, ui.button({ text = "Continue", variant = "primary", onClick = function() agent:continue() end }))
  end
  return ui.column({ key = "item-" .. item.id, gap = 6 }, children)
end

local function submit(text)
  text = text or draft
  if agent:send(text) then
    draft = ""
    composerRev += 1
    scrollRev += 1
    render()
  end
end

local function newChat()
  agent:newChat()
  expanded, fullShown = {}, {}
  draft = ""
  composerRev += 1
  render()
  publishStatus()
end

local function renderChat()
  local local_ = Config.isLoopback(config.host)
  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "robot", size = 18, color = "primary" }),
    ui.label({ text = "Agent", fontWeight = "bold" }),
    ui.label({ text = Config.destination(config) .. " · " .. config.model, fontSize = 12, color = local_ and "primary" or "tertiary" }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ glyph = "plus", variant = "ghost", tooltip = "New chat", onClick = newChat }),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = "Settings", onClick = function()
      openSetup()
      render()
    end }),
    ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = function() panel.close() end }),
  })

  local nodes = {}
  if #agent.items == 0 then
    table.insert(nodes, ui.markdown({ text = "Ask me to do something on this computer, for example "
      .. "*\"move Firefox to workspace 2\"* or *\"why is my disk full?\"*. "
      .. "I propose each command and wait for you to approve it." }))
  end
  for i, item in ipairs(agent.items) do
    table.insert(nodes, messageNode(item, i == #agent.items))
  end

  local footer = {}
  if agent:isBusy() then
    table.insert(footer, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = agent.status == "streaming" and "Thinking…" or "Running…", color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ text = "Stop", glyph = "player-stop", variant = "destructive", controlSize = "sm", tooltip = STOP_TOOLTIP, onClick = function() agent:stop() end }),
    }))
  elseif agent:needsUser() then
    table.insert(footer, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Waiting for you.", color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ text = "Stop", variant = "outline", controlSize = "sm", tooltip = STOP_TOOLTIP, onClick = function() agent:stop() end }),
    }))
  end
  local idle = agent.status == "idle"
  table.insert(footer, ui.input({
    key = "composer-" .. composerRev,
    value = draft, -- seeds a re-created composer, so unsent text survives close/open
    multiline = true,
    submitOnEnter = true,
    height = 76,
    focus = true,
    enabled = idle,
    placeholder = idle and "Ask the agent… (Enter sends, Shift+Enter adds a line)" or "Waiting for the current request…",
    onChange = function(v)
      draft = v
    end,
    onSubmit = submit,
  }))

  return ui.column({ gap = 10, padding = 12, flexGrow = 1 }, {
    header,
    ui.separator({}),
    ui.scroll({ flexGrow = 1, gap = 10, stickToBottom = true, scrollToBottomRev = scrollRev }, nodes),
    ui.column({ gap = 8 }, footer),
  })
end

render = function()
  if view == "setup" or config == nil or agent == nil then
    panel.render(renderSetup())
  else
    panel.render(renderChat())
  end
end

function onOpen(_context)
  local hadConfig = config ~= nil
  if not hadConfig then
    loadConfig()
  end
  if config == nil then
    if view ~= "setup" or form.rev == 0 then
      openSetup()
    end
  else
    if agent == nil then
      makeAgent()
    end
    -- Stay in setup only if the user opened it over a working config;
    -- a config that appeared since the last open shows the chat.
    if not (view == "setup" and hadConfig) then
      view = "chat"
    end
  end
  render()
  publishStatus()
end

loadConfig()
if config then
  view = "chat"
  makeAgent()
end
publishStatus()

-- The runtime is going away: drop the published status so the bar icon
-- falls back to checking the saved settings instead of showing a stale state.
function onExit(_signal, _reason)
  noctalia.state.set("status", nil)
end
