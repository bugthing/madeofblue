--!nonstrict
local T = require("../support/t")
local Redact = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/redact")

local OPTS = { home = "/home/u", protected = { "/home/u/.local/state/agent" } }

local function check(text)
  return Redact.checkSubject(text, OPTS)
end

T.describe("redact.checkSubject", function()
  T.it("ignores ordinary commands", function()
    T.eq(check("niri msg -j windows"), nil)
    T.eq(check("ls ~/.keyboard-layouts"), nil)
    T.eq(check("printenv XDG_SESSION_TYPE"), nil)
  end)

  T.it("blocks the agent's own settings however they are spelled", function()
    T.eq(check("cat /home/u/.local/state/agent/config.json").level, "block")
    T.eq(check("cat $HOME/.local/state/agent/config.json").level, "block")
    T.eq(check("cat ${HOME}/.local/state/agent/config.json").level, "block")
    T.eq(check("cat ~/.local/state/agent/config.json").level, "block")
    T.eq(check("cat .local/state/agent/config.json").rule, "agent settings")
  end)

  T.it("blocks password hashes and keyrings", function()
    T.eq(check("pkexec cat /etc/shadow").level, "block")
    T.eq(check("ls ~/.local/share/keyrings").rule, "login keyring")
  end)

  T.it("flags credential locations", function()
    local hit = check("cat ~/.ssh/id_ed25519.pub")
    T.eq(hit.level, "flag")
    T.eq(hit.rule, "SSH keys")
    T.eq(check("cat ~/.aws/credentials").level, "flag")
    T.eq(check("cat ~/.config/gh/hosts.yml").rule, "GitHub CLI token")
    T.eq(check("ls ~/.mozilla/firefox").rule, "browser profile")
  end)

  T.it("flags secret-looking file names", function()
    T.eq(check("cat project/.env.local").rule, "environment file")
    T.eq(check("cat server.key").rule, "private key file")
    T.eq(check("cat cert.pem").rule, "private key file")
    T.eq(check("secret-tool lookup service x").rule, "secret-named file or tool")
    T.eq(check("cat my-credentials.txt").rule, "credential file")
  end)
end)

return true
