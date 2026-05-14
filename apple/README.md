# Clawdmeter for Apple

Native macOS / iOS / watchOS ports of [Clawdmeter](../) — the same live Claude
Code rate-limit gauges you get on the ESP32, now on the Mac menu bar, on your
iPhone Home Screen, and on your wrist. Plus a historical **$/token analytics**
layer (Today / Past 7d / Past 30d / All time, per repo, with daily-spend
charts) covering both Claude Code and Codex CLI.

## What this is built on

Two upstream sources do most of the heavy lifting; the Apple port is mostly
plumbing on top of them.

1. **The original [Clawdmeter](../) firmware (this repo's `firmware/` and `daemon/`).**
   Every gauge concept, color token (`#d97757` terra-cotta on `#000`), the
   `UsageData` struct shape, the BLE GATT JSON payload (`{"s":N,"sr":M,...}`),
   the Anthropic rate-limit-header polling math, and even the auto-revive
   "send 1 token to keep the 5h timer warm" idea were all prototyped on the
   ESP32 first. `ClawdmeterShared/Sources/ClawdmeterShared/Model/UsageData.swift`
   is a Codable Swift port of `firmware/src/data.h`.

2. **[ccusage](https://github.com/ryoppippi/ccusage) by [@ryoppippi](https://github.com/ryoppippi).**
   The entire analytics layer
   (`ClawdmeterShared/Sources/ClawdmeterShared/Analytics/`) is a Swift
   re-implementation of ccusage's TypeScript aggregation logic. We:
   - parse the same on-disk JSONL files ccusage parses
     (`~/.claude/projects/<slug>/<uuid>.jsonl` for Claude,
     `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` for Codex)
   - dedup on the same `messageId:requestId` tuple
   - apply the same LiteLLM pricing snapshot (filtered to `claude-*` + `gpt-*`
     via `tools/refresh-pricing.sh`)
   - match ccusage's local-calendar-day window math so the numbers line up

   The user's terminal `ccusage` output is the ground-truth our numbers are
   calibrated against. If you find a divergence, ccusage is right and we're
   the one with the bug — file an issue.

## What's here

```
apple/
├── README.md                          this file
├── project.yml                        xcodegen spec
├── Phase0/                            data-source validation (kept for regression — passes)
├── ClawdmeterShared/                  Swift Package, cross-platform
│   ├── Package.swift
│   ├── Sources/ClawdmeterShared/
│   │   ├── Analytics/                       ccusage in Swift (see below)
│   │   │   ├── TokenTotals.swift            sum/Codable rollup type with Decimal cost
│   │   │   ├── UsageRecord.swift            per-event normalized row
│   │   │   ├── RepoIdentity.swift           cwd → canonical-repo bucketing (walks up for .git)
│   │   │   ├── Pricing.swift                LiteLLM snapshot loader, Claude 200k tier handling
│   │   │   ├── ClaudeUsageParser.swift      `~/.claude/projects/*.jsonl` line parser
│   │   │   ├── CodexUsageParser.swift       `~/.codex/sessions/*.jsonl` file-level parser
│   │   │   ├── UsageHistoryLoader.swift     actor; parallel TaskGroup parse, file-mtime cache
│   │   │   ├── UsageHistorySnapshot.swift   per-window byRepo + byDay rollups
│   │   │   ├── UsageHistoryStore.swift      @MainActor ObservableObject; 60s timer refresh
│   │   │   ├── pricing.json                 embedded LiteLLM snapshot (145 models)
│   │   │   └── Views/                       Totals grid, daily Charts BarMark, by-repo list
│   │   ├── Model/UsageData.swift
│   │   ├── Predictor/BurnRatePredictor.swift
│   │   ├── Theme/Theme.swift
│   │   ├── Render/MeterRenderer.swift
│   │   └── Sources/
│   │       ├── AISource.swift                  protocol
│   │       ├── AnthropicSource.swift           rate-limit header parser
│   │       ├── CodexSource.swift               Codex live rate-limit reader
│   │       ├── KeychainTokenProvider.swift     Mac: reads Claude Code's OAuth token
│   │       ├── PastedAnthropicTokenProvider.swift  iOS/Watch: iCloud-Keychain-synced
│   │       ├── CodexTokenProvider.swift
│   │       ├── UsagePoller.swift
│   │       ├── UsageStore.swift                App Group cache for widgets
│   │       ├── UsageCloudMirror.swift          iCloud KV sync (Mac → iOS analytics)
│   │       ├── WatchTokenBridge.swift          WCSession iPhone → Watch (token + UsageData)
│   │       ├── AutoReviver.swift               "keep the 5h timer warm" ping
│   │       └── ESP32BLEDriver.swift            still talks to the original hardware
│   └── Tests/ClawdmeterSharedTests/            XCTest, 71 tests, all passing
├── ClawdmeterMac/                     macOS dashboard + menu bar app
│   ├── ClawdmeterMacApp.swift                @main, Window + Settings
│   ├── AppRuntime.swift                      owns AppModel × 2 (Claude + Codex) + analytics
│   ├── AppModel.swift                        per-provider poller
│   ├── DashboardView.swift                   side-by-side provider columns + analytics row
│   ├── AnalyticsView.swift                   totals grid + daily chart + by-repo
│   ├── PopoverView.swift                     menu-bar popover (per-provider)
│   ├── MenuBarGaugeView.swift                16pt menu-bar gauge
│   ├── AppDelegate.swift                     NSStatusItem + NSPopover wiring
│   └── Assets.xcassets/AppIcon.appiconset/   10 sizes (16 → 1024@2x)
├── ClawdmeteriOS/                     iPhone companion
│   ├── ClawdmeteriOSApp.swift
│   ├── ContentView.swift                     TabView: Live / Analytics
│   ├── iOSAnalyticsView.swift                iCloud-KV-mirrored analytics tab
│   ├── UsageModel.swift                      iOS-side poller + cloud-mirror subscriber
│   ├── SettingsView.swift                    paste OAuth token
│   └── Assets.xcassets/AppIcon.appiconset/
├── ClawdmeteriOSWidgets/              Lock Screen / Home Screen / StandBy widgets
├── ClawdmeterWatch/                   watchOS app
│   ├── ClawdmeterWatchApp.swift
│   ├── ContentView.swift                     wrist meter (session + weekly)
│   ├── WatchUsageModel.swift                 local keychain + WCSession ingress
│   └── Assets.xcassets/AppIcon.appiconset/
└── ClawdmeterWatchWidgets/            watchOS complications (4 families)
```

## Current state

- **`ClawdmeterShared`** — 71/71 XCTest tests passing; pricing snapshot covers
  145 Claude + GPT/Codex models; full analytics aggregator with calendar-day
  windows, top-8 by-repo rollups, per-day chart buckets.
- **Mac app** — menu bar + dashboard window. Dashboard shows Claude + Codex
  live gauges side-by-side and the analytics row below (totals grid, daily
  spend chart, by-repo list with per-section window picker). Token-bridge
  pushes data to the paired Apple Watch over WCSession.
- **iOS app** — TabView with Live (Claude live-polled, Codex via iCloud
  mirror) and Analytics (read-only mirror of Mac's analytics snapshot).
- **Watch app** — wrist meter receives token + usage from paired iPhone
  via `WatchTokenBridge` (`updateApplicationContext` + `transferUserInfo`
  fallback). Falls back to iCloud-Keychain shared access group if the bridge
  doesn't deliver.

## Build

```bash
cd apple
xcodegen                                           # regenerate project after .yml changes
xcodebuild -scheme "Clawdmeter (Mac)"   -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -scheme "Clawdmeter (iOS)"   -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme "Clawdmeter (Watch)" -configuration Debug -destination 'generic/platform=watchOS Simulator' build
( cd ClawdmeterShared && swift test )              # 71 tests, ~0.2s
```

To install on simulators paired with each other for WCSession testing:

```bash
xcrun simctl install <ios-sim-udid> ~/Library/Developer/Xcode/DerivedData/.../Debug-iphonesimulator/Clawdmeter.app
xcrun simctl install <watch-sim-udid> ~/Library/Developer/Xcode/DerivedData/.../Debug-watchsimulator/Clawdmeter.app
```

(On real devices the Watch app installs via the iPhone's Watch app, which
populates the companion bookkeeping that WCSession needs.)

## Analytics layer — how it relates to ccusage

The Swift analytics layer is intentionally a 1:1 port of ccusage's algorithm,
not a redesign. Reading both side-by-side should be a tractable exercise:

| ccusage (TypeScript)         | Clawdmeter Apple (Swift) |
| ---------------------------- | ------------------------ |
| Claude JSONL line parse      | `ClaudeUsageParser.parse(line:)` |
| Codex rollout cumulative-to-delta | `CodexUsageParser.parse(file:)` |
| LiteLLM model→price lookup   | `Pricing.cost(for:tokens:)` (tiered above 200k) |
| Cross-file dedup on `messageId:requestId` | `UsageHistoryLoader` global `Set<String>` |
| Daily bucketing              | `byDayByRepo` cache schema v8 |
| `daily` window               | `Window.today / past7d / past30d / allTime` (local calendar) |

What we added on top of ccusage's model (purely UI-level):
- Per-section window picker (the Token-usage totals + chart use one window,
  the By-repo list has its own — independent control).
- Repo bucketing walks up for `.git` so `~/conductor/workspaces/<repo>/<branch>`
  and `<repo>/.claude/worktrees/<branch>` collapse to the same repo as the
  user's primary checkout.
- Non-git cwds (UUIDs, home dirs, abandoned Paperclip workspace IDs) bucket
  into a single `Other` row instead of polluting the list.

If you spot a divergence between Clawdmeter's numbers and `ccusage` in your
terminal, **ccusage is the ground truth** — file an issue with the discrepancy
and we'll fix the Swift port.

## Refreshing pricing

LiteLLM pushes new model rates periodically. Re-snapshot via:

```bash
./tools/refresh-pricing.sh
```

The script `curl`s the upstream LiteLLM JSON, `jq`-filters to `claude-*` +
`gpt-*` + `o[0-9]+*` keys, and writes
`ClawdmeterShared/Sources/ClawdmeterShared/Analytics/pricing.json`. Commit
the result alongside whatever PR adds new model support.

## Plan mapping

Implementation decisions are tracked in `~/.claude/plans/clone-this-https-github-com-darshanbathi-delegated-storm.md`
under decisions A1–A20 (analytics V1) and E1–E15 (parent Apple plan).
References like "Plan A14" in code comments map to that file.
