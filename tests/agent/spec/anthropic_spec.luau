--!nonstrict
local T = require("../support/t")
local json = require("../support/json")
local Anthropic = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/providers/anthropic")

local CFG = { provider = "anthropic", host = "https://api.anthropic.com", model = "claude-x", token = "tok" }
local SCHEMAS = { { name = "run_command", description = "d", parameters = { type = "object", properties = { command = { type = "string" } }, required = { "command" } } } }

T.describe("anthropic adapter", function()
  T.it("builds a streaming messages request", function()
    local history = {
      { role = "user", text = "hi" },
      { role = "assistant", text = "Checking.", toolCalls = { { id = "t1", name = "run_command", argsJson = '{"command":"ls"}' } } },
      { role = "tool_results", results = { { id = "t1", name = "run_command", content = "exit code: 0" } } },
      { role = "user", text = "thanks" },
    }
    local req = Anthropic.buildRequest(CFG, "sys", history, SCHEMAS, json)
    T.eq(req.url, "https://api.anthropic.com/v1/messages")
    local h = table.concat(req.headers, "\n")
    T.contains(h, "x-api-key: tok")
    T.contains(h, "anthropic-version: 2023-06-01")
    local body = json.decode(req.body)
    T.eq(body.system, "sys")
    T.eq(body.stream, true)
    T.eq(body.tools[1].input_schema.type, "object")
    T.eq(#body.messages, 3, "tool results and the next user text merge into one user turn")
    T.eq(body.messages[2].content[2].type, "tool_use")
    T.eq(body.messages[2].content[2].input.command, "ls")
    T.eq(body.messages[3].content[1].type, "tool_result")
    T.eq(body.messages[3].content[1].tool_use_id, "t1")
    T.eq(body.messages[3].content[2].text, "thanks")
  end)

  T.it("drops whitespace-only assistant text, which the API rejects", function()
    local history = {
      { role = "user", text = "hi" },
      { role = "assistant", text = "\n ", toolCalls = { { id = "t1", name = "read_file", argsJson = '{"path":"/x"}' } } },
      { role = "tool_results", results = { { id = "t1", name = "read_file", content = "ok" } } },
      { role = "assistant", text = "  ", toolCalls = {} },
    }
    local msgs = Anthropic.toWire(history, json)
    T.eq(#msgs[2].content, 1)
    T.eq(msgs[2].content[1].type, "tool_use")
    T.eq(msgs[4].content[1].text, "(no reply)")
  end)

  T.it("assembles streamed text and tool calls", function()
    local st = Anthropic.newStream(json)
    Anthropic.applyEvent(st, { type = "message_start" })
    Anthropic.applyEvent(st, { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } })
    Anthropic.applyEvent(st, { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "Let me look." } })
    Anthropic.applyEvent(st, { type = "content_block_start", index = 1, content_block = { type = "tool_use", id = "t7", name = "read_file", input = {} } })
    Anthropic.applyEvent(st, { type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '{"pa' } })
    Anthropic.applyEvent(st, { type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = 'th":"/etc/hosts"}' } })
    Anthropic.applyEvent(st, { type = "message_delta", delta = { stop_reason = "tool_use" } })
    local reply = Anthropic.finish(st)
    T.eq(reply.text, "Let me look.")
    T.eq(reply.toolCalls[1].id, "t7")
    T.eq(reply.toolCalls[1].argsJson, '{"path":"/etc/hosts"}')
  end)

  T.it("separates consecutive text blocks", function()
    local st = Anthropic.newStream(json)
    Anthropic.applyEvent(st, { type = "content_block_start", index = 0, content_block = { type = "text" } })
    Anthropic.applyEvent(st, { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "A" } })
    Anthropic.applyEvent(st, { type = "content_block_start", index = 1, content_block = { type = "text" } })
    Anthropic.applyEvent(st, { type = "content_block_delta", index = 1, delta = { type = "text_delta", text = "B" } })
    T.eq(Anthropic.finish(st).text, "A\n\nB")
  end)

  T.it("records stream errors", function()
    local st = Anthropic.newStream(json)
    Anthropic.applyEvent(st, { type = "error", error = { type = "overloaded_error", message = "Overloaded" } })
    T.eq(st.error, "Overloaded")
  end)

  T.it("builds a small test request", function()
    local body = json.decode(Anthropic.testRequest(CFG, json).body)
    T.eq(body.max_tokens, 16)
    T.eq(body.stream, nil)
  end)
end)

return true
