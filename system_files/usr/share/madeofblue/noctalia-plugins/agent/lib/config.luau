--!nonstrict
-- Agent connection settings: defaults, validation and (de)serialisation.
-- Pure module: no require, no noctalia.* (see the plan's conventions).
local M = {}

M.PROVIDERS = { "openai", "anthropic" } -- index 0/1 in the panel's ui.select
M.LABELS = { openai = "OpenAI-compatible", anthropic = "Anthropic" }
M.DEFAULT_HOSTS = {
  openai = "https://api.openai.com/v1",
  anthropic = "https://api.anthropic.com",
}
M.MODEL_HINTS = {
  openai = "e.g. gpt-4.1-mini, or qwen2.5 on Ollama",
  anthropic = "e.g. claude-sonnet-5-5",
}

local LOOPBACK = { ["localhost"] = true, ["127.0.0.1"] = true, ["::1"] = true }

local function trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Returns the lower-cased scheme and host name of a URL, or nil.
function M.parseHost(url)
  local scheme, rest = string.match(url or "", "^(%a[%w+.-]*)://(.+)$")
  if not scheme then
    return nil
  end
  local authority = string.match(rest, "^([^/?#]+)")
  if not authority then
    return nil
  end
  authority = string.gsub(authority, "^.*@", "")
  local host = string.match(authority, "^%[([^%]]+)%]") or string.match(authority, "^([^:]+)")
  if not host or host == "" then
    return nil
  end
  return string.lower(scheme), string.lower(host)
end

function M.isLoopback(url)
  local _, host = M.parseHost(url)
  return host ~= nil and LOOPBACK[host] == true
end

function M.normalize(cfg)
  return {
    provider = trim(cfg.provider),
    host = (string.gsub(trim(cfg.host), "/+$", "")),
    model = trim(cfg.model),
    token = trim(cfg.token),
  }
end

-- Returns a list of problems; empty when the settings are usable.
function M.validate(cfg)
  local errors = {}
  if not M.LABELS[cfg.provider] then
    table.insert(errors, "Choose a provider.")
  end
  local scheme, host = M.parseHost(cfg.host)
  if not scheme then
    table.insert(errors, "Host must be a URL such as https://api.example.com.")
  elseif scheme == "http" then
    if not LOOPBACK[host] then
      table.insert(errors, "Plain http is only allowed for localhost; use https.")
    end
  elseif scheme ~= "https" then
    table.insert(errors, "Host must use https (or http for localhost).")
  end
  if cfg.model == "" then
    table.insert(errors, "Enter a model name.")
  end
  if cfg.provider == "anthropic" and cfg.token == "" then
    table.insert(errors, "Anthropic needs an API token.")
  end
  return errors
end

-- Returns settings, or nil and a reason ("missing", "not valid JSON", or a validation error).
function M.decode(raw, json)
  if raw == nil or raw == "" then
    return nil, "missing"
  end
  local ok, data = pcall(json.decode, raw)
  if not ok or type(data) ~= "table" then
    return nil, "not valid JSON"
  end
  local cfg = M.normalize(data)
  local errors = M.validate(cfg)
  if #errors > 0 then
    return nil, errors[1]
  end
  return cfg
end

function M.encode(cfg, json)
  return json.encode({ provider = cfg.provider, host = cfg.host, model = cfg.model, token = cfg.token }, true)
end

function M.destination(cfg)
  if M.isLoopback(cfg.host) then
    return "Local"
  end
  local _, host = M.parseHost(cfg.host)
  return "Remote: " .. (host or "?")
end

return M
