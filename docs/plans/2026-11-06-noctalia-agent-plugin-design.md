# Noctalia agent plugin — design

**Date:** 2026-11-06
**Status:** Approved, awaiting implementation plan

## Goal

A bar icon in madeofblue's Noctalia shell. Clicking it when unconfigured asks for LLM details (provider, host, model, API token). Once configured, clicking it opens a chat where you ask an agent to perform tasks on your system. The agent proposes actions; you approve each one.

## Decisions

| Question | Decision |
| --- | --- |
| Where does the UI live? | A Noctalia plugin. Niri has no bar or plugin system; the agent drives Niri through `niri msg` and `config.kdl`. |
| Who runs the agent loop? | The plugin, in Luau, talking directly to the LLM API. |
| Providers | OpenAI-compatible (OpenAI, Ollama, LM Studio, OpenRouter, vLLM…) and Anthropic native. |
| Approval | Every tool call needs a click on **Run**. |
| Setup flow | Inline form in the panel; saved to the plugin's private data directory. |
| Output review | Auto-redacted and sent, unless a scrubber or sensitive-path rule fires; then the user must choose. |

Noctalia facts this design relies on (v5.4.1, plugin API ≤ 51):

- Plugins provide `[[widget]]` and `[[panel]]` entries, `noctalia.http` / `noctalia.httpStream` (SSE), `noctalia.runAsync` (argv form, output capture), `noctalia.runInTerminal`, `ui.input`, `ui.select`, `ui.markdown`, `noctalia.state`, and `noctalia.pluginDataDir()` (`0700`, files written `0600`).
- Plugins read their settings but cannot write them, hence the inline form with our own config file.
- A `path` plugin source is read-only, so the plugin can ship in `/usr`.
- Noctalia merges every `*.toml` in `~/.config/noctalia/`.

## Architecture

Plugin id `madeofblue/agent`, shipped in the image:

```
/usr/share/madeofblue/noctalia-plugins/
  agent/
    plugin.toml          one [[widget]], one [[panel]], plugin_api level
    widget.luau          bar icon; click toggles the panel
    panel.luau           chooses setup or chat view
    config.luau          load/save/validate config.json in pluginDataDir()
    agent.luau           loop: send → tool calls → approve → run → repeat
    redact.luau          sensitive-path rules and output scrubbers
    tools.luau           tool schemas and execution
    providers/
      openai.luau        /v1/chat/completions, SSE, tool_calls
      anthropic.luau     /v1/messages, SSE, tool_use blocks
    prompt.md            system prompt describing madeofblue
```

Image wiring:

- `system_files/etc/skel/.config/noctalia/agent.toml` — adds the `path` source, enables `madeofblue/agent`, places the widget on the bar.
- `system_files/etc/skel/.config/niri/config.kdl` — `Mod+A` runs `noctalia msg panel-toggle madeofblue/agent:chat`.

Tools (all require approval):

- `run_command` — argv or shell string via `noctalia.runAsync`; returns stdout, stderr, exit code.
- `read_file(path)`
- `write_file(path, content)` — card shows new content, or a diff when overwriting.

The system prompt describes the system: bootc/Bluefin-DX (immutable `/usr`; use flatpak or brew, not `dnf`), Niri (`niri msg` for live changes, `config.kdl` for persistent ones), Noctalia (`noctalia msg`), and `pkexec` for privileged steps since there is no TTY.

The conversation lives in memory only. **New chat** clears it.

**Open risk:** a bar widget list in a skel file may replace Noctalia's default list instead of appending, since TOML arrays do not merge. Verify during planning; if so, the skel file restates the default list plus the agent widget.

## Data flow

**Opening the panel.** `config.load()` decides the view: missing or invalid config → Setup; valid → Chat. A cog in the chat header returns to Setup with current values.

**Setup view.** Provider select, host URL (prefilled per provider), model, API token (masked; optional for OpenAI-compatible so local Ollama works). **Save** validates, then sends a one-token test request. Success writes `config.json` and opens Chat. Failure shows the HTTP status and provider message and saves nothing.

**A chat turn.**

1. Append the user message; the provider adapter builds the request (system prompt, history, tool schemas).
2. Stream with `noctalia.httpStream`. Render text deltas live; accumulate tool-call fragments.
3. Show each tool call as an approval card: tool, exact argv or path, content preview. **Run** executes; **Skip** returns `"user declined"`.
4. Redact the result (see Security). Send it, or hold it for review if flagged.
5. With all results in, loop to step 2. The turn ends when the model replies without tool calls.

**Stop** cancels the stream and abandons the turn. After 20 tool round-trips in one turn, the panel asks whether to continue.

Provider adapters translate between one internal message shape (`{role, text, tool_calls[], tool_results[]}`) and each provider's wire format. Nothing else touches provider JSON.

**Bar icon state** via `noctalia.state`: unconfigured, idle, and busy/needs-approval (accent colour), so a closed panel still signals that the agent is waiting.

## Error handling

- **Network or HTTP failure:** end the turn, show status and provider message, keep history, offer **Retry**. On `401`/`403`, link to Setup.
- **Malformed tool-call JSON:** return `"invalid arguments: …"` to the model. Three consecutive failures end the turn.
- **Command results:** non-zero exit is data, not an error. Output above 16 KB keeps the first and last 8 KB with a marker. 120 s timeout; if the process cannot be killed, report `timed out` and leave it running.
- **Interactive commands:** no TTY, so no `sudo` password prompts. The prompt steers the model to `pkexec` (lxpolkit dialog). Approval cards offer **Open in terminal** via `noctalia.runInTerminal`.
- **Corrupt `config.json`:** treat as unconfigured, show Setup with a notice, and leave the file until the user saves.

## Security: keep secrets on the machine

Tool output and file contents go to the LLM provider. The design minimises what secret material can reach it.

1. **The plugin's token never reaches the model.** `config.json` is hard-blocked for tools and commands. Outgoing requests are scrubbed for the token's literal value. The token is never logged or displayed.
2. **Sensitive-path rules** apply to `read_file`/`write_file` paths and to command text:
   - `~/.ssh`, `~/.gnupg`, `~/.password-store`, `~/.local/share/keyrings`
   - `~/.aws`, `~/.kube`, `~/.docker/config.json`, `~/.config/gh/hosts.yml`, `~/.netrc`, `~/.git-credentials`
   - browser profiles: `~/.mozilla`, `~/.config/{google-chrome,chromium,BraveSoftware}`
   - `/etc/shadow`, `/etc/gshadow`
   - `**/.env*`, `*secret*`, `*credential*`, `*.pem`, `*.key`

   A match marks the card red with the rule name and holds its output for review. The plugin's `config.json`, `shadow` files and keyrings are refused outright.
3. **Output scrubbers** replace matches with `[REDACTED:<kind>]`: PEM private keys; token formats (`sk-…`, `sk-ant-…`, `ghp_`/`gho_`/`github_pat_`, `AKIA…`, `xox[bp]-…`, `glpat-…`); JWTs; `Authorization`/`Bearer` headers; `user:pass@` URLs; `KEY=value` lines whose key contains `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`, `API_KEY` or `PRIVATE`.
4. **Visible egress.** Each result card shows exactly what will be sent, redactions marked. Unflagged results send automatically. Flagged results wait for **Send** / **Send redacted** / **Don't send** (`"output withheld by user"`).
5. **Destination shown.** The chat header reads **Local** for loopback hosts or **Remote: \<host\>**. The token goes only to the configured host, over HTTPS; plain HTTP is accepted only for `localhost`, `127.0.0.1` and `::1`.
6. **Nothing persisted** except `config.json`. No conversation logs, telemetry or clipboard access.

**Limits**, stated in the README and on the setup screen: redaction is best effort. Path rules cannot catch every indirect route to a secret, and pattern scrubbers miss unfamiliar formats. The guarantees are approval before every action, the visible send preview, and the option of a local model.

## Testing

- **Unit tests** in Luau for provider adapters (request building, SSE parsing, tool-call assembly against recorded fixtures), config validation, truncation, path rules and scrubbers. Run with a standalone `luau` binary in CI for modules that avoid `noctalia.*`; check during planning whether Noctalia's own test harness fits better.
- **Image check** in CI: plugin directory and skel files present; `plugin.toml` parses; optionally `noctalia msg plugins list` discovers the plugin.
- **Manual acceptance** in the VM (`just run-vm-qcow2`):
  1. Fresh user: icon present; click shows Setup.
  2. Bad token: error shown, nothing saved.
  3. Valid credentials for each provider: Chat opens.
  4. "What windows are open?" proposes `niri msg -j windows`; approving yields a sensible answer.
  5. Skip is respected; Stop cancels the stream.
  6. `cat ~/.ssh/id_ed25519.pub` style requests are flagged; `env` output shows redactions and waits for review.
  7. `Mod+A` toggles the panel.

## Out of scope (v1)

Conversation history across restarts, keyring storage for the token, auto-approved read-only commands, and a trust/unattended mode.
