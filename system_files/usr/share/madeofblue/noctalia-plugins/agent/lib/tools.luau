--!nonstrict
-- The agent's tools: schemas sent to the model, argument parsing, approval-card
-- text, and execution through an injected io table:
--   io.run(argv, cb) / io.readFile(path) / io.writeFile(path, content)
--   io.expandPath(path) / io.home
-- Pure module: no require, no noctalia.*.
local M = {}

M.TIMEOUT_SECONDS = 120
M.OUTPUT_LIMIT = 16384
M.OUTPUT_KEEP = 8192
local PREVIEW_LIMIT = 4000

M.SCHEMAS = {
  {
    name = "run_command",
    description = "Run a shell command (/bin/sh -c) as the user. There is no terminal: commands cannot prompt "
      .. "for input or passwords; use pkexec for root. Times out after 120 seconds. The user approves every call.",
    parameters = {
      type = "object",
      properties = { command = { type = "string", description = "The exact shell command to run." } },
      required = { "command" },
    },
  },
  {
    name = "read_file",
    description = "Read a text file. Relative paths are relative to the user's home directory.",
    parameters = {
      type = "object",
      properties = { path = { type = "string", description = "File path; ~ is expanded." } },
      required = { "path" },
    },
  },
  {
    name = "write_file",
    description = "Create or replace a text file with the complete given content. Read the file first when editing.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path; ~ is expanded." },
        content = { type = "string", description = "The complete new file content." },
      },
      required = { "path", "content" },
    },
  },
}

local REQUIRED = {
  run_command = { "command" },
  read_file = { "path" },
  write_file = { "path", "content" },
}

-- Returns the argument table, or nil and an error for the model.
function M.parseArgs(name, argsJson, json)
  local fields = REQUIRED[name]
  if not fields then
    return nil, "unknown tool '" .. tostring(name) .. "'"
  end
  local raw = (argsJson == nil or argsJson == "") and "{}" or argsJson
  local ok, args = pcall(json.decode, raw)
  if not ok or type(args) ~= "table" then
    return nil, "arguments are not a JSON object"
  end
  for _, field in ipairs(fields) do
    if type(args[field]) ~= "string" or (field ~= "content" and args[field] == "") then
      return nil, "missing string argument '" .. field .. "'"
    end
  end
  return args
end

-- The text the sensitive-path rules are checked against.
function M.subject(name, args)
  if name == "run_command" then
    return args.command
  end
  return args.path
end

local function preview(s)
  if #s <= PREVIEW_LIMIT then
    return s
  end
  return string.sub(s, 1, PREVIEW_LIMIT) .. "\n…"
end

-- Glyph, title and body text for an approval card.
function M.describe(name, args)
  if name == "run_command" then
    return { glyph = "terminal-2", title = "Run command", body = args.command }
  elseif name == "read_file" then
    return { glyph = "file-text", title = "Read file", body = args.path }
  end
  return { glyph = "file-pencil", title = "Write file", body = args.path .. "\n\n" .. preview(args.content) }
end

function M.sanitizeUtf8(s)
  local out, i = {}, 1
  while i <= #s do
    local len, bad = utf8.len(s, i)
    if len then
      table.insert(out, string.sub(s, i))
      break
    end
    table.insert(out, string.sub(s, i, bad - 1))
    table.insert(out, "?")
    i = bad + 1
  end
  return table.concat(out)
end

function M.truncate(s)
  if #s <= M.OUTPUT_LIMIT then
    return s
  end
  local cut = #s - 2 * M.OUTPUT_KEEP
  return string.sub(s, 1, M.OUTPUT_KEEP) .. "\n…[" .. cut .. " bytes truncated]…\n" .. string.sub(s, -M.OUTPUT_KEEP)
end

function M.formatRun(r)
  local parts = {}
  if r.exitCode == 124 or r.timedOut then
    table.insert(parts, "timed out after " .. M.TIMEOUT_SECONDS .. "s (process killed)")
  end
  table.insert(parts, "exit code: " .. tostring(r.exitCode))
  if r.stdout and r.stdout ~= "" then
    table.insert(parts, "stdout:\n" .. r.stdout)
  end
  if r.stderr and r.stderr ~= "" then
    table.insert(parts, "stderr:\n" .. r.stderr)
  end
  return M.truncate(M.sanitizeUtf8(table.concat(parts, "\n")))
end

function M.resolvePath(path, io)
  local p = io.expandPath(path)
  if string.sub(p, 1, 1) ~= "/" then
    p = io.home .. "/" .. p
  end
  return p
end

-- Runs an approved call and calls cb(outputText) exactly once.
function M.execute(name, args, io, cb)
  if name == "run_command" then
    local argv = { "timeout", "--kill-after=5", tostring(M.TIMEOUT_SECONDS), "/bin/sh", "-c", args.command }
    local started = io.run(argv, function(result)
      cb(M.formatRun(result))
    end)
    if not started then
      cb("error: the command could not be started")
    end
  elseif name == "read_file" then
    local content, err = io.readFile(M.resolvePath(args.path, io))
    if content == nil then
      cb("error: " .. tostring(err))
    elseif content == "" then
      cb("(empty file)")
    else
      cb(M.truncate(M.sanitizeUtf8(content)))
    end
  elseif name == "write_file" then
    local ok, err = io.writeFile(M.resolvePath(args.path, io), args.content)
    if ok then
      cb("wrote " .. #args.content .. " bytes to " .. args.path)
    else
      cb("error: " .. tostring(err))
    end
  else
    cb("error: unknown tool")
  end
end

return M
