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

  T.it("removes PGP private key blocks", function()
    local key = "-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nlQVYBGabc123\n=abcd\n-----END PGP PRIVATE KEY BLOCK-----"
    local out, kinds = scrub("before\n" .. key .. "\nafter")
    T.eq(out, "before\n[REDACTED:private-key]\nafter")
    T.eq(kinds, "private-key")
    out = scrub("x\n-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQVYBGabc123")
    T.eq(out, "x\n[REDACTED:private-key]")
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

  T.it("removes kubeconfig client keys", function()
    local out, kinds = scrub("users:\n- name: admin\n  user:\n    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ\n    client_key: /x/y.key")
    T.contains(out, "    client-key-data: [REDACTED:secret-value]")
    T.contains(out, "    client_key: [REDACTED:secret-value]")
    T.notContains(out, "LS0t")
    T.eq(kinds, "secret-value")
  end)

  T.it("removes secret values inside inline JSON", function()
    local out = scrub('{"access_token":"ya29abc","expires_in":3599,"refresh_token": "1//0gabc"}')
    T.eq(out, '{"access_token":"[REDACTED:secret-value]","expires_in":3599,"refresh_token": "[REDACTED:secret-value]"}')
  end)

  T.it("removes whole inline JSON values containing escaped quotes", function()
    local out = scrub('{"password":"ab\\"cdSECRETREST","user":"x"}')
    T.eq(out, '{"password":"[REDACTED:secret-value]","user":"x"}')
    out = scrub('{"password":"ab\\\\","user":"x"}')
    T.eq(out, '{"password":"[REDACTED:secret-value]","user":"x"}')
  end)

  T.it("removes unquoted inline JSON values", function()
    T.eq(scrub('{"password": hunter2}'), '{"password": [REDACTED:secret-value]}')
    T.eq(scrub('{"id":1,"password":hunter2,"user":"x"}'), '{"id":1,"password":[REDACTED:secret-value],"user":"x"}')
    T.eq(scrub('{"id":1,"password":null,"api_key":{"a":1}}'), '{"id":1,"password":null,"api_key":{"a":1}}')
  end)

  T.it("matches auth headers in any case", function()
    local out = scrub("AUTHORIZATION: Basic dXNlcjpwYXNz\nauthorization: token abc")
    T.eq(out, "AUTHORIZATION: [REDACTED:auth-header]\nauthorization: [REDACTED:auth-header]")
  end)

  T.it("treats a key as a token only when it ends in token", function()
    local text = 'max_tokens: 4096\nMAX_TOKENS=4096\n  "max_tokens": 4096,\n{"token_type":"Bearer","tokenizer":"cl100k_base","max_tokens":4096}'
    local out, kinds = scrub(text)
    T.eq(out, text)
    T.eq(kinds, "")
    out = scrub('GITHUB_TOKEN=abc\ntoken: abc\nx-auth-token: abc\n{"access_token":"a","refresh_token":"b","Token":"c"}')
    T.eq(out, 'GITHUB_TOKEN=[REDACTED:secret-value]\ntoken: [REDACTED:secret-value]\nx-auth-token: [REDACTED:secret-value]\n'
      .. '{"access_token":"[REDACTED:secret-value]","refresh_token":"[REDACTED:secret-value]","Token":"[REDACTED:secret-value]"}')
  end)

  T.it("redacts numeric passwords", function()
    T.eq(scrub("PASSWORD=123456\nDB_PASSWORD: 1234"), "PASSWORD=[REDACTED:secret-value]\nDB_PASSWORD: [REDACTED:secret-value]")
    T.eq(scrub('{"password": 123456}'), '{"password": [REDACTED:secret-value]}')
    T.eq(scrub('{"id":1,"password":123456,"user":"x"}'), '{"id":1,"password":[REDACTED:secret-value],"user":"x"}')
  end)

  T.it("removes secret values in YAML list items", function()
    local out = scrub("users:\n  - password: hunter2\n  - name: bob")
    T.eq(out, "users:\n  - password: [REDACTED:secret-value]\n  - name: bob")
  end)

  T.it("scrubs long unbroken runs in linear time", function()
    -- A quadratic pattern took ~20 s on 64 KB of one word, on the UI thread.
    for _, s in ipairs({ string.rep("m", 65536), string.rep("a.", 32768), string.rep("eyJ", 21845) }) do
      local started = os.clock()
      local out = scrub(s)
      T.eq(out, s)
      T.truthy(os.clock() - started < 1, "took " .. (os.clock() - started) .. "s on " .. string.sub(s, 1, 3))
    end
    T.contains(scrub("x https://bob:pa55@example.com"), "https://[REDACTED:url-credentials]@")
    T.contains(scrub("git+ssh://bob:pa55@example.com"), "git+ssh://[REDACTED:url-credentials]@")
  end)

  T.it("scrubLiterals only removes the given values", function()
    T.eq(Redact.scrubLiterals("GITHUB_TOKEN=abc mytok123", { "mytok123" }), "GITHUB_TOKEN=abc [REDACTED:agent-token]")
  end)
end)

return true
