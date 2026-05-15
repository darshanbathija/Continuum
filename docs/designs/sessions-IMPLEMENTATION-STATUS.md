# Sessions feature — implementation status

This is the running status of the Sessions feature build. The full plan
lives at [`use-tailscale-ssh-for-modular-fern.md`](/Users/darshanbathija_1/.claude/plans/use-tailscale-ssh-for-modular-fern.md);
the CEO scope decisions live at [`sessions-control-plane.md`](./sessions-control-plane.md).
This file maps tasks to commits + tracks what's done vs left.

## Done ✅

### Phase 0 — tmux-cc-probe (commit `47be37b`)
- T1: `tools/tmux-cc-probe/` Swift package with control-mode parser + PTY helper.
- 19/19 parser unit tests passing (octal-escape, UTF-8 boundaries, CRLF
  handling, streaming, large-output reassembly, all tmux 3.6+ directives).
- 6/6 live integration tests passing against real `tmux -C` 3.6a on this Mac.

### Phase 1 — daemon scaffolding (commit `<phase-1-sha>`)
- T2: `ClawdmeterShared/AgentControl/Protocol.swift` — Codable DTOs for the
  entire wire shape. AgentRepo, AgentSession, NewSessionRequest, PairingChallenge,
  AgentEvent (E8 eventSeq), NeedsAttentionResponse (D15 local-notif path),
  TerminalFrameTag (Phase 3). 12/12 round-trip tests passing.
- T3: `AgentControlServer.swift` — Network.framework HTTP/1.1 server. Bind
  `0.0.0.0:21731` with E3 try-next-port fallback. Accept-handler filters
  to loopback + `100.64.0.0/10` CGNAT + Tailscale IPv6 prefix. Every
  request requires `Authorization: Bearer <pairingToken>`. Non-loopback
  additionally checked via `TailscaleWhois`.
- T5: `RepoIndex.swift` — background-refresh actor. Unions
  `~/.claude/projects/` + `~/.codex/sessions/` + configured scan roots
  (default EMPTY per Codex Round 1). 60s background refresh, bounded
  4-level depth.
- T6: `NotificationDispatcher.swift` — in-memory pending-event queue
  with monotonic IDs + ack semantics. D15 path (no APNS).
- T20: `ShellRunner.swift` — argv-only subprocess wrapper (E4). Fixes
  the space-in-path bug for `/Users/.../CC Watch/Clawdmeter`.
- Phase 1d: `SessionsView.swift` placeholder. AppRuntime wiring.
  DashboardView TabView wrapper. Feature flag `clawdmeter.sessions.enabled`
  (default on).
- 71/71 ClawdmeterShared tests passing. `xcodebuild -scheme "Clawdmeter (Mac)"`
  builds clean.

### Phase 2 — tmux integration + session lifecycle (commit `9666173`)
- T7: `TmuxControlClient.swift` — actor owning the `tmux -C` server.
  Spawns over PTY, parses %begin/%end command responses, fans %output
  bytes to per-pane subscribers, emits lifecycle events. Public commands:
  `newWindow`, `sendKeys`, `pasteBytes` (>256B / IME / escapes go through
  set-buffer + paste-buffer per Codex Round 2 #1), `listWindows`,
  `killWindow`, `resizePane`. Parser + PTY helper lifted from probe.
- T8: `AgentSessionRegistry.swift` — @MainActor ObservableObject. Tracks
  sessions, persists `sessions.json` schema v1 atomically. Per-session
  eventSeq counter (E8).
- T9: `AgentSpawner.swift` + `WorktreeManager.swift`. AgentSpawner builds
  claude/codex argv per E4. WorktreeManager does `git worktree add/remove`
  with D12 multi-gate safety (registry-owned + git status clean + git
  stash empty + no attached pane). Slug derivation per D7.
- Server endpoints: POST /sessions, GET /sessions, GET /sessions/<id>,
  DELETE /sessions/<id>.

## Remaining ⏳

### Phase 2 polish
- **T23 supervisor** — auto-restart `tmux -C` on `%exit`, mark sessions
  degraded, surface "tmux server lost" banner. The lifecycle events are
  already wired in TmuxControlClient; just needs a consumer in AppRuntime
  that reacts to `.serverExited`.

### Phase 3 — terminal streaming + structured cards
- **T10 TerminalWebSocketChannel** — WS bridge that subscribes to a pane's
  `%output` stream and forwards bytes to the client. Input frames (from
  client) come back as either `tmux send-keys -l` (≤256B / no escapes)
  or `tmux load-buffer + paste-buffer` (everything else).
- **T11 PlanCardView + StructuredEventList** — cross-platform SwiftUI
  views in ClawdmeterShared. PlanCardView per P2 = collapsed file cards
  with tap-to-expand.
- **MacTerminalView** — `NSViewRepresentable` wrapping `SwiftTerm.TerminalView`
  + WS subscription. Requires adding SwiftTerm as a SwiftPM dependency
  to ClawdmeterShared.

### Phase 4 — plan-mode flow + done-detector
- **T12 ClaudeSessionTail + CodexSessionTail** — FileHandle + DispatchSourceVnode
  on the agent's JSONL. Handles rotation, partial-line writes, delayed
  file creation per Codex Round 2 #2.
- **T13 DoneDetector** — 3-signal heuristic (D4) gated on end-of-turn boundary.
- **T21 DoneDetectorBenchmark** — anonymized fixtures for CI + optional
  local-corpus calibration per E5 (refined by Codex Round 2 hermetic concern).
- **T14 PlanModeWatcher + /approve-plan endpoint + overlay (D13)** — detect
  ExitPlanMode in JSONL → set planText → UI shows yellow pill → user
  approves → overlay covers the pane swap → fresh `claude --resume <id>
  --permission-mode acceptEdits` in same tmux window → done.
- **T22 eventSeq + cursor reconnect** — wire the E8 contract through
  AgentEventStream + WS endpoint with `?since=<seq>` + snapshot frame.

### Phase 5 — iOS + Watch
- **T15 iOSSessionsView + PairingScannerView + AgentControlClient** — third
  tab in iOS ContentView. SwiftTerm UIView + keyboard accessory bar.
- **iOSNotificationManager + BGAppRefreshTask** — local notifs over WS
  while foregrounded, BG poll of /sessions/needs-attention when backgrounded.
- **T16 Watch `.accessoryCircular` complication + approval sheet** —
  plan-waiting badge, tap → modal with plan summary + Approve button.

### Polish + ops
- **T17 Pairing token revoke + regenerate UI** in Mac Settings (the
  PairingTokenStore methods exist; needs the SwiftUI surface).
- **T18 Feature flag UI** — toggle in Settings to disable sessions feature.
- **T24 Visual mockups** — generate 4 surfaces via the design binary when
  the API rate limit clears.
- **CLAUDE.md update** — document the Sessions feature for future agents.

## How to verify what's built so far

```bash
cd Clawdmeter/apple
# 1. Run shared package tests (71 existing + new DTOs)
( cd ClawdmeterShared && swift test )

# 2. Run the tmux-cc-probe (lives one level up at tools/)
( cd ../tools/tmux-cc-probe && swift test && swift run tmux-cc-probe )

# 3. Build the Mac app
xcodegen && xcodebuild -scheme "Clawdmeter (Mac)" build

# 4. Launch the app and verify the daemon binds.
# After running the Mac app once, check:
ls ~/Library/Application\ Support/Clawdmeter/server.json
# Should show `{ "port": 21731, "writtenAt": "..." }`

# 5. From a separate terminal, hit the health endpoint.
TOKEN=$(security find-generic-password -s com.clawdmeter.mac.pairing -w)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:21731/health
# Should return: {"ok":true}

# 6. List repos
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:21731/repos
# Should return the union of ~/.claude/projects + ~/.codex/sessions
```

## Architecture surfaces locked

The remaining phases plug into stable surfaces:
- `AgentSession` Codable shape (Protocol.swift)
- `AgentEvent` + `eventSeq` cursor (Protocol.swift)
- `TerminalFrameTag` wire envelope (Protocol.swift)
- `AgentControlServer` dispatch table (just add cases)
- `TmuxControlClient.subscribeToPane(_:)` AsyncStream for WS bridge
- `AgentSessionRegistry.setPlanText` for the JSONL watcher's output
- `WorktreeManager.delete` for end-of-session GC

Each remaining phase is mechanical given these contracts.

## Outstanding decisions (none blocking)

- Whether to add `SwiftTerm` as a SwiftPM dependency now (Phase 3) or
  defer terminal rendering to a web view. Plan says SwiftTerm; doing so
  adds ~2MB to the binary. Acceptable.
- Whether to expand the AgentControlServer to use SwiftNIO if Network.framework
  shows perf issues under multi-client load. Personal-use scope means
  this is unlikely to matter.

## Commits on this branch

```
9666173  Phase 2: tmux integration + session lifecycle + worktree GC
<phase 1 sha>  Phase 1: daemon scaffolding + Sessions tab placeholder + Protocol DTOs
47be37b  Phase 0: tmux-cc-probe Swift package — control-mode parser + PTY helper
```

(Run `git log --oneline main..feat/sessions-control-plane` to see all
commits on this branch.)
