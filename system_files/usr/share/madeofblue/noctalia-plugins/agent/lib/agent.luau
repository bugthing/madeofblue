--!nonstrict
-- The agent loop: stream a reply, turn tool calls into approval cards, run
-- what the user approves, redact the output, and send results back until the
-- model answers without tool calls.
-- Pure module: every side effect goes through deps (transport, io, onChange).
local Agent = {}
Agent.__index = Agent

Agent.MAX_ROUND_TRIPS = 20
Agent.MAX_INVALID = 3

-- Best human-readable message from an error response body.
function Agent.errorMessage(status, body, json)
  local msg
  local ok, data = pcall(json.decode, body or "")
  if ok and type(data) == "table" then
    if type(data.error) == "table" then
      msg = data.error.message
    elseif type(data.error) == "string" then
      msg = data.error
    end
    msg = msg or data.message
  end
  if type(msg) ~= "string" or msg == "" then
    msg = string.sub(body or "", 1, 300)
  end
  if status and status > 0 then
    return "HTTP " .. status .. ": " .. (msg ~= "" and msg or "request failed")
  end
  return msg ~= "" and msg or "Could not reach the provider."
end

-- deps: provider, tools, redact, json, io, config, system, home, protected,
--       transport(req, onLine, onClose) -> handle with stop(), onChange(agent)?
function Agent.new(deps)
  local self = setmetatable({ deps = deps, gen = 0, nextId = 0 }, Agent)
  self:clear()
  return self
end

function Agent:clear()
  self.history = {}
  self.items = {}
  self.status = "idle"
  self.roundTrips = 0
  self.invalidStreak = 0
  self.batch = nil
  self.current = nil
  self.stream = nil
end

function Agent:changed()
  if self.deps.onChange then
    self.deps.onChange(self)
  end
end

function Agent:push(item)
  self.nextId += 1
  item.id = self.nextId
  table.insert(self.items, item)
  return item
end

function Agent:remove(item)
  for i, it in ipairs(self.items) do
    if it == item then
      table.remove(self.items, i)
      return
    end
  end
end

function Agent:find(id)
  for _, it in ipairs(self.items) do
    if it.id == id then
      return it
    end
  end
  return nil
end

function Agent:secrets()
  return { self.deps.config.token }
end

function Agent:isBusy()
  if self.status == "streaming" then
    return true
  end
  for _, it in ipairs(self.items) do
    if it.state == "running" then
      return true
    end
  end
  return false
end

function Agent:needsUser()
  if self.status == "limit" then
    return true
  end
  for _, it in ipairs(self.items) do
    if it.state == "pending" or it.state == "review" then
      return true
    end
  end
  return false
end

function Agent:cancelInFlight()
  self.gen += 1
  if self.stream then
    self.stream.stop()
    self.stream = nil
  end
end

function Agent:newChat()
  self:cancelInFlight()
  self:clear()
  self:changed()
end

function Agent:send(text)
  if self.status ~= "idle" then
    return false
  end
  text = (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
  if text == "" then
    return false
  end
  local clean, kinds = self.deps.redact.scrub(text, self:secrets())
  self:push({ kind = "user", text = text })
  if #kinds > 0 then
    self:push({ kind = "notice", text = "Redacted from your message before sending: " .. table.concat(kinds, ", ") .. "." })
  end
  table.insert(self.history, { role = "user", text = clean })
  self.roundTrips = 0
  self.invalidStreak = 0
  self:startStream()
  return true
end

function Agent:startStream()
  local d = self.deps
  self.gen += 1
  local gen = self.gen
  self.streamState = d.provider.newStream(d.json)
  self.errorLines = {}
  self.current = self:push({ kind = "assistant", text = "" })
  self.status = "streaming"
  local req = d.provider.buildRequest(d.config, d.system, self.history, d.tools.SCHEMAS, d.json)
  local handle = d.transport(req, function(line)
    if self.gen == gen then
      self:onLine(line)
    end
  end, function(result)
    if self.gen == gen then
      self:onClose(result)
    end
  end)
  if self.gen ~= gen or self.status ~= "streaming" then
    return -- the transport finished synchronously
  end
  if handle == nil then
    self:fail("Could not start the request.", 0)
    return
  end
  self.stream = handle
  self:changed()
end

function Agent:onLine(line)
  local data = string.match(line, "^data:%s?(.*)$")
  if data == nil then
    local field = string.match(line, "^(%a+):")
    if line ~= "" and string.sub(line, 1, 1) ~= ":" and field ~= "event" and field ~= "id" and field ~= "retry" then
      table.insert(self.errorLines, line)
    end
    return
  end
  if data == "[DONE]" then
    return
  end
  local ok, ev = pcall(self.deps.json.decode, data)
  if not ok or type(ev) ~= "table" then
    table.insert(self.errorLines, data)
    return
  end
  self.deps.provider.applyEvent(self.streamState, ev)
  if self.current then
    self.current.text = self.streamState.text
  end
  self:changed()
end

function Agent:fail(message, status)
  self.stream = nil
  if self.current and self.current.text == "" then
    self:remove(self.current)
  end
  self.current = nil
  self:push({ kind = "error", text = message, auth = status == 401 or status == 403, retry = true })
  self.status = "idle"
  self:changed()
end

function Agent:onClose(result)
  self.stream = nil
  local st = self.streamState
  local status = (result and result.status) or 0
  if st.error then
    self:fail(st.error, status)
    return
  end
  if not (result and result.ok) or status >= 400 then
    self:fail(Agent.errorMessage(status, table.concat(self.errorLines, "\n"), self.deps.json), status)
    return
  end
  local reply = self.deps.provider.finish(st)
  table.insert(self.history, { role = "assistant", text = reply.text, toolCalls = reply.toolCalls })
  if self.current and self.current.text == "" then
    self:remove(self.current)
  end
  self.current = nil
  if #reply.toolCalls == 0 then
    self.status = "idle"
    self:changed()
    return
  end
  self:beginBatch(reply.toolCalls)
end

function Agent:retry()
  local last = self.items[#self.items]
  if self.status ~= "idle" or not last or last.kind ~= "error" or not last.retry then
    return
  end
  self:remove(last)
  self:startStream()
end

function Agent:beginBatch(calls)
  local d = self.deps
  local batch = { items = {} }
  self.batch = batch
  local anyInvalid = false
  for _, c in ipairs(calls) do
    local item = self:push({ kind = "tool", callId = c.id, name = c.name })
    table.insert(batch.items, item)
    local args, err = d.tools.parseArgs(c.name, c.argsJson, d.json)
    if not args then
      anyInvalid = true
      item.state = "invalid"
      item.glyph, item.title, item.body = "alert-triangle", "Invalid call: " .. tostring(c.name), c.argsJson
      item.sent = "invalid arguments: " .. err
    else
      item.args = args
      local view = d.tools.describe(c.name, args)
      item.glyph, item.title, item.body = view.glyph, view.title, view.body
      item.canTerminal = c.name == "run_command"
      local hit = d.redact.checkSubject(d.tools.subject(c.name, args), { home = d.home, protected = d.protected })
      if hit and hit.level == "block" then
        item.state = "refused"
        item.rule = hit.rule
        item.sent = "refused: this touches a protected location (" .. hit.rule .. "). The user was not asked."
      else
        item.state = "pending"
        item.rule = hit and hit.rule or nil
      end
    end
  end
  self.invalidStreak = anyInvalid and (self.invalidStreak + 1) or 0
  if self.invalidStreak >= Agent.MAX_INVALID then
    for _, it in ipairs(batch.items) do
      if it.sent == nil then
        it.state = "cancelled"
        it.sent = "cancelled"
      end
    end
    self:commitBatch()
    self:push({ kind = "error", text = "The model sent invalid tool calls " .. Agent.MAX_INVALID .. " times in a row, so the agent stopped." })
    self.status = "idle"
    self:changed()
    return
  end
  self.status = "approval"
  self:maybeContinue()
end

function Agent:approve(id)
  local item = self:find(id)
  if not item or item.state ~= "pending" then
    return
  end
  item.state = "running"
  local gen = self.gen
  self:changed()
  self.deps.tools.execute(item.name, item.args, self.deps.io, function(output)
    if self.gen == gen and item.state == "running" then
      self:onToolOutput(item, output)
    end
  end)
end

-- Scrub the whole output first, then truncate, then sanitise UTF-8: scrubbing
-- truncated text would miss a key whose END line, or a token, was cut.
function Agent:onToolOutput(item, output)
  local t, redact, secrets = self.deps.tools, self.deps.redact, self:secrets()
  local function shape(s)
    return t.sanitizeUtf8(t.truncate(s))
  end
  local scrubbed, kinds = redact.scrub(output, secrets)
  item.output = shape(redact.scrubLiterals(output, secrets))
  item.scrubbed, item.kinds = shape(scrubbed), kinds
  if #kinds > 0 or item.rule then
    item.state = "review"
  else
    item.state = "done"
    item.sent = item.scrubbed
  end
  self:maybeContinue()
end

-- choice: "full" | "redacted" | "withhold"
function Agent:decide(id, choice)
  local item = self:find(id)
  if not item or item.state ~= "review" then
    return
  end
  if choice == "full" then
    item.sent = self.deps.redact.scrubLiterals(item.output, self:secrets())
    item.state = "done"
  elseif choice == "redacted" then
    item.sent = item.scrubbed
    item.state = "done"
  else
    item.sent = "output withheld by the user"
    item.state = "withheld"
  end
  self:maybeContinue()
end

function Agent:skip(id)
  local item = self:find(id)
  if not item or item.state ~= "pending" then
    return
  end
  item.state = "skipped"
  item.sent = "the user declined to run this"
  self:maybeContinue()
end

function Agent:handOff(id)
  local item = self:find(id)
  if not item or item.state ~= "pending" or not item.canTerminal then
    return
  end
  item.state = "handed-off"
  item.sent = "the user chose to run this in their own terminal; its output was not captured"
  self:maybeContinue()
end

function Agent:commitBatch()
  local results = {}
  for _, it in ipairs(self.batch.items) do
    table.insert(results, { id = it.callId, name = it.name, content = it.sent })
  end
  table.insert(self.history, { role = "tool_results", results = results })
  self.batch = nil
end

function Agent:maybeContinue()
  local batch = self.batch
  if batch then
    for _, it in ipairs(batch.items) do
      if it.sent == nil then
        self:changed()
        return
      end
    end
    self:commitBatch()
    self.roundTrips += 1
    if self.roundTrips >= Agent.MAX_ROUND_TRIPS then
      self.status = "limit"
      self:push({ kind = "notice", text = "The agent has made " .. self.roundTrips .. " tool round-trips for this request." })
      self:changed()
      return
    end
    self:startStream()
    return
  end
  self:changed()
end

function Agent:continue()
  if self.status ~= "limit" then
    return
  end
  self.roundTrips = 0
  self:startStream()
end

function Agent:stop()
  if self.status == "idle" then
    return
  end
  self:cancelInFlight()
  if self.current and self.current.text == "" then
    self:remove(self.current)
  end
  self.current = nil
  if self.batch then
    for _, it in ipairs(self.batch.items) do
      if it.sent == nil then
        it.state = "cancelled"
        it.sent = "cancelled by the user"
      end
    end
    self:commitBatch()
  end
  self.status = "idle"
  self:push({ kind = "notice", text = "Stopped." })
  self:changed()
end

return Agent
