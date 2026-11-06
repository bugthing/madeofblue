--!nonstrict
local T = require("../support/t")
local Redact = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/redact")

local function scrub(text, literals)
  local out, kinds = Redact.scrub(text, literals)
  return out, table.concat(kinds, ",")
end

T.describe("redact.scrub", function()
  T.it("leaves ordinary output alone", function()
    local out, kinds = scrub("PATH=/usr/bin\ntask-list done\nmax=3")
    T.eq(out, "PATH=/usr/bin\ntask-list done\nmax=3")
    T.eq(kinds, "")
  end)

  T.it("removes the agent's own token wherever it appears", function()
    local out, kinds = scrub("token is hunter22secret!", { "hunter22secret" })
    T.eq(out, "token is [REDACTED:agent-token]!")
    T.eq(kinds, "agent-token")
  end)

  T.it("removes PEM private keys", function()
    local key = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----"
    local out, kinds = scrub("before\n" .. key .. "\nafter")
    T.eq(out, "before\n[REDACTED:private-key]\nafter")
    T.eq(kinds, "private-key")
  end)

  T.it("removes an unterminated private key to the end of the text", function()
    local out, kinds = scrub("before\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nmore")
    T.eq(out, "before\n[REDACTED:private-key]")
    T.eq(kinds, "private-key")
  end)

  T.it("removes known token formats", function()
    local out = scrub(table.concat({
      "a sk-ant-api03-abcdefghijklmnopqrstuvwxyz",
      "b sk-proj-abcdefghijklmnopqrstuvwxyz",
      "c ghp_abcdefghijklmnopqrstuvwxyz0123456789",
      "d AKIAABCDEFGHIJKLMNOP",
      "e xoxb-1234567890-abcdefghij",
      "f glpat-abcdefghijklmnopqrst",
      "g eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
    }, "\n"))
    T.notContains(out, "abcdefghijklmnopqrstuvwxyz")
    T.notContains(out, "AKIAABCDEFGHIJKLMNOP")
    T.notContains(out, "xoxb-")
    T.notContains(out, "glpat-")
    T.notContains(out, "eyJhbGci")
    T.contains(out, "[REDACTED:anthropic-key]")
    T.contains(out, "[REDACTED:api-key]")
    T.contains(out, "[REDACTED:github-token]")
    T.contains(out, "[REDACTED:aws-key]")
  end)

  T.it("does not treat short look-alikes as tokens", function()
    local out, kinds = scrub("desk-lamp sk-short")
    T.eq(out, "desk-lamp sk-short")
    T.eq(kinds, "")
  end)

  T.it("removes auth headers, bearer tokens and URL credentials", function()
    local out = scrub("Authorization: Basic dXNlcjpwYXNz\ncurl -H 'x: Bearer abcdef123456'\nhttps://bob:pa55@example.com/x")
    T.contains(out, "Authorization: [REDACTED:auth-header]")
    T.contains(out, "Bearer [REDACTED:bearer-token]")
    T.contains(out, "https://[REDACTED:url-credentials]@example.com/x")
    T.notContains(out, "pa55")
  end)

  T.it("removes secret-looking assignments", function()
    local out = scrub(table.concat({
      "GITHUB_TOKEN=abc123",
      "  export DB_PASSWORD='x y'",
      '  "api_key": "zzz",',
      "password: hunter2",
      "x-api-key: kkk",
      "HOME=/home/u",
    }, "\n"))
    T.contains(out, "GITHUB_TOKEN=[REDACTED:secret-value]")
    T.contains(out, "  export DB_PASSWORD=[REDACTED:secret-value]")
    T.contains(out, '  "api_key": [REDACTED:secret-value]')
    T.contains(out, "password: [REDACTED:secret-value]")
    T.contains(out, "x-api-key: [REDACTED:secret-value]")
    T.contains(out, "HOME=/home/u")
  end)

  T.it("scrubLiterals only removes the given values", function()
    T.eq(Redact.scrubLiterals("GITHUB_TOKEN=abc mytok123", { "mytok123" }), "GITHUB_TOKEN=abc [REDACTED:agent-token]")
  end)
end)

return true
