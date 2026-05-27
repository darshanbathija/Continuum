# Clawdmeter

Clawdmeter is a native desktop and mobile control surface for coding agents. It
started as a Claude usage meter, but the current repo is broader: a Mac menu-bar
meter, a Tahoe-style Mac workbench, iPhone and Apple Watch companions, a Linux
desktop port, shared usage analytics, and adapters for Claude Code, Codex,
Antigravity/Gemini, and OpenCode.

At a high level, Clawdmeter does three jobs:

- Shows live quota and spend for coding-agent providers.
- Runs and controls local coding-agent sessions from Mac, iPhone, Watch, and Linux.
- Keeps chat, code, usage, device pairing, diagnostics, and provider setup in one app.

Current source version: `0.29.3` (`apple/project.yml` build `142`).

## What ships

| Surface | Current role |
| --- | --- |
| **Mac app** | Primary app. Menu-bar gauge plus a full Tahoe-style window with Chat, Usage, Code, and Settings tabs. Owns the local daemon, provider runtimes, tmux sessions, OpenCode server, usage aggregation, pairing, and diagnostics. (Design tab + Open Design integration stripped in v0.27.0 — slated to be redesigned and rebuilt.) |
| **iPhone app** | Paired control plane for the Mac. Shows live provider status, analytics, chat/code sessions, new-session creation, plan approvals, diffs, terminal views, and Live Activities. |
| **Apple Watch app** | Wrist view for live usage and sessions that need attention, including plan approval and interruption flows through the paired iPhone. |
| **Widgets / complications** | iOS widgets, watchOS complications, and a Mac widget extension backed by the shared app-group cache. |
| **Linux app** | Native Swift Linux desktop and daemon work under `linux/`, targeting Ubuntu/Zorin GNOME environments with AppIndicator, GTK4/libadwaita, WebKitGTK, VTE, libsecret, and the same shared analytics package. |
| **Shared package** | `apple/ClawdmeterShared` contains wire DTOs, analytics parsers, pricing, provider models, session protocol types, Tahoe UI primitives, and cross-platform tests. |
| **Tools** | Build scripts, bundled runtime fetchers, Codex SDK shim, Antigravity Python sidecar skeleton, and tmux control-mode probes live under `tools/`. (Open Design bridge + plugin removed in v0.27.0.) |

## Provider support

| Provider | How Clawdmeter integrates it |
| --- | --- |
| **Claude Code** | Spawns the `claude` CLI in tmux, parses Claude JSONL usage, reads local auth state where allowed, supports plan mode, accept-edits, bypass mode with repo trust, session resume, slash-command skill discovery, and live chat/code transcript ingestion. |
| **Codex** | Supports CLI-backed sessions and a Codex SDK chat path. Usage parsing reads Codex session JSONL, including cumulative-to-delta conversion. Plan mode maps to read-only sandboxing, and send/interrupt/model/effort flows go through the same daemon surface as other agents. |
| **Antigravity / Gemini** | Gemini quota and Antigravity 2 native sessions are represented through the shared `.gemini` agent kind in current wire contracts. The newer path talks to Antigravity's `agentapi` / language-server runtime, reads conversation DB and brain-dir state, and exposes plan snapshots. |
| **Cursor** | Discovers account models from Cursor, launches Cursor-backed sessions, and treats effort as Cursor Auto until Cursor exposes a real effort control. |
| **OpenRouter via OpenCode** | Runs OpenRouter models through Clawdmeter's shared `opencode serve` process, consumes SSE events, sends prompts through OpenCode's HTTP API, maps OpenRouter usage into Clawdmeter analytics, and surfaces live model metadata under Settings -> Providers. |

## App model

The Mac app is the source of truth. It hosts an in-process `Network.framework`
HTTP and WebSocket daemon:

- HTTP listener starts at `21731`, with fallback ports through `21741`.
- WebSocket listener normally starts at `21732`.
- Non-loopback access is restricted to Tailscale/loopback peer ranges and bearer-token pairing.
- The same daemon backs Mac loopback clients, iPhone pairing, Watch relays, terminal streams, chat snapshots, usage, analytics, diffs, and PR actions.

The main Mac tabs are:

- **Chat** - solo or broadcast chat over Claude, Codex, Antigravity, Cursor, and OpenRouter, with Frontier-style multi-provider comparison endpoints in the daemon.
- **Usage** - live quota cards plus historical spend by provider, day, and repo. OpenCode appears as a dollar-cost lane because it does not expose Anthropic-style rolling quota headers.
- **Code** - repo/session workbench with city-named worktrees, terminal panes, chat transcript, plan/diff/PR/artifact/source panes, archive/reopen flows, and provider filters.
- **Settings** - visual theme, provider setup, per-provider model/effort defaults, Codex SDK diagnostics, Antigravity SDK diagnostics, pairing, Live Activities, auto-revive, and diagnostics.

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

Three reference documents describe what Clawdmeter trusts, what it
sends over the network, and what isn't built yet:

- [`docs/security.md`](docs/security.md) — trust model, cryptographic
  primitives, key lifecycle, per-peer bearer auth, APNS device-token
  egress controls, F3 HOME isolation, audit log scope, kill-switch +
  rate limit, and a pointer to the 14-scenario threat model.
- [`docs/privacy.md`](docs/privacy.md) — every data egress path: the
  relay, the APNS gateway, pricing snapshot fetch, provider CLI
  telemetry, and the update check. Also covers what stays local,
  backup posture, and the GDPR / CCPA deletion story.
- [`docs/known-limitations.md`](docs/known-limitations.md) — what's
  NOT yet shipped: the Mac/iOS clients for the secure cloud relay
  and APNS gateway, the Swift CryptoKit XChaCha20 gap, F3 daemon
  wire-up, the C2 `@Observable` migration, watchOS / iOS launch
  Tahoe-debt, and Mac Code-tab density follow-ups.

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
- `tmux` for live agent sessions.
- Provider CLIs as needed: `claude`, `codex`, `gemini` / Antigravity, and/or `opencode`.

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

## Building Linux

The Linux package lives under `linux/` and shares
`apple/ClawdmeterShared`. It is a Swift package with two executables:
`clawdmeterd` and `clawdmeter`.

Development build:

```bash
sudo apt install -y \
  libgtk-4-dev libadwaita-1-dev \
  libayatana-appindicator3-dev libsecret-1-dev \
  libcairo2-dev libpango1.0-dev \
  libwebkitgtk-6.0-dev libvte-2.91-gtk4-dev \
  pkg-config

cd linux
./scripts/configure-c-shims.sh
swift build
swift test
```

Distribution packages from the repo root:

```bash
./tools/build-linux-appimage.sh
./tools/build-linux-deb.sh
```

Install/user docs:

- `docs/linux/INSTALL.md`
- `docs/linux/PAIRING.md`
- `docs/linux/TROUBLESHOOTING.md`
- `docs/linux/QA-CHECKLIST.md`

## Other test targets

```bash
( cd tools/tmux-cc-probe && swift test )
( cd tools/clawdmeter-codex-sdk && npm test )
( cd tools/clawdmeter-agents && python3 -m pytest )
```

The repo has substantial XCTest coverage under:

- `apple/ClawdmeterShared/Tests/ClawdmeterSharedTests`
- `apple/ClawdmeterMacTests`
- `linux/Tests/ClawdmeterLinuxTests`
- `tools/tmux-cc-probe/Tests`

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
|-- linux/
|   |-- Package.swift                       Linux app and daemon package
|   |-- Sources/                            Swift Linux app, daemon, C shims
|   |-- Tests/                              Linux tests
|   |-- scripts/                            C-shim configuration
|   `-- resources/                          desktop files, service, metadata
|-- docs/
|   |-- designs/                            Sessions/control-plane docs
|   |-- linux/                              Linux install/pairing/QA docs
|   |-- agentapi-*.md                       Antigravity runtime research
|   |-- opencode-research-2026-05-22.md     OpenCode integration research
|   `-- button-wiring-audit.md              UI/backend wiring audit
|-- tools/
|   |-- build-*.sh                          DMG, AppImage, and .deb packaging
|   |-- download-bundled-*.sh               vendored runtime staging
|   |-- build-bundled-open-design.sh        Open Design bundle builder
|   |-- clawdmeter-bridge-host/             Open Design bridge sidecar
|   |-- clawdmeter-open-design-plugin/      Open Design bridge plugin
|   |-- clawdmeter-codex-sdk/               Node Codex SDK bridge
|   |-- clawdmeter-agents/                  Python Antigravity sidecar skeleton
|   `-- tmux-cc-probe/                      tmux control-mode test package
|-- CHANGELOG.md                            detailed release history
|-- VERSION                                 marketing version mirror
`-- CLAUDE.md                               maintainer-oriented implementation notes
```

## Runtime notes

- `tmux` is the main transport for CLI-backed code sessions.
- Chat sessions and code sessions share the same `AgentSessionRegistry` and daemon.
- OpenCode sessions do not use tmux; they go through `opencode serve` plus SSE.
- Antigravity 2 native sessions are HTTP-RPC against a language server, not a long-lived CLI stream.
- iPhone pairing is QR/token based and expects loopback or Tailscale-reachable hosts. Tailscale MagicDNS is the easiest path for iOS App Transport Security.
- Release Mac builds are sandboxed; Debug builds keep broader local access for development.
- App Store/iCloud/CloudKit/notarization paths still depend on Apple account capabilities outside this repo.

## In-app updates

Since v0.24.0 the Mac app checks `https://api.github.com/repos/darshanbathija/Clawdmeter/releases/latest` once 8 seconds after launch and every 24 hours while running. When a newer release ships, a small terra-cotta "Update X.Y.Z" chip appears in the titlebar; click it to read the release notes inline and open the release page in Safari, where you download the new DMG and drag it to `/Applications` the same way you did the first time. Click "Later" to hide the chip for 24 hours per version.

There is no silent in-place install — that would require Sparkle 2.x + paid Developer ID + notarization, and is parked as a phase-2 migration in `TODOS.md`.

Privacy: each daily check sends your IP and a `Clawdmeter/<version>` User-Agent to `api.github.com`. No unique identifier and no app body are transmitted. Equivalent to visiting the GitHub releases page in Safari once a day.

Maintainer notes:

- The repo URL is centralized in `apple/ClawdmeterMac/Updates/GitHubReleaseConstants.swift`. If the GitHub owner/repo ever changes, update the `owner`/`repo` constants there — three URL helpers (browser, API, tag) derive from them automatically. The `tools/build-mac-dmg.sh` script doesn't reference the URL today, but if a future release script does, it has to be updated in lockstep.
- QA can override the API URL via `defaults write com.clawdmeter.mac ClawdmeterDebugReleasesURL "https://…"` and revert with `defaults delete`.

## Credits

- Original Clawdmeter ESP32 firmware: gauge concept, color language, `UsageData`
  shape, and Anthropic rate-limit polling model.
- `ccusage` by ryoppippi: reference behavior for Claude/Codex usage parsing,
  deduplication, daily bucketing, and pricing expectations.
- LiteLLM: pricing data snapshot used by the shared analytics package.
- SwiftTerm: terminal rendering in Mac and iOS session surfaces.
- Open Design, OpenCode, Claude Code, Codex, and Antigravity/Gemini are external
  tools/runtimes that Clawdmeter integrates with rather than replacing.
