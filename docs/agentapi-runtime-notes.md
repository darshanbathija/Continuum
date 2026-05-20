# `agentapi` runtime notes — Phase 0 verification spike

Last run: 2026-05-21
Binary inspected: `/Applications/Antigravity.app/Contents/Resources/bin/language_server` (126,767,984 bytes, arm64 Mach-O)
User dir variant: `~/.gemini/antigravity/bin/agentapi` (100-byte POSIX shell script, alias for the above)
Status: **PARTIAL — OAuth wall blocks the runtime probes.** See "Production-blocking finding" below.

## Confirmed

### Binary locations (D6 multi-path probe)
- `/Applications/Antigravity.app/Contents/Resources/bin/language_server` — confirmed present + executable.
- Other 3 candidate paths from D6 — NOT present on this machine.
- `~/.gemini/antigravity/bin/agentapi` — present as a 100-byte shell script that does:
  ```sh
  #!/bin/sh
  exec "/Applications/Antigravity.app/Contents/Resources/bin/language_server" agentapi "$@"
  ```
- The shell script is a convenience alias; we can invoke `language_server agentapi …` directly with identical results.

### Subcommand surface (D3 partial — argv known, runtime behavior pending OAuth)
`language_server agentapi` prints:
```
Usage: agentapi <command> [args]

Available Commands:
  get-conversation-metadata <conversation_id>
  new-conversation [--model=<flash_lite|flash|pro>] <prompt>
  send-message <recipient_id> <content>
```

### Model flag — CRITICAL FINDING
`--model` accepts **shortcuts only**: `flash_lite`, `flash`, `pro`. NOT full IDs like `gemini-3.5-flash` or `gemini-3.5-flash-thinking`. This contradicts the v0.7 `ModelCatalog.bundled.gemini` entries which all use full IDs (`gemini-3.5-flash`, `gemini-3-pro`, etc.).

**Implication for D2/D7 mapping** — `AgentapiArgvBuilder` MUST translate catalog IDs to shortcuts. No direct mapping shipped. Proposed table (preliminary; needs verification against actual subscription quota behavior):

| ModelCatalog id | agentapi --model | notes |
|---|---|---|
| `gemini-3.5-flash` | `flash` | default |
| `gemini-3.5-flash-thinking` | `flash` + (thinking flag TBD) | thinking mode may be a separate flag not visible in argv help |
| `gemini-3-flash` | `flash` | maps to same shortcut |
| `gemini-3-flash-thinking` | `flash` + thinking | same |
| `gemini-3-pro` | `pro` | |
| `gemini-3.1-pro-high` | `pro` | (effort encoded elsewhere?) |
| `gemini-3.1-pro-low` | `flash_lite` | (guess — needs verification) |

### `agentapi` execution model — DAEMON-CLIENT, not standalone
When invoked without `ANTIGRAVITY_LS_ADDRESS` env var, every agentapi subcommand returns:
```json
{"error": "ANTIGRAVITY_LS_ADDRESS is not set"}
```

This proves `agentapi` is a CLIENT to a running `language_server`, not a standalone process. Architecture confirmed:
- **Server side**: a long-running `language_server` instance with `-persistent_mode=true` (or equivalent) listening on a random port.
- **Client side**: `language_server agentapi <cmd>` with `ANTIGRAVITY_LS_ADDRESS=http://127.0.0.1:<port>` env var.

**Implication for D12** — single shared `language_server` daemon is the right architecture; agentapi clients are stateless wrappers around HTTP calls to it.

### Server flags (from `language_server --help`)
Relevant flags for daemon mode:
- `-persistent_mode=true` — daemon doesn't exit when extension closes
- `-http_server_port=N` (0 = random)
- `-https_server_port=N`
- `-csrf_token=<uuid>`
- `-extension_server_port=N`
- `-extension_server_csrf_token=<uuid>`
- `-headless=true`
- `-local_chrome_headless=true` — skips Chrome eval env
- `-disable_telemetry=true`
- `-app_data_dir=<path>` — relative to GeminiDir; default `antigravity-ide`
- `-gemini_dir=.gemini` — base path (relative or absolute)
- `-parent_pipe_path=<path>` — IPC for parent-process liveness checks

### Server startup log shape
`~/.gemini/antigravity-cli/log/cli-<TS>.log` header reveals:
```
I0521 02:55:54.291048  9401 server.go:1295] Starting language server process with pid 9401
I0521 02:55:54.292520  9401 server.go:471] Language server will attempt to listen on host localhost
I0521 02:55:54.295283  9401 server.go:485] Language server listening on random port at 52585 for HTTPS (gRPC)
I0521 02:55:54.295677  9401 server.go:492] Language server listening on random port at 52586 for HTTP
```

**Two ports per instance**: HTTPS gRPC + HTTP. Ports are random per launch. Discovery shape for `LanguageServerClient.discoverLive()`:
1. List `~/.gemini/antigravity-cli/log/cli-*.log` newest-first by mtime
2. Parse PID from `server.go:1295] Starting language server process with pid <N>`
3. Parse HTTP port from `server.go:492] Language server listening on random port at <N> for HTTP`
4. Liveness via `kill -0 <pid>` + `lsof -nP -iTCP:<port>`

Compare to v0.7's `LanguageServerClient` which reads `~/.gemini/antigravity/logs/<TS>/ls-main.log` (different path, used by the desktop Electron app). **Two log locations to support:**
- `~/.gemini/antigravity/logs/<TS>/ls-main.log` — when Antigravity.app is running
- `~/.gemini/antigravity-cli/log/cli-<TS>.log` — when language_server runs in CLI mode

D2 dual-dir parsers extend to this too.

### CLI mode behavior
`language_server` invoked without specific flags enters "CLI mode" (per log: `I0521 02:55:54.828126  9401 common.go:103] Launching CLI mode`). In this mode:
- Writes to `~/.gemini/antigravity-cli/` (separate from `~/.gemini/antigravity/`)
- Spawns Chrome ("Entering local chrome mode! This is WRONG unless you are running tests"). Likely disable-able via `-local_chrome_headless=true`.
- Initializes a CLI server backend with `cascadeManager=true codeAssist=true`
- Discovers project: `discovered project "/Users/<user>" via /Users/<user>/.antigravitycli`

## Production-blocking finding (HALT criterion per plan)

**Per plan's Execution discipline:**
> Phase 0 spike outputs that materially contradict locked decisions — surface findings + propose adjustment + halt
> Production-blocking discovery (e.g., agentapi requires OAuth flow we can't script)

**OAuth wall:** every server-side initialization step fails with:
```
E0521 02:55:54.818634  9401 log.go:398] Failed to poll ListExperiments: error getting token source: You are not logged into Antigravity.
W0521 02:55:54.819392  9401 log_context.go:117] Cache(availableModels): Singleflight refresh failed
E0521 02:55:54.819416  9401 log.go:398] Failed to poll FetchAvailableModels
W0521 02:55:54.825822  9401 client.go:81] failed to set auth token
```

The user on this machine has **never signed into Antigravity 2**. Confirmed by:
- `~/.gemini/antigravity/logs/` directory does not exist (only created on first Antigravity.app launch with valid auth)
- `~/.gemini/oauth_creds.json` exists (Google OAuth for gemini-cli v0.42) but Antigravity 2 wants a separate Antigravity-scoped OAuth token that goes through `auth provider: You are not logged into Antigravity.`

**Without auth, `agentapi new-conversation` cannot complete** — token fetch fails before model selection. So I cannot:
- Confirm process lifetime (REPL vs one-shot) — needs a real conversation
- Enumerate event catalog (D7) — needs streamed stdout from a real turn
- Verify multiplex behavior (D12) — needs concurrent conversations
- Verify OAuth failure-shape detection (D5) — needs both states (signed-in vs not)

## Adjustments to plan (for user approval)

### Required before continuing Phase 0:
- **User must launch Antigravity 2 and complete sign-in.** This is a one-time UX flow that Clawdmeter cannot automate (per the plan's risk-register row about OAuth wall).

### Confirmed adjustments to lock into plan:
1. **Model flag mapping**: `AgentapiArgvBuilder` translates ModelCatalog IDs → `flash_lite|flash|pro` shortcut. New `ModelCatalogEntry.agentapiAlias` field. Table populated in this doc (preliminary; refresh after live verification).
2. **Daemon-client architecture confirmed**: D12 (single shared LS) is correct. `AntigravityLanguageServerCoordinator` spawns ONE LS with `-persistent_mode=true -local_chrome_headless=true -disable_telemetry=true -app_data_dir=clawdmeter-cli` (last to isolate state from the user's `antigravity-cli/`). Coordinator passes `ANTIGRAVITY_LS_ADDRESS=http://127.0.0.1:<port>` to every agentapi client spawn.
3. **Two log locations for `LanguageServerClient.discoverLive()`**: desktop app path AND CLI mode path. D2 dual-dir parsers gain a third dimension (`~/.gemini/antigravity-cli/log/`).
4. **`-local_chrome_headless=true`** required to prevent Chrome eval env startup (saves RAM + avoids surprising the user with a browser).
5. **Thinking-mode flag is invisible in argv help.** Either `--model=flash` + a separate `--thinking-budget=N` flag exists but isn't documented, OR thinking mode requires a different subcommand. Phase 0 must probe more (post-OAuth).

## Pending probes (need authenticated Antigravity)

After user signs in to Antigravity 2, this spike resumes with:

1. **Process lifetime** (D3): does `agentapi new-conversation` enter REPL or exit after first turn?
2. **Event catalog** (D7): capture stdout from a real conversation. Enumerate every `{type, ...}` JSON shape into `docs/agentapi-event-catalog.md`.
3. **Dir writes**: confirm whether agentapi writes to `~/.gemini/antigravity-cli/conversations/` and/or `~/.gemini/antigravity/conversations/`.
4. **Multiplex** (D12): spawn 2 concurrent `new-conversation` calls against one LS, confirm separate conversation IDs returned without state corruption.
5. **OAuth failure shape detection** (D5): with valid token, run; then revoke (delete oauth file), run again, capture the exact failure shape so `AntigravityInstall.preflight` can detect it.
6. **Thinking mode**: is there a hidden flag (`--thinking-budget=N`?), or does setting `--model=flash` automatically enable thinking based on prompt complexity, or is thinking-mode unavailable via agentapi?
7. **Quota endpoint** (D10): does `/v1internal:fetchUserInfo` return subscription quota when authed? Confirms `AntigravitySource` rewrite path.

## Argv shape — preliminary (locks after probes 1-7 above complete)

```swift
// Confirmed by --help
public enum AgentapiArgvBuilder {
    public static func newConversationArgv(
        languageServerBinary: String,
        modelShortcut: String,           // flash_lite | flash | pro
        prompt: String,
        // approvalMode: ApprovalMode? — flag presence unknown; needs post-OAuth probe
    ) -> [String] {
        [languageServerBinary, "agentapi", "new-conversation",
         "--model=\(modelShortcut)", prompt]
    }

    public static func sendMessageArgv(
        languageServerBinary: String,
        recipientId: String,    // conversation_id from prior new-conversation
        content: String
    ) -> [String] {
        [languageServerBinary, "agentapi", "send-message", recipientId, content]
    }

    public static func getMetadataArgv(
        languageServerBinary: String,
        conversationId: String
    ) -> [String] {
        [languageServerBinary, "agentapi", "get-conversation-metadata", conversationId]
    }
}
```

Approval-mode flag (plan|auto_edit|yolo) is NOT in the `agentapi` argv help. The gemini v0.42 CLI had it; agentapi may have moved it to a server-side setting (`SetUserSettings` gRPC from `LanguageServerService`?) or dropped it entirely. **Needs post-OAuth verification.**

## Next step

User must launch `/Applications/Antigravity.app` and complete sign-in flow. Once `~/.gemini/oauth_creds.json` is populated with an Antigravity-scoped token (distinguishable from the gemini v0.42 token by claim shape), I resume Phase 0 with the pending probes 1-7.

Until then, the implementation is BLOCKED at Phase 0. v0.8.0 commit 1 lands this docs file; no code commits can land without the runtime confirmations.
