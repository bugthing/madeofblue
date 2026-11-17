--!nonstrict
-- Agent connection settings: defaults, validation and (de)serialisation.
-- Pure module: no require, no noctalia.* (see the plan's conventions).
local M = {}

M.PROVIDERS = { "openai", "anthropic" } -- index 0/1 in the panel's panel.luau ui.select
M.LABELS = { openai = "OpenAI-compatible", anthropic = "Anthropic" }
M.DEFAULT_HOSTS = {
  openai = "http://aipro.lan:11435/v1",
  anthropic = "https://api.anthropic.com",
}
M.MODEL_HINTS = {
  openai = "auto-detected from /v1/models, or e.g. local",
  anthropic = "e.g. claude-sonnet-5-5",
}

local LOOPBACK = { ["localhost"] = true, ["127.0.0.1"] = true, ["::1"] = true }

local function isPrivateIpv4(host)
  local a, b, c, d = string.match(host, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not a or a > 255 or b > 255 or c > 255 or d > 255 then
    return false
  end
  return a == 10
    or a == 127
    or (a == 192 and b == 168)
    or (a == 172 and b >= 16 and b <= 31)
    or (a == 100 and b >= 64 and b <= 127)
end

local function isPrivateHost(host)
  if not host or host == "" then
    return false
  end
  if LOOPBACK[host] or isPrivateIpv4(host) then
    return true
  end
  return string.match(host, "%.lan$") ~= nil
    or string.match(host, "%.local$") ~= nil
    or string.match(host, "%.home%.arpa$") ~= nil
    or string.match(host, "%.internal$") ~= nil
end

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
  return isPrivateHost(host)
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
    if not isPrivateHost(host) then
      table.insert(errors, "Plain http is only allowed for localhost or private LAN hosts; use https.")
    end
  elseif scheme ~= "https" then
    table.insert(errors, "Host must use https (or http for localhost/LAN).")
  end
  if cfg.model == "" then
    table.insert(errors, "Enter a model name.")
  end
  if cfg.provider == "anthropic" and cfg.token == "" then
    table.insert(errors, "Anthropic needs an API token.")
  end
  -- These go into the URL and HTTP headers; CR/LF would inject headers.
  for _, field in ipairs({ { "Host", cfg.host }, { "Model", cfg.model }, { "Token", cfg.token } }) do
    if type(field[2]) == "string" and string.find(field[2], "%c") then
      table.insert(errors, field[1] .. " contains invalid characters.")
    end
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
  local _, host = M.parseHost(cfg.host)
  if host and LOOPBACK[host] then
    return "Local"
  elseif isPrivateHost(host) then
    return "LAN: " .. host
  end
  return "Remote: " .. (host or "?")
end

return M
