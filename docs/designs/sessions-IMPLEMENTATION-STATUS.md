# Sessions feature — implementation status

Historical note: this snapshot documents the original tmux-based Sessions build.
The current runtime is direct PTY for Claude/terminal panes plus harness
providers for Codex, Cursor, Gemini, and Grok; old pane-backed sessions are
retired instead of reconnected.

This is the running status of the Sessions feature build. The full plan
lives at [`use-tailscale-ssh-for-modular-fern.md`](/Users/darshanbathija_1/.claude/plans/use-tailscale-ssh-for-modular-fern.md);
the CEO scope decisions live at [`sessions-control-plane.md`](./sessions-control-plane.md).
This file maps tasks to commits + tracks done vs left.

## Status: Phase 0–5 + T17 + T23 + Phase G0–G3 (Codex parity) all shipped.

All three platform schemes (Mac / iOS / Watch) build clean.
**98 / 98 tests pass** (79 ClawdmeterShared + 19 tmux-cc-probe). G19
closed N/A (tmux-confined agents can't request desktop control). G20
multi-Mac federation deferred (requires a second Mac in the tailnet to
test; protocol stays forward-compatible). T24 visual mockups still
deferred on design-API rate limit.

## Done ✅

### Phase 0 — tmux-cc-probe (commit `47be37b`)
- T1: `tools/tmux-cc-probe/` Swift package with control-mode parser + PTY helper.
- 19/19 parser unit tests + 6/6 live integration against `tmux 3.6a`.

### Phase 1 — daemon scaffolding (commit `3819a21`)
- T2: `ClawdmeterShared/AgentControl/Protocol.swift` — all Codable DTOs
  including E8 eventSeq cursor.
- T3: `AgentControlServer.swift` — Network.framework HTTP/1.1 on 21731
  + WS listener on 21732. Accept-handler peer filter
  (`127/8`, `::1`, `100.64/10` Tailscale CGNAT, `fd7a:115c:a1e0::/48`).
- T5: `RepoIndex.swift` — background refresh actor; default-empty scan roots.
- T6: `NotificationDispatcher.swift` — pending-event queue with ack semantics.
- T20: `ShellRunner.swift` — argv-only subprocess wrapper (E4 fix for
  space-in-path).

### Phase 2 — tmux integration + session lifecycle (commit `9666173`)
- T7: `TmuxControlClient.swift` — actor with PTY spawn, command dispatch,
  per-pane AsyncStream fan-out, lifecycle events.
- T8: `AgentSessionRegistry.swift` — `@MainActor`, atomic sessions.json
  schema v1, per-session eventSeq.
- T9: `AgentSpawner.swift` + `WorktreeManager.swift` — argv builders +
  D12 multi-gate worktree GC.
- POST/GET/DELETE `/sessions` endpoints.

### T19 — CEO plan promoted to repo (commit `7ead39b`)
- `docs/designs/sessions-control-plane.md` — full CEO plan with all 17
  scope decisions.

### Phase 3 + 4 + T17 + T23 (commit `<latest>`)
- T10 `TerminalWebSocketChannel.swift` — WS bridge with byte-safe input
  transport (`send-keys -l` for short / `paste-buffer -d` for >256B per
  Codex Round 2 #1).
- T11 `PlanCardView` + `StructuredEventList` — cross-platform SwiftUI in
  ClawdmeterShared per P2 = C.
- T22 `AgentEventStream` — E8 cursor contract: per-session eventSeq, retention
  ring (1024 events / 1hr), snapshot frame when cursor is stale.
- T12 `JSONLTail` — line-buffered FileHandle + DispatchSourceVnode with
  rotation / delete / delayed-creation recovery (Codex Round 2 #2).
- T13 `DoneDetector` — three-signal heuristic gated on end-of-turn boundary.
- T14 `PlanModeWatcher` — ExitPlanMode detection + plan-files parsing.
- T14 `POST /sessions/<id>/approve-plan` — kills plan-mode pane, spawns
  fresh `claude --permission-mode acceptEdits` in same tmux window cwd.
- T17 `PairingSettingsView.swift` — Mac Settings tab "Sessions" with
  Core Image QR code, host/ports/token display, regenerate + revoke
  buttons, supervisor health, scan-roots editor.
- T23 `TmuxSupervisor.swift` — consumes lifecycle AsyncStream from
  TmuxControlClient; on `%exit` marks sessions degraded, attempts 3
  exponential-backoff restarts (1s/3s/9s), surfaces "tmux unrecoverable"
  banner in Settings.
- `MacTerminalView.swift` — NSViewRepresentable wrapping `SwiftTerm.TerminalView`,
  URLSession WS client.

### Phase 5 — iOS + Watch (commit `<latest>`)
- T15 `AgentControlClient.swift` (iOS) — REST/WS client with UserDefaults
  config; all daemon endpoints exposed.
- T15 `iOSSessionsView.swift` — third TabView tab with pairing prompt,
  repo list, session detail (Structured ↔ Terminal segmented control).
- T15 `PairingScannerView.swift` — AVCaptureSession QR scanner parsing
  `clawdmeter://` URLs.
- `iOSTerminalView.swift` — SwiftTerm UIView + keyboard accessory bar
  (Esc / Ctrl-latch / Tab / 4 arrows at 44pt each).
- `iOSNotificationManager.swift` — D15 fallback: `UNUserNotificationCenter`
  + `BGAppRefreshTask` registered in `ClawdmeteriOSApp` (com.clawdmeter.ios.refresh).
- T16 `PlanWaitingComplication.swift` — `.accessoryCircular` only (v1 cut
  per D10). Reads from App Group UserDefaults; deep links to `clawdmeter://approve`.
- `WatchPlanBridge.swift` (Watch) + `WatchPlanBridgeIOS.swift` (iPhone) —
  WCSession bridge with `applicationContext` (latest-wins) +
  `transferUserInfo` (queued) delivery. Watch approve sends
  `{op:"approvePlan",sessionId}` back; iPhone forwards to daemon.
- `PlanApprovalView.swift` (Watch) — modal sheet with goal + plan
  summary + terra-cotta Approve button.

### Phase G0 — Codex 3-pane workspace parity (commit `a83919b`)
- G1+G2+G3+G4+G5: `SessionWorkspaceView` (HSplitView with sidebar | chat
  | review), `ModePicker` (Local|Worktree|Cloud-disabled chip control,
  mid-session restart via D13 overlay), `GitDiffPane` (live `git diff
  HEAD` with per-hunk Stage/Revert + Commit sheet + vnode watch on
  `.git/index`), `MarkdownRenderer` (`AttributedString(markdown:)` with
  fenced code blocks), `PlanTrackerPane` (vertical step timeline +
  auto-complete heuristic + manual tap-toggle).
- Protocol gains `SessionMode` + `AgentSession.{mode, archivedAt}` with
  back-compat decoder. 4 new ProtocolTests for SessionMode round-trip +
  legacy decode → infer mode from worktreePath.

### Phase G1 — Power features (commits `a83919b` + `4f2d549`)
- G6 sidebar search + Cmd+Shift+F focus.
- G7 archive (`archivedAt`) + context menu + Show-archived toggle.
- G8 keyboard nav: Cmd+1..9 jump to Nth visible session, Cmd+N new
  session, Cmd+W toggle review pane.
- G9 `SourcesPane` — file + URL citations from Read/Grep/Glob/WebFetch
  tool_use blocks, click → reveal in Finder / open URL.
- G10 `ArtifactsPane` — thumbnail grid + `QLPreviewView` overlay for
  PDF/image/doc artifacts.
- G11 `SpeechDictation` — SFSpeechRecognizer + AVAudioEngine; Ctrl+M
  toggles, partial transcripts append live; Info.plist gains
  NSSpeechRecognitionUsageDescription + NSMicrophoneUsageDescription.

### Phase G2 — Workspace depth (commit `b879b35`)
- Protocol gains `TerminalPaneRef`, `ScheduledFollowUp`,
  `AgentSession.{terminalPanes, scheduledFollowUps, parentSessionId}`.
  `sessions.json` bumped to schema v2 with back-compat decoder.
- G12 multi-terminal: `TmuxControlClient.splitWindow` + `killPane`,
  `AgentControlServer` honors optional `paneId` in WS envelope,
  `MacTerminalView` accepts `paneId` parameter; SwiftUI `.id()` drives
  WS reconnect on tab switch. `TerminalTabContainer` in CenterThread
  with "+" to spawn additional panes and × to close non-primary.
- G13 `InAppBrowser` — `WKWebView` + URL bar + back/forward/reload +
  Cmd-click element comment overlay that posts a CSS selector + snippet
  back via `WKScriptMessageHandler` and injects
  `[BROWSER COMMENT @ <selector>] <text>` into the agent's tmux pane.
- G14 pop-out window: new `WindowGroup("session-detail", for: UUID.self)`,
  `PoppedOutSessionView` with stay-on-top toggle via `NSWindow.level`.
  Menu item "Pop out window" (Cmd+⌥+N) routes through a Notification
  that `DashboardOpener` turns into `openWindow(value:)`.
- G15 `SessionScheduler` — single re-armable DispatchSourceTimer
  observing `registry.$sessions`; fires past-due immediately; delivers
  via `tmuxClient.pasteBytes`. UI: `FollowUpSchedulerSheet` with
  DatePicker + prompt field + pending list with trash.

### Phase G3 — PR + sub-chats + plugins (commit `6f8d8db`)
- G16 `PRMirror` + `PRReviewPane` — auto-detects PR URL in chat (regex
  over assistant text + tool results), polls `gh pr view --json` every
  30s, exposes state/title/author/diff stats/review state + Approve
  button (`gh pr review --approve`). Manual URL entry when auto-detect
  hasn't fired. 6th tab in the review pane.
- G17 threaded sub-chats: `SessionsModel.spawnSubchat(parentId:)`
  creates a child with `parentSessionId` set, sharing parent's cwd +
  mode; sidebar nests children under parents with an arrow.turn.down.right
  indent (iterative depth-first flatten so SwiftUI's opaque return
  type doesn't trip on self-recursion). Cmd+; on the open session
  forks a sub-chat; right-click context menu also offers it.
- G18 `PluginRegistry` — read-only inventory of MCP servers + plugins
  from `~/.codex/config.toml` (top-level `[mcp_servers.<name>]` sections)
  and `~/.claude/settings.json` (`enabledPlugins` + `mcpServers`).
  Surfaced in `PairingSettingsView` "Plugins" section.

### Post-G3 polish

- **30-day session sidebar** (commit `d9bcb02`) — `RecentSession` DTO +
  `AgentRepo.recentSessions`; `RepoIndex` splits `liveNowWindow` (5 min,
  green dot) from `recentActivityWindow` (30 days, per-JSONL rows).
  Each recent row opens a synthetic AgentSession pinned to that exact
  JSONL path via `forcedChatStoreURLs`. Repos sort by most-recent
  activity. 50-row cap per repo.
- **JSONL encoder fix** (commit `6c4fb61`) — `SessionChatStore.resolveSessionFileURL`
  now applies Claude's full encoding (`/`, `_`, ` ` → `-`) and walks up
  parent directories to find sessions filed under a parent of the git
  repo.
- **Tool-run disclosure** (commit `4aa6112`) — `ChatThreadScroll`
  buckets consecutive tool_use + tool_result messages into a single
  "Ran N commands" DisclosureGroup; each tool inside is independently
  expandable to show command + result. `QuietDisclosure` style strips
  the default chrome to a chevron only. Bash's `description` is the
  headline; the command is in `expandedDetail`.
- **Responsive layout** (commit `95c26be`) — workspace measures its own
  width via `WorkspaceWidthKey` PreferenceKey; below 1100pt the review
  pane is removed from the hierarchy so Sessions sidebar + chat get the
  room. Cmd+W toggle disables itself with a "widen the window" tooltip.
- **Smart auto-scroll** — chat thread only follows new messages when the
  bottom anchor is visible; "Jump to latest" floating button appears
  when scrolled away from the tail.

### Build matrix
```
xcodebuild -scheme "Clawdmeter (Mac)"   build  → BUILD SUCCEEDED
xcodebuild -scheme "Clawdmeter (iOS)"   build  → BUILD SUCCEEDED
xcodebuild -scheme "Clawdmeter (Watch)" build  → BUILD SUCCEEDED
swift test (ClawdmeterShared)                  → 79/79
swift test (tools/tmux-cc-probe)               → 19/19
```

## Deferred ⏳

- **T24** — Visual mockups for the 4 priority surfaces. The design API
  returned 429 (rate limited) on every attempt during this build. Retry
  whenever the quota refreshes: `$D variants --brief "..." --count 2
  --output-dir ~/.gstack/projects/darshanbathija-Clawdmeter/designs/sessions-feature-20260516/<surface>/`.
  The 8.5/10 design score after Pass 1-7 review still stands; mockups
  push to 9.5/10 by making the visual taste concrete.
- **Real-corpus DoneDetector benchmark (T21)** — the detector + synthetic
  fixtures are in place. The CI-hermetic anonymized-corpus job is one
  more morning of work (snapshot ~10 real sessions, anonymize, add the
  precision/recall threshold test). Not blocking.
- **AgentEventStream live broadcast on `recordEvent`** — the global event
  log accumulates correctly, and the snapshot/replay path works on
  reconnect. The "live push to active subscribers" hop is currently
  driven by the `registry.$sessions` Combine subscription; for finer-
  grained live updates, a `NotificationCenter`-style fanout from
  `recordEvent` is the polish.

## Architectural notes

- **Single Mac, dual-port listener** (HTTP 21731 + WS 21732) — Apple
  `NWProtocolWebSocket` makes the WS upgrade native; HTTP-on-same-port
  WS upgrade would have required hand-rolled WS framing. Two listeners
  is the cleaner architecture for our personal-use scope.
- **Auth = bearer token + Tailscale whois** for non-loopback peers.
  Loopback still requires token (defense-in-depth against local processes).
- **No APNS** — D15 cleared this path. `BGAppRefreshTask` polls
  `/sessions/needs-attention` every ~15-30 min when iOS schedules it;
  foreground uses the WS event stream for live notifications.
- **Plan→impl swap is robust**, not brittle — no keystroke injection into
  Claude's TUI. The daemon kills the plan-mode window and spawns
  `claude --resume <id> --permission-mode acceptEdits` in the same cwd
  (worktree, if used). UI overlay covers the visual gap per D13.

## Commits on this branch

```
git log --oneline main..feat/sessions-control-plane
```

(Run that command for the live list.)
