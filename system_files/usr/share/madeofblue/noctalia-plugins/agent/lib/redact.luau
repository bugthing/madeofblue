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

M._replacePlain = replacePlain

return M
