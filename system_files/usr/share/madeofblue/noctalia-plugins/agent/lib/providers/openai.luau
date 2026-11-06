--!nonstrict
-- OpenAI-compatible Chat Completions adapter (OpenAI, Ollama, LM Studio,
-- OpenRouter, vLLM, ...). Pure module: no require, no noctalia.*.
local M = {}

local function headers(cfg)
  local h = { "Content-Type: application/json", "Accept: text/event-stream" }
  if cfg.token ~= "" then
    table.insert(h, "Authorization: Bearer " .. cfg.token)
  end
  return h
end

function M.toWire(system, history)
  local msgs = { { role = "system", content = system } }
  for _, m in ipairs(history) do
    if m.role == "user" then
      table.insert(msgs, { role = "user", content = m.text })
    elseif m.role == "assistant" then
      local msg = { role = "assistant", content = m.text }
      if m.toolCalls and #m.toolCalls > 0 then
        msg.tool_calls = {}
        for _, c in ipairs(m.toolCalls) do
          table.insert(msg.tool_calls, { id = c.id, type = "function", ["function"] = { name = c.name, arguments = c.argsJson } })
        end
      end
      table.insert(msgs, msg)
    elseif m.role == "tool_results" then
      for _, r in ipairs(m.results) do
        table.insert(msgs, { role = "tool", tool_call_id = r.id, content = r.content })
      end
    end
  end
  return msgs
end

function M.buildRequest(cfg, system, history, schemas, json)
  local tools = {}
  for _, s in ipairs(schemas) do
    table.insert(tools, { type = "function", ["function"] = { name = s.name, description = s.description, parameters = s.parameters } })
  end
  return {
    url = cfg.host .. "/chat/completions",
    method = "POST",
    headers = headers(cfg),
    body = json.encode({ model = cfg.model, stream = true, messages = M.toWire(system, history), tools = tools }),
  }
end

function M.testRequest(cfg, json)
  return {
    url = cfg.host .. "/chat/completions",
    method = "POST",
    headers = headers(cfg),
    body = json.encode({ model = cfg.model, messages = { { role = "user", content = "Reply with OK." } } }),
  }
end

function M.newStream(json)
  return { json = json, text = "", calls = {}, order = {}, error = nil }
end

function M.applyEvent(st, ev)
  if type(ev.error) == "table" then
    st.error = ev.error.message or "the provider reported an error"
    return
  elseif type(ev.error) == "string" then
    st.error = ev.error
    return
  end
  local choice = type(ev.choices) == "table" and ev.choices[1] or nil
  if not choice then
    return
  end
  local delta = choice.delta or {}
  if type(delta.content) == "string" then
    st.text ..= delta.content
  end
  for _, tc in ipairs(delta.tool_calls or {}) do
    local idx = tc.index or 0
    local call = st.calls[idx]
    if not call then
      call = { id = "", name = "", argsJson = "" }
      st.calls[idx] = call
      table.insert(st.order, idx)
    end
    if type(tc.id) == "string" and tc.id ~= "" then
      call.id = tc.id
    end
    local fn = tc["function"]
    if fn then
      if type(fn.name) == "string" and fn.name ~= "" and call.name == "" then
        call.name = fn.name
      end
      if type(fn.arguments) == "string" then
        call.argsJson ..= fn.arguments
      elseif type(fn.arguments) == "table" then
        call.argsJson = st.json.encode(fn.arguments)
      end
    end
  end
end

function M.finish(st)
  local calls = {}
  for _, idx in ipairs(st.order) do
    local c = st.calls[idx]
    table.insert(calls, {
      id = c.id ~= "" and c.id or ("call_" .. tostring(idx)),
      name = c.name,
      argsJson = c.argsJson ~= "" and c.argsJson or "{}",
    })
  end
  return { text = st.text, toolCalls = calls }
end

return M
