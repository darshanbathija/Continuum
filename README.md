# Continuum

Continuum is a native desktop and mobile control surface for coding agents. It
started as a Claude usage meter, but the current repo is broader: a Mac menu-bar
meter, a Tahoe-style Mac workbench, iPhone and Apple Watch companions, shared
usage analytics, and adapters for Claude Code, Codex, Antigravity/Gemini, and
OpenCode.

At a high level, Continuum does three jobs:

- Shows live quota and spend for coding-agent providers.
- Runs and controls local coding-agent sessions from Mac, iPhone, and Watch.
- Keeps chat, code, usage, device pairing, diagnostics, and provider setup in one app.

Current source version: `0.31.9` (`apple/project.yml` build `209`).

## What ships

| Surface | Current role |
| --- | --- |
| **Mac app** | Primary app. Menu-bar gauge plus a full Tahoe-style window with Chat, Usage, Code, and Settings tabs. Owns the local daemon, provider runtimes, direct PTY terminals, OpenCode server, usage aggregation, pairing, and diagnostics. (Design tab + Open Design integration stripped in v0.27.0 — slated to be redesigned and rebuilt.) |
| **iPhone app** | Paired control plane for the Mac. Shows live provider status, analytics, chat/code sessions, new-session creation, plan approvals, diffs, terminal views, and Live Activities. |
| **Apple Watch app** | Wrist view for live usage and sessions that need attention, including plan approval and interruption flows through the paired iPhone. |
| **Widgets / complications** | iOS widgets, watchOS complications, and a Mac widget extension backed by the shared app-group cache. |
| **Shared package** | `apple/ClawdmeterShared` contains wire DTOs, analytics parsers, pricing, provider models, session protocol types, Tahoe UI primitives, and Apple-platform tests. |
| **Tools** | Build scripts, bundled runtime fetchers, Codex SDK shim, and Antigravity Python sidecar skeleton live under `tools/`. (Open Design bridge + plugin removed in v0.27.0.) |

## Provider support

| Provider | How Continuum integrates it |
| --- | --- |
| **Claude Code** | Spawns the `claude` CLI in a per-session direct PTY, parses Claude JSONL usage, reads local auth state where allowed, supports plan mode, accept-edits, bypass mode with repo trust, session resume, slash-command skill discovery, and live chat/code transcript ingestion. |
| **Codex** | Uses the Codex app-server harness for chat and code sessions. Usage parsing reads Codex session JSONL, including cumulative-to-delta conversion. Plan mode maps to read-only sandboxing, and send/interrupt/model/effort flows go through the same daemon surface as other agents. |
| **Antigravity / Gemini** | Gemini quota and Antigravity native sessions are represented through the shared `.gemini` agent kind in current wire contracts. Sessions run through the headless `agy` harness, read conversation DB and brain-dir state, and expose plan snapshots. |
| **Cursor** | Discovers account models from Cursor, launches Cursor-backed ACP harness sessions, and treats effort as Cursor Auto until Cursor exposes a real effort control. |
| **Grok** | Runs through a headless harness, surfaces Grok usage limits and token history, and participates in Chat, Code, Usage, and provider-picker flows. |
| **OpenRouter via OpenCode** | Runs OpenRouter models through Continuum's shared `opencode serve` process, consumes SSE events, sends prompts through OpenCode's HTTP API, maps OpenRouter usage into Continuum analytics, and surfaces live model metadata under Settings -> Providers. |

## App model

The Mac app is the source of truth. It hosts an in-process `Network.framework`
HTTP and WebSocket daemon:

- HTTP listener starts at `21731`, with fallback ports through `21741`.
- WebSocket listener normally starts at `21732`.
- Non-loopback access is restricted to the secure relay path, Tailscale/loopback peer ranges, and bearer-token pairing.
- The same daemon backs Mac loopback clients, iPhone pairing, Watch relays, terminal streams, chat snapshots, usage, analytics, diffs, and PR actions.

The main Mac tabs are:

- **Chat** - solo or broadcast chat over Claude, Codex, Antigravity, Cursor, and OpenRouter, with Frontier-style multi-provider comparison endpoints in the daemon.
- **Usage** - live quota cards plus historical spend by provider, day, and repo. OpenCode appears as a dollar-cost lane because it does not expose Anthropic-style rolling quota headers.
- **Code** - repo/session workbench with city-named worktrees, terminal panes, chat transcript, Browser Preview with comment chips, plan/diff/PR/artifact/source panes, archive/reopen flows, and provider filters.
- **Settings** - visual theme, provider setup, per-provider model/effort defaults, provider diagnostics, pairing, Live Activities, auto-revive, and diagnostics.

## Analytics

The analytics layer is a Swift implementation of the same ideas behind
`ccusage`: parse local agent logs, normalize token events, deduplicate, price
with a LiteLLM snapshot, then roll up by provider, day, time window, and repo.

Important files:

- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/ClaudeUsageParser.swift`
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/CodexUsageParser.swift`
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/AntigravityUsageParser.swift`
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/OpencodeUsageParser.swift`
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryLoader.swift`
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/Pricing.swift`
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/pricing.json`

Repo identity intentionally normalizes real git repositories so Conductor
worktrees, `.claude/worktrees`, and a primary checkout collapse into the same
row. Non-repo directories are grouped into an `Other` bucket.

Refresh pricing with:

```bash
./tools/refresh-pricing.sh
```

## Security and privacy

Three reference documents describe what Continuum trusts, what it
sends over the network, and what remains deferred:

- [`docs/security.md`](docs/security.md) — trust model, cryptographic
  primitives, key lifecycle, per-peer bearer auth, APNS device-token
  egress controls, F3 HOME isolation, audit log scope, kill-switch +
  rate limit, and a pointer to the 14-scenario threat model.
- [`docs/privacy.md`](docs/privacy.md) — every data egress path: the
  relay, the APNS gateway, pricing snapshot fetch, provider CLI
  telemetry, and the update check. Also covers what stays local,
  backup posture, and the GDPR / CCPA deletion story.
- [`docs/known-limitations.md`](docs/known-limitations.md) — what's
  still deferred: F3 daemon wire-up, per-provider HOME isolation,
  C2 `@Observable` migration, watchOS / iOS launch Tahoe-debt,
  Sparkle follow-ups, and Mac Code-tab density follow-ups.

The full normative design for the secure relay + APNS gateway lives
at [`docs/design/secure-relay-apns-2026-05-26.md`](docs/design/secure-relay-apns-2026-05-26.md).

## Building Apple targets

Apple project source of truth is `apple/project.yml`; regenerate the Xcode
project with `xcodegen` after changing targets, settings, resources, or
schemes.

Requirements:

- Apple Silicon Mac for the packaged DMG path.
- Xcode with Swift 5.10 support and the current Apple platform SDKs used by the project.
- `xcodegen` for regenerating `apple/Clawdmeter.xcodeproj`.
- Provider CLIs as needed: `claude`, `codex`, `cursor-agent`, `grok`, `gemini` / Antigravity, and/or `opencode`.

Useful build commands:

```bash
brew install xcodegen

cd apple
xcodegen

( cd ClawdmeterShared && swift test )

xcodebuild -scheme "Clawdmeter (Mac)" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -scheme "Clawdmeter (Mac)" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild -scheme "Clawdmeter (iOS)" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -scheme "Clawdmeter (Watch)" \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Package a Mac DMG from the repo root:

```bash
./tools/build-mac-dmg.sh
```

The DMG script regenerates the project when `xcodegen` is available, archives
the Mac scheme, builds a compressed DMG, verifies the mounted app, and enforces
a soft/hard size budget.

Optional bundled runtime staging:

```bash
./tools/download-bundled-node.sh
./tools/download-bundled-uv.sh
./tools/download-bundled-opencode.sh
```

For faster local iteration, the Xcode prebuild steps can be skipped where
supported with:

```bash
CLAWDMETER_SKIP_BUNDLED_NODE=1
CLAWDMETER_SKIP_BUNDLED_UV=1
CLAWDMETER_SKIP_BUNDLED_OPENCODE=1
```

Skipping those makes the corresponding bundled feature depend on a system
install or become inert in that local build.

## Other test targets

```bash
( cd tools/clawdmeter-codex-sdk && npm test )
( cd tools/clawdmeter-agents && python3 -m pytest )
```

The repo has substantial XCTest coverage under:

- `apple/ClawdmeterShared/Tests/ClawdmeterSharedTests`
- `apple/ClawdmeterMacTests`

## Repo layout

```text
.
|-- apple/
|   |-- project.yml                         xcodegen source of truth
|   |-- Clawdmeter.xcodeproj/               generated Xcode project
|   |-- ClawdmeterShared/                   shared Swift package
|   |-- ClawdmeterMac/                      Mac app, daemon, Tahoe UI, providers
|   |-- ClawdmeterMacTests/                 Mac-hosted XCTest target
|   |-- ClawdmeteriOS/                      iPhone companion app
|   |-- ClawdmeteriOSWidgets/               iOS widgets
|   |-- ClawdmeterWatch/                    watchOS app
|   |-- ClawdmeterWatchWidgets/             watch complications
|   `-- ClawdmeterMacWidgets/               macOS widget extension
|-- docs/
|   |-- designs/                            Sessions/control-plane docs
|   |-- agentapi-*.md                       Antigravity runtime research
|   |-- opencode-research-2026-05-22.md     OpenCode integration research
|   `-- button-wiring-audit.md              UI/backend wiring audit
|-- tools/
|   |-- build-mac-dmg.sh                    Mac DMG packaging
|   |-- download-bundled-*.sh               vendored runtime staging
|   |-- clawdmeter-codex-sdk/               Node Codex SDK bridge
|   |-- clawdmeter-agents/                  Python Antigravity sidecar skeleton
|   |-- release-mac.sh                      signed/notarized Sparkle release path
|   `-- extract-antigravity-proto.sh        Antigravity protocol inventory helper
|-- CHANGELOG.md                            detailed release history
|-- VERSION                                 marketing version mirror
`-- CLAUDE.md                               maintainer-oriented implementation notes
```

## Runtime notes

- Claude sessions and terminal panes run through direct PTY hosts managed by the daemon.
- Codex, Cursor, Gemini, and Grok sessions run through their harness providers; missing live harnesses surface stale-session errors instead of falling back to a terminal.
- Chat sessions and code sessions share the same `AgentSessionRegistry` and daemon.
- OpenCode sessions go through `opencode serve` plus SSE.
- Legacy `tmuxWindowId` / `tmuxPaneId` fields still decode for old registries; sessions carrying them are retired and return `410 legacy_session_retired`.
- iPhone pairing is QR/token based and can use the secure relay path; loopback/Tailscale remains available for local development and fallback.
- Release Mac builds are sandboxed; Debug builds keep broader local access for development.
- App Store/iCloud/CloudKit/notarization paths still depend on Apple account capabilities outside this repo.

## In-app updates

The Mac app now uses Sparkle 2.9.2 as the primary updater. `Update App`
is available from the titlebar, the Code action cluster, Settings, and
the app menu. Sparkle reads the GitHub Pages appcast at
`https://darshanbathija.github.io/Continuum/updates/appcast.xml` and
installs signed, notarized DMGs in place.

GitHub Releases is still the recovery link and public artifact host. If
Sparkle setup, signature validation, translocation, or installation
fails, the UI opens the GitHub release page as the fallback.

Maintainer notes:

- Release configuration is shared between
  `apple/ClawdmeterMac/Updates/GitHubReleaseConstants.swift`,
  `tools/release-config.sh`, and `tools/release-mac.sh`.
- Public Mac releases must go through `tools/release-mac.sh`; it gates
  Developer ID signing, notarization, Sparkle signatures, minimum OS
  alignment, appcast output, and GitHub asset ordering.
- The first Sparkle-capable release is a manual bootstrap install. The
  acceptance path must still prove installed-app update behavior from
  version N to N+1 and migration from `/Applications/Clawdmeter.app` to
  `/Applications/Continuum.app`.

## Credits

- Original usage-meter ESP32 firmware: gauge concept, color language, `UsageData`
  shape, and Anthropic rate-limit polling model.
- `ccusage` by ryoppippi: reference behavior for Claude/Codex usage parsing,
  deduplication, daily bucketing, and pricing expectations.
- LiteLLM: pricing data snapshot used by the shared analytics package.
- SwiftTerm: terminal rendering in Mac and iOS session surfaces.
- Open Design, OpenCode, Claude Code, Codex, and Antigravity/Gemini are external
  tools/runtimes that Continuum integrates with rather than replacing.
