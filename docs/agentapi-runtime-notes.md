# `agentapi` runtime notes — Phase 0 verification spike (COMPLETE)

Last run: 2026-05-21 against Antigravity 2.0.1 (PID 26408 on this machine, signed in).
Binary: `/Applications/Antigravity.app/Contents/Resources/bin/language_server` (126,767,984 bytes arm64 Mach-O).
User-dir shim: `~/.gemini/antigravity/bin/agentapi` (100-byte POSIX shell script — alias for above).

## TL;DR — plan needs major revision

Phase 0 contradicts the originally-planned spawn/relay architecture in several material ways. The carveout in the plan's Execution Discipline triggers: *"Phase 0 spike outputs that materially contradict locked decisions — surface findings + propose adjustment + halt."*

**The actual agentapi shape is much closer to HTTP-RPC than to "spawn a CLI in tmux":**

- `new-conversation` and `send-message` are **fire-and-forget one-shot CLI calls** that return immediately with just an ID. Agent work happens asynchronously inside the running language_server process. No streamed stdout.
- Conversations are now stored as **SQLite databases** (`<id>.db` + `.db-wal` + `.db-shm` in WAL mode), NOT protobuf `.pb` files. v0.7's `ConversationProtoParser` does NOT handle the new format.
- Approval modes (plan/yolo/accept-edits) are **not exposed** via agentapi argv. Only `--model={flash_lite|flash|pro}`.
- agentapi requires **a running language_server** (typically Antigravity.app's) — Clawdmeter spawning its own LS is fallback, not primary.

## Confirmed argv contract

```
Usage: agentapi <command> [args]

Available Commands:
  get-conversation-metadata <conversation_id>
  new-conversation [--model=<flash_lite|flash|pro>] <prompt>
  send-message <recipient_id> <content>
```

`new-conversation` flags (verified by `--help`-via-error):
```
Usage of new-conversation:
  -model string
    	Model tier to use (flash_lite, flash, pro). (default "flash")
```

That's the entire surface. No `--thinking-budget`, no `--approval-mode`, no `--workspace`, no `--cwd`, no `--system-prompt`. Just `-model` + the prompt.

## Required environment

agentapi is a CLIENT that talks to a running language_server over HTTP. Three env vars must be set for any call to succeed:

| Variable | Value | Source |
|---|---|---|
| `ANTIGRAVITY_LS_ADDRESS` | `http://127.0.0.1:<port>` | Parse from Antigravity.app's `language_server` argv (`--http_server_port`) OR lsof on its PID. Port `53824` on this run; **random per LS launch**. |
| `ANTIGRAVITY_CSRF_TOKEN` | UUID | From Antigravity.app's `language_server` argv (`--csrf_token c61...`). Fixed per LS launch. |
| `ANTIGRAVITY_PROJECT_ID` | UUID | From `~/.gemini/config/projects/<uuid>.json` discovered via `~/.antigravitycli/<uuid>.json` symlink. Per-workspace. |

Without `ANTIGRAVITY_PROJECT_ID` (even from a clean cwd):
```json
{"error": "failed to start cascade: rpc error: code = Unknown desc = project_id is required when providing project_env_config"}
```

The CSRF token + LS address combo is the SAME state-machine `LanguageServerClient.swift` already extracts in v0.7. Reuse that flow.

## Architecture revision — agentapi is HTTP-RPC, not CLI-with-stream

### What the plan assumed
- Each Gemini session = a long-lived process spawned via `language_server agentapi new-conversation …`
- Process streams events via stdout JSON-lines (Codex SDK pattern)
- `AntigravitySubscriptionRelay` manages per-session process lifecycle
- Tmux pane shows the agent's live output

### What's actually true
- `new-conversation` is **synchronous over HTTP** — completes in ~70ms returning just `{conversationId, prompt}`. The agent's actual turn happens server-side inside Antigravity's language_server.
- `send-message` is same shape — completes immediately with echo.
- To **observe** the agent's progress, you must EITHER:
  - **Read the SQLite DB** (`~/.gemini/antigravity/conversations/<id>.db`) directly. WAL mode means reads see latest state without blocking the writer.
  - **Subscribe to language_server's gRPC streaming endpoints** (`/v1internal:streamGenerateChat` and friends — binary strings showed them).
  - **Tail the brain dir** for `~/.gemini/antigravity/brain/<id>/{task.md, implementation_plan.md, *.metadata.json}` updates.

### Implications for the locked decisions

| Decision | Status | Revision |
|---|---|---|
| **D3 process lifetime fork** | Resolved → one-shot | No tmux pane needed. agentapi is HTTP-RPC. Spawn is sub-second; no process to manage per session. |
| **D9 SDKSubscriptionRelay protocol** | OBSOLETE for agentapi | Codex pattern doesn't apply. Antigravity needs `AntigravitySnapshotPoller` (SQLite WAL reader) instead of `AntigravitySubscriptionRelay` (stdout streamer). |
| **D12 single shared language_server** | Resolved → use Antigravity.app's LS | Clawdmeter's daemon does NOT spawn its own LS for the primary path. We attach to the existing Antigravity.app LS via probe-and-defer (D4). Spawn-our-own-LS is a fallback for when the app is closed. |
| **D7 event catalog** | Pending → SQLite schema, not stdout | Need a `ConversationDBReader` that opens the SQLite, queries `steps` table, maps `step_type` integers to ChatItems. SQLite schema captured in `docs/agentapi-event-catalog.md`. |
| **D2 dual-dir parsing** | Refined | Both `.pb` (legacy v0.7 conversations) and `.db` (new v0.8 conversations) coexist in `~/.gemini/antigravity/conversations/`. Need format-detector + dual parser. `antigravity-cli/` dir has OLD test conversations only. |
| **D14 v0.42 fallback** | Still valid | Users without Antigravity.app installed get gemini v0.42 path. |
| **D10 AntigravitySource (quota)** | Re-scoped to v0.8.0 | Still need to swap cloudcode-pa → language_server `/v1internal:fetchUserInfo` for subscription quota. Can ride on the same LS HTTP client. |
| **Approval modes** | NO LONGER SUPPORTED for agentapi sessions | Plan-mode / yolo / accept-edits flags don't exist in agentapi argv. v0.8.0 sessions effectively run in agentapi's default behavior (which is "ask for tools"-ish — needs more probing). Document as known limitation. |

## File format change — SQLite, not protobuf

Conversations created via agentapi in this run produced:
```
~/.gemini/antigravity/conversations/4d67b68a-7d62-45bd-a3cc-e4f46fb27ef3.db
~/.gemini/antigravity/conversations/4d67b68a-7d62-45bd-a3cc-e4f46fb27ef3.db-wal
~/.gemini/antigravity/conversations/4d67b68a-7d62-45bd-a3cc-e4f46fb27ef3.db-shm
```

Old `.pb` files (v0.7 conversations) coexist in the same directory. The DB schema is captured in `docs/agentapi-event-catalog.md`. Top-level shape:

```
trajectory_meta          1 row    cascade_id = conversation_id
steps                    N rows   message/turn entries with step_type, status, step_payload (proto blob)
gen_metadata             K rows   generation metadata blobs
executor_metadata        2 rows   executor state
trajectory_metadata_blob 1 row    overall metadata
parent_references        0 rows   (sub-chats)
battle_mode_infos        0 rows   (A/B)
```

`step_payload` is a protobuf blob — same proto schema as `.pb` files used to contain. We can reuse the proto schema work from v0.7's `ConversationProtoParser` to decode `step_payload`, just driven from SQLite rows instead of file bytes.

## Brain dir + state.pbtxt — UNCHANGED

`~/.gemini/antigravity/brain/<conversation_id>/` is still created with `.system_generated/` subdir. v0.7's `BrainPlanParser`, `AntigravityStateReader` (for `~/.gemini/antigravity/antigravity_state.pbtxt`), and `BrainSummaryIndexer` (for `agyhub_summaries_proto.pb`) all still apply unchanged.

`agyhub_summaries_proto.pb` IS actively written (mtime tracks recent activity). The string-scan approach in v0.7's indexer continues to work.

## Antigravity.app's `language_server` argv (this run)

```
language_server --standalone \
    --override_ide_name antigravity \
    --subclient_type hub \
    --override_ide_version 2.0.1 \
    --override_user_agent_name antigravity \
    --https_server_port 0 \
    --csrf_token c61581fa-3454-479a-8ab7-130701bf3772 \
    --app_data_dir antigravity \
    --api_server_url https://generativelanguage.googleapis.com \
    --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com \
    --enable_sidecars
```

Listens on `127.0.0.1:53823` (HTTPS/gRPC) + `127.0.0.1:53824` (HTTP). agentapi talks to HTTP (53824); language_server's other clients use gRPC.

## Discovery shape for `LanguageServerClient.discoverLive()`

When Antigravity.app is running:
1. `pgrep -f "Antigravity.app.*language_server"` → finds the PID
2. Parse `--csrf_token` from `ps -o command= <pid>` → CSRF
3. `lsof -nP -iTCP -sTCP:LISTEN -p <pid>` → returns 2 listening ports; pick the second numerically (HTTP, not gRPC)
4. Parse `--app_data_dir` and `--cloud_code_endpoint` from same ps output

When Antigravity.app is NOT running:
1. No `language_server` process exists for this account
2. Plan-D4 fallback: Clawdmeter daemon spawns its own LS with `language_server -persistent_mode=true -local_chrome_headless=true -disable_telemetry=true -app_data_dir=clawdmeter-cli -http_server_port=0 -csrf_token=$(uuidgen)`
3. Parse port from `~/.gemini/antigravity-cli/log/cli-<TS>.log` (the `Language server listening on random port at <N> for HTTP` line)

## Subscription quota endpoint (`/v1internal:fetchUserInfo`)

Untested in this Phase 0 (didn't make the HTTP call directly), but binary strings confirm the endpoint exists. Returns user info including subscription tier. v0.8.1's `AntigravitySource` rewrite calls this via the same CSRF-gated HTTP client.

## Phase 0.5 verification spike (2026-05-21, post eng-review #2)

Three probes from the revised plan, all resolved against the on-disk artifacts left by the earlier Phase 0 run (Antigravity.app was not running during this probe — the persisted state was enough).

### Probe 1 — `step_payload` blob decode (T7/D11)

`step_payload` in the SQLite `steps` table is **plain protobuf, not encrypted.** Hex dump of first 64 bytes per row shows canonical wire format:

```
0|14|3|194|080E20032A9A010A0C08E6CCB8D00610C0878DDA031804622464373031626363612D...
3|9 |3|4082|080920032AA00E0A0C08E8CCB8D0061088E3BDDF01180222B60B0A086967617936726C3312086C6973745F6469721A...
6|8 |3|1417|080820032AFE040A0C08E9CCB8D0061098BD8C980218022297020A0876646D746E6F74361209766965775F66696C651A...
```

- Byte 0 = `0x08` (varint, field 1) — step index
- Byte 2 = `0x20` (varint, field 4) — status-like field
- Byte 4 = `0x2A` (length-delimited, field 5) — nested message (actual step content)
- Strings visible inline: `list_dir`, `view_file`, `gigay6rl3`, `vdmtno6` — tool call IDs + tool names readable as plain UTF-8 inside the nested message.

**Verdict: D11 path A** — `ConversationProtoParser.decode(_ data:)` refactor proceeds. The `step_payload` blob feeds the same proto decode as legacy `.pb` files. No pivot to gRPC `StreamGenerateChat` needed.

### Probe 2 — security preset location (T5/D10) — RESOLVED via filesystem, not gRPC

Plan said: probe `GetUserSettings` gRPC for default approval mode. **Reality: lives on disk in `~/.gemini/config/projects/<id>.json` under `settings.*`.** No gRPC call needed.

Example (CC Watch project, `459a1414-...`):
```json
"settings": {
  "fileAccessPolicy":     "AGENT_SETTING_POLICY_ASK",
  "internetPolicy":       "AGENT_SETTING_POLICY_ASK",
  "autoExecutionPolicy":  "CASCADE_COMMANDS_AUTO_EXECUTION_OFF",
  "artifactReviewMode":   "ARTIFACT_REVIEW_MODE_ALWAYS"
}
"permissionGrants": {
  "allow": [
    "command(find)",
    "command(grep)"
  ]
}
```

**Display string mapping for chat header (D10):**

| `autoExecutionPolicy` value | Chat-header copy |
|---|---|
| `CASCADE_COMMANDS_AUTO_EXECUTION_OFF` | "Antigravity: ask before each tool" |
| `CASCADE_COMMANDS_AUTO_EXECUTION_ON` (assumed) | "Antigravity: auto-execute tools" |
| Other | "Antigravity: unknown preset (check app settings)" |

Plus parenthetical `+ N pre-approved commands` when `permissionGrants.allow` non-empty.

**Verdict: D10 simplified.** Replace `LanguageServerClient.getUserSettings()` (gRPC) with `AntigravityProjectSettings.read(forProjectId:)` filesystem helper. Watch the project JSON via FSEvents for live updates. Saves the entire `GetUserSettings` gRPC implementation.

### Probe 3 — `workspace_uri` field (T4/D6) — RESOLVED at `projectResources.resources[].gitFolder.folderUri`

Plan said: scan projects JSON for `workspace_uri` field. **Reality: workspace path at `projectResources.resources[].gitFolder.folderUri`** with URL-encoded paths.

Examples on this machine:
- `glide.co` → `file:///Users/darshanbathija_1/Downloads/glide.co`
- `CC Watch` → `file:///Users/darshanbathija_1/Downloads/CC%20Watch` (URL-encoded space)
- `Defx V3` → `file:///Users/darshanbathija_1/Downloads/Defx%20V3`
- `outside-of-project` → `projectResources: null` (sentinel for "no specific project")

**Verdict: D6 refined.** `AntigravityProjectResolver`:
1. Walk `~/.gemini/config/projects/*.json`
2. For each: `data.projectResources?.resources[].gitFolder?.folderUri` → strip `file://` prefix → URL-decode
3. Canonicalize via `RepoIdentity.normalize`
4. Match against `RepoIdentity.normalize(session.repoKey)`
5. Cache `[normalizedRepoKey: projectId]`
6. Skip records where `projectResources == nil`
7. Honor `gitFolder.allowWrite` if present — when `false`, surface read-only banner.

### Pending probes (not blocking v0.8.0 commits)

These don't block any code path locked in the plan. Resolve during v0.8.0 implementation if convenient.

1. `/v1internal:fetchUserInfo` exact JSON shape (needs LS running). D9 ships with a tolerant decoder + 'Open Antigravity' fallback.
2. Concurrent `agentapi new-conversation` under load — verify multiplex works for ≥3 simultaneous calls.
3. `setUserSettings` writeback — if we ever want to flip approval policy from Clawdmeter (not in v0.8.0).
4. Sub-chats parent-child linkage — Antigravity-side gRPC `Cascade`, deferred to v0.9.

## Untested / pending probes from original Phase 0

1. **gRPC streaming** for real-time turn observation — DEFERRED (D11 path A makes SQLite WAL the primary observation source).
2. **Sub-chats** — Deferred to v0.9.
3. **`SetUserSettings` gRPC** — OBSOLETE per Probe 2 (filesystem path works).
4. **`/v1internal:fetchUserInfo` shape** — pending, non-blocking.
5. **Concurrent agentapi calls** — likely safe, verify during implementation.
