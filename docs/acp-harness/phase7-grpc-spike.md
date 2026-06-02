# Phase 7 spike — Antigravity / Gemini over gRPC (the "bigger path")

**Date:** 2026-06-02 · **Verdict: GO — and bigger than the plan assumed.**
The plan locked "drive via agentapi one-shot, *observe* via gRPC." The spike
finds the `language_server` gRPC surface exposes a **full drive loop**
(start + stream + cancel + revert + permission), not just observation. Gemini
can be a first-class harness provider over gRPC, not a send-and-watch ceiling.

Tooling: `tools/extract-antigravity-proto.sh` (runnable; re-extracts everything
below). Artifacts: `docs/acp-harness/antigravity-proto/{proto-inventory,field-map,v1internal-fields,rpc-methods}.txt`.

## What's recoverable (and how)

`Antigravity.app/Contents/Resources/bin/language_server` is a 121 MB Go binary
built with the modern protobuf runtime (`*_go_proto`). It embeds:

- **271 `.proto` file paths** — the full compiled schema inventory.
- **8 600 `protobuf:"…"` struct tags** — every message's field name + number +
  wire type + json name. **These struct tags ARE the schema** and are the
  reliable extraction source for a Go binary (no carving needed). 248 of them
  cover the step/diff/tool/permission surface we map.
- **626 gRPC `/package.Service/Method` paths** — the service + method surface.

Notes on the two extraction routes:
- **Struct-tag field map (authoritative, always works).** What the tool uses.
- **FileDescriptorProto carve + `protoc --decode` (best-effort).** Boundary
  detection in a stripped Go binary is unreliable; the tool attempts it and
  falls back to the field map. `protoc` (libprotoc 35) is present; `grpcurl`
  and `protoc-gen-go` are not.
- **gRPC server reflection is NOT compiled in** → no live `grpcurl describe`.
  Static extraction is the path; this is why the field map matters.

## The real surface — `exa.language_server_pb.LanguageServerService`

The Cascade* methods (Cascade = Antigravity's agent loop) are the drive surface.
This supersedes the plan's `v1internal:streamGenerateChat` guess (that service,
`google.internal.cloud.code.v1internal.JetskiService`, exists but is auth/quota/
settings plumbing — `FetchUserInfo`, `FetchAvailableModels`, `GenerateContent`).

| Capability | RPC (`LanguageServerService/…`) | Maps to |
|---|---|---|
| **Start a turn** | `StartCascade` | `AgentDriver.start` / `prompt` |
| **Observe (stream)** | `StreamCascadeReactiveUpdates`, `StreamAgentStateUpdates`, `StreamCascadeSummariesReactiveUpdates`, `StreamUserTrajectoryReactiveUpdates` | `HarnessEvent` stream |
| **Cancel** | `CancelCascadeSteps`, `CancelCascadeInvocation`, `ForceStopCascadeTree` | `AgentDriver.cancel` |
| **Undo** | `RevertToCascadeStep` | (new) revert control |
| **Read state** | `GetCascadeTrajectory`, `GetCascadeTrajectorySteps`, `GetAllCascadeTrajectories` | revive / cold-load |
| **Terminal** | `StreamTerminalShellCommand` | terminal pane (Phase 6 trust-gated) |

`StreamCascadeReactiveUpdates` (server-streaming) is the equivalent of the ACP
`session/update` stream — it pushes Cascade step deltas as the turn runs.

## Step → HarnessEvent mapping (field numbers from `v1internal-fields.txt`)

The trajectory step payload is a oneof (`step_payload`); the cases we map:

| Cascade step field | HarnessEvent |
|---|---|
| `trajectory_steps` (rep, 1) — the step list | (drives the whole projection) |
| assistant text / summary deltas | `.agentMessageDelta` |
| `tool_call` (oneof, json `toolCall`) + `tool_call_id` / `tool_call_json` (2) | `.toolCall` |
| `unified_diff` (1/3) · `file_diffs` (rep,1) · `diff_outline` (1) · `file_diff_comments` (rep,10) · `trajectory_file_diffs_update` (11) | `.diff` |
| `is_permission` (varint,3) · `approval_type` (varint,3/4, enum `UserTeamDetailsType`) · `PermissionId` · `preapprovals` (rep,1/2) · `proposal_tool_calls` (rep,1) | `.permissionRequest` |
| terminal status / completion | `.turnEnded(stopReason:)` |

Enum to pull next: `exa.cortex_pb.CortexStepType` (`allowed_cascade_step_types`,
varint 18) — the canonical step-type discriminator; transcribe it from the field
map / a carved descriptor before writing the decoder.

## Transport — already 90% wired

`LanguageServerClient` (`ClawdmeterMac/AgentControl/LanguageServerClient.swift`)
already discovers everything the gRPC client needs, per launch:
- **CSRF token** — parsed from the LS process argv (`--csrf_token <uuid>`; the
  asar confirms `crypto.randomUUID()` → `startLanguageServer(port, csrf)`).
- **gRPC port** — `httpsPort` (the lower of the two consecutive listening ports;
  `httpsBaseURL` = `https://127.0.0.1:<port>`). The higher port is agentapi HTTP.

So Phase 7 reuses `LanguageServerClient.discoverLive()` for `(csrf, httpsPort)`
and opens a gRPC channel to `httpsBaseURL` with the CSRF on metadata.

## Implementation plan — `AntigravityCascadeDriver` (`.antigravityAgentAPI`)

1. **gRPC client.** Add SwiftPM `grpc-swift` (+ `swift-protobuf`) OR hand-roll
   HTTP/2 framing over the neutral transport. Generate Swift types from the
   field map (hand-write the ~6 messages we touch; do not vendor all 271 protos).
2. **Drive.** `StartCascade(prompt, cwd, model)` to begin a turn; reuse
   `cancel → CancelCascadeSteps`; `revert → RevertToCascadeStep`.
3. **Observe.** `StreamCascadeReactiveUpdates` (server-stream) → decode step
   payloads → `AntigravityCascadeMapper` → `HarnessEvent` (mirror `ACPEventMapper`),
   then the SAME `AcpHarnessProjection`/bridge path lands it in `SessionChatStore`.
4. **Permission.** `is_permission`/`approval_type` steps → `PendingPermissionPrompt`;
   answer by the corresponding Cascade approval RPC (identify the
   `Approve*Cascade*` / pre-approval mutation in `rpc-methods.txt`).
5. **Fallbacks.** Keep `AntigravityChatIngestor` (SQLite-WAL) as the cold/offline
   reader; keep agentapi one-shot (`new-conversation`/`send-message`) as the
   degraded drive path when the gRPC stream is unavailable. Keep the
   `usage["antigravity"]` key (don't strand v6 iOS).

## Risks / open items (resolve during implementation, not now)

- **TLS on the gRPC port.** `httpsBaseURL` is `https://` — likely a self-signed
  per-launch cert. The channel must pin/accept it (the CSRF is the real auth).
- **`StartCascade` request shape.** Confirm required fields (workspace/cwd,
  model, conversation id) from the field map before first call.
- **`grpc-swift` dependency weight** vs hand-rolled HTTP/2 — decide in Phase 7
  proper; the neutral `NdjsonRpcConnection` does NOT speak HTTP/2, so gRPC needs
  its own channel either way.
- **Stability marker.** The binary logs "unstable steps in conversation; last
  stable index" — the stream emits provisional steps; honor a stable-index
  cursor so we don't render-then-retract (like the ACP turn buffer).

**Bottom line:** the proto schema is recoverable today, and the gRPC surface is a
real drive loop. Phase 7 is a build (gRPC client + mapper), not a research risk.
