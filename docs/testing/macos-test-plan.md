# macOS app — step-by-step test plan

Goal: test the Continuum **macOS** app thoroughly via XCTest, focused
on the daemon + the new ACP harness (the least-tested, most bug-prone surface),
then run everything and fix the bugs found.

## Strategy

- **Unit + integration via XCTest** — no UI automation. The Mac daemon is
  `@MainActor`; tests instantiate `AgentControlServer` / `AgentSessionRegistry`
  / `DaemonChatStoreRegistry` with **temp-dir** stores (pattern from
  `AgentControlServerChatRouteTests`), and drive the harness with **test
  doubles** (`FakeAcpAgent` stdio double; a new `FakeHarnessDriver` actor
  conforming to `AgentDriver` for bridge tests).
- Shared, transport-free logic (mappers, router, trust gate, wire) is tested in
  the **SwiftPM** suite (`swift test`); Mac-target logic (bridge, server,
  registries, drivers, SessionChatStore) in **ClawdmeterMacTests**
  (`xcodebuild test`).
- Two run lanes: `swift test` (fast) and `xcodebuild test -scheme 'Clawdmeter (Mac)'`.

## Step 0 — baseline

Run both suites unchanged; record current failures (each failure = a bug to fix
or a stale test). `swift test` was 1289/0; capture the Mac-target result.

## Step 1 — fill the harness/daemon gaps (new XCTests)

| Area | File(s) | What to assert |
|---|---|---|
| **AcpHarnessBridge** | `ClawdmeterMacTests/AcpHarnessBridgeTests.swift` (+ `FakeHarnessDriver`) | text buffers→flush on turnEnded; plan→planText; tool→row; permission→prompt + `pendingPermissionRpcIds` map + `respondToPermission` round-trip clears prompt; turnEnded(.cancelled)→`.interrupted`; teardown drains buffer + closes; gRPC factory (no child) start path |
| **HarnessSessionRegistry** | same file | register / bridge(for:) / contains / remove(teardown) |
| **Daemon harness routing** | `AgentControlServerHarnessRouteTests.swift` | `acpSupport(for:)` (grok/cursor→non-nil, others nil); Codex app-server and headless `agy` harnesses are the default; send/interrupt/permission for a session WITH a registered bridge; legacy session w/o bridge returns stale/retired |
| **SessionChatStore** | extend / `SessionChatStoreParsingTests.swift` | `ParsedLine.from` Claude + Codex `response_item` shapes, malformed/empty lines, dedup; `appendSDKMessages` + plan/turn-state setters |
| **Registries** | extend `AgentSessionRegistry*Tests` | `inferred(.grok)→.acpGrok`, `inferred(.cursor)→.acpCursor`, `inferred(.codex)→.codexAppServer`, `inferred(.gemini)→.agyHeadless` persisted round-trip; create w/ nil legacy pane fields; delete; lenient decode of old sessions.json |
| **Codex/Antigravity driver** | extend `AntigravityCascadeClientDecodeTests`; `CodexAppServerDriver` via FakeAcpAgent-style frames | decode→mapper round-trips for the remaining step/event kinds |

## Step 2 — adversarial bug-hunt (read-only)

Review the recent harness code (`AgentControlServer` harness branches,
`AcpHarnessBridge`, `AcpAgentDriver` fs handlers, the drivers, `RepoTrustGate`
consumers) for: concurrency (actor reentrancy, races), error/teardown paths,
double-response on a JSON-RPC id, store leaks (acquire without release),
flag/gate inversions, Sendable hazards. Report findings with file:line + a
repro/fix; do not fix blind.

## Step 3 — run + fix loop

`swift test` + `xcodebuild test` → triage failures + reported bugs → fix real
bugs (smallest correct change) → re-run until both suites green. Commit per
coherent fix/test batch on `feat/acp-harness`.

## Run commands

```bash
cd apple && xcodegen
( cd ClawdmeterShared && swift test )
xcodebuild test -scheme "Clawdmeter (Mac)" -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
# focus a class: -only-testing:ClawdmeterMacTests/AcpHarnessBridgeTests
```
