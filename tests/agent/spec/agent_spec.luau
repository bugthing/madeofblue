--!nonstrict
local T = require("../support/t")
local json = require("../support/json")
local Agent = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/agent")
local OpenAI = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/providers/openai")
local Tools = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/tools")
local Redact = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/redact")

local TOKEN = "tok-SECRET-123456"

local function sse(t)
  return "data: " .. json.encode(t)
end
local function text(s)
  return sse({ choices = { { delta = { content = s } } } })
end
local function call(id, name, args)
  return sse({ choices = { { delta = { tool_calls = { { index = 0, id = id, ["function"] = { name = name, arguments = args } } } } } } })
end

local function setup()
  local h = { requests = {}, runs = {} }
  local io = {
    home = "/home/u",
    expandPath = function(p)
      return (string.gsub(p, "^~", "/home/u"))
    end,
    run = function(argv, cb)
      table.insert(h.runs, { argv = argv, cb = cb })
      return true
    end,
    readFile = function()
      return nil, "no such file"
    end,
    writeFile = function()
      return true
    end,
  }
  h.agent = Agent.new({
    provider = OpenAI,
    tools = Tools,
    redact = Redact,
    json = json,
    io = io,
    config = { provider = "openai", host = "https://api.example.com/v1", model = "m", token = TOKEN },
    system = "sys",
    home = "/home/u",
    protected = { "/home/u/.local/state/agent" },
    transport = function(req, onLine, onClose)
      local s = { req = req, onLine = onLine, onClose = onClose, stopped = false }
      s.stop = function()
        s.stopped = true
      end
      table.insert(h.requests, s)
      return s
    end,
  })
  function h.reply(lines, status)
    local s = h.requests[#h.requests]
    for _, l in ipairs(lines) do
      s.onLine(l)
    end
    s.onClose({ ok = true, status = status or 200 })
  end
  function h.body(n)
    return json.decode(h.requests[n or #h.requests].req.body)
  end
  function h.lastTool()
    for i = #h.agent.items, 1, -1 do
      if h.agent.items[i].kind == "tool" then
        return h.agent.items[i]
      end
    end
    return nil
  end
  function h.lastItem()
    return h.agent.items[#h.agent.items]
  end
  return h
end

T.describe("agent", function()
  T.it("streams a plain answer and returns to idle", function()
    local h = setup()
    T.eq(h.agent:send("  hello  "), true)
    T.eq(h.agent.status, "streaming")
    T.eq(h.body().messages[2].content, "hello")
    h.reply({ ": keep-alive", "event: x", text("Hi "), text("there"), "data: [DONE]" })
    T.eq(h.agent.status, "idle")
    T.eq(h.lastItem().text, "Hi there")
    T.eq(#h.agent.history, 2)
    T.eq(h.agent:send("again"), true)
  end)

  T.it("ignores empty messages and messages while busy", function()
    local h = setup()
    T.eq(h.agent:send("   "), false)
    h.agent:send("one")
    T.eq(h.agent:send("two"), false)
  end)

  T.it("shows HTTP errors and retries with the same history", function()
    local h = setup()
    h.agent:send("hello")
    h.reply({ '{"error":{"message":"invalid x-api-key"}}' }, 401)
    local item = h.lastItem()
    T.eq(item.kind, "error")
    T.eq(item.text, "HTTP 401: invalid x-api-key")
    T.eq(item.auth, true)
    T.eq(h.agent.status, "idle")
    T.eq(#h.agent.history, 1)
    h.agent:retry()
    T.eq(#h.requests, 2)
    T.eq(h.lastItem().kind, "assistant")
  end)

  T.it("runs an approved command and sends the result back", function()
    local h = setup()
    h.agent:send("what windows are open?")
    h.reply({ call("c1", "run_command", '{"command":"niri msg -j windows"}') })
    local item = h.lastTool()
    T.eq(item.state, "pending")
    T.eq(h.agent.status, "approval")
    T.eq(h.agent:needsUser(), true)
    h.agent:approve(item.id)
    T.eq(item.state, "running")
    T.eq(h.agent:isBusy(), true)
    h.runs[1].cb({ exitCode = 0, stdout = "[]", stderr = "" })
    T.eq(item.state, "done")
    T.eq(#h.requests, 2)
    local msgs = h.body().messages
    T.eq(msgs[4].role, "tool")
    T.eq(msgs[4].tool_call_id, "c1")
    T.contains(msgs[4].content, "exit code: 0")
    h.reply({ text("No windows are open.") })
    T.eq(h.agent.status, "idle")
  end)

  T.it("tells the model when the user skips a call", function()
    local h = setup()
    h.agent:send("delete stuff")
    h.reply({ call("c1", "run_command", '{"command":"rm -rf ~/tmp"}') })
    h.agent:skip(h.lastTool().id)
    T.eq(#h.runs, 0)
    T.contains(h.body().messages[4].content, "declined")
  end)

  T.it("hands a command off to the terminal", function()
    local h = setup()
    h.agent:send("edit")
    h.reply({ call("c1", "run_command", '{"command":"nano x"}') })
    h.agent:handOff(h.lastTool().id)
    T.contains(h.body().messages[4].content, "terminal")
  end)

  T.it("refuses protected paths without asking", function()
    local h = setup()
    h.agent:send("show me /etc/shadow")
    h.reply({ call("c1", "run_command", '{"command":"pkexec cat /etc/shadow"}') })
    T.eq(h.lastTool().state, "refused")
    T.eq(#h.runs, 0)
    T.eq(#h.requests, 2)
    T.contains(h.body().messages[4].content, "refused")
  end)

  T.it("holds output from flagged paths for review", function()
    local h = setup()
    h.agent:send("show my ssh config")
    h.reply({ call("c1", "run_command", '{"command":"cat ~/.ssh/config"}') })
    local item = h.lastTool()
    T.eq(item.rule, "SSH keys")
    h.agent:approve(item.id)
    h.runs[1].cb({ exitCode = 0, stdout = "Host example", stderr = "" })
    T.eq(item.state, "review")
    T.eq(#h.requests, 1)
    h.agent:decide(item.id, "redacted")
    T.eq(#h.requests, 2)
    T.contains(h.body().messages[4].content, "Host example")
  end)

  T.it("holds output containing secrets and can withhold it", function()
    local h = setup()
    h.agent:send("env")
    h.reply({ call("c1", "run_command", '{"command":"printenv"}') })
    local item = h.lastTool()
    h.agent:approve(item.id)
    h.runs[1].cb({ exitCode = 0, stdout = "GITHUB_TOKEN=abc123\nHOME=/home/u", stderr = "" })
    T.eq(item.state, "review")
    T.eq(item.kinds[1], "secret-value")
    T.contains(item.scrubbed, "GITHUB_TOKEN=[REDACTED:secret-value]")
    h.agent:decide(item.id, "withhold")
    T.eq(h.body().messages[4].content, "output withheld by the user")
  end)

  T.it("never sends the agent's own token, even on Send full", function()
    local h = setup()
    h.agent:send("my token is " .. TOKEN)
    T.eq(h.agent.items[2].kind, "notice")
    h.reply({ call("c1", "run_command", '{"command":"printenv"}') })
    local item = h.lastTool()
    h.agent:approve(item.id)
    h.runs[1].cb({ exitCode = 0, stdout = "X=" .. TOKEN, stderr = "" })
    h.agent:decide(item.id, "full")
    for _, s in ipairs(h.requests) do
      T.notContains(s.req.body, TOKEN)
    end
  end)

  T.it("gives up after repeated invalid tool calls", function()
    local h = setup()
    h.agent:send("go")
    for _ = 1, Agent.MAX_INVALID do
      h.reply({ call("c1", "run_command", '{"cmd":"ls"}') })
    end
    T.eq(#h.requests, Agent.MAX_INVALID)
    T.eq(h.agent.status, "idle")
    T.contains(h.lastItem().text, "invalid tool calls")
  end)

  T.it("pauses at the round-trip limit and continues on request", function()
    local saved = Agent.MAX_ROUND_TRIPS
    Agent.MAX_ROUND_TRIPS = 2
    local h = setup()
    h.agent:send("loop")
    h.reply({ call("c1", "read_file", '{"path":"/etc/shadow"}') })
    h.reply({ call("c2", "read_file", '{"path":"/etc/shadow"}') })
    T.eq(h.agent.status, "limit")
    T.eq(#h.requests, 2)
    h.agent:continue()
    T.eq(#h.requests, 3)
    Agent.MAX_ROUND_TRIPS = saved
  end)

  T.it("stops cleanly while waiting for approval", function()
    local h = setup()
    h.agent:send("go")
    h.reply({ call("c1", "run_command", '{"command":"ls"}') })
    local item = h.lastTool()
    h.agent:approve(item.id)
    h.agent:stop()
    T.eq(item.state, "cancelled")
    T.eq(h.agent.status, "idle")
    h.runs[1].cb({ exitCode = 0, stdout = "late", stderr = "" })
    T.eq(item.state, "cancelled")
    T.eq(h.agent.history[#h.agent.history].role, "tool_results")
  end)

  T.it("stops a stream and ignores late lines", function()
    local h = setup()
    h.agent:send("go")
    local s = h.requests[1]
    h.agent:stop()
    T.eq(s.stopped, true)
    s.onLine(text("late"))
    s.onClose({ ok = true, status = 200 })
    T.eq(h.lastItem().text, "Stopped.")
  end)

  T.it("starts a new chat", function()
    local h = setup()
    h.agent:send("go")
    h.agent:newChat()
    T.eq(#h.agent.items, 0)
    T.eq(#h.agent.history, 0)
    T.eq(h.agent.status, "idle")
  end)
end)

return true
