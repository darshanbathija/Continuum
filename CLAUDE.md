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
