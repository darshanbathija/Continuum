# Project context

Native Mac / iOS / watchOS apps that surface live Claude Code + Codex CLI
rate-limit gauges and historical `$/token` analytics. Read this first; this
file exists so a fresh Claude Code session can bootstrap without re-reading
the whole repo.

This codebase has TWO upstream sources you must credit and respect:

1. **The original Clawdmeter ESP32 firmware** (separate repo). The Apple
   port replays its design language — same gauges, same color tokens
   (`#d97757` terra-cotta on `#000`), the same `UsageData` JSON shape, the
   same auto-revive idea, the same rate-limit-header polling math.
   `ClawdmeterShared/Model/UsageData.swift` is a Codable Swift port of the
   firmware's `data.h`.

2. **[ccusage](https://github.com/ryoppippi/ccusage)** by
   [@ryoppippi](https://github.com/ryoppippi). Everything under
   `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/` is a Swift
   re-implementation of ccusage's TypeScript token-aggregation logic. Same
   JSONL files parsed, same `messageId:requestId` dedup, same LiteLLM
   pricing snapshot. **`ccusage daily` is the ground truth** — if our
   numbers diverge, ccusage is right.

## Repo layout

```
Clawdmeter/
├── README.md                          download + install + build instructions
├── CLAUDE.md                          this file
├── tools/
│   ├── build-mac-dmg.sh               idempotent DMG packager — runs xcodegen
│   │                                   + xcodebuild archive + hdiutil
│   └── refresh-pricing.sh             curls LiteLLM pricing, filters to
│                                       claude-* / gpt-* / o[0-9]+*, writes
│                                       Analytics/pricing.json
└── apple/                             Xcode workspace + Swift package
    ├── project.yml                    xcodegen spec — regenerates .xcodeproj
    ├── README.md                      apps engineering doc (architecture,
    │                                   target layout, build matrix)
    ├── ClawdmeterShared/              cross-platform Swift Package
    │   ├── Package.swift
    │   ├── Sources/ClawdmeterShared/
    │   │   ├── Analytics/             ccusage-in-Swift
    │   │   │   ├── TokenTotals.swift          Codable rollup; Decimal cost
    │   │   │   ├── UsageRecord.swift           per-event normalized row
    │   │   │   ├── RepoIdentity.swift          cwd → canonical-repo bucketing
    │   │   │   ├── Pricing.swift               LiteLLM lookup; tiered Claude
    │   │   │   ├── ClaudeUsageParser.swift     `~/.claude/projects/*.jsonl`
    │   │   │   ├── CodexUsageParser.swift      `~/.codex/sessions/*.jsonl`
    │   │   │   ├── UsageHistoryLoader.swift    actor; parallel TaskGroup
    │   │   │   ├── UsageHistorySnapshot.swift  per-window byRepo + byDay
    │   │   │   ├── UsageHistoryStore.swift     @MainActor ObservableObject
    │   │   │   ├── pricing.json                embedded LiteLLM snapshot
    │   │   │   └── Views/                      TotalsGrid, DailyChart, RepoList
    │   │   ├── Model/UsageData.swift           rate-limit snapshot struct
    │   │   ├── Predictor/BurnRatePredictor.swift
    │   │   ├── Theme/Theme.swift               colors, fonts, layout tokens
    │   │   └── Sources/
    │   │       ├── AISource.swift              poll-source protocol
    │   │       ├── AnthropicSource.swift       rate-limit header parser
    │   │       ├── CodexSource.swift           Codex live rate-limit reader
    │   │       ├── KeychainTokenProvider.swift    Mac: reads CC's OAuth token
    │   │       ├── PastedAnthropicTokenProvider.swift iOS/Watch: iCloud-Keychain
    │   │       ├── UsagePoller.swift
    │   │       ├── UsageStore.swift                App Group cache for widgets
    │   │       ├── UsageCloudMirror.swift          iCloud KV (Mac → iOS)
    │   │       ├── WatchTokenBridge.swift          WCSession iPhone → Watch
    │   │       └── AutoReviver.swift               "keep the 5h timer warm"
    │   └── Tests/ClawdmeterSharedTests/            XCTest, 59 tests
    ├── ClawdmeterMac/                     macOS app
    │   ├── ClawdmeterMacApp.swift             @main, Window + Settings
    │   ├── AppRuntime.swift                   owns AppModel × 2 + analytics
    │   ├── AppModel.swift                     per-provider poller + reviver
    │   ├── DashboardView.swift                provider columns + analytics row
    │   ├── AnalyticsView.swift                totals + daily chart + by-repo
    │   ├── PopoverView.swift                  menu-bar popover
    │   ├── MenuBarGaugeView.swift             16pt status-bar gauge
    │   ├── AppDelegate.swift                  NSStatusItem + NSPopover wiring
    │   └── Assets.xcassets/AppIcon.appiconset/   10 sizes (16 → 1024@2x)
    ├── ClawdmeteriOS/                     iPhone app
    │   ├── ContentView.swift                  TabView: Live / Analytics
    │   ├── iOSAnalyticsView.swift             iCloud-KV-mirrored analytics tab
    │   ├── UsageModel.swift                   poller + cloud-mirror subscriber
    │   └── SettingsView.swift                 paste-token UI
    ├── ClawdmeteriOSWidgets/              Lock Screen / Home / StandBy widgets
    ├── ClawdmeterWatch/                   watchOS app
    │   ├── ContentView.swift                  wrist meter
    │   └── WatchUsageModel.swift              keychain + WCSession ingress
    ├── ClawdmeterWatchWidgets/            watchOS complications (4 families)
    └── ClawdmeterMacWidgets/              Mac menu-bar widget extension
```

## Build / run

```bash
cd apple
xcodegen                                                                # regen .xcodeproj
( cd ClawdmeterShared && swift test )                                   # 59 tests, ~0.2s
xcodebuild -scheme "Clawdmeter (Mac)"   -destination 'platform=macOS,arch=arm64'   build
xcodebuild -scheme "Clawdmeter (iOS)"   -destination 'generic/platform=iOS Simulator'  build
xcodebuild -scheme "Clawdmeter (Watch)" -destination 'generic/platform=watchOS Simulator' build
```

To produce a DMG for distribution: `./tools/build-mac-dmg.sh` → `dist/Clawdmeter-<version>-arm64.dmg`.

## Analytics layer one-pager

This is the part most likely to need editing in a future session, so it gets
its own section.

- **Loader**: `UsageHistoryLoader` is an `actor`. `loadAll()` walks
  `~/.claude/projects/` and `~/.codex/sessions/` in parallel via
  `withTaskGroup`. Parsers are `nonisolated static` so the task group
  genuinely parallelizes. The newest-mtime file per provider always
  bypasses the file-mtime cache because the active session may still be
  appending mid-walk.
- **Cache**: `~/Library/Application Support/Clawdmeter/analytics-cache.json`,
  schema v8. Per-file shape is
  `byDayByRepo: [Date: [RepoKey: TokenTotals]] + dedupKeys: [String] +
  unpricedModelTokens: [String: TokenTotals]`. Bump the version constant
  in `UsageHistoryLoader.swift` whenever the schema changes — old caches
  re-parse on first load.
- **Repo canonicalization**: `RepoIdentity.normalize(cwd)` walks up for
  `.git`. Handles three patterns:
  1. Regular git directory → use it.
  2. Worktree pointer file → read `gitdir:`, resolve to main worktree.
  3. Conductor pattern (`~/conductor/workspaces/<repo>/<branch>`) →
     introspect a live sibling's `.git` pointer to discover the underlying
     main repo.

  Non-git paths (UUIDs, home dirs) collapse to `RepoKey.other` ("Other" in
  the UI).
- **Windows**: `Today / Past 7d / Past 30d / All time`, calendar-day-aligned
  in the user's local timezone via `Calendar.current.startOfDay(for:)`.
  This matches ccusage's `daily` default. UTC bucketing was tried, rejected,
  diverged near midnight.
- **Mac → iOS sync**: Mac writes `UsageHistorySnapshot` to iCloud KV under
  key `cloud.analytics.v1`. iOS reads on `didChangeExternallyNotification`.
  Personal-team Apple Developer accounts can't sign the iCloud entitlement
  — iOS shows "iCloud not enabled" / "Waiting for Mac sync" until the user
  upgrades to the paid Developer Program.
- **iPhone → Watch sync**: `WatchTokenBridge` uses
  `WCSession.updateApplicationContext` (latest-wins) with a
  `transferUserInfo` queued-delivery fallback. iCloud Keychain shared
  access group (`$(AppIdentifierPrefix)com.clawdmeter`) is the legacy
  fallback when WCSession can't deliver.

## Token sourcing

| Surface | Source |
| --- | --- |
| **Mac (Claude)** | `KeychainTokenProvider` reads Claude Code's own OAuth token from `~/.claude/.credentials.json` / the local Keychain. |
| **Mac (Codex)** | `CodexSource` reads cached rate-limit state from `~/.codex/sessions/*.jsonl` directly — no token needed. |
| **iOS** | `PastedAnthropicTokenProvider.shared()` reads an iCloud-Keychain-synced entry the Mac mirrors on launch. Pasting a token in iOS Settings also works as a fallback. |
| **Watch** | First tries `WatchTokenBridge.didReceiveToken` (iPhone pushes it over WCSession). Falls back to the same shared-Keychain provider iOS uses. |

## App icon

Source PNG: `~/Downloads/Clawd Logo.png` (user's design). Crop pipeline in
`tools/build-mac-dmg.sh` and the asset catalogs:

1. Find bounding box of pixels where HSV saturation > 50 (the colored
   glows around the dual logos, excluding the white outer corners and the
   dark interior).
2. Tight square crop centered on that bbox with 4% padding.
3. Resize to 1024×1024.
4. Drop into iOS / watchOS `AppIcon.appiconset/AppIcon-1024.png`.
5. For Mac, generate the 7 size variants via `sips -Z` and reference them
   in the Mac asset catalog's `Contents.json` (16/32/64/128/256/512/1024
   mapped to 1x/2x pairs).

No flood-fill, no rim sweep, no pixel manipulation — the HSV crop alone
removes the source's white outer area cleanly.

## Sessions feature v2 (2026-05-17)

Mobile-native control plane for Claude Code + Codex. iPhone (and Watch)
can now start, monitor, and control sessions running on the paired Mac
in worktrees, with Conductor-grade model picker + effort dial + plan/code
toggle + mid-session swap. See `docs/designs/sessions-v2.md` for the
full v2 ship details and `TODOS.md` for deferred work.

Wire (v3): `Protocol.swift` carries `ReasoningEffort`, `ModelCatalog`
(5 Claude + 5 Codex models bundled), `HealthResponse` with `wireVersion`,
`ChangeModel/Effort/Mode/Send/Autopilot/PickWinner` DTOs, `PRStatus`,
`CreatePRRequest`, `GitDiffFile` + `GitDiffHunk`, `PreflightQuery/Response`,
`WireChatSnapshot`. `AgentSession` schema v3 adds `effort`,
`abPairSessionId`, `abPairDecidedAt`. v2 decoders accept new fields via
`decodeIfPresent` — back-compat preserved. v2 readers reading a v3
sessions.json silently drop the new fields.

Daemon (Mac): `AgentControlServer` uses a route-table dispatcher
(`RouteTable.swift`) with 19 new endpoints (`/models`,
`/sessions/:id/{chat-snapshot,diff,pr,terminals,model,effort,mode,send,
interrupt,autopilot,ab-pair/pick-winner,create-pr,merge}`,
`/sessions/preflight`, `DELETE /sessions/:id/terminals/:paneId`).
`AgentSpawner` uses `ShellRunner.locateBinary` (no hardcoded paths) and
the correct CLI flags: `claude --effort {low,medium,high,xhigh,max}` and
`codex -c model_reasoning_effort="..."`. `AgentSessionRegistry` uses a
single `with()` helper so v3 fields propagate across every mutation
(T41 audit). `AutopilotState` persists per-repo trust to
`~/.clawdmeter/autopilot-trusted-repos.json`. `AuditLog` writes
hash-only JSONL to `~/.clawdmeter/audit/{sends,swaps,autopilot}.jsonl`,
rotating at 1MB or 7 days. `RateLimiter` caps 1 send/sec + 1 swap/5sec
per session.

Mac UI: `SessionWorkspaceView` composer header now hosts `ModelPicker`
+ `EffortDial` chips next to the existing `ModePicker`.
`SessionConfigChanger` is the kill-pane + respawn-with-new-config
helper. `SessionsModel.switchModel/Effort/PlanMode` wire it up.

iOS Sessions tab: full picker rewrite. `iOSModelPicker` /
`iOSEffortDial` / `iOSSessionControlsStrip` / `iOSSessionActivityStrip`.
`SessionDetailView` is a 5-tab structure (Chat / Plan / Diff / PR /
Terminal). `iOSDiffView`, `iOSPRPane`, `iOSPlanTrackerView` cover
mobile review surfaces. `iOSChatStore` mirrors the daemon's chat
snapshot; `iOSChatStoreCache` is LRU-2 with protected sessions.

Watch: `SessionsListView` Crown-scrollable list. `WatchSessionDetailView`
with Approve / Interrupt / Voice-reply buttons. `WatchPlanBridge` extended
to receive `sessionsSummaryJSON` over WCSession `applicationContext`.

Theme: `SessionsV2Theme` is the single source for accent (`#D97757`),
codex blue (`#5C9DFF`), spacing scale, corner radius, animation tokens.
Replaces the literal `Color(red: 0xD9/255, ...)` repeated across ≥6 sites.

City labels: `CityPool` (200 cities) + `CityNamer` (persisted
session→city assignments). iOS sidebar + Watch complication + Live
Activity show city names alongside goal-derived branches.

Live Activity: `SessionLiveActivityAttributes` + `LiveActivityCoordinator`
ship the aggregate "N active sessions" pattern (E6 — not per-session).
Foreground updates in-process; background APNS push (D9 narrow scope)
deferred to v2.0.1.

Chimes: `ChimeAudioPlayer` ships 4 packs (SF Muni, NYC MTA, Bell,
Fanfare). Quiet-hours window default 22:00→07:00. Falls back to
AudioToolbox `AudioServicesPlaySystemSound(1336)` when bundled `.caf`
assets are missing.

Tests: 153/153 (was 133) in `ClawdmeterShared` after adding
`SessionsV2Tests` covering schema v3 round-trip + back-compat,
`ReasoningEffort` flag mapping, `ModelCatalog.bundled` consistency,
mid-session change DTOs, `HealthResponse`, `WireChatSnapshot`, `CityPool`,
`WatchSessionSummary`. 19/19 in `tools/tmux-cc-probe`. All three
platform schemes build clean.

## Sessions feature v1 (added 2026-05-16, extended through Phase G3)

Read-write control plane for Claude Code + Codex CLI agent sessions, on top
of the existing read-only analytics. Mac runs a SwiftNIO-free
Network.framework HTTP+WS daemon (port 21731 / 21732) inside `ClawdmeterMac`;
iPhone + Watch consume it over Tailscale. tmux `-CC` is the PTY layer.

### Daemon + data layer — `apple/ClawdmeterMac/AgentControl/`
- `TmuxControlClient` (actor) + `ControlModeParser` + `PseudoTerminal` —
  the parser was Phase 0-validated against tmux 3.6a; see
  `tools/tmux-cc-probe/` for the unit + integration tests. Owns
  `splitWindow` (G12 multi-terminal) and `killPane`.
- `AgentControlServer` + `WSChannel` protocol + `TerminalWebSocketChannel`
  + `AgentEventStream` — dual-port listener (HTTP + WS) with
  accept-handler peer filter to `127/8`, `::1`, `100.64/10` CGNAT, and
  `fd7a:115c:a1e0::/48` Tailscale IPv6. Every endpoint requires
  `Authorization: Bearer <token>` from `PairingTokenStore`. Non-loopback
  additionally verified via `TailscaleWhois` (60s cache, fail-closed-on-error).
  WS subscription envelope can target a specific `paneId` (G12 multi-
  terminal); falls back to the session's primary pane when absent.
- `AgentSessionRegistry` (@MainActor ObservableObject) — atomic
  `sessions.json` schema v2 + per-session monotonic `eventSeq` (E8 cursor
  contract). Schema v2 added `mode`, `archivedAt`, `terminalPanes`,
  `scheduledFollowUps`, and `parentSessionId`; v1 files decode cleanly
  because the new keys default to empty in `AgentSession.init(from:)`.
- `RepoIndex` (actor) — background refresh from `~/.claude/projects/`,
  `~/.codex/sessions/`, and user-configured scan roots (default empty;
  bounded 4-level depth on git discovery). Two activity windows:
  `liveNowWindow` (5 min, drives the green dot) and `recentActivityWindow`
  (30 days, drives the per-JSONL "Recent" rows in the sidebar).
- `JSONLTail` + `DoneDetector` + `PlanModeWatcher` + `SessionEventWiring`
  — per-session JSONL watch fires plan-ready / done-detected events into
  the registry, which the AgentEventStream fans out to subscribed clients.
- `TmuxSupervisor` — auto-restart on `%exit` with exponential backoff;
  marks sessions degraded; banner in Mac Settings → Sessions tab.
- `ShellRunner` — argv-only subprocess wrapper. NEVER concat into shell
  strings (the repo path has a space; concat breaks).
- `SessionScheduler` (G15) — single re-armable `DispatchSourceTimer`
  observing `registry.$sessions`; fires scheduled follow-ups by pasting
  the prompt into the session's tmux pane via `paste-buffer`.
- `PRMirror` (G16) — auto-detects a GitHub PR URL in chat (regex over
  assistant text + tool_result bodies), polls `gh pr view --json` every
  30s, exposes title / state / additions / deletions / review state +
  an Approve action that shells out to `gh pr review --approve`.
- `PluginRegistry` (G18) — read-only inventory of MCP servers + plugins
  from `~/.codex/config.toml` and `~/.claude/settings.json`. Surfaced in
  the Pairing Settings pane.
- `SpeechDictation` (G11) — `SFSpeechRecognizer` + `AVAudioEngine`
  wrapper. Ctrl+M toggles dictation in the composer; partial transcripts
  append live via `.onReceive(dictation.$partialTranscript)`.

### Mac UI — `apple/ClawdmeterMac/Workspace/`
Three-pane workspace replaces the prior 2-pane push/pop (which had a
back-button bug on macOS NavSplitView). `HSplitView` with sidebar | thread
| review. Width-responsive via a `WorkspaceWidthKey` PreferenceKey:
- ≥ 1100pt → all three panes; review pane respects the user's Cmd+W toggle.
- < 1100pt → review pane drops out so Sessions sidebar + chat stay
  first-class. Toolbar Cmd+W button disables itself with a "widen the
  window" tooltip.
- `SessionWorkspaceView.swift` — the container.
- `ModePicker.swift` — chip-style segmented control above the composer
  (Local | Worktree | Cloud-disabled). Switching mode mid-session
  re-spawns the agent in the new cwd via the D13 overlay flow.
- `GitDiffPane.swift` — live `git diff HEAD` with per-hunk Stage/Revert,
  Commit sheet, vnode watch on `.git/index` for auto-refresh.
- `PlanTrackerPane.swift` — vertical step timeline derived from
  `planText` + numbered/Step lines in assistant turns; heuristic
  auto-complete + manual tap-toggle; Approve & run button.
- `SourcesPane.swift` — file + URL citations from Read/Grep/Glob/
  WebFetch tool_use blocks (G9).
- `ArtifactsPane.swift` — thumbnail grid + `QLPreviewView` overlay for
  PDF/image/doc artifacts the agent wrote (G10).
- `InAppBrowser.swift` — `WKWebView` + nav chrome + Cmd-click element
  comment overlay that injects `[BROWSER COMMENT @ <selector>] <text>`
  into the agent's tmux pane (G13).
- `PRReviewPane.swift` — G16 PR card with state badge + body + Approve.
- `MarkdownRenderer.swift` (under `AgentControl/`) — native
  `AttributedString(markdown:)` for assistant bubbles + fenced code
  blocks with monospaced rendering (G4).
- `ChatThreadScroll` (inside `SessionWorkspaceView.swift`) — groups
  consecutive tool_use + tool_result messages into a single "Ran N
  commands" `DisclosureGroup`; each tool inside is itself expandable.
  Smart auto-scroll: only follows new messages when the bottom anchor
  is visible (otherwise the user is reading history and we don't yank
  them). "Jump to latest" overlay button appears when scrolled away.
- `PoppedOutSessionView` (in `ClawdmeterMacApp.swift`) — G14 detachable
  session window scene `session-detail` opened via `openWindow(value:)`;
  pin button toggles `NSWindow.level = .floating` for stay-on-top.

### Keyboard
- `Cmd+N` — new session sheet.
- `Cmd+W` — toggle review pane (greyed out at narrow widths).
- `Cmd+Shift+F` — focus sidebar search.
- `Cmd+1..9` — jump to Nth visible session.
- `Cmd+;` — branch a sub-chat off the open session (G17, nested under
  parent in the sidebar via `parentSessionId`).
- `Cmd+⌥+N` — pop out the open session into a detached window.
- `Cmd+↩` — send composer input.
- `Ctrl+M` — toggle voice dictation in the composer.

### Sidebar behavior
- Repos sort by most-recent activity (newest first); alphabetical
  fallback; "Other" always last.
- Each repo expands to show Clawdmeter-spawned sessions (registry-
  owned), sub-chats nested under their parents (G17), then a "Recent
  (last 30 days)" section listing every JSONL touched in the window —
  one row per JSONL with relative timestamp and a green dot when still
  in the live-now window. Clicking a recent row opens that specific
  JSONL as read-only chat (synthetic AgentSession pinned to the path).
- Search field + Show-archived toggle. Context-menu on each session
  row: Archive / Unarchive, New sub-chat, End session.

### iOS / Watch
- iOS surface: `apple/ClawdmeteriOS/iOSSessionsView.swift` (third
  TabView tab) + `AgentControlClient` + `PairingScannerView` (AVCapture
  QR scanner) + `iOSTerminalView` (SwiftTerm + 7-button keyboard accessory)
  + `iOSNotificationManager` (BGAppRefreshTask + UNUserNotificationCenter,
  D15 path — no APNS). G2/G3 surfaces (multi-terminal tab strip, in-app
  browser, PR review, sub-chats, scheduler) are Mac-only in v1.
- Watch surface: `PlanWaitingComplication` (`.accessoryCircular` only
  per D10) + `PlanApprovalView` + `WatchPlanBridge` (WCSession from iPhone).

### State + tests
Build matrix: Mac, iOS, and Watch all build clean. Tests: 79/79 in
ClawdmeterShared (Protocol round-trip + back-compat for SessionMode,
G2 schema fields, RecentSession), 19/19 in tools/tmux-cc-probe.
Implementation status doc at `docs/designs/sessions-IMPLEMENTATION-STATUS.md`;
full CEO plan at `docs/designs/sessions-control-plane.md`.

Feature flag: `UserDefaults clawdmeter.sessions.enabled` (default true).
When false, daemon doesn't start and Sessions tab is hidden.

### SessionChatStore JSONL resolution

`SessionChatStore.resolveSessionFileURL(repoCwd:)` applies Claude's full
project-dir encoding (`/`, `_`, ` ` → `-`) and walks up parent
directories: when Claude was launched from a parent of the git repo
(e.g. `CC Watch/` wrapping `Clawdmeter/`), the JSONLs are filed under
the parent's encoded name. A naive `/`→`-` encoder misses both cases.

## Style + voice

- Code comments lead with **what + why**, not implementation play-by-play.
- When fixing a bug, prefer a one-line root-cause comment over a
  multi-paragraph explanation. The diff says the rest.
- For Tahoe-specific workarounds (the Mac app has several around
  `MenuBarExtra` and main-queue dispatch), KEEP the comment that explains
  the bug — they're surprising and a future session will revert them
  without knowing why.

## Skill routing

When the user's request matches an available skill, invoke it via the
Skill tool. When in doubt, invoke the skill.

- Product / scope → `/plan-ceo-review`
- Architecture → `/plan-eng-review`
- Design plan review → `/plan-design-review`
- Full review pipeline → `/autoplan`
- Bugs / errors → `/investigate`
- Site QA → `/qa` or `/qa-only`
- Diff review → `/review`
- Visual polish → `/design-review`
- Ship / PR → `/ship` or `/land-and-deploy`
- Doc sync after ship → `/document-release`
- Save / restore session state → `/context-save` / `/context-restore`
