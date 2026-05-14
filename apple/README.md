# Clawdmeter for Apple — engineering README

Detail layout for the Xcode workspace. The top-level [`../README.md`](../README.md)
has the user-facing download + install + build flow.

## What this is built on

1. **The original [Clawdmeter](https://github.com/darshanbathija/Clawdmeter)
   ESP32 firmware.** Every gauge concept, color token (`#d97757` terra-cotta
   on `#000`), the `UsageData` struct shape, the BLE GATT JSON payload, the
   Anthropic rate-limit-header polling math, and the auto-revive "keep the
   5h timer warm" idea were all prototyped on the ESP32 first.
   `ClawdmeterShared/Sources/ClawdmeterShared/Model/UsageData.swift` is a
   Codable Swift port of the firmware's `data.h`.

2. **[ccusage](https://github.com/ryoppippi/ccusage) by
   [@ryoppippi](https://github.com/ryoppippi).** The entire analytics layer
   under `ClawdmeterShared/Sources/ClawdmeterShared/Analytics/` is a Swift
   re-implementation of ccusage's TypeScript aggregation. We parse the same
   on-disk JSONL files ccusage parses, dedup on the same
   `messageId:requestId` tuple, and apply the same LiteLLM pricing snapshot
   (filtered to `claude-*` + `gpt-*` + `o[0-9]+*` via
   `../tools/refresh-pricing.sh`). The user's terminal `ccusage` output is
   the ground-truth our numbers are calibrated against. If you find a
   divergence, **ccusage is right** — file an issue with the discrepancy
   and we'll fix the Swift port.

## Layout

```
apple/
├── README.md                                this file
├── project.yml                              xcodegen spec → Clawdmeter.xcodeproj
├── ClawdmeterShared/                        Swift Package, cross-platform
│   ├── Package.swift
│   ├── Sources/ClawdmeterShared/
│   │   ├── Analytics/                       ccusage in Swift
│   │   │   ├── TokenTotals.swift            Codable rollup with Decimal cost
│   │   │   ├── UsageRecord.swift            per-event normalized row
│   │   │   ├── RepoIdentity.swift           cwd → canonical repo (walks up for .git)
│   │   │   ├── Pricing.swift                LiteLLM lookup, Claude 200k tiering
│   │   │   ├── ClaudeUsageParser.swift      `~/.claude/projects/*.jsonl` line parser
│   │   │   ├── CodexUsageParser.swift       `~/.codex/sessions/*.jsonl` file parser
│   │   │   ├── UsageHistoryLoader.swift     actor; TaskGroup walks both dirs
│   │   │   ├── UsageHistorySnapshot.swift   per-window byRepo + byDay rollups
│   │   │   ├── UsageHistoryStore.swift      @MainActor ObservableObject; 60s timer
│   │   │   ├── pricing.json                 embedded LiteLLM snapshot (~145 models)
│   │   │   └── Views/                       TotalsGrid, DailyChart, RepoList
│   │   ├── Model/UsageData.swift            rate-limit snapshot struct (epoch tuple)
│   │   ├── Predictor/BurnRatePredictor.swift
│   │   ├── Theme/Theme.swift                colors, fonts, layout tokens
│   │   └── Sources/
│   │       ├── AISource.swift                  poll-source protocol
│   │       ├── AnthropicSource.swift           rate-limit header parser
│   │       ├── CodexSource.swift               Codex live rate-limit reader
│   │       ├── KeychainTokenProvider.swift     Mac: reads Claude Code OAuth token
│   │       ├── PastedAnthropicTokenProvider.swift  iOS/Watch: iCloud-Keychain-synced
│   │       ├── CodexTokenProvider.swift
│   │       ├── UsagePoller.swift
│   │       ├── UsageStore.swift                App Group cache for widgets
│   │       ├── UsageCloudMirror.swift          iCloud KV sync (Mac → iOS)
│   │       ├── WatchTokenBridge.swift          WCSession iPhone → Watch
│   │       └── AutoReviver.swift
│   └── Tests/ClawdmeterSharedTests/            XCTest, 59 tests, all passing
├── ClawdmeterMac/                              macOS app
│   ├── ClawdmeterMacApp.swift                  @main, Window + Settings
│   ├── AppRuntime.swift                        owns AppModel × 2 + analytics
│   ├── AppModel.swift                          per-provider poller + reviver
│   ├── DashboardView.swift                     provider columns + analytics row
│   ├── AnalyticsView.swift                     totals grid + daily chart + by-repo
│   ├── PopoverView.swift                       menu-bar popover (per-provider)
│   ├── MenuBarGaugeView.swift                  16pt status-bar gauge
│   ├── AppDelegate.swift                       NSStatusItem + NSPopover wiring
│   └── Assets.xcassets/AppIcon.appiconset/     10 sizes (16 → 1024@2x)
├── ClawdmeteriOS/                              iPhone app
│   ├── ContentView.swift                       TabView: Live / Analytics
│   ├── iOSAnalyticsView.swift                  iCloud-KV-mirrored analytics tab
│   ├── UsageModel.swift                        poller + cloud-mirror subscriber
│   ├── SettingsView.swift
│   └── Assets.xcassets/AppIcon.appiconset/
├── ClawdmeteriOSWidgets/                       Lock Screen / Home / StandBy widgets
├── ClawdmeterWatch/                            watchOS app
│   ├── ContentView.swift                       wrist meter
│   ├── WatchUsageModel.swift                   keychain + WCSession ingress
│   └── Assets.xcassets/AppIcon.appiconset/
├── ClawdmeterWatchWidgets/                     watchOS complications (4 families)
└── ClawdmeterMacWidgets/                       Mac menu-bar widget extension
```

## Build matrix

```bash
brew install xcodegen          # one-time
cd apple
xcodegen                       # regenerate Clawdmeter.xcodeproj
( cd ClawdmeterShared && swift test )

xcodebuild -scheme "Clawdmeter (Mac)"   -destination 'platform=macOS,arch=arm64'   build
xcodebuild -scheme "Clawdmeter (iOS)"   -destination 'generic/platform=iOS Simulator'  build
xcodebuild -scheme "Clawdmeter (Watch)" -destination 'generic/platform=watchOS Simulator' build
```

DMG packaging lives one level up: `../tools/build-mac-dmg.sh`.

## ccusage ↔ Swift mapping

| ccusage (TypeScript)                       | Clawdmeter (Swift) |
| ------------------------------------------ | ------------------ |
| Claude JSONL line parse                    | `ClaudeUsageParser.parse(line:)` |
| Codex cumulative → per-event deltas        | `CodexUsageParser.parse(file:)` |
| LiteLLM model → price (with Claude 200k tier) | `Pricing.cost(for:tokens:)` |
| Cross-file dedup on `messageId:requestId`  | `UsageHistoryLoader` global `Set<String>` |
| Daily bucketing                            | Cache schema v8 `byDayByRepo: [Date: [RepoKey: TokenTotals]]` |
| `daily` window (local calendar)            | `Window.today / past7d / past30d / allTime` |

What we added on top of ccusage (UI-only):

- Per-section window picker (Token-usage totals + chart use one window; the
  by-repo list has its own — independent control).
- Repo bucketing walks up for `.git` so Conductor branches, `.claude/worktrees`
  worktrees, and the user's primary checkout of the same repo collapse to
  one row.
- Non-git cwds (UUIDs, home dirs, abandoned Paperclip workspace IDs) collapse
  into a single **Other** row.

## Token sourcing

| Surface | Source |
| --- | --- |
| Mac (Claude) | `KeychainTokenProvider` reads Claude Code's local OAuth token. |
| Mac (Codex)  | `CodexSource` reads cached rate-limit state from `~/.codex/sessions/*.jsonl`. |
| iOS          | `PastedAnthropicTokenProvider.shared()` — iCloud-Keychain shared access group; Mac mirrors the token here on launch. |
| Watch        | First tries `WatchTokenBridge.didReceiveToken` (iPhone pushes via WCSession). Falls back to the shared Keychain. |

## Cache schema versioning

`AnalyticsCache.currentVersion` in `UsageHistoryLoader.swift` gates the
on-disk format. Bump it whenever you change the per-file shape; old caches
re-parse on first load. Recent versions:

- v6 — added Conductor / `.claude/worktrees` path fallbacks
- v7 — added downward "sole-git-child" descent (catches parent-of-repo cwds)
- v8 — non-git cwds collapse into `RepoKey.other` instead of polluting the list

## What still needs Xcode / a paid developer account

- **Notarization.** The current build is signed with a personal Apple
  Developer team (free tier). It works fine — Gatekeeper just asks the
  user to right-click → Open the first time. Notarization needs the
  `$99/yr` Apple Developer Program.
- **iCloud capabilities.** The iCloud KV sync used for Mac → iOS analytics
  needs the iCloud entitlement, which is also paid-tier-only. Without it,
  the iOS analytics tab shows "iCloud not enabled" / "Waiting for Mac sync"
  cards. The Mac app silently no-ops the `UsageCloudMirror.write*` calls.
- **CloudKit container.** Same paid-tier requirement.

The Mac app's primary surfaces (live polling, analytics row, menu bar)
all work fine on the free tier. iOS works for the Live tab (it has its
own poller via iCloud Keychain token sync). Watch works via WCSession.
