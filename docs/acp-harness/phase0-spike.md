# Phase 0 — ACP harness de-risk spike (results)

Run 2026-06-02 on this machine, branch `feat/acp-harness`. Goal: confirm the real wire dialects before any architecture work, per the approved plan (`~/.claude/plans/resilient-zooming-summit.md`).

## TL;DR

| Agent | Verdict | Transport | Auth method id | loadSession | Notes |
|---|---|---|---|---|---|
| **Grok** | ✅ GO | ACP v0.11.3 over stdio (`grok agent --no-leader stdio`) | `grok.com` | yes | agent v0.2.11; models runtime-discoverable; `always-approve` command exists |
| **Cursor** | ✅ GO | ACP v0.11.3 over stdio (`cursor-agent acp`) | `cursor_login` | yes | `image:true`, `sessionCapabilities.list`; in-session config TBD |
| **Antigravity** | ⚠️ CEILING | agentapi = fire-and-forget HTTP-RPC + SQLite observation | n/a (LS CSRF) | n/a | **plan/approval NOT exposed via agentapi**; send + observe only |

Both ACP agents returned a textbook ACP `initialize` result (`protocolVersion: 1`, `agentCapabilities.loadSession: true`, `authMethods`). Fixtures: `fixtures/grok-initialize.json`, `fixtures/cursor-initialize.json`.

## Confirmed design points (feed into Phase 2)

1. **Resolve auth from `initialize.authMethods`, never hardcode.** Grok = `grok.com`, Cursor = `cursor_login`. (The dpcode reference's `xai.api_key`/`cached_token` is stale — grok agent is now 0.2.11.)
2. **Runtime model discovery works for ACP agents.** Grok advertises `availableModels` in `initialize._meta.modelState` (`grok-build`, 500k ctx). This partly obsoletes the `cli-list-models-missing` learning for ACP agents — prefer the advertised list, fall back to a catalog.
3. **`loadSession: true` on both** → the revive path (`session/load` → fallback `session/new`) is supported.
4. **`_meta` is pervasive and carries vendor data.** Grok nests `_meta` at top level, in `agentCapabilities`, and per-model (`x.ai/fs_notify`, `grokShell`). Model `_meta` as a permissive `JSONValue` and apply the `_meta`-strip quirk at the decode edge.
5. **SECURITY: scrub fixtures.** Grok's live `initialize._meta.mcpServers` echoed the user's MCP configs **including secrets** (Google client secret, an Instantly API key in a URL). Any captured frames committed as fixtures MUST be scrubbed (done here). The driver must also never log raw `initialize` `_meta`.
6. Grok exposes an `always-approve` slash command and `--always-approve` flag — maps to our plan-approval / autopilot path.

## Antigravity ceiling (materially adjusts Phase 7)

A prior completed spike (`docs/agentapi-runtime-notes.md`, `docs/agentapi-event-catalog.md`, 2026-05-21 vs Antigravity 2.0.1) already established the agentapi shape, and it contradicts the plan's Phase-7 hope of "real plan/diff/permission RPCs":

- `agentapi new-conversation` / `send-message` are **one-shot HTTP-RPC** calls that return just an id; the turn runs server-side in Antigravity.app's `language_server`. No stdout stream.
- The **entire argv surface is `--model={flash_lite|flash|pro}` + prompt.** No `--approval-mode`, no plan/accept-edits, no workspace/cwd flags. So **plan-approval and permission prompting are not drivable through agentapi.**
- Observation is via the conversation **SQLite DB** (`~/.gemini/antigravity/conversations/<id>.db`, WAL) — which is exactly what `AntigravityChatIngestor` already tails — or the `language_server` gRPC streaming endpoints (`/v1internal:streamGenerateChat`) which need CSRF + protobuf-schema extraction.

### Recommended Phase-7 adjustment

Gemini/Antigravity cannot be a full interactive drive-harness (plan-approve + permission round-trips) through agentapi as it exists. Re-scope Phase 7 to one of:
- **(A) Send + rich observe** (recommended, durable, low-risk): drive = send prompt; observe = SQLite WAL streaming (extend the existing ingestor) + brain-dir plan. No plan-approval/permission parity. Document the ceiling in-product.
- **(B) gRPC streaming + protobuf extraction**: higher fidelity (real step stream, maybe permissions blob), but a large lift (CSRF gRPC client + `tools/extract-antigravity-proto.sh` + protobuf decode of `steps.step_payload`/`permissions`). Only if Gemini parity is a hard requirement.

This is the plan's "Phase-0 contradicts a locked expectation → surface + propose adjustment" carveout. Needs a user call before Phase 7 (does not block the Grok vertical slice).

## How the fixtures were captured

`initialize` request sent verbatim:
```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},"clientInfo":{"name":"clawdmeter-spike","version":"0.1.0"}}}
```
Grok responded on stdout immediately. Cursor needs a writable `$HOME` (it `mkdir`s `~/.cursor/projects/...`) — run with an isolated HOME in tests. Neither required network auth to answer `initialize` (auth is a later `authenticate` call).
