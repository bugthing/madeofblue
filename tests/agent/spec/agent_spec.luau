--!nonstrict
local T = require("../support/t")
local json = require("../support/json")
local Agent = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/agent")
local OpenAI = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/providers/openai")
local Anthropic = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/providers/anthropic")
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

local function setup(provider)
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
    provider = provider or OpenAI,
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

  T.it("refuses file tools whose path resolves into a protected location", function()
    local h = setup()
    h.agent:send("read it")
    h.reply({ call("c1", "read_file", '{"path":"~/.local/state/x/../agent/config.json"}') })
    T.eq(h.lastTool().state, "refused")
    T.eq(h.lastTool().rule, "agent settings")
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

  T.it("redacts a private key whose END line falls in the truncated middle", function()
    local h = setup()
    h.agent:send("show")
    h.reply({ call("c1", "run_command", '{"command":"cat x"}') })
    local item = h.lastTool()
    h.agent:approve(item.id)
    local body = string.rep("a", 7000)
      .. "\n-----BEGIN OPENSSH PRIVATE KEY-----\n"
      .. string.rep("KEYBODY", 1200)
      .. "\n-----END OPENSSH PRIVATE KEY-----\n"
      .. string.rep("c", 20000)
    h.runs[1].cb({ exitCode = 0, stdout = body, stderr = "" })
    T.eq(item.state, "review")
    T.eq(item.kinds[1], "private-key")
    T.notContains(item.scrubbed, "KEYBODY")
    T.contains(item.scrubbed, "[REDACTED:private-key]")
    h.agent:decide(item.id, "redacted")
    T.notContains(h.requests[#h.requests].req.body, "KEYBODY")
  end)

  T.it("redacts tokens that straddle the truncation cut", function()
    -- The first 8192 bytes of the formatted output are kept; prefix is the
    -- "exit code: 0\nstdout:\n" header.
    local header = #"exit code: 0\nstdout:\n"
    local ghp = "ghp_" .. string.rep("Z", 36)
    local h = setup()
    h.agent:send("show")
    h.reply({ call("c1", "run_command", '{"command":"cat x"}') })
    local item = h.lastTool()
    h.agent:approve(item.id)
    local body = string.rep("a", Tools.OUTPUT_KEEP - header - 11) .. " " .. ghp .. " " .. string.rep("q", 30000)
    h.runs[1].cb({ exitCode = 0, stdout = body, stderr = "" })
    T.eq(item.state, "review")
    T.notContains(item.scrubbed, "ghp_")
    h.agent:decide(item.id, "redacted")
    T.notContains(h.requests[#h.requests].req.body, "ghp_")

    h = setup()
    h.agent:send("show")
    h.reply({ call("c1", "run_command", '{"command":"cat x"}') })
    item = h.lastTool()
    h.agent:approve(item.id)
    body = string.rep("a", Tools.OUTPUT_KEEP - header - 10) .. TOKEN .. string.rep("q", 30000)
    h.runs[1].cb({ exitCode = 0, stdout = body, stderr = "" })
    T.eq(item.state, "review")
    h.agent:decide(item.id, "full")
    T.notContains(h.requests[#h.requests].req.body, "tok-SECR")
  end)

  T.it("never splits a UTF-8 character when truncating", function()
    local h = setup()
    h.agent:send("show")
    h.reply({ call("c1", "run_command", '{"command":"cat x"}') })
    local item = h.lastTool()
    h.agent:approve(item.id)
    local header = #"exit code: 0\nstdout:\n"
    local body = string.rep("a", Tools.OUTPUT_KEEP - header - 1) .. "é" .. string.rep("x", 20000) .. "é" .. string.rep("y", Tools.OUTPUT_KEEP - 1)
    h.runs[1].cb({ exitCode = 0, stdout = body, stderr = "" })
    T.contains(item.sent, "bytes truncated")
    T.truthy(utf8.len(item.sent) ~= nil, "sent output is valid UTF-8")
    T.truthy(utf8.len(item.scrubbed) ~= nil, "scrubbed output is valid UTF-8")
    T.truthy(utf8.len(item.output) ~= nil, "full output is valid UTF-8")
  end)

  T.it("removes the token from every request body, whatever its source", function()
    local h = setup()
    h.agent.deps.system = "sys " .. TOKEN
    table.insert(h.agent.history, { role = "assistant", text = "echo " .. TOKEN })
    h.agent:send("hi")
    T.notContains(h.requests[1].req.body, TOKEN)
    T.contains(h.requests[1].req.body, "[REDACTED:agent-token]")
    T.contains(table.concat(h.requests[1].req.headers, "\n"), "Bearer " .. TOKEN, "headers keep the token")
  end)

  T.it("runs a tool round trip through the Anthropic adapter", function()
    local h = setup(Anthropic)
    h.agent:send("what windows are open?")
    T.contains(h.requests[1].req.url, "/v1/messages")
    h.reply({
      "event: message_start",
      sse({ type = "message_start", message = { id = "msg_1", role = "assistant" } }),
      "event: content_block_start",
      sse({ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } }),
      sse({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "Checking." } }),
      sse({ type = "content_block_stop", index = 0 }),
      sse({ type = "content_block_start", index = 1, content_block = { type = "tool_use", id = "toolu_1", name = "run_command", input = {} } }),
      sse({ type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '{"command":' } }),
      sse({ type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '"niri msg -j windows"}' } }),
      sse({ type = "content_block_stop", index = 1 }),
      sse({ type = "message_delta", delta = { stop_reason = "tool_use" } }),
      sse({ type = "message_stop" }),
    })
    local item = h.lastTool()
    T.eq(item.state, "pending")
    T.eq(item.args.command, "niri msg -j windows")
    h.agent:approve(item.id)
    h.runs[1].cb({ exitCode = 0, stdout = "[]", stderr = "" })
    T.eq(#h.requests, 2)
    local msgs = h.body().messages
    T.eq(#msgs, 3)
    T.eq(msgs[2].role, "assistant")
    T.eq(msgs[2].content[1].text, "Checking.")
    T.eq(msgs[2].content[2].type, "tool_use")
    T.eq(msgs[2].content[2].id, "toolu_1")
    T.eq(msgs[2].content[2].input.command, "niri msg -j windows")
    T.eq(msgs[3].role, "user")
    T.eq(msgs[3].content[1].type, "tool_result")
    T.eq(msgs[3].content[1].tool_use_id, "toolu_1")
    T.contains(msgs[3].content[1].content, "exit code: 0")
    h.reply({
      sse({ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } }),
      sse({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "None." } }),
      sse({ type = "message_delta", delta = { stop_reason = "end_turn" } }),
    })
    T.eq(h.agent.status, "idle")
    T.eq(h.lastItem().text, "None.")
  end)

  T.it("returns a mixed batch's results in call order", function()
    local h = setup()
    h.agent:send("go")
    h.reply({ sse({ choices = { { delta = { tool_calls = {
      { index = 0, id = "c1", ["function"] = { name = "run_command", arguments = '{"command":"uptime"}' } },
      { index = 1, id = "c2", ["function"] = { name = "run_command", arguments = '{"command":"rm -rf ~/tmp"}' } },
      { index = 2, id = "c3", ["function"] = { name = "read_file", arguments = '{"path":"/etc/shadow"}' } },
    } } } } }) })
    local items = {}
    for _, it in ipairs(h.agent.items) do
      if it.kind == "tool" then
        table.insert(items, it)
      end
    end
    T.eq(#items, 3)
    T.eq(items[3].state, "refused")
    h.agent:skip(items[2].id)
    T.eq(#h.requests, 1, "waits for the approved call")
    h.agent:approve(items[1].id)
    h.runs[1].cb({ exitCode = 0, stdout = "up 1 day", stderr = "" })
    T.eq(#h.requests, 2)
    local results = h.agent.history[#h.agent.history].results
    T.eq(#results, 3)
    T.eq(results[1].id, "c1")
    T.contains(results[1].content, "up 1 day")
    T.eq(results[2].id, "c2")
    T.contains(results[2].content, "declined")
    T.eq(results[3].id, "c3")
    T.contains(results[3].content, "refused")
    local msgs = h.body().messages
    T.eq(msgs[4].tool_call_id, "c1")
    T.eq(msgs[5].tool_call_id, "c2")
    T.eq(msgs[6].tool_call_id, "c3")
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
