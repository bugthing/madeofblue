--!nonstrict
local T = require("../support/t")
local json = require("../support/json")
local OpenAI = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/providers/openai")

local CFG = { provider = "openai", host = "https://api.example.com/v1", model = "m1", token = "tok" }
local SCHEMAS = { { name = "run_command", description = "d", parameters = { type = "object", properties = { command = { type = "string" } }, required = { "command" } } } }
local HISTORY = {
  { role = "user", text = "hi" },
  { role = "assistant", text = "", toolCalls = { { id = "c1", name = "run_command", argsJson = '{"command":"ls"}' } } },
  { role = "tool_results", results = { { id = "c1", name = "run_command", content = "exit code: 0" } } },
}

T.describe("openai adapter", function()
  T.it("builds a streaming chat-completions request", function()
    local req = OpenAI.buildRequest(CFG, "sys", HISTORY, SCHEMAS, json)
    T.eq(req.url, "https://api.example.com/v1/chat/completions")
    T.eq(req.method, "POST")
    T.contains(table.concat(req.headers, "\n"), "Authorization: Bearer tok")
    local body = json.decode(req.body)
    T.eq(body.model, "m1")
    T.eq(body.stream, true)
    T.eq(body.messages[1].role, "system")
    T.eq(body.messages[2].content, "hi")
    T.eq(body.messages[3].tool_calls[1]["function"].arguments, '{"command":"ls"}')
    T.eq(body.messages[4].role, "tool")
    T.eq(body.messages[4].tool_call_id, "c1")
    T.eq(body.tools[1]["function"].name, "run_command")
  end)

  T.it("omits Authorization without a token", function()
    local req = OpenAI.buildRequest({ host = "http://localhost:11434/v1", model = "m", token = "" }, "s", {}, SCHEMAS, json)
    T.notContains(table.concat(req.headers, "\n"), "Authorization")
  end)

  T.it("assembles streamed text and tool calls", function()
    local st = OpenAI.newStream(json)
    OpenAI.applyEvent(st, { choices = { { delta = { content = "Hel" } } } })
    OpenAI.applyEvent(st, { choices = { { delta = { content = "lo" } } } })
    OpenAI.applyEvent(st, { choices = { { delta = { tool_calls = { { index = 0, id = "c9", ["function"] = { name = "run_command", arguments = '{"comm' } } } } } } })
    OpenAI.applyEvent(st, { choices = { { delta = { tool_calls = { { index = 0, ["function"] = { arguments = 'and":"ls"}' } } } }, finish_reason = "tool_calls" } } })
    local reply = OpenAI.finish(st)
    T.eq(reply.text, "Hello")
    T.eq(#reply.toolCalls, 1)
    T.eq(reply.toolCalls[1].id, "c9")
    T.eq(reply.toolCalls[1].name, "run_command")
    T.eq(reply.toolCalls[1].argsJson, '{"command":"ls"}')
  end)

  T.it("accepts arguments sent as an object and fills missing ids", function()
    local st = OpenAI.newStream(json)
    OpenAI.applyEvent(st, { choices = { { delta = { tool_calls = { { index = 0, ["function"] = { name = "read_file", arguments = { path = "/x" } } } } } } } })
    local call = OpenAI.finish(st).toolCalls[1]
    T.eq(call.id, "call_0")
    T.eq(json.decode(call.argsJson).path, "/x")
  end)

  T.it("records in-stream errors", function()
    local st = OpenAI.newStream(json)
    OpenAI.applyEvent(st, { error = { message = "overloaded" } })
    T.eq(st.error, "overloaded")
  end)

  T.it("builds a non-streaming test request", function()
    local body = json.decode(OpenAI.testRequest(CFG, json).body)
    T.eq(body.model, "m1")
    T.eq(body.stream, nil)
  end)
end)

return true
