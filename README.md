# Clawdmeter for Apple

Live Claude Code + Codex CLI rate-limit gauges on every Apple surface you look at — Mac menu bar, iPhone Home Screen, Apple Watch face — plus a dashboard with historical `$/token` analytics (Today / Past 7d / Past 30d / All time, per repo, daily spend chart).

The Mac app reads Claude Code's OAuth token from your local Keychain, polls Anthropic's rate-limit headers every 60s, mirrors the snapshot to the paired iPhone over iCloud, and pushes to the paired Apple Watch over WatchConnectivity.

> **Built on the shoulders of two upstream projects:**
> - **[Clawdmeter (the original)](https://github.com/darshanbathija/Clawdmeter)** by [@darshanbathija](https://github.com/darshanbathija) — the ESP32 desk-side dashboard that started it all. Every gauge concept, color token (`#d97757` on `#000`), the `UsageData` JSON shape, the Anthropic rate-limit-header polling pattern, and the "send 1 token to keep the 5h timer warm" auto-revive idea were all prototyped there first. This repo is the native Apple port of that hardware project.
> - **[ccusage](https://github.com/ryoppippi/ccusage)** by [@ryoppippi](https://github.com/ryoppippi) — the entire `$/token` analytics layer (`ClawdmeterShared/Sources/ClawdmeterShared/Analytics/`) is a Swift re-implementation of ccusage's TypeScript aggregation. We parse the same on-disk JSONL files ccusage parses, dedup the same way, and apply the same LiteLLM pricing snapshot. `ccusage daily` in your terminal is the ground-truth our numbers match.

## Download for Linux (Ubuntu 22.04+ / ZorinOS 16+)

**[➜ Download from Releases](https://github.com/darshanbathija/Clawdmeter/releases/latest)** — either `.AppImage` (works on any distro, ~200MB; bundles GTK4 + WebKitGTK 6.0 deps) or `.deb` (Ubuntu 24.04+ / ZorinOS 17+, ~30MB; uses system GTK4).

```bash
# AppImage — works on Ubuntu 22.04, 24.04, Zorin 16, Zorin 17, Debian 12+
chmod +x Clawdmeter-*-x86_64.AppImage
./Clawdmeter-*-x86_64.AppImage

# .deb — Ubuntu 24.04+ / ZorinOS 17+ only
sudo apt install ./clawdmeter_*_amd64.deb
clawdmeter
```

The menu-bar gauge needs the GNOME AppIndicator extension on stock Ubuntu (ZorinOS preinstalls it). Clawdmeter detects the missing extension at first launch and offers to install it via `extensions.gnome.org`, or you can run `sudo apt install gnome-shell-extension-appindicator`. See [docs/linux/INSTALL.md](docs/linux/INSTALL.md), [PAIRING.md](docs/linux/PAIRING.md), [TROUBLESHOOTING.md](docs/linux/TROUBLESHOOTING.md).

## Download for Mac (Apple Silicon)

**[➜ Download the latest Clawdmeter.dmg from Releases](https://github.com/darshanbathija/Clawdmeter/releases/latest)**

1. Open the DMG.
2. Drag **Clawdmeter.app** into the **Applications** folder.
3. First launch: **right-click → Open** in Applications, then **Open** in the Gatekeeper dialog.

macOS asks once because the build is signed with a personal Apple Developer team (notarization needs a paid `$99/yr` Apple Developer Program account). After the first Open, Gatekeeper trusts the app forever.

The Clawdmeter icon appears in the menu bar. Click it to view your Claude / Codex usage; "Open dashboard" opens the full window with the analytics row.

## What's in the box

| Surface | What it does |
|---|---|
| **Mac menu bar** | Live session % + reset countdown for Claude and Codex side-by-side. Click → popover with the same data + an "Open dashboard" link. |
| **Mac dashboard window** | Side-by-side Claude + Codex live cards (session %, weekly %, auto-revive controls) plus the **Token usage** row: totals grid (4 windows × 2 providers, dollars primary), stacked daily-spend chart, by-repo breakdown with its own window picker. A **Sessions** tab is a first-class chat workbench for live Claude Code + Codex CLI sessions — slash-command palette, `@`-mention picker, attachments (drag-drop / file-picker / paste image), running-session cost ticker, autopilot trust gate, and a `Cmd+T` overlay for raw tmux when you need it (see below). A "Sync with iPhone" button in the header opens a pairing QR + Copy URL popover. |
| **iPhone app** | TabView: **Live** (Claude live-polled, Codex mirrored from Mac), **Analytics** (totals + by-repo, synced from the Mac over Tailscale once paired), and **Sessions** (start / monitor / approve plans / view diffs / merge PRs on Mac sessions from your phone). |
| **Apple Watch app** | Wrist meter showing session + weekly usage, plus a session list + Approve / Interrupt / Voice-reply controls for the paired Mac's live agents. |
| **Widgets** | Lock Screen + Home Screen widgets on iOS, complications on watchOS (four families), and a Mac menu bar widget that ships with the Mac app. |

## Sessions: a Mac chat IDE for Claude Code + Codex, paired to your phone

The Sessions tab on Mac is a first-class chat workbench for the CLIs themselves. The matching iPhone tab is the mobile control plane against the same daemon.

- **Mac chat IDE (v0.3.0).** The Sessions tab is a chat workspace, not a session manager. Send turns from a powerful composer: slash-command palette (`/` lists every installed Claude Code skill walked from `~/.claude/skills/` and the project's `.claude/skills/`), `@`-mention picker (open sessions, agent-cited files, recent JSONLs), attachments (drag-drop from Finder, file picker, paste image as PNG, `QLThumbnailGenerator` previews, 50MB cap), voice dictation (Ctrl+M), and a running-session cost ticker fed by `Pricing.shared`. The send button transforms into a stop button while the session runs. Raw tmux is one keystroke away via the `Cmd+T` overlay.
- **Continue here.** Right-click a recent JSONL row in the sidebar to spawn a fresh tmux pane with `--resume <cli-id>` (Claude) or `resume <cli-id>` (Codex) — the new pane reads the CLI's own session id out of the JSONL header so the chat history stays continuous.
- **Autopilot chip with per-repo trust.** A chip in the composer row toggles `--dangerously-skip-permissions` (Claude) or `--dangerously-bypass-approvals-and-sandbox` (Codex). Untrusted repos hit a confirm sheet that flips the chip CTA to "Trust repo + enable autopilot" and the daemon enforces the trust list at the wire — a bearer-token-holding peer can't bypass it.
- **Cross-Apple compose-draft handoff.** New iPhone "Open on Mac" button on the new-session sheet posts a `compose-draft` envelope over the existing pairing WebSocket; the Mac dashboard pre-fills the centered empty-state composer (text + suggested repo / agent / model / effort). Wire version bumped 3 → 4; iOS shows "Update Clawdmeter on the Mac" if the paired Mac is on the older protocol.
- **Pairing host resolution rewritten.** `TailscaleHost.resolve()` reads the Tailscale interface address directly via `getifaddrs(3)` and falls back to `tailscale status --json` across three known install paths. Old code only checked `/opt/homebrew/bin/tailscale` and silently fell back to `127.0.0.1` — iPhones couldn't reach the Mac. The pairing popover and Settings → Sessions pane now show the resolved host kind and warn explicitly when the host is loopback or the Tailscale backend is down.
- **Plan mode works for both agents.** Claude maps to `--permission-mode plan`, Codex maps to `--sandbox read-only`. Approve & run flips the permission / sandbox afterwards.
- **Pairing is QR + Tailscale.** Tap "Sync with iPhone" on the Mac, scan or paste the URL on the phone. No iCloud, no APNS, no `.p8` key custody.
- **The Mac daemon** (`Network.framework` HTTP + WS on ports 21731 / 21732, bound to loopback + Tailscale CGNAT) exposes the full control surface to the iPhone and Watch.

See `docs/designs/sessions-v2.md` for the v2.0 control-plane ship, `CHANGELOG.md` for the v0.3.0 chat-IDE rewrite, and `TODOS.md` for deferred work.

## Building from source

Requires macOS 14+ and Xcode CLT. Everything else (`xcodebuild`, `hdiutil`, `codesign`) is built into the OS.

```bash
brew install xcodegen            # one-time
git clone https://github.com/darshanbathija/Clawdmeter
cd Clawdmeter/apple
xcodegen                         # regenerate Clawdmeter.xcodeproj from project.yml
( cd ClawdmeterShared && swift test )   # 250 tests, ~0.4s
xcodebuild -scheme "Clawdmeter (Mac)"   -destination 'platform=macOS,arch=arm64' build
xcodebuild -scheme "Clawdmeter (iOS)"   -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme "Clawdmeter (Watch)" -destination 'generic/platform=watchOS Simulator' build
```

To produce a downloadable DMG for distribution:

```bash
./tools/build-mac-dmg.sh
# → dist/Clawdmeter-<version>-arm64.dmg
```

The script is idempotent — rerun any time. See `apple/README.md` for the per-target layout and the analytics architecture.

## Refreshing LiteLLM pricing

The Mac app ships an embedded LiteLLM pricing snapshot (`apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/pricing.json`). When new Anthropic or OpenAI models ship, refresh it:

```bash
./tools/refresh-pricing.sh
```

`curl`s the upstream LiteLLM JSON, `jq`-filters to `claude-*` + `gpt-*` + `o[0-9]+*` keys, commits the snapshot.

## How the analytics line up with ccusage

The Swift analytics layer is intentionally a 1:1 port of ccusage's algorithm — not a redesign.

| ccusage (TypeScript) | Clawdmeter (Swift) |
| --- | --- |
| Claude JSONL line parse | `ClaudeUsageParser.parse(line:)` |
| Codex cumulative → per-event deltas | `CodexUsageParser.parse(file:)` |
| LiteLLM model → price lookup | `Pricing.cost(for:tokens:)` (tiered above 200k) |
| Cross-file dedup on `messageId:requestId` | `UsageHistoryLoader` global `Set<String>` |
| Daily bucketing | `byDayByRepo` cache schema v8 |
| `daily` window default | Local-calendar `Today / Past 7d / Past 30d / All time` |

What we added on top (pure UI):
- **Per-repo bucketing** that walks up for `.git` so Conductor worktrees, `.claude/worktrees/<branch>` directories, and the user's main checkout of the same repo all collapse to one row.
- **Non-git cwds** (UUIDs, home dirs, abandoned workspace IDs) collapse into a single **Other** row instead of polluting the list.
- **Independent window pickers** for the totals/chart vs the by-repo list.

If you spot a divergence between Clawdmeter's numbers and `ccusage` in your terminal, **ccusage is right** — file an issue and we'll fix the Swift port.

## Credits

- **[ccusage](https://github.com/ryoppippi/ccusage)** by [@ryoppippi](https://github.com/ryoppippi) — entire analytics aggregator, dedup logic, and LiteLLM pricing model are a Swift re-implementation of ccusage's TypeScript work.
- **[Clawdmeter ESP32 firmware](https://github.com/darshanbathija/Clawdmeter/tree/clawdmeter)** — gauge concept, color tokens, `UsageData` JSON shape, rate-limit-header polling math, auto-revive idea, BLE GATT shape. The Apple port carries the same design language and the same UsageData struct.
- **Anthropic** rate-limit headers (`anthropic-ratelimit-unified-5h-*`, `-7d-*`) — the only data source for live gauges; documented at https://docs.anthropic.com.
- **[LiteLLM](https://github.com/BerriAI/litellm)** — pricing data; we ship a filtered snapshot of `model_prices_and_context_window.json`.

## Licensing

This repo uses the Anthropic brand fonts (Tiempos Text, Styrene B) and color tokens that Anthropic owns. The Swift code itself is non-proprietary, but the bundled fonts and brand colors are not. If you fork, you'll need to either swap the typography to a license-clean alternative or get permission from Anthropic. The original ESP32 Clawdmeter README has the long version of this warning.
