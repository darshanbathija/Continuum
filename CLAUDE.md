# Project context

Native Mac / iOS / watchOS apps that surface live Claude Code + Codex CLI
rate-limit gauges and historical `$/token` analytics. Read this first; this
file exists so a fresh Claude Code session can bootstrap without re-reading
the whole repo.

## Design System

Always read DESIGN.md before making any visual or UI decisions.
All font choices, colors, spacing, and aesthetic direction are defined there.
Do not deviate without explicit user approval.
In QA mode, flag any code that doesn't match DESIGN.md.

This codebase has TWO upstream sources you must credit and respect:

1. **The original ESP32 firmware** (separate repo). The Apple
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
├── VERSION                            single source-of-truth: Mac DMG + Linux AppImage + .deb
├── tools/
│   ├── build-mac-dmg.sh               idempotent DMG packager — runs xcodegen
│   │                                   + xcodebuild archive + hdiutil
│   ├── build-linux-appimage.sh        AppImage packager — linuxdeploy + appimagetool
│   ├── build-linux-deb.sh             .deb packager — dpkg-deb
│   └── refresh-pricing.sh             curls LiteLLM pricing, filters to
│                                       claude-* / gpt-* / o[0-9]+*, writes
│                                       Analytics/pricing.json
├── docs/
│   └── linux/                         Linux-specific docs: INSTALL, PAIRING,
│                                       TROUBLESHOOTING, QA-CHECKLIST (release gate)
├── linux/                             Linux desktop port (new — branch `linux-app`)
│   ├── Package.swift                  swift-tools-version 6.0; deps on Hummingbird (Phase 3)
│   │                                   + SwiftCrossUI (Phase 3.5) + shared via path
│   ├── Sources/
│   │   ├── ClawdmeterDaemon/          @main headless daemon binary
│   │   ├── ClawdmeterLinux/           desktop app (tray + UI + storage)
│   │   │   ├── Transport/             Hummingbird transport + peer-filter + bearer-auth
│   │   │   ├── Storage/               XDG paths + libsecret + LinuxUsageStore
│   │   │   ├── Tray/                  AppIndicator + Cairo gauge + SNI detector
│   │   │   └── UI/                    SwiftCrossUI primary + direct CGtk4 (Sessions IDE)
│   │   └── C*/                        9 C shim module maps (pkg-config-resolved)
│   ├── Tests/ClawdmeterLinuxTests/    34 tests (security + storage + UI + visual)
│   ├── scripts/configure-c-shims.sh   pkg-config validation
│   └── resources/                     .desktop + .appdata.xml + systemd unit +
│                                       packaging/appimage/ + packaging/deb/
├── .github/workflows/linux.yml        Linux CI matrix + AppImage/.deb build + install tests
├── .github/PULL_REQUEST_TEMPLATE.md   Manual VM gate sign-off checklist
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
    │   │   ├── AgentControl/                   shared CLI-session helpers
    │   │   │   ├── Protocol.swift              v4 wire DTOs (compose-draft)
    │   │   │   └── JSONLSessionId.swift        Claude `sessionId` / Codex `payload.id`
    │   │   ├── Composer/                       chat-composer state model
    │   │   │   ├── ComposerStore.swift         text + attachments + chips; locked semantics
    │   │   │   └── SkillFrontmatter.swift      YAML frontmatter parser for SkillCatalog
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
    │   └── Tests/ClawdmeterSharedTests/            XCTest, 250 tests
    ├── ClawdmeterMac/                     macOS app
    │   ├── ClawdmeterMacApp.swift             @main, Window + Settings
    │   ├── AppRuntime.swift                   owns AppModel × 2 + analytics
    │   ├── AppModel.swift                     per-provider poller + reviver
    │   ├── DashboardView.swift                provider columns + analytics row
    │   ├── AnalyticsView.swift                totals + daily chart + by-repo
    │   ├── PopoverView.swift                  menu-bar popover
    │   ├── MenuBarGaugeView.swift             16pt status-bar gauge
    │   ├── AppDelegate.swift                  NSStatusItem + NSPopover wiring
    │   ├── AgentControl/                      v1 daemon + v0.3.0 Tailscale host
    │   │   ├── TailscaleHost.swift            getifaddrs(3) + status JSON fallback
    │   │   └── … (see "Sessions feature v1/v2" below for the full set)
    │   ├── Workspace/Composer/                v0.3.0 Mac chat IDE module
    │   │   ├── ComposerInputCore.swift        SwiftUI composer bound to ComposerStore
    │   │   ├── EmptyStateCenteredComposer.swift   Codex-style centered first-send composer
    │   │   ├── AttachmentChip.swift           per-attachment chip with QL preview
    │   │   ├── AttachmentStaging.swift        writes to attachments/ or worktree sandbox
    │   │   ├── AutopilotChip.swift            confirm sheet + per-repo trust gate
    │   │   ├── CommandPalette.swift           slash-command palette (SkillCatalog)
    │   │   ├── MentionPicker.swift            @-mention picker (sessions / sources / JSONLs)
    │   │   └── MacComposerSender.swift        loopback HTTP client → daemon /sessions/:id/send
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

To produce a DMG for distribution: `./tools/build-mac-dmg.sh` → `dist/Continuum-<version>-arm64.dmg`.

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

## Sessions WhatsApp-smooth pipeline (v0.5.0 build 33, 2026-05-19)

Four mergeable phases moved the iPhone and Mac chat surfaces from
"feels heavy / sluggish to scroll" to native-chat smoothness. The plan
went through `/office-hours` → `/plan-eng-review` → Codex outside-voice
review (which gutted the original plan with 3 P0s + 9 P1s); the rescoped
v1 ships in four commits on `main`, none of which require a wire
version bump above 5.

The originally-planned APNS push, ConversationFilter, cursor delta
envelope, shared cross-platform container, and Mac sidebar List
migration were all explicitly deferred during the review; see
`TODOS.md` "v0.6 / v1.1 — WhatsApp-smooth Sessions follow-ups" for the
follow-up briefs.

### Phase 0a — daemon-owned per-session chat store

- New file `apple/ClawdmeterMac/AgentControl/DaemonChatStoreRegistry.swift`.
  `@MainActor` class that owns a `[UUID: SessionChatStore]` registry
  on the *daemon* side. Mirrors the pattern Mac UI's `SessionsView`
  uses for the dashboard, but lives in `AgentControlServer` so HTTP
  + WS subscribers can share one long-lived store per session id
  instead of forcing a fresh JSONL reparse on every `/chat-snapshot`
  request.
- Subscriber retention: `acquire(for:)` / `release(sessionId:)`
  pair for long-lived subscribers (WS in Phase 2), `snapshotStore(for:)`
  for one-shot HTTP handlers. Idle sweep evicts after 5 minutes of
  no subscribers; hard cap at 20 resident stores.
- Cold-miss fallback path preserved in `handleGetChatSnapshot` —
  first request after server boot or after eviction still works at
  legacy reparse latency, and the warmed store catches up for the
  next request.
- `WireChatSnapshot.updateCounter` is now populated from
  `SessionChatStore.updateCounter` (the actual transcript cursor)
  instead of `session.lastEventSeq` (a registry/status counter). Wire
  version bumped 4 → 5 with `chatSubscribeMinimum = 5` gating Phase 2.
  Field shape unchanged; v4 iOS clients keep working — only the
  semantics shifted.

### Phase 0b — SessionFileResolver + Codex respawn lineage

- New file `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/SessionFileResolver.swift`.
  Maps `AgentSession.id → on-disk JSONL URL` with explicit lineage
  tracking for Codex sessions across `approve-plan` boundaries.
- Why: `approve-plan` intentionally kills the plan-mode pane and
  spawns a fresh Codex rollout file (new JSONL with a new Codex
  session id). The pre-Phase-0b daemon resolved Codex chat via
  `newestCodexJSONL()` (global newest) — works for one session at a
  time but silently strands on the wrong file as soon as any other
  Codex session ticks over.
- API: `resolve(session:)` returns the cached URL if still valid OR
  scans `~/.codex/sessions/` for the newest rollout in the session's
  activity window (`createdAt … lastEventAt + 5min`). `record(sessionId:rolloutURL:)`
  for the spawn path; `invalidate(sessionId:)` for the `approve-plan`
  handler. Belt-and-suspenders auto-promotion: even without explicit
  invalidate, `resolve` will pick up a newer in-window rollout if one
  appears.
- `SessionChatStore.resolveSessionFileURL(repoCwd:)` and `encodeCwd`
  / `newestJSONL` are now `nonisolated static` so the resolver's
  `@Sendable` Claude closure can call them without an actor hop.
  Pure FileManager calls, no isolation required.
- The resolver is constructed in `AgentControlServer.init` and
  injected into `DaemonChatStoreRegistry` via the `resolveURL` closure.
  `handleApprovePlan` calls `chatFileResolver.invalidate(sessionId:)`
  after the respawn succeeds.

### Phase 1 — iPhone + Mac chat lists → native List

- iOS `liveChatList` at [iOSSessionsView.swift:935](apple/ClawdmeteriOS/iOSSessionsView.swift:935)
  and Mac `ChatThreadScroll.body` at
  [SessionWorkspaceView.swift:1488](apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1488)
  moved from `ScrollView { LazyVStack }` with per-row `.id(item.id)`
  + per-row `.onAppear` / `.onDisappear` pin-tracking to native `List`.
  - The per-row `.id(item.id)` defeats SwiftUI row recycling
    (~10x scroll-perf cost at 1k+ messages per Stream benchmarks).
  - The per-row appearance callbacks fired on EVERY chat item as the
    user scrolled, doing N appearance dispatches per scroll-frame.
- Both surfaces now use a single 1pt `Color.clear` bottom-sentinel
  row whose `.onAppear` / `.onDisappear` drive `pinnedToBottom`. One
  callback per scroll-edge event, not N per scroll-frame.
- Scroll-on-new-item path coalesces rapid bumps via a 50ms
  `Task.sleep` debounce so streaming reply tokens stop animating
  scroll-to-latest per token.
- Mac AppKit `List` fall-back documented: if perf regresses on very
  long sessions, swap to `LazyVStack` without `.id(item.id)` keeping
  identity stable via `ForEach(id: \.id)`.

### Phase 2 — chat-subscribe WS push (replaces iOS 3s HTTP polling)

- New file `apple/ClawdmeterMac/AgentControl/ChatStreamWebSocketChannel.swift`.
  Server-side `WSChannel` that observes `SessionChatStore.$snapshot`
  via Combine, debounces commits at 100ms via `.debounce`, encodes a
  `WireChatSnapshot` as JSON, and sends as a WS text frame. Lifecycle
  pairs `acquire` on `start()` with `release` on `stop()` so the
  registry's idle sweep eventually evicts the store after the last
  subscriber disconnects.
- Dispatcher gains a `"chat-subscribe"` case alongside
  `"compose-draft"`, `"terminal"`, `"events"` in
  `AgentControlServer.routeWSSubscription`. Same envelope shape:
  `{op, token, sessionId}`. Bearer auth + Tailscale whois gates
  cover the new path via the existing routing — zero new auth surface.
- **No delta encoding in v1.** Codex's outside-voice review (D6)
  explicitly cut the `WireChatEvent.appendItems` /
  `.patchLastToolRun` / `.resyncRequired` envelope until measurements
  prove the bandwidth savings justify the bug surface.
- iOS `iOSChatStore` is now a long-lived WS subscriber. `start()`
  spawns a `runSubscriptionLoop` Task that:
  - Gates on `serverWireVersion ≥ chatSubscribeMinimum = 5` (older
    Macs stay on the HTTP fallback ladder).
  - Opens a `URLSessionWebSocketTask`, sends `{op: "chat-subscribe",
    token, sessionId}`, then receives frames in a loop and applies
    each one wholesale.
  - On transient WS error, retries with exp backoff 1→2→4→8→16→30s
    plus 0-20% jitter.
  - After 3 consecutive WS failures, falls back to HTTP polling for
    3 cycles before retrying WS. Prevents stranding when the
    daemon's WS port flaps but HTTP works.
- `UIApplication.didBecomeActiveNotification` observer cancels the
  current WS task if the last received frame is >30s stale, forcing
  the subscription loop to reconnect.
- `AgentControlClient.fetchChatSnapshot(sessionId:)` HTTP path
  preserved both for the fallback ladder and any one-shot callers.

### Tests

- `apple/ClawdmeterShared/Tests/ClawdmeterSharedTests/AgentControl/SessionFileResolverTests.swift`
  (new — 9 cases). Covers Claude path delegation, Codex
  activity-window scanning, cache reuse, the regression-critical
  `testCodexApprovePlanRespawnLineage_CRITICAL`,
  `testCodexExplicitInvalidateForcesRescan`,
  `testCodexCachedFileMissingFallsBackToScan`,
  `testFallbackToNewestForSyntheticPreview`, `testRecordSetsCacheDirectly`.
- `testWireVersionConstant` in `SessionsV2Tests` updated to assert
  the `4 → 5` bump + `chatSubscribeMinimum = 5`.
- 267 → 276 ClawdmeterShared tests. Mac / iOS / Watch schemes all
  build clean (CODE_SIGNING_ALLOWED=NO).
- See `TODOS.md` "Mac + iOS XCTest test targets" for the 9 spec'd
  tests that need new test scaffolding before they can land.

## Sessions feature v2 (2026-05-17)

Mobile-native control plane for Claude Code + Codex. iPhone (and Watch)
can now start, monitor, and control sessions running on the paired Mac
in worktrees, with Conductor-grade model picker + effort dial + plan/code
toggle + mid-session swap. See `docs/designs/sessions-v2.md` for the
full v2 ship details and `TODOS.md` for deferred work.

Wire (v4 as of v0.3.0): `Protocol.swift` carries `ReasoningEffort`, `ModelCatalog`
(5 Claude + 5 Codex models bundled), `HealthResponse` with `wireVersion`,
`ChangeModel/Effort/Mode/Send/Autopilot/PickWinner` DTOs, `PRStatus`,
`CreatePRRequest`, `GitDiffFile` + `GitDiffHunk`, `PreflightQuery/Response`,
`WireChatSnapshot`. v4 adds the `compose-draft` WS op for X1 cross-Apple
handoff with `composeDraftMinimum=4`; older Macs return `.unsupportedData`
close so iOS gates the post on `serverWireVersion`. `AgentSession`
schema v3 adds `effort`, `abPairSessionId`, `abPairDecidedAt`. v2 decoders
accept new fields via `decodeIfPresent` — back-compat preserved. v2 readers
reading a v3 sessions.json silently drop the new fields.

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
per session. (Both shipped as infrastructure in v2.0; wired into the
handlers in v2.0.1 — see the polish section below.)

Mac UI: `SessionWorkspaceView` composer header now hosts `ModelPicker`
+ `EffortDial` chips next to the existing `ModePicker`.
`SessionConfigChanger` is the kill-pane + respawn-with-new-config
helper. `SessionsModel.switchModel/Effort/PlanMode` wire it up.

iOS Sessions tab: full picker rewrite. `iOSModelPicker` /
`iOSEffortDial` / `iOSSessionControlsStrip` / `iOSSessionActivityStrip`.
`SessionDetailView` is a 5-tab structure (Chat / Plan / Diff / PR /
Terminal). `iOSDiffView`, `iOSPRPane`, `iOSPlanTrackerView` cover mobile
review surfaces. `iOSChatStore` mirrors the daemon's chat snapshot;
`iOSChatStoreCache` is LRU-2 with protected sessions. (The Terminal tab
becomes multi-pane and the Artifacts pane lands in v2.0.1 — see polish
section below.)

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

Tests at v2.0 ship: 153/153 (was 133) in `ClawdmeterShared` after adding
`SessionsV2Tests` covering schema v3 round-trip + back-compat,
`ReasoningEffort` flag mapping, `ModelCatalog.bundled` consistency,
mid-session change DTOs, `HealthResponse`, `WireChatSnapshot`, `CityPool`,
`WatchSessionSummary`. All three platform schemes build clean. (Subsequent
polish + the v0.3.0 chat-IDE rewrite carry the suite to 250 — see
CHANGELOG.md.)

## Sessions v2.0.1 polish (2026-05-17 same-day follow-up)

After the v2.0 ship, a same-day polish pass closed the most visible
asymmetries and rendering gaps the user hit in the first hour of real
use. Mac DMG bumped builds 7 → 14 across this pass and re-uploaded to
the `v0.2.0-mac` GitHub release.

- **Pairing is front-and-center.** New `PairingQRPopoverContent` view
  is hosted by a terra-cotta "Sync with iPhone" button in the Mac
  dashboard header (`DashboardView.swift`) — clicking opens a popover
  with the QR code + a Copy URL CTA. The full Settings → Sessions
  pane still owns regenerate/revoke. On iOS, every empty state that
  needs pairing (Sessions / Analytics / Codex card) now shows a
  shared `PairingCTAButtons` view with side-by-side Scan QR + Paste
  URL, each pre-targeting the corresponding tab in `PairingFlow` via
  the new `initialMode` parameter.
- **Plan mode for Codex.** `AgentSpawner.codexArgv` accepts
  `planMode: Bool` and emits `-s read-only`. `handleApprovePlan`
  branches on `session.agent` and uses `claudeArgv` (`acceptEdits`)
  or `codexArgv` (`workspace-write`) for the post-approve respawn.
  Codex sessions seeded into plan mode get a synthetic `planText`
  so the existing `PlanCardView` / `iOSPlanTrackerView` render the
  Approve & run button without code changes — Codex doesn't emit
  `ExitPlanMode`. The "Claude only" copy in both New Session sheets
  and the `iOSSessionControlsStrip` Plan/Code toggle is gone.
- **Codex chat actually renders.** `SessionChatStore.ParsedLine.from`
  gained a `case "response_item":` branch + `decodeCodexResponseItem`
  helper. Maps Codex's payload shapes (`message` user/assistant,
  `function_call`, `function_call_output`, `reasoning`) into the
  existing `ChatMessage` model. Filters Codex's auto-injected
  `<environment_context>` user turns and `role: developer` system
  wrappers. Tool-arg summaries use Codex's names (`cmd`, `brief`,
  `apply_patch` variants) via `summarizeCodexInput`. The
  `TranscriptLoader` daemon endpoint reuses the same parser, so iOS
  gets Codex chat rendering for free.
- **Sub-agents stop drowning the sidebar.** `RepoIndex.readCodexSessionMeta`
  now reads `payload.thread_source` / `payload.agent_role` from each
  Codex rollout. Rollouts tagged `subagent` (Codex worker threads —
  one user turn can spawn 5–10) are skipped at the meta stage. Parent
  rollouts still surface as Recent rows.
- **Sessions sidebar collapses by repo on iOS.** Repo headers in
  `iOSSessionsView.repoList` are now `Section(isExpanded:)` (iOS 17+).
  Default: expanded if the repo has a live or active session,
  collapsed otherwise. Manual taps win via `manuallyExpanded` /
  `manuallyCollapsed` Sets. Headers gained a rotating chevron + a
  count badge for the combined `sessions + recentSessions`.
- **Analytics totals + chart show provider logos.** New cross-platform
  `ProviderBadgeImage` (`ClawdmeterShared/Analytics/Views/`) handles
  the AppKit/UIKit `.isTemplate` asymmetry (Codex silhouette needs
  `.template` to render on dark backgrounds; Claude's burst keeps
  full color). `AnalyticsTotalsGrid` header row uses it; `AnalyticsDailyChart`
  hides Swift Charts' auto-legend (`.chartLegend(.hidden)`) and
  renders a custom legend with the same logos.
- **RateLimiter + AuditLog wired into daemon handlers (T12 + T13, build 14).**
  Infrastructure shipped in v2.0; this closes the call sites.
  `handleSendPrompt` calls `RateLimiter.tryAcquireSend` (1/sec) and 429s
  on deny; `handleChangeModel`/`Effort`/`Mode` call `tryAcquireSwap`
  (1/5sec); each path records to the matching `AuditLog` stream.
  `handleApprovePlan` records a `(plan-approve agent=…)` swap entry so
  the new agent-branched respawn path is auditable. New
  `HTTPResponse.tooManyRequests` static returns a structured 429 body.
- **Settings → Diagnostics tab (T17 + T18, build 14).** New
  `DiagnosticsSettingsView` hosts a segmented Audit Log / Wire Inspector
  surface picker. T17 reads `~/.clawdmeter/audit/{sends,swaps,autopilot}.jsonl`
  with text + session-ID filter, tap-to-expand-raw, "Open in Finder"
  affordance. T18 is a new `WireInspector` actor (off by default; cap
  500 entries ~5MB) with a toggle + live tail polling every second; the
  daemon dispatches into it from `dispatch()` (incoming requests) and
  the response sender (outgoing responses via a detached observer Task).
- **iOS multi-pane terminal tab strip (T33, build 14).** `iOSTerminalView`
  accepts an optional `paneId` passed through the WS envelope (falls
  back to primary when nil — preserves v1 behavior). New
  `iOSTerminalTabsView` wraps it in a horizontal chip strip; tap a chip
  to switch panes (re-id forces WS teardown + reconnect on a new
  paneId), tap `+` to spawn (`POST /sessions/:id/terminals`),
  long-press a non-primary chip for Delete.
- **iOS artifacts pane + daemon `/artifact` endpoint (build 14).**
  Closes the v2.0.1 TODOS.md "iOS artifacts pane" carryover. New
  `iOSArtifactsPane` (reached from SessionDetail overflow menu →
  "Artifacts (N)") lists `chatStore.snapshot.artifactEntries`,
  downloads bytes via the new `GET /sessions/:id/artifact?path=…`
  endpoint to `tmp/clawdmeter-artifacts/<sessionId>/`, and hands the
  local URL to `QLPreviewController` via `.quickLookPreview`. The
  daemon endpoint canonicalizes the path + requires it to live under
  the session's worktree (rejects `?path=../../../etc/passwd`); cap
  at 50MB so giant agent-written files don't park the daemon.

All changes ship via feature branch → PR → merge, never directly to `main`.
Use `/ship` to create the PR and `/land-and-deploy` to merge it. Each branch
should be scoped to a single logical change so PRs are small and reviewable.
The build version (`CURRENT_PROJECT_VERSION` in `apple/project.yml`) is the
source of truth for what's in the DMG.

## Sessions Mac chat IDE (v0.3.0 build 17, 2026-05-18)

Five-wave rewrite of the Sessions tab into a chat workbench. The tab is
no longer a session manager that hosts a `[Chat | Terminal]` segmented
picker; chat is the only mode and raw terminal is demoted to a `Cmd+T` overlay
reusing `TerminalTabContainer`. The composer is the surface that took the
biggest jump.

- **Wave A — Continuable sessions.** Right-click a recent JSONL row → "Continue here"
  parses the CLI's own session id from the file header via the new
  `JSONLSessionId` helper (Claude `sessionId` / Codex `payload.id`) and
  spawns a direct runtime with `--resume <id>` / `resume <id>`. The new
  session pins to the same JSONL so chat history is continuous.
  `SessionsModel.spawnSession` gains `resumeSessionId`, `model`,
  `effort`, and `pinnedJSONLURL` parameters.
- **Wave B — Runtime-as-chat first-class.** Mac send path moves to the
  daemon's `POST /sessions/:id/send` via the new `MacComposerSender`
  loopback HTTP client, so the daemon's audit + rate-limit + PTY/harness send
  heuristics apply
  uniformly across Mac and iOS. Send button transforms into a stop
  button (`/sessions/:id/interrupt`) when the session is running.
- **Wave C — Powerful composer.** New shared `ComposerStore`
  (`ClawdmeterShared/Composer/`) owns text/attachments/chip state with
  a `SendError` enum and locked semantics: text preserved on error,
  attachments preserved on error, trailing-newline always appended for
  PTY submission. `ComposerInputCore` SwiftUI view binds it.
  Paperclip is wired to `.fileImporter` + `.onDrop` + `NSPasteboard`
  clipboard image paste. Image-paste-as-PNG, drag-drop from Finder, and
  the file picker all route through `AttachmentStaging` which writes
  to `~/Library/Application Support/Clawdmeter/attachments/<sessionId>/`
  for Claude or Codex local, or into `<worktree>/.clawdmeter-attachments/`
  when Codex is in worktree mode (so files live inside its sandbox root).
  `QLThumbnailGenerator` previews on each chip; 50MB hard cap.
- **Wave D — Centered empty state.** "Pick a session to open it here"
  replaced by `EmptyStateCenteredComposer` with `What should we work on
  in <repo>?`, a repo picker chip, and full Mode/Model/Effort/Plan chips.
  First send spawns a session via `model.spawnSession`, waits for pane
  readiness, then posts the prompt as the opening user turn.
- **Wave E — Polish.** Worktree-branch chip on the chat header.
  Tool-run groups default-collapsed. Read-only footer points at the new
  Continue-here context-menu.

Composer chip extensions:

- **Slash-command palette (X4).** Typing `/` opens a popover that lists
  installed Claude Code skills walked from `~/.claude/skills/<name>/SKILL.md`
  (global) + `<repo>/.claude/skills/<name>/SKILL.md` (project-local) for
  Claude sessions, or a built-in `/clear`/`/compact`/`/model`/`/help`/`/quit`
  list for Codex. `SkillCatalog` runs the 127-file scan + YAML frontmatter
  parse on a `Task.detached` background thread with a 30s TTL + dir-mtime
  invalidation, so the palette opens without ever stalling the main thread.
  Frontmatter parser lives in shared `SkillFrontmatter` for testability.
- **`@`-mention picker.** Typing `@` opens a popover listing open sessions +
  agent-cited files in this session (`SourceEntry`) + recent JSONLs across
  sessions. Full repo-file walker deferred to follow-up (see TODOS.md).
- **Autopilot chip (T12).** Confirm sheet warns the toggle interrupts the
  current turn. Repos not on the autopilot trust list show
  "Trust this repo for autopilot?" and the CTA flips to "Trust repo + enable
  autopilot" calling `AutopilotState.trustRepo(repoKey)` before
  `setAutopilot`. Daemon's `handleSetAutopilot` enforces per-repo trust at
  the wire: HTTP 403 when `req.enabled` is true and the repo is not on
  `trustedRepoKeys`. Bearer-token-holding peers can't bypass the UI.
- **Running-session cost ticker.** Composer footer shows `~$X • Y K tokens`
  from `SessionChatStore.snapshot` × `Pricing.shared.cost(for:tokens:)`.
  Soft-red `⚠︎ weekly cap N%` badge at ≥95% for Claude sessions;
  Codex sessions get no cap badge (Anthropic's weekly cap doesn't map).

Cross-Apple compose-draft handoff (X1):

- New WS op `compose-draft` on the daemon dispatcher. iOS new-session
  sheet ships an "Open on Mac" button that opens a one-shot WebSocket,
  posts a `ComposeDraft` envelope (text + suggested repo/agent/model/effort),
  awaits the 1-byte ACK, closes. Mac dashboard listens via `NotificationCenter`
  and pre-fills `EmptyStateCenteredComposer`. Wire version bumped 3 → 4
  with `composeDraftMinimum=4`; iOS gates `postComposeDraft` on
  `serverWireVersion >= composeDraftMinimum` and surfaces "Update
  Continuum on the Mac" for older Macs. Inbound text capped at 64KB;
  `AuditLog` records every draft.

Pairing host resolution rewritten:

- `TailscaleHost.resolve()` reads the Tailscale interface address
  directly via `getifaddrs(3)` — no shell-out, no path assumptions.
  Falls back to `tailscale status --json` across three known install
  locations (`/opt/homebrew/bin/`, `/usr/local/bin/`, App Store install).
  Detects `BackendState != "Running"` so the Mac surface warns "Tailscale
  installed but not running" instead of letting you scan a dead URL.
- Old code shelled out to `/opt/homebrew/bin/tailscale` only; when the
  binary lived elsewhere, the pairing URL silently fell back to `127.0.0.1`
  and iPhones couldn't reach the Mac. This was the root cause of the
  "I paired but nothing works" symptom.

Tests: 250/250 in `ClawdmeterShared` (was 215). Added
`JSONLSessionIdTests` (10), `SkillFrontmatterTests` (10),
`ComposerStoreTests` (+15 cases for state/render/error/empty-state
behavior). `SessionsV2Tests` wire-version assertion bumped 3 → 4.

## Sessions feature v1 (added 2026-05-16, extended through Phase G3)

Read-write control plane for Claude Code + Codex CLI agent sessions, on top
of the existing read-only analytics. Mac runs a SwiftNIO-free
Network.framework HTTP+WS daemon (port 21731 / 21732) inside `ClawdmeterMac`;
iPhone + Watch consume it over Tailscale. Claude and terminal surfaces use
direct PTY hosts; Codex, Cursor, Gemini, and Grok use harness providers.

### Daemon + data layer — `apple/ClawdmeterMac/AgentControl/`
- `ClaudePtyRegistry` + `TerminalPtyRegistry` + `PseudoTerminal` —
  direct PTY hosts for Claude sessions and terminal panes. Owns terminal
  spawn, input, resize, output streaming, and process-group teardown.
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
- `ShellRunner` — argv-only subprocess wrapper. NEVER concat into shell
  strings (the repo path has a space; concat breaks).
- `SessionScheduler` (G15) — single re-armable `DispatchSourceTimer`
  observing `registry.$sessions`; fires scheduled follow-ups through the
  session runtime.
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
  into the agent runtime (G13).
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
- Each repo expands to show Continuum-spawned sessions (registry-
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
G2 schema fields, RecentSession).
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

## Chat tab (v0.23.6 Chat V2 → v0.24.0 Chat V3 broadcast)

The Chat tab is a separate surface from the Sessions / Code tab
described above. Sessions/Code is a direct runtime / harness agent workbench;
Chat is the function-first conversational surface. They share the
same `AgentSessionRegistry`, `DaemonChatStoreRegistry`, and
`/sessions` daemon, but the UI and ingestion paths diverge.

### Chat V2 (v0.23.6 build 121, 2026-05-23) — function-first rebuild

- `MacChatV2View` / `IOSChatV2View` replace eight legacy chat
  surfaces. Live snapshot-bound; no per-row re-render storms.
- Wire v14 adds `TurnState` + `WireChatSnapshot.currentTurnState` +
  `CreateChatSessionRequest.deepResearch`. Per-turn lifecycle is
  authoritative now — the previous "no new event in 2s = done"
  heuristic is the fallback for wire v13- daemons only.
- Per-backend Stop: PTY `ESC` for Claude, harness cancellation for Codex,
  Cursor, Gemini, and Grok, and OpenCode HTTP cancel where available.
- Honest Deep Research across Claude, Codex, and Antigravity; gated
  by `tools/verify-deep-research.sh`.
- `PermissionPromptCard` lifted into `ClawdmeterShared` with a
  `PermissionResponder` protocol so both Mac + iOS render the same
  prompt shape.
- Wire-version gates live in `AgentControlWireVersion`:
  `chatMinimum=9`, `frontierMinimum=9`, `turnLifecycleMinimum=14`,
  `deepResearchMinimum=14`, `chatSearchMinimum=14`. iOS gates each
  feature behind the matching `supports*` predicate so older paired
  Macs degrade with a banner instead of failing silently.

### Chat V3 broadcast (v0.24.0 build 125, 2026-05-23) — multi-provider compare

Chat tab gets a broadcast mode. Pick 2–3 providers, send one prompt,
see the answers side-by-side with per-provider tokens and cost. Star
the better answer per turn. Continue from a winner to demote the
broadcast group to a Solo chat that keeps the winning transcript.

**Wire (`Protocol.swift`):**
- `CreateFrontierRequest` / `CreateFrontierResponse` /
  `FrontierGroupSnapshot` / `FrontierSendRequest` (with optional
  `perChildText: [UUID: String]`) / `FrontierTurnWinner` /
  `SetFrontierTurnWinnerRequest`.
- HTTP: `POST /chat-sessions/frontier`,
  `POST /chat-sessions/frontier/:groupId/send`,
  `POST /chat-sessions/frontier/:groupId/pick-winner`,
  `POST /chat-sessions/frontier/:groupId/turn-winner`,
  `POST /chat-sessions/frontier/:groupId/retry-slot`.
- WebSocket: `frontier-subscribe` op streams a
  `FrontierGroupSnapshot` per child on a 100ms debounce; envelope is
  `{op, token, groupId}`.
- `GET /chat-providers` returns per-provider availability so the
  broadcast mode picker can grey out providers that aren't
  configured (Antigravity not running, Codex creds missing, etc.).
- Deep Research is a creation-time toggle on every
  `FrontierModelSlot` and propagates to every child (Codex sandbox
  flag, Claude system prompt).

**Surfaces:**
- Mac (`MacChatV2View`): left history sidebar, mode toggle (Solo vs
  Broadcast), provider summary chips above the chat, and a
  horizontally-scrollable column-per-provider transcript. Tahoe
  glass aesthetic from the standalone Continuum redesign.
- iOS (`IOSChatV2View`): compact version. Provider pills above the
  selected-reply card, swipe between providers.

**Pick-winner semantics (the destructive variant):**
- `handlePickFrontierWinner` archives every loser child, then calls
  `AgentSessionRegistry.clearFrontierGroupBinding(id:)` on the
  winner to drop its `frontierGroupId` / `frontierChildIndex`. The
  winner appears in the sidebar as a regular Solo chat; follow-ups
  go through `POST /sessions/:id/send`.
- UIs flip `openTarget` to `.solo(winner.id)` on the response
  callback so the active surface follows the winner out of the
  broadcast group.
- Star (`/turn-winner`) is the non-destructive variant: pure
  metadata on the group's `turnWinners` list, no archive.

**Per-child send fan-out:**
- `FrontierSendRequest.perChildText` lets the broadcast composer
  send the same bytes to multiple children while only `@`-mentioning
  each child's own staging path. `uploadAndBuildPerChildPrompts`
  uploads once per child via per-child paths in
  `<worktree>/.clawdmeter-attachments/<sessionId>/`. Legacy
  `SendPromptRequest` shape still accepted for back-compat.
- Mid-fan-out archive race: each per-child send re-checks
  `archivedAt` immediately before issuing the prompt, so a
  concurrent `/pick-winner` can't leak the prompt to a just-archived
  loser.
- `frontierGroupChildren(groupId:includeArchived:)` defaults to
  live-only. Pick-winner enumerates with `includeArchived: true`;
  every other path (send fan-out, WS snapshot, search hydration)
  gets live-only.

**Minimum-broadcast gate:**
- `CreateFrontierResponse.hasMinimumBroadcast` requires ≥ 2
  successful spawns. A single-success response surfaces every failed
  slot's `reason` so the composer can show why a broadcast degraded
  instead of silently dropping into a one-agent "broadcast."

**Search/history hydration:**
- A search hit for a Frontier group whose live children dropped
  below 2 (e.g. after pick-winner archived losers) now reopens the
  matched session as Solo, not as a read-only transcript. Keeps
  history navigable after the broadcast resolves.

**New files (shared package):**
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Chat/FrontierSnapshotStore.swift`
  — `@MainActor ObservableObject` mirror of the WS snapshot; Mac +
  iOS bind to it directly.
- `apple/ClawdmeterMac/AgentControl/FrontierWebSocketChannel.swift`
  — daemon WS channel; observes each child's `SessionChatStore`,
  debounces, encodes a `FrontierGroupSnapshot` with current
  `turnWinners`.

**Pre-existing system property closed (P2 fix in same PR):**
- `OpencodeAuthFile.migrateLegacyEntriesIfNeeded` no longer bails
  when the canonical file exists. It reads canonical, merges any
  legacy provider entries that canonical was missing, and writes
  back. Malformed canonical files are still left untouched so users
  with salvageable bytes don't lose them.

**Tests:** 643 ClawdmeterShared, 190 Mac. New: 6 in
`AgentSessionRegistryFrontierTests` (live-only filter +
`clearFrontierGroupBinding`), 4 in `WireV9Tests` (broadcast minimum
+ per-child round-trip), 1 in `OpencodeAuthFileTests` (canonical
preservation across migration probe).

**Deferred follow-ups:** see `TODOS.md` "v0.24.0 follow-up —
Broadcast Chat V3 adversarial-review deferrals" for the 11
non-blocking findings (WS reconnect after pick-winner, two-pass
decode silence, partial-upload degradation, OpencodeAuthFile
inter-process race, etc.).

## Code V2 control plane (v0.26.0 build 129, 2026-05-23)

Lands as one coordinated ship: the Mac daemon owns durable workspace
records keyed by canonical repo root, a real idempotency-key outbox
that prevents iOS retries from double-sending, a MagicDNS-first
pairing flow that survives sleep/wake and Wi-Fi switching, and the
six iOS workbench panes finally wired into session detail. Wire
protocol bumps v15 → v16; every change is additive so older Macs
keep decoding via `decodeIfPresent`.

### Persisted workspace store

- `apple/ClawdmeterMac/AgentControl/WorkspaceStore.swift` (381 lines).
  `@MainActor` file-backed registry of `CodeWorkspaceRecord` keyed by
  canonical repo root. Atomic writes to
  `~/Library/Application Support/Clawdmeter/workspaces.json` with a v1
  schema. Stable IDs come from deterministic SHA-256 over the repo
  path so a record's UUID survives daemon restarts.
- One-shot migration from `sessions.json`: on first launch with no
  `workspaces.json`, groups sessions by canonical repo root and seeds
  `WorkspaceProviderDefaults` from the newest session in each group.
  Old `sessions.json` is left untouched — the migration is read-only
  against it.
- New endpoints: `GET /workspaces` returns the full list,
  `PATCH /workspaces/:id` updates `WorkspaceProviderDefaults` (model,
  effort, mode, agent). iOS reads via
  `AgentControlClient.listWorkspaces()` and
  `updateWorkspaceDefaults(workspaceId:defaults:)`. The intent: the
  iOS new-session sheet inherits per-repo defaults so the user
  doesn't re-pick model+effort every time they spawn an agent in the
  same repo.
- `apple/ClawdmeterMacTests/WorkspaceStoreTests.swift` (10 cases)
  covers round-trip, migration from `sessions.json`, upsert
  semantics, deterministic-UUID stability across launches, and
  concurrent write isolation.

### Mobile command outbox with receipt dedup

Server side:
- `apple/ClawdmeterMac/AgentControl/MobileCommandOutbox.swift` (233
  lines). Actor with a 256-entry bounded LRU + 24h TTL. Every write
  endpoint (`/send`, `/approve-plan`, `/interrupt`, `/model`,
  `/effort`, `/mode`, `/autopilot`, `/ab-pair/pick-winner`,
  `/create-pr`, `/merge`) routes through
  `tryReplayIdempotent` / `sendCommandResponse` wrappers. A retried
  request with the same `MobileCommandEnvelope.idempotencyKey`
  replays the cached response instead of re-executing the side
  effect — no double-send, no double-merge.
- New JSONL audit stream at
  `~/.clawdmeter/audit/mobile-commands.jsonl` (hashed payload
  fingerprints, no PII). The outbox replays the last 256 audit
  entries on daemon startup to re-seed the receipt cache, so a
  daemon restart still dedups in-flight retries. Replay-hits report
  `status: .acknowledged` (we already saw this; the side effect
  already happened) but carry no cached response body — body shape
  is endpoint-specific and we don't leak content across rotations.

iOS side:
- `apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift` (411
  lines). `@MainActor ObservableObject` with a persistent queue at
  `Application Support/Clawdmeter/outbox.json`. Schema is a flat
  `{version, pending, failed}` dict; `MobileCommandEnvelope` is
  Codable so no on-disk migration needed.
- Exp backoff schedule `[1s, 4s, 15s, 60s, 5min, 30min]`. Beyond
  index 5 the envelope is parked in `.failed` permanently for user
  triage. Transient 5xx / network errors retry; 4xx (other than 429)
  go terminal immediately.
- `apple/ClawdmeteriOS/Workspace/iOSOutboxPane.swift` (124 lines)
  surfaces pending + failed envelopes with swipe Retry / Cancel.
  Reached via a per-session badge in the session detail nav bar.
- **v0.26 follow-up (this branch):** outbox is now app-scoped
  `@StateObject` on `IOSRootView`, passed down as `@ObservedObject`
  to `IOSSessionDetailView`. The original v0.26.0 ship held it as
  `@StateObject` per-detail-view — on iPad multi-window or rapid
  session switches two sibling instances could race the persisted
  `outbox.json`. Hoisting to app scope means one outbox owns the
  queue for the whole process.
- **v0.26 follow-up (this branch):** iOS composer / refine / approve
  callsites now route through `outbox.enqueueSend` /
  `outbox.enqueueApprovePlan` instead of direct `agentClient` calls.
  Composer clears immediately on enqueue; offline sends queue +
  retry with exp backoff; failures surface in the outbox badge
  instead of getting silently swallowed.

### MagicDNS-first pairing + clawdmeters:// scheme

- `TailscaleHost.resolve()` reordered so MagicDNS hostnames come
  first when `clawdmeter.pairing.preferMagicDNS` is on (default
  true). The pairing QR survives IP changes — no more re-scanning
  after sleep/wake or Wi-Fi switching.
- Settings → Pairing gains a Connectivity section with two toggles:
  "Prefer MagicDNS host in pairing QR" and "Use TLS for pairing
  (advanced)". With `preferTLS` on AND a MagicDNS host present, the
  QR emits the `clawdmeters://` scheme; iOS `PairingScannerView`
  accepts both `clawdmeter://` and `clawdmeters://` and persists a
  `useHTTPS` flag on `PairingChallenge`.
- Server-side TLS termination is explicitly deferred — the daemon
  still listens on plain HTTP today. The scheme + iOS flag are
  forward-compat plumbing for when `tailscale cert` wiring ships
  separately. Pairing without TLS still works exactly as it did in
  v0.25.0.

### iOS workbench tabs

- `IOSSessionDetailView` refactored from a single ScrollView into a
  chip-strip tab bar above content. Six tabs in the new
  `SessionWorkbenchTab` enum — Chat (custom thread + composer),
  Plan (`iOSPlanTrackerView`), Diff (`iOSDiffView`), PR
  (`iOSPRPane`), Terminal (`iOSTerminalTabsView`), Files
  (`iOSArtifactsPane`).
- The pane views existed as standalone files since Sessions v2
  but were never embedded in session navigation. This ship wires
  them up.
- Conditional visibility: Plan only when a plan exists, Terminal
  only when panes are spawned, Files only when artifacts are
  present. Last-selected tab persists per session in UserDefaults
  under `clawdmeter.ios.session.<sessionId>.tab`.
- `iOSPlanTrackerView` gained an `onApprove: (() async -> Void)?`
  callback so the parent routes through `AgentControlClient`
  (now via the outbox — see follow-up above).

### Wire v15 → v16 + new client methods

- `AgentControlWireVersion.current` bumped to 16.
  `workspacesMinimum = 16` gates the workspace endpoints,
  `mobileOutboxMinimum = 16` gates the idempotent write path. iOS
  surfaces a banner when paired to a Mac on `< 16` so older daemons
  degrade visibly instead of failing silently.
- New DTOs in Protocol.swift: `InterruptRequest`,
  `UpdateWorkspaceDefaultsRequest`, `WorkspaceListResponse`,
  `MobileCommandReceipt.jsonDictionary` helper for inlining receipts
  into ad-hoc JSON response bodies.
- `MobileCommandKind` cases added: `changeModel`, `changeEffort`,
  `changeMode`, `setAutopilot`, `pickWinner`, `updateWorkspace`.
- New typed methods on `AgentControlClient`: `listWorkspaces`,
  `updateWorkspaceDefaults(workspaceId:defaults:)`, `createPR`,
  `merge`. These replace ad-hoc URL building in iOS panes.
- `interruptSession`, `setAutopilot`, `approvePlan` upgraded from
  `async -> Void` to `@discardableResult async -> Bool` so the
  outbox can detect offline failures. **The bug this fixed:** the
  outbox was unconditionally returning `true` for these three
  commands because the client methods had no return value, so
  offline interrupts / approvals / autopilot toggles were falsely
  acknowledged.

### OpenCode + Codex SDK idempotency closures

- `AgentControlServer.handleSendPrompt` OpenCode and Codex SDK
  delegate paths were bypassing the idempotency record helper —
  retries would re-execute the side effect even though the
  framework appeared to dedup. Both now route through
  `sendCommandResponse` so the recorded receipt actually matches
  the work that ran.

### Follow-up fixes on this branch (darshanbathija/code-v3)

Five non-v0.26.0-spec'd patches that landed during the post-ship
review pass:

- **Watch build broken on watchOS — fixed.**
  `apple/ClawdmeterShared/Sources/ClawdmeterShared/Chat/Views/PermissionPromptCard.swift:157`
  was selecting `Color(.secondarySystemBackground)` on watchOS where
  UIKit doesn't expose it. Added `#elseif os(watchOS)` branch with a
  fixed `Color(white: 0.11)` (matches iOS dark-mode rendering of
  `secondarySystemBackground`, since watch is always dark).
  `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/AntigravityUsageParser.swift:88`
  was unconditionally calling `AntigravityDBUsageParser.parseUsage`
  which links SQLite3, also missing on watchOS. Gated behind
  `#if os(macOS) || os(iOS)` with a byte-estimator fallback for
  watch/tv builds. The watch app doesn't ingest Antigravity
  conversations directly today (it reads aggregated usage from the
  paired iPhone), so the fallback path is unreachable in practice
  but keeps the cross-platform build clean.
- **OpencodeAuthFile test flake — fixed.**
  `OpencodeAuthFile.migrateLegacyEntriesIfNeeded` was scanning the
  legacy sandbox-container path even when `XDG_DATA_HOME` was set,
  so `OpencodeAuthFileTests` running with an isolated `XDG_DATA_HOME`
  could pick up bytes from a process-wide leftover sandbox into the
  test's "isolated" root. Now: if `XDG_DATA_HOME` is set and
  non-empty, skip migration entirely. Tests get a clean isolated
  context; users with explicit XDG opt-out get no transparent
  migration (their explicit opt-in says they know where their data
  lives).
- **App-scoped MobileCommandOutbox + composer routing.**
  See "iOS side" follow-up bullets above. Both changes are scoped
  to `IOSRootView.swift` + `IOSSessionDetailView.swift`; the outbox
  itself is unchanged.

### Tests

- New: `apple/ClawdmeterMacTests/WorkspaceStoreTests.swift` (10),
  `apple/ClawdmeterMacTests/E2E/WireV14ContractTests.swift` (14),
  `apple/ClawdmeterMacTests/OpencodeProcessManagerTests.swift` (14).
- Extended: `apple/ClawdmeterShared/Tests/ClawdmeterSharedTests/AgentControl/WireV11Tests.swift`
  for wire v16 round-trips (11 cases total).
- Mac, iOS, and Watch schemes all build clean under
  `CODE_SIGNING_ALLOWED=NO` after the watchOS gating fix.

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
