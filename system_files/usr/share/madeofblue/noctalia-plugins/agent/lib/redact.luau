--!nonstrict
-- Keeps secrets on the machine: sensitive-path rules for tool subjects and
-- scrubbers for tool output. Best effort by design; the approval gate and the
-- visible send preview are the real guarantees.
-- Pure module: no require, no noctalia.*.
local M = {}

local function replacePlain(s, from, to)
  if from == "" then
    return s, 0
  end
  local out, i, n = {}, 1, 0
  while true do
    local a, b = string.find(s, from, i, true)
    if not a then
      break
    end
    table.insert(out, string.sub(s, i, a - 1))
    table.insert(out, to)
    i = b + 1
    n += 1
  end
  table.insert(out, string.sub(s, i))
  return table.concat(out), n
end

-- Substring rules, matched against the lower-cased subject.
local BLOCK_FRAGMENTS = {
  { rule = "system password hashes", text = "/etc/shadow" },
  { rule = "system password hashes", text = "/etc/gshadow" },
  { rule = "login keyring", text = ".local/share/keyrings" },
}

local FLAG_FRAGMENTS = {
  { rule = "SSH keys", text = ".ssh" },
  { rule = "GnuPG keys", text = ".gnupg" },
  { rule = "password store", text = ".password-store" },
  { rule = "AWS credentials", text = ".aws" },
  { rule = "Kubernetes credentials", text = ".kube" },
  { rule = "container registry credentials", text = ".docker/config.json" },
  { rule = "GitHub CLI token", text = "gh/hosts.yml" },
  { rule = "netrc credentials", text = ".netrc" },
  { rule = "git credentials", text = ".git-credentials" },
  { rule = "browser profile", text = ".mozilla" },
  { rule = "browser profile", text = "google-chrome" },
  { rule = "browser profile", text = "chromium" },
  { rule = "browser profile", text = "bravesoftware" },
}

-- Lua patterns, matched against the lower-cased subject.
local FLAG_PATTERNS = {
  { rule = "environment file", pattern = "%.env" },
  { rule = "private key file", pattern = "%.pem%f[^%w]" },
  { rule = "private key file", pattern = "%.key%f[^%w]" },
  { rule = "secret-named file or tool", pattern = "secret" },
  { rule = "credential file", pattern = "credential" },
}

-- Checks a command string or path. Returns nil, or { level = "block" | "flag", rule = string }.
-- opts.home: the user's home directory; opts.protected: absolute paths that must never be touched.
function M.checkSubject(text, opts)
  opts = opts or {}
  local home = opts.home or ""
  local norm = text or ""
  if home ~= "" then
    norm = replacePlain(norm, "${HOME}", home)
    norm = replacePlain(norm, "$HOME", home)
    norm = replacePlain(norm, "~/", home .. "/")
  end
  for _, path in ipairs(opts.protected or {}) do
    if string.find(norm, path, 1, true) then
      return { level = "block", rule = "agent settings" }
    end
    if home ~= "" and string.sub(path, 1, #home + 1) == home .. "/" then
      if string.find(norm, string.sub(path, #home + 2), 1, true) then
        return { level = "block", rule = "agent settings" }
      end
    end
  end
  local lower = string.lower(norm)
  for _, r in ipairs(BLOCK_FRAGMENTS) do
    if string.find(lower, r.text, 1, true) then
      return { level = "block", rule = r.rule }
    end
  end
  if string.find(lower, "kubectl", 1, true) and string.find(lower, "config%s+view") and string.find(lower, "--raw", 1, true) then
    return { level = "flag", rule = "kubeconfig" }
  end
  for _, r in ipairs(FLAG_FRAGMENTS) do
    if string.find(lower, r.text, 1, true) then
      return { level = "flag", rule = r.rule }
    end
  end
  for _, r in ipairs(FLAG_PATTERNS) do
    if string.find(lower, r.pattern) then
      return { level = "flag", rule = r.rule }
    end
  end
  return nil
end

local TOKEN_RULES = {
  { kind = "private-key", pattern = "%-%-%-%-%-BEGIN [%w ]*PRIVATE KEY[%w ]*%-%-%-%-%-.-%-%-%-%-%-END [%w ]*PRIVATE KEY[%w ]*%-%-%-%-%-" },
  -- No END line (cut off, or pasted partially): redact to the end of the text.
  { kind = "private-key", pattern = "%-%-%-%-%-BEGIN [%w ]*PRIVATE KEY[%w ]*%-%-%-%-%-.*" },
  { kind = "anthropic-key", pattern = "%f[%w]sk%-ant%-[%w%-_]+", min = 20 },
  { kind = "api-key", pattern = "%f[%w]sk%-[%w%-_]+", min = 20 },
  { kind = "github-token", pattern = "%f[%w]gh[pousr]_%w+", min = 20 },
  { kind = "github-token", pattern = "%f[%w]github_pat_[%w_]+", min = 30 },
  { kind = "aws-key", pattern = "%f[%w]AKIA[%u%d]+", min = 20 },
  { kind = "slack-token", pattern = "%f[%w]xox[abprs]%-[%w%-]+", min = 15 },
  { kind = "gitlab-token", pattern = "%f[%w]glpat%-[%w%-_]+", min = 20 },
  { kind = "jwt", pattern = "eyJ[%w%-_]+%.eyJ[%w%-_]+%.[%w%-_]+" },
}

local SECRET_KEY_WORDS = {
  "TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "API-KEY", "APIKEY", "PRIVATE",
  "KEY_DATA", "KEY-DATA", "CLIENT_KEY", "CLIENT-KEY", -- kubeconfig client-key-data
}

local function isSecretKey(key)
  local upper = string.upper(key)
  for _, word in ipairs(SECRET_KEY_WORDS) do
    if string.find(upper, word, 1, true) then
      return true
    end
  end
  return false
end

-- Empty, already redacted, or purely numeric (max_tokens: 4096) values stay.
local function keepValue(value)
  return string.match(value, "^[\"'%s,]*$") ~= nil
    or string.sub(value, 1, 9) == "[REDACTED"
    or string.match(value, "^%s*%d+[,]?%s*$") ~= nil
end

local function scrubAssignment(line, mark)
  local prefix, key, sep, value = string.match(line, "^(%s*export%s+)([%w_]+)(=)(.*)$")
  if not prefix then
    -- The optional "- " allows YAML list items.
    prefix, key, sep, value = string.match(line, '^(%s*%-?%s*)([%w_%.%-"]+)(%s*[=:]%s*)(.*)$')
  end
  if not prefix or not isSecretKey(key) or keepValue(value) then
    return nil
  end
  return prefix .. key .. sep .. mark("secret-value")
end

-- Removes only the given literal values (the agent's own token).
function M.scrubLiterals(text, literals)
  for _, lit in ipairs(literals or {}) do
    if type(lit) == "string" and #lit >= 6 then
      text = replacePlain(text, lit, "[REDACTED:agent-token]")
    end
  end
  return text
end

-- Returns the scrubbed text and a sorted list of the kinds of secret removed.
function M.scrub(text, literals)
  local hits = {}
  local function mark(kind)
    hits[kind] = true
    return "[REDACTED:" .. kind .. "]"
  end

  for _, lit in ipairs(literals or {}) do
    if type(lit) == "string" and #lit >= 6 then
      local n
      text, n = replacePlain(text, lit, "[REDACTED:agent-token]")
      if n > 0 then
        hits["agent-token"] = true
      end
    end
  end

  for _, r in ipairs(TOKEN_RULES) do
    text = string.gsub(text, r.pattern, function(m)
      if r.min and #m < r.min then
        return nil
      end
      return mark(r.kind)
    end)
  end

  text = string.gsub(text, "([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]%s*:%s*)[^\r\n]+", function(prefix)
    return prefix .. mark("auth-header")
  end)
  text = string.gsub(text, "([Bb]earer%s+)([%w%-%._~%+/=]+)", function(prefix, token)
    if #token < 8 or string.sub(token, 1, 9) == "[REDACTED" then
      return nil
    end
    return prefix .. mark("bearer-token")
  end)
  text = string.gsub(text, "(%a[%w+.-]*://)([^/%s:@]+):([^/%s@]+)@", function(scheme)
    return scheme .. mark("url-credentials") .. "@"
  end)
  text = string.gsub(text, "[^\n]+", function(line)
    return scrubAssignment(line, mark)
  end)
  -- "key": "value" pairs anywhere in a line, e.g. one-line JSON responses.
  text = string.gsub(text, '("([%w_%.%-]+)"%s*:%s*)"([^"\n]*)"', function(prefix, key, value)
    if not isSecretKey(key) or keepValue(value) then
      return nil
    end
    return prefix .. '"' .. mark("secret-value") .. '"'
  end)

  local kinds = {}
  for kind in pairs(hits) do
    table.insert(kinds, kind)
  end
  table.sort(kinds)
  return text, kinds
end

M._replacePlain = replacePlain

return M
