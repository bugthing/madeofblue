--!nonstrict
-- Anthropic Messages API adapter. Pure module: no require, no noctalia.*.
local M = {}

local API_VERSION = "2023-06-01"
local MAX_TOKENS = 4096

local function headers(cfg)
  return {
    "Content-Type: application/json",
    "Accept: text/event-stream",
    "x-api-key: " .. cfg.token,
    "anthropic-version: " .. API_VERSION,
  }
end

-- Anthropic requires alternating roles, so consecutive same-role turns merge.
function M.toWire(history, json)
  local msgs = {}
  local function push(role, blocks)
    local last = msgs[#msgs]
    if last and last.role == role then
      for _, b in ipairs(blocks) do
        table.insert(last.content, b)
      end
    else
      table.insert(msgs, { role = role, content = blocks })
    end
  end
  for _, m in ipairs(history) do
    if m.role == "user" then
      push("user", { { type = "text", text = m.text } })
    elseif m.role == "assistant" then
      local blocks = {}
      if string.find(m.text, "%S") then -- the API rejects whitespace-only text blocks
        table.insert(blocks, { type = "text", text = m.text })
      end
      for _, c in ipairs(m.toolCalls or {}) do
        local ok, input = pcall(json.decode, c.argsJson)
        if not ok or type(input) ~= "table" then
          input = { _raw = c.argsJson }
        elseif next(input) == nil then
          -- An empty Luau table may encode as [], which the API rejects; tools
          -- with no arguments are invalid for us anyway.
          input = { _empty = true }
        end
        table.insert(blocks, { type = "tool_use", id = c.id, name = c.name, input = input })
      end
      if #blocks == 0 then
        table.insert(blocks, { type = "text", text = "(no reply)" })
      end
      push("assistant", blocks)
    elseif m.role == "tool_results" then
      local blocks = {}
      for _, r in ipairs(m.results) do
        table.insert(blocks, { type = "tool_result", tool_use_id = r.id, content = r.content })
      end
      push("user", blocks)
    end
  end
  return msgs
end

function M.buildRequest(cfg, system, history, schemas, json)
  local tools = {}
  for _, s in ipairs(schemas) do
    table.insert(tools, { name = s.name, description = s.description, input_schema = s.parameters })
  end
  return {
    url = cfg.host .. "/v1/messages",
    method = "POST",
    headers = headers(cfg),
    body = json.encode({
      model = cfg.model,
      max_tokens = MAX_TOKENS,
      system = system,
      stream = true,
      tools = tools,
      messages = M.toWire(history, json),
    }),
  }
end

function M.testRequest(cfg, json)
  return {
    url = cfg.host .. "/v1/messages",
    method = "POST",
    headers = headers(cfg),
    body = json.encode({ model = cfg.model, max_tokens = 16, messages = { { role = "user", content = "Reply with OK." } } }),
  }
end

function M.newStream(json)
  return { json = json, text = "", calls = {}, order = {}, error = nil }
end

function M.applyEvent(st, ev)
  local kind = ev.type
  if kind == "error" then
    st.error = (type(ev.error) == "table" and ev.error.message) or "the provider reported an error"
  elseif kind == "content_block_start" then
    local block = ev.content_block or {}
    if block.type == "tool_use" then
      st.calls[ev.index] = { id = block.id or "", name = block.name or "", argsJson = "" }
      table.insert(st.order, ev.index)
    elseif block.type == "text" and st.text ~= "" then
      st.text ..= "\n\n"
    end
  elseif kind == "content_block_delta" then
    local delta = ev.delta or {}
    if delta.type == "text_delta" then
      st.text ..= (delta.text or "")
    elseif delta.type == "input_json_delta" then
      local call = st.calls[ev.index]
      if call then
        call.argsJson ..= (delta.partial_json or "")
      end
    end
  end
end

function M.finish(st)
  local calls = {}
  for _, idx in ipairs(st.order) do
    local c = st.calls[idx]
    table.insert(calls, {
      id = c.id ~= "" and c.id or ("toolu_" .. tostring(idx)),
      name = c.name,
      argsJson = c.argsJson ~= "" and c.argsJson or "{}",
    })
  end
  return { text = st.text, toolCalls = calls }
end

return M
