# Changelog

All notable changes to Continuum are recorded here. Marketing version
is `MARKETING_VERSION` in `apple/project.yml`; build number is
`CURRENT_PROJECT_VERSION` in the same file (source of truth for the DMG).

## [0.31.6 build 206] - 2026-06-06 - Remove tmux runtime (`darshanbathija/remove-tmux`)

### Removed

- Removes tmux runtime code, control-mode parsing, bundled tmux provisioning, the tmux control-mode probe tool, and tmux-specific tests from active Mac/shared build paths.
- Retires old tmux pane-backed sessions instead of reconnecting them, while preserving legacy `tmuxWindowId` and `tmuxPaneId` decoding compatibility.

### Changed

- Claude Code and chat sessions now always use the direct Claude PTY registry for sends, interrupts, deletes, approval, revive, scheduler, and config-swap flows.
- Codex, Cursor, Gemini, and Grok stay on ACP/app-server/headless harnesses; missing live harnesses now surface stale-session responses instead of tmux fallbacks.
- Terminal, vendor provisioning, and OpenCode setup surfaces now use direct PTY hosts while keeping the existing terminal WebSocket frame shape.
- Bumps `VERSION` 0.31.5 -> 0.31.6, `MARKETING_VERSION` 0.31.5 -> 0.31.6, and `CURRENT_PROJECT_VERSION` 205 -> 206.

## [0.31.5 build 205] - 2026-06-06 - Strip external session noise from Code (`darshanbathija/session-noise`)

### Removed

- Code sidebar session discovery no longer scans Claude/Codex external CLI roots or configured scan roots for recent JSONLs.
- Removes visible outside-session surfaces from the Mac Code tab, including Active outside sections, collapsed History rows, Discover parallel sessions copy, read-only outside JSONL opening, Continue here, and external JSONL rename affordances.
- Removes external recent JSONL mention suggestions from the composer while keeping open Continuum sessions and cited files.
- Removes iOS continuation entry points that were only reachable through repo recent sessions.

### Changed

- Repo snapshots are now produced from `WorkspaceStore` and Continuum-owned session state, with `recentSessions: []` kept for wire compatibility.
- Backward-compatible endpoints for read-only continuation and JSONL alias rename remain inert without visible UI entry points.
- Live Cursor drive tests now skip cleanly when the local Cursor account reports agent usage exhaustion.
- Bumps `VERSION` 0.31.4 -> 0.31.5, `MARKETING_VERSION` 0.31.4 -> 0.31.5, and `CURRENT_PROJECT_VERSION` 204 -> 205.

## [0.31.4 build 204] - 2026-06-06 - Stop Claude background prompt polling (`darshanbathija/stop-claude-hi-spam`)

### Fixed

- Claude usage polling now reads the non-generative OAuth usage endpoint instead of creating throwaway `hi` conversations through `/v1/messages`.
- Claude auto-revive is paused across Mac and iOS until a non-consuming keepalive endpoint exists, so stale toggles or RPC calls cannot spend quota in the background.
- The Auto-revive settings surfaces now show the feature as unavailable instead of offering controls that can create hidden Claude prompts.
- Focused regression coverage now asserts Claude polling sends no prompt body and auto-revive sends no network request.

### Changed

- Bumps `VERSION` 0.31.3 -> 0.31.4, `MARKETING_VERSION` 0.31.3 -> 0.31.4, and `CURRENT_PROJECT_VERSION` 203 -> 204.

## [0.31.3 build 203] - 2026-06-06 - Relay/APNS hardening, chat launch, and updater fixes (`darshanbathija/security-fixes`, `darshanbathija/fix-bugs`)

### Fixed

- Relay pairing now provisions first-connect creation credentials from the signed pairing bundle and requires proof-bound session creation, closing the unauthenticated session-creation path.
- The relay creation-grant route now requires its own operator bearer, so the Worker cannot be used as a public signing oracle for attacker-chosen sessions.
- Desktop, iOS, and relay clients now bound request wait time and preserve offline mobile commands in the outbox instead of hanging indefinitely on relay misses.
- APNS gateway bearer validation now accepts the relay-provisioned signing key path and rejects malformed or mismatched bearer tokens more strictly.
- Chat V2 broadcast can start Codex from GUI-launched Continuum builds by resolving the real `codex` CLI path and passing a login-shell PATH into ACP stdio children.
- Chat V2 broadcast can start Claude without getting blocked behind Claude Code's first-run trust prompt by pre-trusting the per-chat scratch folder before spawning.
- ACP startup failures now surface actionable messages, including agent process exits and child stderr, instead of opaque `ClawdmeterShared.ACPError error 1` text.
- The Updates surface now uses Continuum's top-right popover for manual checks instead of also showing Sparkle's centered "You're up to date" dialog.
- The Update button still hands off to Sparkle immediately when a probe finds a release, instead of being swallowed by the manual-check debounce.

### Changed

- Adds focused relay/APNS/mobile outbox regression coverage and refreshes the release gates across relay, APNS gateway, shared Swift, Mac, iOS, and watchOS builds.
- Bumps `VERSION` 0.31.2 -> 0.31.3, `MARKETING_VERSION` 0.31.2 -> 0.31.3, and `CURRENT_PROJECT_VERSION` 202 -> 203.

## [0.31.2 build 202] - 2026-06-06 - Browser Preview annotations (`darshanbathija/design-comments`)

### Added

- Code sessions now include a first-class Browser Preview surface that can open the current worktree's running app from any completed assistant turn.
- Browser Preview keeps a persistent browser per session/worktree, supports full-workspace browsing with the repo/worktree sidebar still visible, and adds Browser as a selectable Code right-side mode.
- Browser annotations can be attached to the composer as removable `Comment: ...` chips, with redacted browser context rendered into the outgoing draft.
- Preview launch now resolves setup/run commands for the current worktree, reserves a local port range, reuses only matching healthy servers, and exposes setup/run health as a dedicated preview lifecycle.

### Fixed

- Preview no longer reopens a stale healthy browser URL from another working directory when the active session/worktree changed.
- WebView routing is now keyed by browser workspace so multiple sessions cannot steal each other's navigation or annotation commands.

### Changed

- Bumps `VERSION` 0.31.0 -> 0.31.2, `MARKETING_VERSION` 0.31.1 -> 0.31.2, and `CURRENT_PROJECT_VERSION` 201 -> 202.

## [0.31.1 build 201] - 2026-06-06 - Code tab sidebar alignment (`darshanbathija/code-tab-sidebar-align`)

### Fixed

- Removes the redundant Managed label from the Code tab sidebar so repos start directly under Projects.
- Aligns selected worktree row backgrounds with Conductor-style symmetric margins while preserving branch indentation.
- Bumps `MARKETING_VERSION` 0.31.0 -> 0.31.1 and `CURRENT_PROJECT_VERSION` 200 -> 201.

## [0.31.0 build 200] - 2026-06-06 - Sparkle appcast recovery (`darshanbathija/screenshot-error`)

### Fixed

- Publishes the first signed Sparkle appcast for the current Mac release line.
- Restores the public GitHub Pages feed used by the in-app Updates screen.
- Bumps `CURRENT_PROJECT_VERSION` 199 → 200 so installed build 199 clients can update.

## [0.31.0 build 199] - 2026-06-06 - Quiet Black Workbench redesign (every surface) (`v2-design-changes`)

### Changed

- **The whole app is redesigned to the new `DESIGN.md` "Quiet Black Workbench" direction** — a fully-neutral, near-black, instrument-grade dark tool that replaces the Tahoe liquid-glass system. Across macOS, iPhone, watchOS, and every widget/complication: glass/blur/glow/gradient-decoration is gone, panels are flat surfaces separated by 0.5px hairline seams and perceptible elevation steps (`bg #050507` → `surface-1/2/3` → `modal`), radii are tight (row 4 / button 5 / card 6 / modal 8 / rail 3), and the primary action is a **light** button rather than a chromatic one.
- **One unified token layer (`ContinuumTokens`).** A single source of truth for the palette, semantic state (`live`/`warn`/`error`/`paused`), provider identity, radii, the SF Pro Rounded / SF Pro Text / SF Mono type split, and mechanical motion. The old `TahoeTokens`, `SessionsV2Theme`, and `ClawdmeterTheme` palettes now forward to it; dark-only for v1 (the appearance / surface / wallpaper / accent / glass-intensity knobs are gone); the custom Tiempos/Styrene fonts are dropped for system SF.
- **The rail meter is the signature.** Quota reads as a horizontal rail (7px `#202126` track, provider T2 gradient fill, 1px lit edge, 80% limit tick, warn/error cap, ~140ms galvanometer settle). It replaces every ring/arc gauge — dashboard, menu-bar, iPhone Live, watch app, and all widgets/complications.
- **Color is rationed.** Greyscale by default; provider color appears only as a 6px dot, a 3px column/row edge, a chart segment, or the meter fill — never a provider-colored button, header, or panel. Claude keeps the heritage terra-cotta `#D97757` (as the dot only); Codex is graphite `#8A9099`; Antigravity is `#5C9DFF`.
- **Charts** use stacked bars with the same provider T2 gradients as the meters, SF Mono axes, dashed hairline gridlines, and keep `$0` providers in the legend.
- **New shared primitives:** flat panel, rail meter, light primary + hairline ghost buttons, pill segmented control, live switch, composer chip, provider dot/edge/glyph, a LiveTicker (1Hz heartbeat) and an odometer counter.

### Notes

- All four targets build (Mac/iOS/Watch + widget extensions); the `ClawdmeterShared` suite is green (new `ContinuumTokenTests` lock the palette/radii/meter-tick/provider values). The three legacy theme types remain as thin forwarding shims (the palette is already consolidated to `ContinuumTokens`); deleting them + migrating every consumer directly is a no-user-visible-change refactor deferred to a follow-up. A light variant, LiveTicker composer wiring, and the Linux (Cairo/GTK) port are deliberate follow-ups.

## [0.30.1 build 199] - 2026-06-06 - Correct Cursor monthly usage and analytics (`darshanbathija/cursor-usage-fix`)

### Fixed

- Cursor usage now uses monthly Total, Auto, and API quota data across the Usage tab, menu bar, chat/code usage chips, and `/usage`, instead of the old 5-hour/weekly labels.
- Cursor chat and code usage events now feed analytics, tokens-by-model, and repo spend through app-owned usage records.
- Cursor Composer hook records now resolve to bundled OpenRouter Kimi K2.5 pricing so analytics can show real dollars where token records include Composer usage.

Bumps `MARKETING_VERSION` 0.30.0 → 0.30.1, `CURRENT_PROJECT_VERSION` 198 → 199.

## [0.29.46 build 185] - 2026-06-02 - Code tab world-class pass: live feedback, motion, and a themeable accent (`darshanbathija/code-tab-audit-revamp`)

### Added

- **Every Code-tab action now tells you what happened.** Interrupting a run, switching model/effort/mode, and approving a plan used to call the daemon and show nothing — a working button looked identical whether it succeeded or failed. Each now surfaces a success or failure toast (with a severity glyph + tint), so a failed mode-swap or a rejected plan-approval is visible instead of silently swallowed.
- **Press feedback on every button.** A new shared `PressableButtonStyle` (subtle 0.97 press, 120ms, Reduce-Motion-aware) replaces the dead-feeling default across the workbench — clicks now register visibly.
- **Loading skeletons** replace bare spinners on the Diff and Artifacts review panes, so panes read as filling in rather than stalled.
- **XCTest visual analyzer** (`CodeTabVisualSnapshotTests`) renders the chips, skeletons, and buttons to PNGs headlessly so the design can be regression-diffed without launching the app.

### Changed

- **Motion across the Code tab.** The composer's running rim now breathes at 1.8s (the one DESIGN.md motion spec that was unimplemented); new chat turns fade and rise in; the Mode and Effort chips slide their selection pill between segments; the review-pane tab indicator slides and the body cross-fades on switch; the Diff pane animates its width expand. All of it collapses to static under Reduce Motion.
- **One accent for the whole tab.** The Mode/Effort chips followed a hardcoded terra-cotta while the buttons, composer send, and rim followed the user's chosen Tahoe accent — so the header mixed two colors. The chips now follow the Tahoe accent too (Halo blue by default, themeable in Settings).
- **`SessionWorkspaceView.swift` decomposed** from a 6,631-line monolith into 14 per-surface files (Sidebar, CenterThread, ChatThreadScroll, ReviewPane, the review/terminal panes). Pure moves — behavior unchanged, the streaming/Equatable perf path untouched.

## [0.29.45 build 184] - 2026-06-02 - Revive degraded sessions from iPhone (`fix/ios-revive-endpoint`)

### Added

- **Revive a degraded session from the paired iPhone.** New `POST /sessions/:id/revive` daemon endpoint (wire v25) respawns a degraded session's dead tmux pane with the same config + `--resume`. The iOS session controls strip shows a **Revive** button on degraded sessions; it's gated on the Mac's wire version, so an iPhone paired to an older Mac hides the button instead of failing. The endpoint shares the same rate-limit + idempotency contract as the other config-swap commands, so a double-tap or offline retry can't double-spawn the agent. (Mac-side Revive shipped in 0.29.44; this brings it to mobile.)

## [0.29.44 build 183] - 2026-06-02 - Revive degraded sessions (respawn dead tmux panes) (`fix/session-revive-on-attach`)

### Added

- **Revive a degraded session.** When the tmux server restarts (e.g. on app relaunch) it reassigns pane ids, leaving sessions `degraded` with a dead `tmuxPaneId` and a terminal that can't reconnect. Right-click a degraded session → **Revive session** respawns the agent into a fresh tmux pane with the same model/effort/mode and `--resume`, so the conversation continues and the terminal reconnects to a live shell. New `SessionConfigChanger.revive(sessionId:)` skips killing an already-dead pane and updates the registry's pane ids + status.

### Fixed

- **The terminal reconnects after a pane changes.** The primary terminal tab's view identity now includes the session's `tmuxPaneId`, so when a revive (or any respawn) moves the session to a new pane, the WebSocket tears down the dead-pane subscription and opens a fresh one to the live pane — instead of staying stuck on the old pane.

## [0.29.43 build 182] - 2026-06-02 - Terminal no longer hangs + per-workspace management (`feat/terminal-and-workspace-mgmt`)

### Fixed

- **The in-app Terminal no longer hangs on "Waiting for visible shell output."** When a session's tmux pane was gone (the tmux server restarts on app relaunch and reassigns pane ids, leaving "degraded" sessions with a stale `tmuxPaneId`), `capture-pane` errored, the error was swallowed, and no frame was ever sent — so an idle/dead pane left the terminal spinning forever. The channel now always sends an initial frame so the overlay clears, and when the pane is genuinely gone it shows a clear "session was restarted — revive to reconnect" notice instead of a silent blank. Newly-started sessions get a working live terminal.

### Added

- **Per-workspace management in the sidebar.** Each managed workspace row now has a gear (and right-click menu): New session here, Archive all sessions, Settings & Env Variables…, and Remove from list. "Remove from list" forgets the workspace card without touching the repo on disk.
- **Auto-prune of orphaned workspaces.** On launch, workspace cards whose repo directory no longer exists on disk (throwaway/QA clones deleted out from under the app) are dropped, so the same project no longer shows up as multiple stale duplicates.

## [0.29.42 build 181] - 2026-06-02 - Stop the recurring "access data from other apps" prompt (`fix/continuum-cross-app-prompt`)

### Fixed

- **No more "Continuum would like to access data from other apps" prompt every few minutes.** A provider you have enabled but aren't logged into (e.g. Codex or Gemini/Antigravity) used to make the usage poller retry its cross-app read (`~/.codex`, `~/.gemini`) on every tick, re-triggering the macOS Tahoe consent prompt. The poller now backs off for 6 hours on terminal auth failures and re-attempts only when you reopen the app, so the prompt stops instead of repeating.

### Changed

- **Quiet machines do near-zero cross-app reads.** `UsagePoller` now skips a provider's full poll when its data directory is unchanged since the last successful read (new stat-only `AISource.dataChangedSince` probe, overridden by the Codex and Antigravity/Gemini sources). Opening the app or refreshing (`forcePoll`) always does a fresh read. This cuts both work and the cross-app touches that surface the prompt.

### Added

- **One-time Full Disk Access opt-in (Settings → Providers).** A banner deep-links to System Settings → Privacy & Security → Full Disk Access while a cross-app provider is enabled and access is missing. Because the Release build runs without the App Sandbox, granting Full Disk Access durably stops the prompt for the shipped app — the powerful one-time opt-in that replaces the recurring nag.

## [0.29.34 build 173] - 2026-06-01 - Fix Claude CLI discovery under the sandbox (`darshanbathija/sandbox-claude-bin`)

### Fixed

- **"claude CLI not on PATH" — Claude sessions and the Claude provider now work again.** A recent Claude Code update moved its binary to `~/.local/share/claude/versions/<ver>`, with `~/.local/bin/claude` as a symlink to it. The sandbox follows that symlink at exec time, but the app's entitlements granted `~/.local/bin/` and `~/.local/share/cursor-agent/` without `~/.local/share/claude/`, so the kernel denied executing the real binary and `locateBinary("claude")` fell through to "not on PATH." Added the read-only `~/.local/share/claude/` exception (mirroring the existing cursor-agent one). Independent of how the app is launched.

## [0.29.33 build 172] - 2026-06-01 - Simplify provider onboarding and settings (`darshanbathija/settings-onboarding`)

### Changed

- **One compact provider card, shared by Settings → Providers and first-run onboarding.** Each provider row shows just the glyph/name, an opt-in toggle, and a default-model menu, in chat vendor order (ChatGPT, Claude, Antigravity, Cursor, OpenRouter). Enablement stays in `ProviderEnablement` / `runtime.setProviderEnabled` and model defaults in `ProviderDefaultsStore`.
- **Disabled providers stay fully passive.** Cursor/OpenRouter model and auth-file discovery is now gated behind provider enablement across Settings, `/models`, `/chat-providers`, and session-launch availability — a disabled provider triggers no catalog refreshes or auth probes.

### Removed

- Unused legacy `ProvidersSettingsView.swift` and its stale Xcode project references.

## [0.29.32 build 171] - 2026-06-01 - Spawned agent panes inherit the real PATH (`darshanbathija/spawn-node-path`)

### Fixed

- **Agent hooks that need `node` (and other CLI tools) now work in spawned sessions.** Continuum is a GUI app, so it only inherited launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`); the tmux panes it spawns for agents inherited that too. Claude Code's `node`-based `SessionStart` hooks then failed with `node: command not found` because Homebrew's `/opt/homebrew/bin` wasn't on the path. New sessions now run with the user's real login-shell `PATH` (resolved once and cached), with the Homebrew/`/usr/local/bin` dirs as a backstop. A caller-supplied `PATH` (e.g. from a repo `.env`) keeps precedence; the enriched dirs are appended so tooling stays discoverable.

## [0.29.31 build 170] - 2026-06-01 - Workflow test-fixes: correct new-session transcripts + Tahoe conformance (`darshanbathija/test-fixes`)

End-to-end testing of the three core workflows (import a repo, start a session, send a chat) against the live daemon surfaced two real bugs, plus a Tahoe design-conformance sweep across the Mac and iOS surfaces.

### Fixed

- **A just-spawned session no longer shows another session's transcript.** The chat-snapshot JSONL resolver walked parent directories with no lower bound, so any session whose own transcript hadn't been written yet (a brand-new session, or a worktree on an unborn branch) resolved to `~/.claude/projects/-Users-<user>/` and surfaced an unrelated conversation. The parent-walk is now bounded to strict descendants of `$HOME`, so it still catches the "launched one level above the repo" case but never climbs into the home directory's own history. Covered by a new 4-case regression test.
- **Quick-started repos are now immediately usable for sessions.** "Quick start" ran `git init` but never made a commit, leaving the repo on an unborn branch — so the default worktree-based new-session flow landed the agent in a commit-less worktree. Quick start now makes an initial empty commit (with an identity fallback) so a worktree can branch from a real HEAD.

### Changed

- **Tahoe design conformance.** Degraded session status now renders in the danger red (`#ff5f57`) instead of a muted gray; the pairing QR image renders at its native 224px instead of a half-resolution 160px buffer; adding a project that's already imported now shows a "Already in your projects" toast instead of silently doing nothing; the settings toggle animation uses the spec `cubic-bezier(0.3, 0.7, 0.4, 1)` curve; the first plan step's badge is accent-highlighted on Mac and iOS; the Chat composer's idle placeholder reads "Ask anything. Use / for skills, @ for files."; the "+ Add project" button is the spec 24px / 10px-radius size; the Code review-pane tabs are pinned to 30px with the spec active-tab shadow + hairline; and the iPhone-sync settings row is labeled "Sync with iPhone".
## [0.29.30 build 169] - 2026-05-28 - Collapsed transcript projection (`darshanbathija/collapse-status`)

### Added

- **Collapsed transcript projection for chat threads.** Mac and iOS chat surfaces now group each user turn around the latest assistant answer, hiding noisy intermediate tool/result rows behind an expandable "worked for" summary while preserving full transcript access.
- **Output and edit chips on collapsed turns.** Collapsed turns surface generated artifacts and edited-file summaries so users can jump to important outputs without expanding every hidden row.

### Fixed

- **Collapsed chat caches refresh when transcript content changes.** iOS snapshots with legacy/stale counters now receive a local counter bump when transcript items change, so collapsed projections refresh without hashing every transcript row in SwiftUI.
- **Streaming tool output stays visible while a turn is running.** Collapsed projection now waits for the final assistant answer before hiding intermediate tool/result rows behind the "worked for" summary.
- **Mac artifact chips resolve relative paths from the session workspace.** Popped-out and Chat V2 transcript artifact buttons now resolve relative paths from the session runtime/worktree/repo root instead of the app process working directory.
- **Jump-to-last-user targets the visible turn anchor.** The transcript shortcut now skips synthetic tool-result user rows and expands the collapsed turn before scrolling.

### Tests

- Added regression coverage that unfinished streaming turns keep active tool output visible instead of collapsing it early.
- Verified `swift test --package-path apple/ClawdmeterShared`, Mac debug build, and iOS simulator debug build.

Bumps `MARKETING_VERSION` 0.29.29 -> 0.29.30, `CURRENT_PROJECT_VERSION` 168 -> 169.

## [Unreleased]

### Added

- **Workspace manual-QA polish batch (Code tab).** Sixteen targeted fixes across the Code workspace, all uncovered during a bug-fixing manual-QA pass. Term tab now embeds the live PTY-backed `TerminalTabContainer` instead of an echoed-bash summary — open Term, get a real shell in the session's repo. PR pane survives synthetic preview sessions: when the daemon returns `sessionUnknown` for a session it doesn't have in its registry, `PRCoordinator` switches to the existing `PRMirror` chat-scan + manual-URL fallback so the pane stops showing "Daemon returned HTTP 404" forever. Per-row "+" buttons quick-spawn directly with Codex / gpt-5.5 / max effort / plan mode, skipping the New Session sheet (Opt-click for the full sheet). Top-right trio replaced by a single pane menu (Plan / Diff / Sources / Artifacts / PR / Browser / Terminal + Collapse) with diff width clamped to `(workspace × 0.58, 560pt, workspace − 520pt)` when Diff is selected — Diff is no longer a useless 380pt strip. Right pane defaults to collapsed for new users. Composer chips collapsed from two to one: `PermissionModeChip` uses `Menu(primaryAction:)` so click flips plan ⇆ acceptEdits and long-press opens the full ask/edits/plan/bypass picker (`</> code` chip removed). Code's model chip now hosts the same rich vendor-rail picker the Chat tab uses, sharing the favorites list via `ProviderDefaultsStore` (`clawdmeter.providerDefaults.favoriteModelsByVendor` UserDefaults key) — star a model in Chat, it's starred in Code too. Chat / Usage / Code / Settings tab switches are now ZStack-cached and cross-fade in 0.16s (`reduceMotion`-aware); first visit lazy-mounts, subsequent visits show in one frame. "Ran N commands" chip animates the digit on increment (`contentTransition(.numericText)`) with a spring scale-bounce and shows a `Running <tool> · <input>` subtitle while any pair is in flight. Turn timer no longer resets every 5-30s — it now ignores synthetic mid-turn `.userText` injections from tool-result frames carrying sibling text blocks. Session header's `⚡ ask` pill is interactive now (Menu with all 4 permission modes). Sidebar History section is collapsed by default behind a toggle button. "+ New session" folder-plus button is now a clear primary CTA (30×30, terra-cotta accent) instead of greyed-out chrome. LiteLLM pricing snapshot refreshed (no rate changes since 2026-05-23); OpenCode parser audit confirmed it still mirrors upstream `ccusage/opencode/loader.rs + parser.rs` 5-step cost-fallback bit-for-bit. Tab-strip leading spacer tightened 76 → 60pt so the Chat chip stops floating in dead space past the traffic lights. 1137/1137 ClawdmeterShared tests still pass; Mac scheme builds clean.

- **A10: shell/detail split on chat-subscribe + wireVersion 21.** Splits the chat-subscribe WS stream into a thin `ChatShellEvent` followed by a heavy `ChatDetailEvent`. v21+ clients receive both frames per 100ms coalesced commit. Wire-version 20 and earlier clients keep receiving the legacy `WireChatSnapshot` JSON frame unchanged. On the synthesized 100-message burst fixture, the shell payload is **99% smaller** than the legacy snapshot (206B vs 102,845B). iOS / Mac / Watch builds green.

- **E4: iOS daemon outbound relay client with background-lifecycle handling.** New `IOSRelayClient` opens an outbound WSS to the E2 relay Worker, exchanges X25519 handshakes, and seals/opens chat-class frames with XChaCha20-Poly1305 IETF. Background lifecycle per design doc §11. **Shared `RelayFrameCodec` + `HChaCha20.swift` land in `ClawdmeterShared/Relay/` — no libsodium-swift dep; pure-Swift HChaCha20 (~90 LOC) verified against RFC §2.2.1 + libsodium vectors.** Cross-verifies byte-exact against all 7 test vectors in `infra/relay/test-vectors/`. 17 lifecycle + handshake tests; 14 cross-impl crypto tests.

- **E6: Mac daemon → APNS gateway integration; plan-approval push fires ≤2s.** The Mac daemon now posts encrypted push payloads to the merged E5 APNS gateway Worker (PR #147) so the paired iPhone surfaces plan-approval cards, session-done banners, and permission prompts within ~2 seconds of the Mac-side event — replacing the 15–30 min BG-refresh lag the GTM doc flagged as the launch blocker. New `APNSGatewayClient` (Mac actor) seals the body with ChaCha20-Poly1305 via CryptoKit's `ChaChaPoly` under an HKDF-derived key (`info="clawdmeter.apns.v1"`), signs the per-peer bearer (`HMAC-SHA256(RELAY_BEARER_SIGNING_KEY, "apns:" + sid + ":" + fingerprint)` — exact match for the E5 Worker's `verifyBearer`), and POSTs `/push` over TLS 1.3-pinned URLSession. `APNSGatewayPushCoordinator` joins the device-token registry (new `APNSPushDeviceTokenStore`), the pairing record (E7's `RelayPairingStore`), the signing key (env-var fallback for dev; relay-provisioned in production once E3 lands), and user-facing settings (`APNSGatewaySettings`, all surfaces default-on). `SessionEventWiring` fans out plan-ready + done-detected into a fresh push trigger. New `POST/DELETE /devices/apns-token` routes accept the iPhone's `didRegisterForRemoteNotificationsWithDeviceToken` callback (E4 will wire). 410-Gone responses purge stale token from the local store. Measured integration-test timing: 0.009s basic plan-approval path, 0.062s end-to-end via coordinator, 0.507s with simulated 500ms gateway latency — all under the 2s SLO.

- **F3-wire: per-instance HOME isolation + Keychain partitioning + wireVersion 20.** Daemon-side counterpart to F3 source-only (PR #142). `AppRuntime` is now instance-aware (one `AppModel` per `ProviderInstanceId`, keyed by `wireId`, back-compat shortcut properties resolve to the primary). New `ProviderInstanceEnvironment.buildEnv(for:)` does explicit env scrubbing on child-process spawn (`CLAUDE_*` / `ANTHROPIC_*` / `CODEX_*` / `OPENAI_*` / `GEMINI_*` / `OPENCODE_*` / `OPENROUTER_*` / `CURSOR_*` deny-list per Codex eng-review #10). `PastedAnthropicTokenProvider.forInstance(_:)` adds Keychain access-group partitioning. Wire bumps to **v20** with `NewSessionRequest` + `AgentSession` gaining optional `providerInstanceId: String?`; `UsageEnvelope` accepts dual-keyed entries (kind-only + instance-keyed) with symmetric fallback. `ProviderInstanceLogRedaction.redact` substitutes raw `homePathOverride` with `<HOME for <kind>/<name>>`. 17 new tests under `ProviderInstanceWireTests`. v19 clients see only primary. (Wire-version numbering note: plan referenced v21 assuming A10 would land at v20 first; A10 hasn't shipped, so F3-wire claims v20 directly.)

- **Security + privacy + known-limitations docs (E8, Gate 0).** Three new reference docs under `docs/` describe the secure-cloud relay + APNS gateway story for the end user. `docs/security.md` covers the trust model, cryptographic primitives (X25519 ECDH + HKDF-SHA256 + XChaCha20-Poly1305), key lifecycle, D22 per-peer bearer auth, D21 mitigation suite, Codex #5 device-token egress controls, F3 HOME isolation shape, audit-log redaction rules, and a pointer to the 14-scenario threat model. `docs/privacy.md` enumerates every byte that leaves the user's Mac (relay envelopes, APNS pushes, pricing snapshot, provider CLI telemetry) vs. what stays local; documents the GDPR / CCPA deletion story that PR #146 made real (the `wal_checkpoint(TRUNCATE)` after `deleteSession`). `docs/known-limitations.md` enumerates what's NOT yet in main: E3 / E4 / E6 clients, Swift CryptoKit XChaCha20 nonce-size gap, C2 `@Observable` migration, watchOS + iOS Tahoe debt. Linked from README under a new "Security and privacy" section.

- **E7: relay-session-token QR pairing (Gate 3 GTM launch blocker).** Mac → iPhone pairing now defaults to a relay-based flow that doesn't depend on Tailscale or shared LAN reachability. Tapping "Pair iPhone" on the Mac generates an ephemeral X25519 keypair plus per-peer bearer tokens (mac/iOS), encodes them into a `clawdmeter-pair://v1/<base64url>` URL, and renders a QR. The iPhone scans, parses the bundle, generates its own X25519 keypair, derives the shared symmetric key via HKDF-SHA256(salt=sid, info="clawdmeter.relay.v1"), and persists the record + key to Application Support + Keychain. New `RelayPairingService` (Mac) and `IOSRelayPairingService` (iOS) drive the `unpaired → generatingBundle → keyExchanged → readyButNotConnected` state machine. E7 stops at the handshake — E3 (Mac) + E4 (iOS) will open the actual relay WebSocket against the merged E2 Worker (#151). Legacy Tailscale pairing stays available behind an "Advanced" disclosure on both peers so users on a Tailnet aren't broken.
- **Optimistic UI for the composer (A13).** Tap Send and your message renders as a pending bubble above the input strip within one frame — no more "did it go?" beat while the JSONL tail catches up. The bubble dissolves into the confirmed user message once the daemon's `user` line lands (auto-reconcile by body), so there's no flicker on settle. When the daemon rejects the send (HTTP 4xx, transport failure), the bubble stays visible with an inline error chip and a Retry button (D24 eng-review acceptance: no silent drop). Brief daemon outages are handled with an offline queue: messages stage locally as "queued offline" and drain in FIFO order on the next successful send. Capped at 8 entries so a long outage doesn't grow unbounded — the overflow surfaces as `.failed` so the user can manually retry.

- **Code tab hover polish + composer chip shortcuts (#185, surgical scope).** Composer chips (`UsageStatusChip`, `PermissionModeChip`, `SessionStatusBadges`) gain hover affordances, stable icon-button dimensions, tooltip/help copy, and accessibility labels. New `ClawdmeterShortcutRegistry` provides a typed catalog of Code/session/composer chords (`⌘T`, `⌘⇧T`, `⌘N`, `⌘U`, `⌘⇧R`, `⌘⇧A`, model/effort/context controls). `WorkspaceHoverControls` adds shared Code hover chrome. `TahoeChip` and the chip family pick up consistent prominent-opt-in shadows. Tab-spawn wiring intentionally leaves the workspace-tabs model from #174 in place; only the additive hover + chip + shortcut-registry surface lands here. New tests: `UIPrimitivesTests` (shortcut registry uniqueness + chord expectations, 11 tests), `CodeTabHoverShortcutUITests` (Code composer controls, `⌘U`, `⌘N`, session rename chord when a session row exists).

### Fixed

- **Code sidebar no longer shells out while SwiftUI renders session rows.** Repo identity badges now paint from cached metadata or a deterministic local fallback, then resolve `remote.origin.url` asynchronously after the row appears. This prevents the AttributeGraph crash seen when adding a Codex session for a repo that may already have Claude-managed/worktree state.

### Changed

- **perf(chat): slice `SessionChatStore` publishing into per-concern slices (A5).** Splits `SessionChatStore`'s fat `@Published snapshot: ChatSnapshot` into three per-concern `ObservableObject` slices so SwiftUI views invalidate only on the concern they actually consume. Pre-A5, every staging commit (every 16 ms during a streaming burst) fanned out one `objectWillChange` to every observer regardless of whether the relevant fields had moved.
  - **New `ChatMessagesSlice`**: `@Published` items, messages, planSteps, sourceEntries, artifactEntries, codexTodos, updateCounter. Fires on every staging commit that mutates the transcript.
  - **New `ChatLiveStatusSlice`**: `@Published` lastEventAt, currentTurnStartedAt, currentTurnState, isLoading, hasOlderHistory, pendingPermissionPrompt. Fires on turn transitions and pagination flips.
  - **New `ChatComposerSlice`**: `@Published` modelHint + the four token categories (cumulative + most-recent turn). Fires ONLY when an assistant turn lands new `message.usage` — tool results and user-text appends no longer invalidate the composer's context-window meter or the activity strip's cost label.
  - Every per-slice setter is equality-guarded, so a staging commit that touches only items doesn't bump composerSlice (and vice versa).
  - **Migrated view consumers:** `ChatThreadScroll` → messagesSlice + liveStatusSlice; `ArtifactsPane`, `SourcesPane`, `CodexPlanPane`, `PlanTrackerPane`, `PoppedChatThread` → messagesSlice; `SessionActivityStrip` → liveStatusSlice + composerSlice.
  - `@Published snapshot`, `isLoading`, `hasOlderHistory`, `pendingPermissionPrompt` stay on `SessionChatStore` for non-view consumers (PRMirror's Combine subscription, AgentControlServer, ChatStreamWebSocketChannel, NotificationDispatcher, FrontierWebSocketChannel, DaemonChatStoreRegistry).

### Internal

- New `OptimisticPendingMessage` value type in `ClawdmeterShared/Composer/` owns the `.sending → .failed | .queuedOffline | cleared` state machine. Aliased as `SessionChatStore.PendingMessage` so the slot stays addressable from existing Mac call sites.

### Tests

- `SessionChatStoreSlicePublishingTests.swift` — verifies (a) composerSlice does NOT publish on a transcript-only user-text append, (b) composerSlice DOES publish on an assistant turn with `message.usage`, (c) permission-prompt toggle invalidates only liveStatusSlice (not messagesSlice or composerSlice), (d) all three slices mirror the staging snapshot's values after ingest.

### Deferred

- Find-bar overlay isolation. The find-bar inside `ChatThreadScroll` shares the parent body, so a transcript append still re-evaluates its body (small cost — TextField + 4 buttons). Full isolation requires extracting `TranscriptFindBarOverlay` as an Equatable child view with on-demand match computation.
- `@Observable` migration (C2 in the plan) is a separate PR that will re-architect the slices as `@Observable` macro types.

## [0.29.24 build 163] - 2026-05-27 - Vendor provisioning (`darshanbathija/cli-vendor-auth`)

### Added

- **Advanced provisioning in Settings.** Adds Settings -> Advanced -> Provisioning with category filters, Check Device, vendor rows, CLI auth status, MCP status, signup links, visible install/auth actions, and environment import CTAs. V1 covers MongoDB Atlas, Upstash, Supabase, Fly, Railway, Hetzner, AWS, GCP, Azure, and Cloudflare/Wrangler.
- **Wire v24 vendor-provisioning API.** Adds catalog, device-check, terminal action, env preview, and env import routes under `/vendor-provisioning`, wired through `AppRuntime`, `AgentControlServer`, and `AgentControlClient`.
- **Repo-env import bridge.** Vendor env candidates flow through PR 201's import preview and `RepoEnvStore.importVariables`, always store as sensitive Keychain-backed values, preserve duplicate/overwrite behavior, support selected repos plus current-repo set IDs, and record `actor: vendor:<id>` provenance without persisting secrets in JSON.
- **Visible CLI/tmux launch path.** Install and auth actions are allowlisted, launched through tmux-backed visible terminal windows, and return terminal window/pane identifiers instead of running hidden credential commands.

### Tests

- Added vendor catalog, allowlist, concurrent probe, MCP matching, env preview/import, route DTO, and UI smoke coverage.
- Verified focused shared wire tests plus Mac route/service regression gates, including `RepoEnvStoreTests` and `TmuxControlClientValidationTests`.

Bumps `MARKETING_VERSION` 0.29.23 -> 0.29.24, `CURRENT_PROJECT_VERSION` 162 -> 163.

## [0.29.21 build 160] - 2026-05-27 - Generated Markdown document tabs (`darshanbathija/chat-md-render`)

### Added

- **Generated Markdown artifact metadata.** Chat transcripts now carry provider-agnostic generated-artifact metadata for Markdown documents, including Claude/Codex/generic write-like tool payloads, `apply_patch` headers, legacy transcript fallback, uppercase Markdown extensions, and metadata-marked no-extension Markdown paths.
- **Read-only Markdown document tabs on Mac.** The Code workbench can manually open generated Markdown files into center document tabs beside chat and terminal tabs, deduped by workspace plus standardized absolute path, with native SwiftUI Markdown rendering, explicit missing/permission/too-large/binary states, and Open in Editor / Reveal / Copy Path / Refresh actions.
- **iOS document-tab parity.** iPhone session detail now exposes the same document-tab model and artifact row action, renders Markdown documents through the shared parser, and keeps tab selection state separate from chat and terminal tabs.

### Fixed

- iOS Markdown document loading now uses the Mac daemon's dedicated `/sessions/:id/markdown-document` endpoint so generated docs under paths like `~/.gstack/projects/...` can open even when they are outside the session worktree.
- Rapid iOS tab switches now guard async loader generations so cancelled or stale loads cannot overwrite the currently selected document tab.

### Tests

- Added shared generated-artifact detector coverage, shared Markdown document model coverage, Mac session-store/tab/row-action coverage, and iOS document-tab behavior coverage.
- Verified `swift test`, targeted Mac and iOS XCTest gates, and a Mac scheme build.

Bumps `MARKETING_VERSION` 0.29.20 -> 0.29.21, `CURRENT_PROJECT_VERSION` 159 -> 160.

## [0.29.16 build 155] - 2026-05-27 - Repo environment variable sets (`darshanbathija/repo-env-vars`)

### Added

- **Repo environment variables in Settings.** Developers can create repo-specific sets such as local, testnet, staging, and prod; add variables in a dense Vercel-style table; filter by set/source/type/status; import `.env` text; and share global variables into multiple repos without reading secret values into the settings list.
- **Runtime env-set resolution.** Sessions, mode switches, restore/respawn paths, run profiles, in-app browser launches, and tmux windows resolve the pinned env set before launch, materialize only the Continuum-managed block in `.env.local`, preserve manual lines, and pass tmux variables via native `-e KEY=value`.
- **Repo env V2 design reference.** Added `docs/designs/repo-env-v2-vercel-parity.md` to capture the table-first UX, filter model, repo/set matrix, import flows, and Vercel-parity follow-up scope.

### Fixed

- Duplicate shared-variable assignments are rejected before they create key collisions in a target repo.
- Failed Keychain deletes now preserve metadata and surface an error instead of claiming the secret was removed.
- Mid-session respawns preflight env materialization before killing the existing tmux window.

### Tests

- Added `RepoEnvStoreTests` for metadata persistence, secret-free JSON, assignment resolution, import parsing, materialization conflicts, duplicate assignment rejection, and Keychain failure handling.
- Added tmux validation for native env injection and UI smoke coverage for the Env Variables settings table, filters, import flow, and add-variable drawer.

Bumps `MARKETING_VERSION` 0.29.15 -> 0.29.16, `CURRENT_PROJECT_VERSION` 154 -> 155.

## [0.29.14 build 153] - 2026-05-27 - Workspace tabs + Code sidebar active-session priority (`darshanbathija/session-tabs`)

### Added

- **Workspace tab strip for Mac sessions.** Users can open lightweight draft chat tabs with `⌘T`, keep multiple chats in the same workspace row, and promote a draft on first send without creating another worktree.
- **Opt-in sibling context inheritance.** Draft chats can include selected sibling transcripts as capped digest files, with inherited attachments copied into the promoted session and recorded in an audit manifest.
- **First-class terminal tabs.** Terminal tabs now live beside chat tabs for tmux-backed sessions, including `⇧⌘T` and menu affordances that avoid opening dead terminal panes for providers without a tmux pane.
- **iOS workspace tab strip.** iPhone session detail views now show the same workspace tab model, with terminal affordances hidden unless the backing session can actually stream a terminal.

### Changed

- **Code sidebar now prioritizes Continuum-created work.** Managed code sessions and same-workspace tabs appear first, grouped by workspace/repo and ordered by most recent child activity. Pinned state still renders as UI state, but default ordering is recency-first.
- **External JSONL sessions are split by activity.** Outside-Continuum sessions touched within 10 minutes appear under active repo groups, while older external recents move to a visually separated bottom History section grouped by repo and date. The 30-day `RepoIndex.recentSessions` source and 5-minute live-dot behavior stay unchanged.
- **Repo rows can start new workspaces.** Repo headers now expose a sibling `+` action that opens the existing new-session/worktree sheet with that repo preselected without also toggling row expansion.

### Fixed

- Same-workspace sessions now track explicit worktree ownership so ending a tab cannot delete a shared checkout it did not create.
- Inherited attachment staging is isolated per session to prevent sibling Codex sessions in the same checkout from leaking files into each other.
- First-send promotion revalidates selected sibling sources before inheritance, so archived, stale, or current-session IDs are excluded safely.
- Archived managed Code sessions no longer leak into normal Date, Agent, None, Repo, or Status views; they are visible only through the Archive filter.
- Opening an external JSONL read-only no longer creates a duplicate first-party workspace row, and Continuum-owned JSONLs are suppressed from external active/history rows without adding a new wire/schema field.
- External search now matches recent-session metadata, so filtering by JSONL path, prompt text, alias, or provider still surfaces the relevant external repo/history rows.

### Tests

- Added shared tests for workspace sibling grouping, wire v22 ownership/context fields, and transcript digest rendering caps.
- Added Mac tests for draft promotion, same-workspace spawning, terminal-tab gating, and inherited attachment copy behavior.
- Added Mac sidebar projection coverage for managed-session recency, archive hiding, active/history cutoff boundaries, cutoff-clock cache invalidation, external/history exclusivity, grouping leak prevention, repo-row `+` behavior, and external JSONL read-only ownership.

Bumps `MARKETING_VERSION` 0.29.13 -> 0.29.14, `CURRENT_PROJECT_VERSION` 152 -> 153.

## [0.29.12 build 151] - 2026-05-26 - Code session rename persistence (`darshanbathija/rename-fix`)

### Fixed

- **Code session renames now stick.** Renaming a Code session from the Mac sidebar writes to the canonical session record, so the new title survives app reloads and matches the sidebar, header, command palette, iOS mirror, and daemon rename surfaces.
- **Clearing a session name is consistent.** The Clear name action now removes the canonical custom name and clears stale client-local title overrides left by older builds, so old presentation-only labels no longer shadow the real session title.
- **Code tab build membership is refreshed.** The Mac target now includes the workspace notification file needed by Code tab actions such as pop-out and transcript find.

### Tests

- Added Mac regression coverage for trimming, persisting, reloading, clearing, and missing-id behavior in Code session rename.
- Kept sidebar projection cache coverage aligned with the status grouping input so custom-name changes invalidate stale rows correctly.

Bumps `MARKETING_VERSION` 0.29.11 -> 0.29.12, `CURRENT_PROJECT_VERSION` 150 -> 151.

## [0.29.13 build 152] - 2026-05-27 - Continuum-owned Conductor-style workspaces (`darshanbathija/branch-issues`)

New existing-repo sessions now provision Continuum-owned worktrees under `~/Clawdmeter/workspaces/<project>/<city>` instead of the legacy `.claude/worktrees` layout. The provisioning path creates the branch/worktree first, writes ownership metadata in the Git dir, copies ignored local files in full-local-clone mode by default, and launches each provider from the prepared cwd without surfacing Continuum-owned trust popups.

### Added

- `WorkspaceFilesToCopyConfig` now supports pattern mode and all-ignored mode, with `.worktreeinclude` taking precedence over repo settings and the all-ignored default copying directories, dependencies, build artifacts, and local database groups subject to caps.
- `WorktreeManager` now resolves Conductor-style project/city storage, creates branch-alias symlinks, writes copy manifests in the worktree Git dir, enforces destination parent-chain validation, and cleans up only manifest-owned unchanged files on failure or delete.
- Session provisioning metadata now records storage root, project slug, city slug, branch alias, copy mode, copied/skipped counts, byte totals, manifest path, and failure summaries for UI/audit use.

### Fixed

- Mode switches, OpenCode chat/frontier sessions, and session deletion now preserve the prepared runtime cwd and clean owned worktrees even for providers that do not have a tmux pane.
- SQLite-like ignored DB groups (`.db`, `.sqlite`, `.sqlite3` plus `-wal`/`-shm`) copy atomically and fail closed when companion files are missing or mutate during provisioning.
- Copy/spawn failures clean up manifest-owned files and remove the provisional worktree without creating a durable registry session row.

### Tests

- Added coverage for copy-all ignored defaults, `.worktreeinclude` overrides and negation, branch alias creation, Conductor-hosted project slug resolution, cap failure cleanup, manifest-safe deletion, parent-chain validation, runtime cwd updates, and provider trust argv.
- Verification: `swift test` in `apple/ClawdmeterShared`; targeted Mac XCTest for `WorkspaceStoreTests` + `AgentSessionRegistryFrontierTests`; full `xcodebuild -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" CODE_SIGNING_ALLOWED=NO build`.

Bumps `MARKETING_VERSION` 0.29.12 -> 0.29.13, `CURRENT_PROJECT_VERSION` 151 -> 152.

## [0.29.11 build 150] - 2026-05-26 - Rebrand sweep + OpenCode status pill + design polish (`fix/v0.29.11-rebrand-bleed-and-opencode-badge`)

Verifier loop on v0.29.9 surfaced two classes of leftover work from the Continuum rebrand and the new OpenCode CLI auth row. Folded both into a single follow-up.

### Fixed

- **OpenCode row now shows a status pill** like Claude Code + Cursor SDK do. "Ready" (green) when CLI auth has providers, "Sign-in pending" (yellow) when the binary is installed but auth.json is empty, "Not installed" (orange) when the CLI isn't on PATH, "Checking…" while the probe is still running. Previously the row was the only authenticated provider without an at-a-glance state indicator — the info was in the subtitle but you had to read 8 words to know whether OpenCode was ready.
- **Rebrand string bleed cleaned up.** v0.29.7 / v0.29.8 swept the obvious visible strings, but a verifier pass on v0.29.9 caught more references that still said "Clawdmeter":
  - Settings → Providers header subtitle: "External agent runtimes ~~Clawdmeter~~ Continuum can drive."
  - AppleScript-fallback alert text for both Claude Code + OpenCode "Auth via CLI" buttons: "Couldn't drive Terminal from ~~Clawdmeter~~ Continuum (…)".
  - iOS Settings + iOS Pairing + Watch ContentView + Mac widgets + iOS notification copy: "Open ~~Clawdmeter~~ Continuum on your Mac / iPhone …".
  - Mac widget configurationDisplayName: "~~Clawdmeter~~ Continuum".

### Known not-fixed

- The "Probing…" subtitle on the OpenCode row when auth.json is missing takes ~25s to resolve to "No upstream providers yet". The new status pill mitigates this (it shows "Checking…" so the row no longer looks frozen) but the underlying probe latency is still slow. Tracking separately.
- macOS LaunchServices can nondeterministically launch `/Applications/Clawdmeter.app` (legacy) instead of `/Applications/Continuum.app` (current) when both exist with the same bundle identifier `com.clawdmeter.mac`. INSTALL.txt tells users to trash the legacy app, but the install path could detect and warn proactively. Tracking separately — full bundle-ID transition (Phase 2 under Montauk Analytics paid dev) makes this moot.
- Latest design critique scored 95.35/100 — short of the 98 floor /verify calls for. Three follow-up items would push it to 98+: F-09 chip-cluster overflow to "+N" inline chip, F-02 system-wide `TahoeTokens.statusColor()` token, F-10 chip stroke removal.

Bumps `MARKETING_VERSION` 0.29.9 -> 0.29.11, `CURRENT_PROJECT_VERSION` 148 -> 150.

## [0.29.9 build 148] - 2026-05-26 - OpenCode auth flows through the CLI (`feat/opencode-cli-auth`)

Continuum no longer maintains a parallel "paste an OpenRouter key" affordance for OpenCode. The user's `opencode` CLI session is now the single source of truth — Continuum reads `~/.local/share/opencode/auth.json` to enumerate connected upstream providers and routes chat through the long-running `opencode serve` daemon (which already uses those CLI creds upstream). Settings → Providers → OpenCode now mirrors the Claude Code row's "Auth via CLI" shape.

### Changed

- **Settings → Providers → OpenCode** - the "Activate / Edit API key" sheet is replaced by a status row showing "Using opencode CLI auth — N upstream providers available" plus a list of provider chips. When auth.json is empty or the binary is missing, the row exposes an "Auth via CLI" button that opens Terminal pre-typed with `opencode auth login` (with the same AppleScript+clipboard fallback the Claude row uses for sandboxed builds).
- **`OpencodeAuthFile`** - exposes `enumeratedProviders()` returning a typed `[UpstreamProvider]` (id, auth type, display name) so the Settings panel doesn't re-parse the JSON itself.
- **`opencodeMessageBody`** - no longer injects `model.providerID` / `model.modelID` / `variant`. `opencode serve` picks the upstream model from the CLI's own default-model state, so the desktop UI's stale model selection can't silently override what the user just configured in Terminal.

### Removed

- **`OpencodeAPIKeySheet.swift`** - the in-app API-key sheet is gone. The CLI's `opencode auth login` flow is the only supported path; pasting keys directly from Continuum is no longer offered.

### Verification

- Manual: with `~/.local/share/opencode/auth.json` present and an OpenRouter token in it, sending a chat to OpenCode streams a response without Continuum prompting for any key.
- Manual: removing auth.json drops the row to "No upstream providers yet" with an "Auth via CLI" button that opens Terminal with `opencode auth login` queued.
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` -> pending CI run on the PR (no local macOS toolchain on the build agent).

Bumps `MARKETING_VERSION` 0.29.8 -> 0.29.9, `CURRENT_PROJECT_VERSION` 147 -> 148.

## [0.29.8 build 147] - 2026-05-26 - PRODUCT_NAME flip: `/Applications/Continuum.app` (`rebrand/continuum-product-name`)

Extends the v0.29.7 display-only rebrand: PRODUCT_NAME on the Mac target flips from `Clawdmeter` to `Continuum`, so the `.app` folder users see in `/Applications`, Finder Get Info, Spotlight, and Activity Monitor process names is now `Continuum.app` / `Continuum`. CFBundleName (which mirrors PRODUCT_NAME) also reads `Continuum` now, so the previous display-vs-name split (display "Continuum" but bundle name still "Clawdmeter") is closed.

Bundle identifier stays `com.clawdmeter.mac`. App Group `group.76S62SDSD3.com.clawdmeter`, keychain-access-group prefix, and on-disk data at `~/Library/Application Support/Clawdmeter/` + `~/Library/Containers/com.clawdmeter.mac/` are all untouched — existing installs upgrade with zero data migration. The full bundle-id transition to `com.montaukanalytics.continuum.*` still waits on the Montauk Analytics Developer Program enrollment.

### Migration note

Users upgrading from v0.29.7 or earlier will see BOTH `/Applications/Clawdmeter.app` (legacy) and `/Applications/Continuum.app` (new) after dragging the new DMG into Applications. They're the same app — the new DMG's `INSTALL.txt` tells users to drag the legacy `Clawdmeter.app` to the Trash. Data and pairing carry over automatically (bundle identifier is unchanged).

### Changed

- **`apple/project.yml`** — ClawdmeterMac target: `PRODUCT_NAME: Continuum`. iOS + Watch targets stay on PRODUCT_NAME = Clawdmeter (iOS / Watch home-screen names already update via CFBundleDisplayName; no on-screen file path to rename there).
- **`tools/build-mac-dmg.sh`** — `APP_NAME = "Continuum"` so the .app folder lookup, xcarchive path (`Continuum.xcarchive`), and DMG verification all line up. The standalone `DISPLAY_NAME` variable introduced in v0.29.7 is gone — APP_NAME does both jobs now.
- **`INSTALL.txt` inside the DMG** — adds a migration step telling users to trash the legacy Clawdmeter.app.

Bumps `MARKETING_VERSION` 0.29.7 -> 0.29.8, `CURRENT_PROJECT_VERSION` 146 -> 147.

## [0.29.7 build 146] - 2026-05-26 - Continuum display-only rebrand + v0.29.6 DMG launch fix (`rebrand/continuum-display-name`)

Two things in one ship:

**Rebrand (Phase 1: display-only).** The app is now called **Continuum** in every user-visible surface — menu bar, Dock, Finder, App Switcher, Window title, the in-app About panel, copyright, microphone/speech privacy strings, the DMG filename and the volume name it mounts as. The bundle identifier (`com.clawdmeter.mac`), PRODUCT_NAME (`Clawdmeter`), on-disk data path (`~/Library/Application Support/Clawdmeter/`), App Group, and keychain-access-group prefix all stay where they are. No data migration; existing installs upgrade in place; paired iPhones remain paired. Phase 2 (full bundle-id transition to `com.montaukanalytics.continuum.*`, signing identity transfer to the new Apple Developer Program team under `accounts@montaukanalytics.xyz`, and notarization of the DMG) lands when the new team enrollment is active.

**DMG launch fix (critical).** v0.29.6 shipped a DMG that wouldn't launch on a clean install with "Launchd job spawn failed" (error 163). Root cause was in the helper re-sign step I added in v0.29.4: the outer-app re-sign passed entitlements verbatim, so the `$(AppIdentifierPrefix)` macro stayed literal in the signed entitlements blob — Gatekeeper rejected the unexpanded keychain-access-group token and launchd refused to spawn. The same step also added `--options runtime` to the outer app, forcing hardened runtime onto the main binary which xcodebuild had signed without it (library validation can then refuse to load bundled Swift dylibs). Fixed in `tools/build-mac-dmg.sh` by extracting the team id from the outer codesign descriptor, expanding the macro into a temp entitlements file via `sed`, and dropping `--options runtime` from the outer call so only the external helpers (`Vendor/opencode/opencode`, `Vendor/uv/uv`) carry the runtime flag.

### Changed

- **CFBundleDisplayName = "Continuum"** on the Mac + iOS Info.plists. CFBundleName / PRODUCT_NAME stay as `Clawdmeter` so bundle paths don't drift.
- **DMG filename + mounted volume name** are now `Continuum-x.y.z-arm64.dmg` and `Continuum`. `INSTALL.txt` calls out that the .app on disk is still named `Clawdmeter.app` (internal name) so users don't think they grabbed the wrong package.
- **Visible Swift strings** rewritten: dashboard window title, agent-server start-failure alert, in-app update CTA copy, "Continuum Support" diagnostics bundle folder, iOS privacy footer copy, iOS / Watch widget titles, Watch navigation title.
- **Copyright** updated to `© 2026 Continuum (Montauk Analytics).`

### Fixed

- **v0.29.6 DMG won't launch** — see DMG launch fix above. Fully re-signed bundle now passes `codesign --verify --deep --strict` and launches cleanly on a fresh `/Applications` install.

### Known limitations

- The XProtect "Apple could not verify '.bbb…dylib' is free of malware" popup is unchanged; killing that requires notarization, which requires the paid Apple Developer Program enrollment under `accounts@montaukanalytics.xyz`. Tracked separately.
- GitHub repository name stays at `darshanbathija/Clawdmeter` for now. UpdateNotifier still hits `releases/latest` on that repo, so existing in-app update chip keeps working through the transition.

Bumps `MARKETING_VERSION` 0.29.6 -> 0.29.7, `CURRENT_PROJECT_VERSION` 145 -> 146.

## [0.29.6 build 145] - 2026-05-25 - Consolidated UI ship fixes (`darshanbathija/conductor-ui-research-v1`)

Consolidates the client-local UI rollout and closes the ship-blocking notification, export, provider-default, and diagnostics issues found during review.

### Added

- **Command and shortcut primitives** - adds shared command, shortcut, path-link, toast, repo identity, attention, and session presentation primitives used by Mac and iOS UI surfaces.
- **Mac workbench affordances** - adds command palette, shortcut sheet, file picker entry points, composer history/saved prompts, transcript/file actions, diff review state, PR/check/TODO actions, terminal assist, diagnostics, What’s New, and session export surfaces.
- **iOS parity affordances** - adds long-press session actions, notification/DND preferences, code/session state badges, path/action surfaces, and matching presentation-state behavior.

### Changed

- **Provider defaults stay live in Chat V2** - Mac Chat V2 refreshes provider defaults and reapplies them when defaults or catalog data change.
- **OpenRouter via OpenCode uses the current request shape** - OpenCode sends nested OpenRouter provider/model payloads with variant preserved.
- **Diff and export behavior are safer** - diffs are no longer truncated for review, and exported presentation state is scoped to the selected session instead of dumping global local state.
- **Notification routing honors local presentation state** - Mac and iOS notification delivery now respects DND, event mute, session mute, batching, chime, and sensitive-preview settings.

### Fixed

- **Support bundle privacy** - support bundles redact prompt/body/message fields in visible diagnostics and audit copies, normalize symlinked audit paths, and omit raw app logs by default.
- **iOS DND retries** - app-level DND now acks suppressed notification events before system authorization checks so background refresh does not keep refetching the same events.
- **Settings miswire** - `Notify at 90%` is shown as unavailable again until quota-alert dispatch is actually connected.
- **PR test fixtures** - PRCoordinator tests include the checks payload required by the current PR summary shape.

### Verification

- `swift test --package-path apple/ClawdmeterShared` -> **745 tests passed, 3 skipped**.
- `swift test --package-path tools/tmux-cc-probe` -> **19 tests passed**.
- `xcodebuild test -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" ... -only-testing:ClawdmeterMacTests/DiagnosticsSupportBundleTests -only-testing:ClawdmeterMacTests/SessionExportBundleWriterTests CODE_SIGNING_ALLOWED=NO` -> **3 tests passed**.
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` -> **passed**.
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (iOS)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO` -> **passed**.
- `git diff --check origin/main...HEAD && git diff --check origin/main && git diff --check` -> **passed**.
- `codex review` -> **no P1s after fixes; final P2s were fixed before commit**.

Bumps `MARKETING_VERSION` 0.29.5 -> 0.29.6, `CURRENT_PROJECT_VERSION` 144 -> 145.

## [0.29.5 build 144] - 2026-05-25 - Session lifecycle control plane (`darshanbathija/code-sessions`)

Code and Chat sessions now expose a unified lifecycle snapshot that paired clients can fetch or subscribe to without reverse-engineering status strings, transcript markers, or provider-specific runtime details.

### Added

- **Lifecycle wire v19** - adds `SessionLifecycleSnapshot`, phase/capability/evidence DTOs, `GET /sessions/:id/lifecycle`, and the `lifecycle-subscribe` WebSocket op while keeping `AgentSession.status` as the older-client compatibility field.
- **Lifecycle reducer** - derives plan approval, checkpoint, PR, runtime, and provider-action state into one stable snapshot surface for Mac and paired clients.
- **Lifecycle notifications** - invalidates lifecycle subscribers when plan text/approval or checkpoint state changes, with semantic WebSocket dedupe that includes evidence and checkpoint state.

### Fixed

- **Non-tmux runtime phases** - classifies Codex SDK, OpenCode, Cursor, and Antigravity runtime sessions without leaving them stuck in spawning-only lifecycle state.
- **Plan sequence updates** - advances registry event sequence on plan text and approval mutations so paired lifecycle subscribers receive the change.
- **Wire v19 merge compatibility** - preserves the provider-defaults v19 gates from `main` alongside lifecycle v19 gates.

### Verification

- `swift test --package-path apple/ClawdmeterShared --filter 'SessionLifecycleWireTests|WireV11Tests|WireV19ProviderDefaultsTests'` -> **19 tests passed**.
- `xcodebuild test -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" -destination "platform=macOS,arch=arm64" -only-testing:ClawdmeterMacTests/SessionLifecycleReducerTests -only-testing:ClawdmeterMacTests/AgentControlServerChatRouteTests/test_lifecycleRouteAndClientReturnSnapshot -only-testing:ClawdmeterMacTests/WorkbenchStateTests/test_recordCheckpointInvalidatesLifecycleSubscribers CODE_SIGNING_ALLOWED=NO CLAWDMETER_SKIP_BUNDLED_NODE=1 CLAWDMETER_SKIP_BUNDLED_UV=1` -> **9 tests passed**.
- `git diff --check && git diff --cached --check` -> **passed**.

Bumps `MARKETING_VERSION` 0.29.4 -> 0.29.5, `CURRENT_PROJECT_VERSION` 143 -> 144.

## [0.29.4 build 143] - 2026-05-25 - Sandbox triage + composer + chat UI papercuts (`fix/claude-auth-cli-applescript`)

Eleven cuts in the v0.29.3 shipped DMG, fixed together. Four sandbox-related (Claude auth button, Cursor model picker, XProtect dialog, missing Homebrew CLI lookup) plus six chat-surface papercuts (Codex legend color, Code-tab command flood, hover auto-expand, thinking-time precision + anchor, context-window ring) plus the Cursor model id parser.

### Fixed

- **Claude Code "Auth via CLI" button works in shipped DMGs** - the Settings -> Providers -> Claude Code "Auth via CLI" / "Sign in" buttons have been silent no-ops since v0.29.2. They drive Terminal via `NSAppleScript`, but the Release entitlements file didn't include the apple-events automation entitlement, so the sandbox rejected the bridge and the swallowed error left the user looking at a button that did nothing. Adds `com.apple.security.automation.apple-events` and a `temporary-exception.apple-events` scoped to `com.apple.Terminal`. macOS prompts the user once for automation permission on first click. If the user denies it (or runs an older build without the entitlement) the AppleScript failure now copies the install / login command to the clipboard and shows an alert offering to open Terminal manually — no more silent no-ops. Your existing Claude Code auth wasn't actually broken; the button only matters for first-time auth, re-auth after token expiry, or installing the CLI on a fresh machine.

- **Settings -> Cursor model chooser populates again** - cursor-agent's `~/.local/bin/cursor-agent` is a symlink into `~/.local/share/cursor-agent/versions/<rev>/cursor-agent`. The Release sandbox only had a read-only exception for `~/.local/bin/`, not for the symlink's real target, so the kernel denied execution of the real binary and `CursorModelProbe` got nothing back. Settings -> Providers -> Cursor then showed only the "Auto" fallback row with no other models to pick. Adds `~/.local/share/cursor-agent/` to the read-only sandbox exceptions so `cursor-agent --list-models` runs and the live catalog (Composer 2, Codex 5.3, Codex 5.2 variants, etc.) shows up in the dropdown again.

- **New session works for Homebrew-installed codex/claude/cursor** - the new-session dialog reported "Agent CLI not found on PATH: codex" and blocked the Start button for any user who installed the codex CLI via Homebrew (`/opt/homebrew/bin/codex`) or Intel Homebrew (`/usr/local/bin/codex`). The Release sandbox only granted home-relative exceptions, so `FileManager.isExecutableFile` couldn't even stat the Homebrew prefixes, let alone exec the binaries. Adds `com.apple.security.temporary-exception.files.absolute-path.read-only` entries for `/opt/homebrew/` and `/usr/local/` so `ShellRunner.locateBinary` finds Homebrew-installed agents on both Apple Silicon and Intel Macs.

- **No more "Apple could not verify '.bbb…dylib'" dialog while using Codex** - the bundled `Vendor/opencode/opencode` (and `Vendor/uv/uv`) helpers ship ad-hoc signed (TeamIdentifier=not set, `flags=0x20002`). When opencode spawns the Bun runtime, Bun extracts hashed native modules like `.bbb6ffeffdf6fffd-00000000.dylib` to TMPDIR and dlopens them. On macOS Tahoe, XProtect refuses to clear the dlopen without a trust chain on the loader process and pops the malware-verification dialog mid-Codex-poll. The DMG build script now re-signs both helpers with our Apple Development identity, the hardened runtime turned on, and `com.apple.security.cs.disable-library-validation` set so Bun's intentionally-unsigned runtime dylibs still load. Helpers gain a trust chain, XProtect goes quiet, Bun keeps working — verified by inspecting the re-signed binaries' codesign output (`TeamIdentifier=76S62SDSD3`, `flags=0x10000(runtime)`).

- **Cursor model chooser actually populates with usable model ids** - even after the sandbox fix above let `cursor-agent --list-models` run, the parser was returning every entry with the full text line as its id (`"composer-2.5 - Composer 2.5 Fast (default)"`) because cursor-agent's current output format is `<id> - <Display Name>` and the parser only knew how to split on double-space / tab. Picking any model from the menu would then send the literal labelled string back to the CLI, which obviously fails. Parser now strips everything after the first ` - ` so the id is just `composer-2.5-fast` and the display name is recomputed cleanly. Verified against a 115-line snapshot of `cursor-agent --list-models` covering Composer 2 / 2.5, GPT-5.1 → 5.5 Codex variants, and Claude Opus 4.7 / Sonnet 4.6 thinking variants.

- **Analytics legend matches the chart bars again** - the Codex chip in the "ANALYTICS · Claude · Codex · Antigravity · OpenCode · Cursor" legend at the top of the Usage tab rendered as a dark gray square even though the Codex bars in the stacked spend chart use OpenAI's bright blue. The chip's `LinearGradient` was `glow → base` (both low-chroma blue-gray) while the bars use `halo → glow` (full-saturation blue at top). Same colors per provider now — the chip visually keys the bar above it.

- **Code tab no longer floods the transcript with individual exec_command rows** - a long agent burst (e.g. 50 sed/rg/cat probes from one assistant turn) previously rendered as 50 individual `> exec_command` rows in the Code tab transcript. The `ChatItemBuilder` already groups consecutive tool calls into one `ChatItem.toolRun`, and the Chat tab already wraps that in a "Ran N commands" disclosure — but the Code tab's `SessionWorkspaceView` was iterating `otherPairs` directly into a `VStack` and skipping the wrapper. Routing the bucket through `toolRunGroup` so 50 commands collapse to one "Ran 50 commands ›" pill that the user can expand if they actually want to read each one.

- **Edited-file disclosures stay closed until clicked** - the `EditDiffRow` chat row had a deliberate "hover to peek the diff" affordance: an `onHover` modifier flipped a state flag that the disclosure binding OR'd with the explicit-click state, so passing the cursor over an edited-file row would auto-open the inline diff. Users reported this as disorienting — scrolling through a long transcript made diffs flash open and closed as the pointer crossed each row. The hover affordance and its modifier are gone; the disclosure is now click-only.

- **Thinking-time pill stops flashing two decimal places** - the live activity indicator (`8.94s · thinking…`) shown above the composer was rendering elapsed seconds at `%.2f` precision while ticking ~10× per second. The hundredths digit changes faster than the eye can read, which felt twitchy. Now `%.1f`s on both Mac (`LiveSessionActivityIndicator`) and iOS (`iOSSessionActivityStrip`) so the digit settles every 100ms instead of every 10ms.

- **Thinking-time pill anchors to the turn, not the click** - the elapsed counter used to start from `lastEventAt` (most recent ANY event), so reopening a long-running session showed "0.0s · thinking…" and counted up from the click — totally disconnected from "how long has the model been working on this task". Adds `currentTurnStartedAt` to `ChatSnapshot` (timestamp of the most recent `.userText` message) and passes it through as `activityStartedAt`. The pill now shows total turn elapsed time as long as the agent is mid-turn; the existing `isActive` guard (no events for 30s) still hides the pill when the turn completes.

- **Context-window ring shows context, not the busiest plan cap** - the composer's right-side usage chip drew the ring fill from `max(contextFraction, sessionPct, weeklyPct)`, so a half-empty current-session context (33% of 1M) hid behind a 75%-full weekly bucket. The ring now reflects only `contextUsedTokens / contextLimitTokens` so a glance tells you how much room is left in the model's prompt. Plan caps still live in the popover, each on their own row.

Bumps `MARKETING_VERSION` 0.29.3 -> 0.29.4, `CURRENT_PROJECT_VERSION` 142 -> 143.

## [0.29.3 build 142] - 2026-05-25 - Provider defaults and model selectors (`darshanbathija/provider-models`)

Provider model and effort choices are now durable per vendor, with OpenRouter and Cursor treated as first-class default rows in Settings and as richer model picker surfaces in Chat.

### Added

- **Provider defaults store** - adds a shared `ProviderDefaultsStore` keyed by `ChatVendor`, persisted under `clawdmeter.providerDefaults.*`, with migration from the older Chat V2 per-vendor model and effort keys.
- **Paired defaults API** - adds wire v19 support for `GET /provider-defaults` and `PUT /provider-defaults/:vendor`, including older-Mac fallback behavior and local persistence on paired clients.
- **Settings defaults controls** - adds `Default model` and `Default effort` controls to Settings -> Providers, renames the OpenCode row to `OpenRouter via OpenCode`, and uses live OpenRouter and Cursor model catalogs where available.
- **Chat selector panels** - replaces cramped Chat V2 vendor chips with searchable Mac and iOS selector panels that show model names, raw ids, context windows, availability, badges, recommendation copy, and effort controls.

### Fixed

- **New-session default propagation** - applies provider defaults before catalog fallback for new Chat V2 solo/broadcast sessions, Mac new Code sessions, and iOS new sessions while leaving existing running sessions unchanged.
- **OpenRouter effort support** - clears unsupported OpenRouter efforts based on model metadata and maps supported effort through the OpenCode/OpenRouter request body shape.
- **Cursor effort handling** - renders Cursor effort as disabled Auto unless future model probe data reports explicit effort support.
- **Selector layout resilience** - bounds long OpenRouter/Cursor model names on Mac and iOS so provider chips and picker rows remain readable within Tahoe spacing.

### Verification

- `swift test --package-path apple/ClawdmeterShared --scratch-path /tmp/clawdmeter-shared-ship-test --disable-automatic-resolution` -> **732 tests passed, 3 skipped**.
- Focused Mac tests for `SessionLauncherModelTests`, `OpencodeSendTests`, and `WireV14ContractTests` -> **31 tests passed**.
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` -> **BUILD SUCCEEDED**.
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (iOS)" -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO` -> **BUILD SUCCEEDED**.
- Independent engineering verifier -> **no blocking issues**.
- Independent Tahoe design critique -> **98/100 pass**.

Bumps `MARKETING_VERSION` 0.29.2 -> 0.29.3, `CURRENT_PROJECT_VERSION` 141 -> 142.

## [0.29.2 build 141] - 2026-05-25 - Chat polish and session scrolling fixes (`darshanbathija/chat-polish-bugfixes`)

The Code and iOS session views now stay pinned to the latest message when a session opens, scroll smoothly through long transcripts, and show the model/effort metadata the selected session is actually using.

### Fixed

- **Session activity chrome** - collapses duplicate thinking/activity surfaces, removes the idle iOS activity strip, and shows elapsed thinking time with two decimal places while work is active.
- **Latest-message stickiness** - remounts center threads per selected session and keeps Mac/iOS transcript panes pinned to the newest message without jumpy auto-scroll while the user is reading history.
- **Long iOS transcript scrolling** - renders full iOS chat snapshots through `LazyVStack`, adds a smooth Latest button, and keeps the DEBUG scroll performance probe available for long-session validation.
- **Selected model and effort** - resolves session model metadata from runtime bindings, persisted session fields, or provider defaults, and preselects the same model/effort in the bound composer.
- **Duplicate project sections** - canonicalizes repo display names across Mac and shared project list renderers so duplicate visible projects collapse into one sidebar section while preserving sessions and recents.
- **OpenCode security quarantine** - moves runtime temp/cache paths into app-controlled directories and strips quarantine attributes around OpenCode spawn/auth probes to avoid repeated macOS security prompts.
- **Claude Code auth CTA** - replaces docs-only copy with an Auth via CLI button that opens Terminal to install/expose Claude Code and run `claude /login`.

### Verification

- `swift test --package-path apple/ClawdmeterShared` -> **724 tests passed, 1 skipped**.
- `swift test --package-path tools/tmux-cc-probe` -> **19 tests passed**.
- Focused Mac `SessionSidebarGrouperTests` -> **7 tests passed**.
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` -> **BUILD SUCCEEDED**.
- XcodeBuildMCP iPhone 17 Pro simulator build + launch for `Clawdmeter (iOS)` -> **SUCCEEDED**.
- Long iOS transcript scroll probe fixture (4,000 rows) -> **p50 16.67ms, p95 16.67ms, p99 16.67ms, avg 59.6 fps**.

Bumps `MARKETING_VERSION` 0.29.1 -> 0.29.2, `CURRENT_PROJECT_VERSION` 140 -> 141.

## [0.29.1 build 140] - 2026-05-25 - Chat vendor and model picker unification (`darshanbathija/chat-tab-fixes`)

Chat V2 now has one broadcast-style composer. One selected vendor starts a single-vendor chat; two or three selected vendors create a Frontier broadcast with one child per vendor.

### Added

- **Shared chat vendor selection** - adds `ChatVendor` / `ChatVendorSelection` state with per-vendor model and effort picks, defaulting cold launch to ChatGPT `gpt-5.5` with high effort.
- **Vendor picker coverage** - adds visible ChatGPT, Claude, Antigravity, Cursor, and OpenRouter vendor chips on Mac and iOS, capped at 1-3 selected vendors.
- **Provider model catalogs** - wires Claude family picks, Cursor model discovery, and OpenRouter model discovery through the shared `/models` catalog.
- **HTTP-level route coverage** - adds AgentControlServer tests for solo `/chat-sessions`, one-slot `/chat-sessions/frontier` rejection, Cursor availability success/failure, OpenRouter route metadata, and live route smoke gates.

### Fixed

- **Solo/Broadcast split** - removes the visible Solo/Broadcast toggle from Chat V2 surfaces; selected vendor count now determines solo versus Frontier behavior.
- **Cursor chat route** - Cursor chat creation no longer returns `cursor_chat_not_supported`; it creates Cursor-backed chat sessions and avoids unsupported plan mode until a real Cursor resume id exists.
- **OpenRouter runtime metadata** - OpenRouter chats execute through OpenCode while persisting `billingProvider = openrouter`, the OpenRouter model id, and visible `chatVendor = openrouter` metadata.
- **Provider availability gates** - unavailable Cursor/OpenRouter vendors remain visible but fail closed with route-level 503 reasons instead of silently falling through to another provider.
- **PTY process cleanup** - PTY master/slave ownership is now idempotent, fixing the live OpenRouter route crash caused by double-closing file descriptors.

### Verification

- `swift test` in `apple/ClawdmeterShared` -> **722 tests passed, 1 skipped**.
- Focused Mac tests for Chat V2 store, AgentControl server routes, Cursor argv, and OpenRouter auth/model plumbing -> **52 tests passed, 2 live-gated skipped**.
- Live provider route smoke with `.context/run-live-provider-route-tests` -> **2 tests passed** (Cursor create, OpenRouter create + send).
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (iOS)" -destination "generic/platform=iOS Simulator"` -> **BUILD SUCCEEDED**.

Bumps `MARKETING_VERSION` 0.29.0 -> 0.29.1, `CURRENT_PROJECT_VERSION` 139 -> 140.

## [0.29.0 build 139] - 2026-05-24 — Desktop Code tab Conductor parity (`darshanbathija/conductor-parity`)

The desktop Code tab now behaves like a real workbench instead of a read-only session viewer. Agents can be launched and resumed from a denser composer, queued while running, reviewed through Plan/Diff/PR/Browser/Terminal panes, protected by checkpoints, and organized through Conductor-style status buckets.

### Added

- **Production Code workbench shell** — adds the Mac Code shell, launch model, persistent workbench state, and session/workspace right-pane memory so the Code tab can preserve repo context, density, selected pane, queued sends, PR cache, and run profiles across sessions.
- **Run/Preview loop** — adds real local run process management, stdout/stderr capture, localhost URL detection, URL health checks, auto-preview loading, run controls, and browser-context prompts generated from command-clicked page elements.
- **Safety checkpoints and restore UX** — adds checkpoint creation before prompt sends, plan approval, queued sends, diff destructive actions, and PR merge, with restore previews that show the target ref, safety ref, diff stat, patch preview, dirty tracked state, untracked sidecar files, and explicit restore confirmation.
- **Conductor-style sidebar buckets** — adds Active, In Review, Done, and Archived grouping with status chips, counts, collapsible groups, review-state classification, activity pulse treatment, overflow fade polish, and richer session-row actions.
- **PR/check/run workbench plumbing** — adds local command runners, PR coordination, PR review/merge controls backed by daemon or local state, and code-shell integration rather than placeholder UI.
- **Tool and edit-diff presentation models** — adds structured tool presentation and capped edit-diff previews so transcript rows can show meaningful changed-file context without overwhelming the chat.

### Changed

- **Composer and first-run UX** — tightens the desktop composer, adds quick-start prompt chips, improves reconnect/empty states, and moves workspace switching into a focused overlay palette with keyboard affordances.
- **Session transcript rendering** — improves tool rows, bash output, edit-diff rows, and plan/diff handoffs so Chat stays readable while Plan/Diff/PR/Terminal remain dense enough for real coding work.
- **Status and session filters** — adds the shared `inReview` status filter and updates Sessions v2 expectations for the full desktop bucket model.

### Fixed

- **Queue while running** — prompts sent while a session is running are now retained as editable queued work instead of being dropped or pretending to send immediately.
- **Destructive-action safety** — diff revert/delete, PR merge, prompt send, queued send, and plan approval now fail closed if a safety checkpoint cannot be created.
- **Read-only resume recovery** — resumed transcript sends now recover the original prompt and attachments into the promoted live session if the safety checkpoint or send path fails before delivery.
- **Run/Preview E2E confidence** — tests now cover real local HTTP process startup, detected URL health, browser context prompt generation, and the WKWebView command-click bridge payload.

Bumps `MARKETING_VERSION` 0.28.0 → 0.29.0, `CURRENT_PROJECT_VERSION` 138 → 139.

## [0.28.0 build 138] - 2026-05-24 — Live Cursor usage source + sandbox/path fix for CLI discovery (`feat/cursor-source`)

The Cursor tile on the Usage tab now shows REAL billing-period usage and reset time from `api2.cursor.sh`, instead of the static `Cursor Auto 0%` placeholder PR #96 shipped. Plus the sandbox/path issue that hid Cursor from the Chat/Code composer agent picker is fixed — `cursor-agent` is now discoverable from the sandboxed Release build.

### Added — full live CursorSource (mirrors CodexSource/AntigravitySource)

- **`CursorTokenProvider`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/CursorTokenProvider.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/CursorTokenProvider.swift)) reads `cursor-access-token` and `cursor-refresh-token` from the macOS Keychain via `SecItemCopyMatching`. `cursor-agent login` stores both items as generic-password entries in the user's login keychain with a permissive ACL, so the sandboxed Continuum can read them after a one-time "Always Allow" prompt. 5-minute in-memory cache TTL matches cursor-agent's own refresh cadence. `refreshIfNeeded()` drops the cache and re-reads — we don't call Cursor's refresh endpoint ourselves, trusting cursor-agent's own background rotation to update the on-disk copy.
- **`CursorSource`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/CursorSource.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/CursorSource.swift)) POSTs a gRPC-Web framed empty request to `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` with the keychain JWT bearer. Parses the proto response (hand-rolled `CursorProtoReader`, fileprivate) to extract:
  - `field 2` — billing-period end (unix epoch ms) → `sessionEpoch` + `resetMins`.
  - `field 5` — included usage count (e.g. 200 for Free) → `organizationID` plan badge ("200 included / period").
  - `field 7` — percent-used summary string ("You've used 12% of your included usage") → parsed via regex → `sessionPct`. Cursor returns the percent server-side as a pre-formatted string; we extract the integer.
  - Mirrors `sessionPct` / `sessionResetMins` into the weekly bucket so the Usage tile's Weekly row reads the same value instead of zero (Cursor only exposes one billing window).
- **`CursorSourceTests`** (5 cases) pins the parser against `Fixtures/cursor-GetCurrentPeriodUsage.bin` — a real free-tier capture saved during Phase 1 of this ship. Covers the happy path, trailer-only error responses, totally-empty bodies, past-billing-period clamping, and gRPC-Web frame unwrapping. CI catches Cursor backend schema drift here instead of letting the Usage tile silently flap to 0%.
- **`ProviderConfig.cursor`** added to `ProviderConfig.swift` — `id: "cursor"`, `displayName: "Cursor"`, `logoAssetName: "CursorLogo"`, no `reviveModel` (Cursor's monthly billing period doesn't fit AutoReviver's perpetual-5h-window model), `hasWeeklyWindow: false`.
- **`AppRuntime.cursorModel`** added as a sibling to `claudeModel` / `codexModel` / `geminiModel`. Wired through `start()` so the poller fires on the same 60s cadence as the others.
- **`MacTahoeAdapter.tahoeLive.cursor`** now calls `tahoeRow(model: cursorModel, provider: .cursor)` — the same code path Claude/Codex/Antigravity use. The static `Cursor Auto 0%` placeholder is gone.

### Fixed — sandbox/path discovery for CLI binaries (PR #96 follow-up)

- **`ShellRunner.locateBinary`** ([apple/ClawdmeterMac/AgentControl/ShellRunner.swift](apple/ClawdmeterMac/AgentControl/ShellRunner.swift):272) now uses `ClawdmeterRealHome.path()` (getpwuid) instead of `FileManager.default.homeDirectoryForCurrentUser.path`. Inside the sandboxed Release build, the previous path resolved to `~/Library/Containers/com.clawdmeter.mac/Data/.local/bin/` (empty) instead of the user's actual `~/.local/bin/` — so `cursor-agent` (and `claude`, and any other user-installed CLI) were unfindable. Same fix pattern v0.26.2/v0.26.3 applied to CodexTokenProvider / GeminiTokenProvider / CodexSource. The follow-up unblocks PR #96's Cursor agent picker, which was correct code but never had a discoverable binary in Release.
- **`ClawdmeterMac-Release.entitlements`** adds two more read-only `temporary-exception.files.home-relative-path.read-only` paths:
  - `/.local/bin/` — for `ShellRunner.locateBinary` to read cursor-agent + future CLI siblings.
  - `/.cursor/` — for future work that reads `~/.cursor/cli-config.json` (plan auth metadata, IDE state). The Keychain reads go through `Security.framework` and don't need a filesystem entitlement, but adding `/.cursor/` now avoids a future entitlement re-shuffle.

### Known limitations

- **Token rotation:** we don't call Cursor's `/refresh` endpoint ourselves. When the access token JWT expires (~7 day life), `CursorSource` will surface `.unauthenticated` until `cursor-agent` itself rotates the keychain entry (cursor-agent runs a background refresh loop, but only when invoked). If the tile reads 0% for many days, run `cursor-agent status` once to nudge the refresh.
- **Free-tier capture only:** the fixture is from a Free-tier account that has 0% usage in the current period, so the percent-extraction path is exercised against `"You've used 0% of your included usage"`. A future Pro-tier capture with non-zero usage should be added to broaden parser coverage.
- **Schema drift risk:** Cursor ships weekly+, and the reverse-engineered field numbers (1/2/5/7) could change. `CursorSourceTests` catches drift in CI, but you're the on-call for re-capturing the fixture when the wire format moves.
- **First-launch keychain prompt:** the very first time CursorSource polls in a freshly-installed Continuum build, macOS may surface a "Continuum wants to use confidential information stored in the keychain" dialog. Click Always Allow once — subsequent reads are silent.

### TOS posture

`api2.cursor.sh/aiserver.v1.DashboardService/*` is the same internal Connect-protocol surface cursor-agent itself uses. We hit it with the user's own JWT, do only `Get*` reads (no mutations), and surface counts the user can already see in `cursor.com/dashboard`. Same risk class as Codex against `chatgpt.com/backend-api/wham/usage` and Antigravity against `cloudcode-pa.googleapis.com`.

Bumps `MARKETING_VERSION` 0.27.1 → 0.28.0, `CURRENT_PROJECT_VERSION` 137 → 138.

## [0.27.1 build 137] - 2026-05-24 - Cursor provider sessions (`darshanbathija/cursor-cli-sdk`)

Adds Cursor as a first-class provider for Code sessions while keeping the launch semantics tied to the user's own Cursor subscription and authenticated Cursor Agent CLI.

### Added

- **Cursor Code sessions on Mac** - starts new Cursor coding sessions through the Cursor Agent CLI, preferring `cursor-agent` and falling back to `agent`, with `--workspace <repoPath>` and `--model <cursorModelId>` when a concrete Cursor model is selected.
- **Cursor resume support** - resumes only when Continuum has a real Cursor chat/session id and passes it through `--resume <cursorChatId>`. Cursor approval, respawn, and model-swap paths now require that proven resume id instead of silently starting a fresh session.
- **iOS-to-Mac Cursor start/resume** - iOS exposes Cursor in provider pickers and sends start/resume requests to the paired Mac; the Mac owns the actual Cursor CLI launch in the repo/worktree.
- **Dynamic Cursor model catalog** - probes authenticated Cursor CLI model visibility, caches account-visible models, includes Cursor default / Auto as the fallback, and stores the chosen model on the Continuum session/runtime binding.
- **Cursor usage and Tahoe wiring** - Cursor now appears in provider labels, picker styling, analytics totals, live/session surfaces, and Tahoe provider mappings.
- **Cursor transcript mirror** - Cursor CLI sessions do not expose a Claude/Codex JSONL, so the daemon mirrors sent prompts and terminal snapshots into the main chat until native Cursor transcript import can attach a proven Cursor chat id.

### Fixed

- **Unsupported plan mode is fail-closed** - Cursor new Code sessions no longer enter a fake plan mode. The Mac and daemon reject `planMode=true` Cursor starts with `cursor_plan_mode_not_supported`, and Mac/iOS plan controls are gated where Cursor cannot safely resume.
- **Preflight before provisional worktrees** - local Mac Cursor starts now verify the CLI binary, auth state, and selected model before creating a worktree.
- **Spawn cleanup** - failed local and daemon Cursor spawns release provisional worktrees and generated city names.
- **Imported Cursor model honesty** - imported Cursor IDE sessions preserve a discovered model only when it can be proven; otherwise the UI reports Cursor default / Auto.

### Verification

- `xcodebuild test -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" -destination "platform=macOS" -only-testing:ClawdmeterMacTests/AgentSpawnerChatArgvTests` -> **TEST SUCCEEDED** (10 tests).
- `swift test` in `apple/ClawdmeterShared` -> **700 tests passed, 3 skipped**.
- `xcodebuild build -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (iOS)" -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"` -> **BUILD SUCCEEDED**.
- `git diff --check` -> clean.

## [0.27.0 build 136] - 2026-05-24 — Strip Design tab + Open Design integration (`strip/design-tab`)

The Design tab has been removed across every surface so it can be designed and built fresh from scratch. The current implementation didn't work in practice — the bundled Open Design Node daemon ate ~80 MB of the DMG, the WKWebView never reliably loaded, the Tailscale-forwarded iOS proxy broke whenever the daemon restarted, and the Code↔Design handoff opened blank screens.

This is a deliberately large, surgical removal — **breaking** for anyone who depended on the Design surface or the `/design/import-folder` daemon route. The pairing wire protocol drops `designPort` + `designToken` but stays backward-compatible (older Mac builds emit them; the new iOS parser silently ignores unknown query params).

### Removed (pure-Design, 4696 files / ~1M lines gone)

- **`apple/ClawdmeterMac/Tahoe/MacDesignView.swift`** — WKWebView wrapper, ColdStartCard, ErrorCard. Whole file.
- **`apple/ClawdmeteriOS/Tahoe/IOSDesignView.swift`** — iOS UIViewRepresentable + DesignPortForwarder consumer. Whole file.
- **`apple/ClawdmeterMac/AgentControl/OpenDesignDaemonManager.swift`** — daemon lifecycle, file-lock, Keychain OD_API_TOKEN, bridge port atomics, derivedDesignToken HKDF. Whole file.
- **`apple/ClawdmeterMac/AgentControl/DesignPortForwarder.swift`** — TCP byte-pump for iOS access over Tailscale, token validation, ?token= query stripping, Set-Cookie injection. Whole file.
- **`apple/ClawdmeterMac/Resources/Vendor/open-design/`** — entire bundled Node 102 daemon + Next.js web export + node_modules + clawdmeter-bridge plugin + sidecar packages. ~80 MB on disk, ~32 MB tracked.
- **`tools/build-bundled-open-design.sh`** — pnpm build + stage + per-file codesign of `.node` natives.
- **`tools/clawdmeter-bridge-host/`** — Node sidecar that minted desktop-import-tokens + proxied to `/api/import/folder`.
- **`tools/clawdmeter-open-design-plugin/`** — the in-Design "Open in Code" bridge plugin source.
- **`apple/ClawdmeterMacTests/DesignPortForwarderTests.swift`** + **`OpenDesignDaemonManagerTests.swift`** — the tests for the deleted code.

### Removed (surgical edits to surviving files)

- **`apple/ClawdmeterMac/Tahoe/MacRootView.swift`** — Tab enum drops `.design`. Switch-case routing to `MacDesignView`, `clawdmeterDidOpenInDesign` notification handler, `clawdmeterSwitchTab` `.design` branch, titlebar Design chip, `designHealthColor(for:)` and `designChipText(for:)` helpers, and the `TahoeDashTab("Design", …)` row in the tab strip all gone.
- **`apple/ClawdmeterMac/AppRuntime.swift`** — `openDesignDaemon` property, `openFolderInDesign(baseDir:)` method, `clawdmeterDidOpenInDesign` + `clawdmeterDesignBridgeUnavailable` Notification names, design-bridge atomic plumbing and eager `ensureRunning()` call all stripped.
- **`apple/ClawdmeterMac/AgentControl/AgentControlServer.swift`** — `attachDesignBridge(bridgePortProvider:bridgeAuthTokenProvider:)`, the `designBridgePortProvider` + `designBridgeAuthTokenProvider` instance properties, the `POST /design/import-folder` route registration, the `handlePostDesignImportFolder(...)` handler, and the `isSafeDesignImportBase(_:)` allow-list helper all removed.
- **`apple/ClawdmeterMac/AppDelegate.swift`** — the File menu "Open Folder in Design…" item (`installFileMenuExtensions()` + `openFolderInDesignAction()`) gone.
- **`apple/ClawdmeterMac/PairingSettingsView.swift`** + **`PairingQRPopoverContent.swift`** — the `&dp=` / `&dt=` query-param appenders on the pairing URL builders (both `copyPairingURL()` and the QR refresh path) stripped. The Mac no longer emits Design routing fields in pairing payloads.
- **`apple/ClawdmeteriOS/Tahoe/IOSRootView.swift`** — Tab enum drops `.design`. Switch-case routing to `IOSDesignView`, the tab-bar row, and the related comments updated.
- **`apple/ClawdmeteriOS/Tahoe/IOSPairingView.swift`** — `client.setDesignPairing(...)` call after persisting the pairing tokens removed.
- **`apple/ClawdmeteriOS/PairingScannerView.swift`** — `dp` + `dt` query-param parsing in `parse(urlString:)` stripped. Unknown params keep being ignored, so older Mac QR URLs that still emit them keep pairing fine — they just don't populate Design routing values (there are no Design routing values anymore).
- **`apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/Protocol.swift`** — `PairingChallenge.designPort` + `designToken` properties and their CodingKeys removed. `decodeIfPresent` keeps backward compat for older Mac emitters; new init signature is `init(host:port:wsPort:token:useHTTPS:)`.
- **`apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AgentControlClient.swift`** — `designPortKey` + `designTokenKey` UserDefaults keys, `designPort` + `designToken` accessors, `setDesignPairing(designPort:designToken:)` method, and the Design keys in `clearPairing()`'s wipe loop all stripped.
- **`apple/project.yml`** — the `Resources/Vendor/open-design/**` source-scan exclusion (no longer needed; the dir is gone) and the `Build bundled Open Design (if missing or stale)` preBuildScript both removed.

### Verification

- `xcodebuild -scheme "Clawdmeter (Mac)" -configuration Release build` → **BUILD SUCCEEDED**.
- `xcodebuild -scheme "Clawdmeter (iOS)" -configuration Release -destination "generic/platform=iOS" build` → green (next ship verification).
- `swift test` in `apple/ClawdmeterShared/` → **693 passed, 0 failed, 3 skipped** (skipped = integration probes that need a live language_server, unchanged by this PR).

### Compatibility notes

- **Pairing protocol is forward-compatible.** v0.27.0 iOS pairing scanners ignore the `dp` and `dt` query params if an older Mac (v0.26.x or earlier) emits them in the QR URL. v0.27.0 Macs simply stop emitting those params; v0.26.x iOS scanners decode the URL fine and silently skip the now-missing fields.
- **Wire protocol unchanged** — no `AgentControlWireVersion` bump. The `/design/import-folder` route returns 404 on a v0.27.0 daemon; older iOS builds that try to hit it will see the same 404. Code is the only path that needs the route, and we removed both ends.
- **No data migration needed.** UserDefaults `clawdmeter.sessions.designPort` and `clawdmeter.sessions.designToken` entries on existing iOS installs are now orphans — they sit untouched, take a few bytes, and are read by no one.

Bumps `MARKETING_VERSION` 0.26.6 → 0.27.0, `CURRENT_PROJECT_VERSION` 135 → 136.

## [0.26.6 build 135] - 2026-05-24 — Antigravity Tier-1 LS-local probe (framework + schema; sandbox-blocked discovery) (`fix/antigravity-ls-probe`)

The Antigravity card has read `0% / "resets in —"` for every user whose only Gemini surface is the Antigravity 2 desktop app — `AntigravitySource` Tier 2 (`cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`) requires `~/.gemini/oauth_creds.json`, which only `gemini auth login` from a terminal creates. Antigravity 2 signs in via the GUI without ever writing that file. The `AntigravitySource.poll()` had a `lsQuotaProbe` hook for a Tier-1 LS-local probe, but the production constructor in `AppRuntime.swift:149` left it defaulted to nil — Tier 1 was code that never ran.

This ship wires it.

### Added

- **`AntigravityLSQuotaProbe`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/AntigravityLSQuotaProbe.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/AntigravityLSQuotaProbe.swift)) — discovers the running Antigravity 2 `language_server` via the existing `AntigravityLSPClient.discover()` (uses `lsof -nP -iTCP -sTCP:LISTEN | grep language_`), calls `/exa.language_server_pb.LanguageServerService/GetUserStatus` with an empty body, decompresses the gzip-wrapped response, and walks the protobuf to extract:
  - `field 13.1.2` → plan name (`"Pro"`, `"Plus"`, …) — surfaced through the `organizationID` slot so the UI badge can read it.
  - `field 13.8` + `field 13.9` → daily messages used + remaining. Session% = `used / (used + remaining) * 100`.
  - `field 33.1.*.15.2.1` → daily reset epoch (drills into the first repeated model entry under the field-33 wrapper that carries a `ModelUsage` submessage).
- **Schema is reverse-engineered** from a live Antigravity 2.0.6 LSP — no `.proto` file is published. The capture rig is `AntigravityLSQuotaProbeIntegrationTests`; run it with `CLAWDMETER_PROBE_LS=1 swift test --filter AntigravityLSQuotaProbeIntegrationTests` against a live Antigravity 2 install to re-derive the bytes when the schema changes.
- **`AntigravityLSQuotaProbeTests`** (4 cases) pins the parser against a captured `Fixtures/antigravity-GetUserStatus.bin`. CI catches a schema regression here instead of silently dropping the tile back to 0%. Covers the happy path, non-gzip passthrough, malformed-gzip rejection, and the "LSP responded but no quota" → nil → Tier-2-fallthrough branch.
- **Self-contained gzip decoder** (`AntigravityLSQuotaProbe.decompressIfGzip`) — Antigravity gzips responses even when we request `grpc-encoding: identity`. Strips the 10-byte gzip header (handling FEXTRA / FNAME / FCOMMENT / FHCRC variants), the 8-byte trailer, and feeds the bare deflate stream to libcompression's `COMPRESSION_ZLIB`.
- **`LSProtoReader`** — file-private minimal forward-only protobuf walker. Targets only the wire types this probe needs (varint, length-delimited, fixed32) plus a `findLengthDelimited(field:)` that can be called repeatedly to iterate over repeated submessages. Deliberately not a full proto runtime — keeping the maintenance surface to the four fields this probe reads.

### Changed

- **`AppRuntime.swift`** ([apple/ClawdmeterMac/AppRuntime.swift](apple/ClawdmeterMac/AppRuntime.swift):149) now passes `lsQuotaProbe: { await AntigravityLSQuotaProbe.probe() }` to the production `AntigravitySource`. When Antigravity 2 desktop is open, the tile reflects real `used / cap` daily quota with the actual reset countdown. When it isn't, the probe returns nil and Tier 2 (cloudcode-pa) takes over exactly as before.

### Known limitation — sandbox blocks port discovery

**The Antigravity tile still reads 0% / "resets in —" in this shipped build.** Verified post-install via the unified log:

```
[com.clawdmeter.shared:AntigravityLSQuotaProbe] AntigravityLSQuotaProbe: probe() called — attempting LSP discovery
[com.clawdmeter.shared:AntigravityLSQuotaProbe] AntigravityLSQuotaProbe: discover() returned nil — no running language_server (or lsof inaccessible in sandbox)
```

Root cause: `AntigravityLSPClient.discover()` spawns `/usr/sbin/lsof` via `Process()`. macOS App Sandbox blocks the execution of binaries outside the app bundle by default, and there's no clean `temporary-exception` entitlement that re-allows it (the only file-related ones permit *reading* the binary, not *executing* it). So `lsof` never runs and discovery returns nil even though the same `lsof` command from a shell finds the running `language_server` on port 54129.

Three viable follow-up paths, none of which fit in this ship's scope:

1. **Bundle a copy of `lsof` inside `Contents/Resources/`** — sandboxed apps can exec binaries inside their own bundle. ~5 MB binary footprint, signature management overhead.
2. **Port-scanning fallback in Swift** — iterate the ephemeral range (49152–65535) attempting an HTTPS handshake + CSRF scrape on each. Slow (~10–30s per poll) but no entitlement work.
3. **Disable sandbox in Release** — restores discovery but also re-opens the bundled-Node RCE surface the v0.26.2 entitlements ship was designed to keep contained. Hard "no" without a separate threat-model review.

This ship lands the **framework** so the next iteration just has to replace the discovery primitive:

### Notes

- **TOS posture**: the LSP is an internal Google interface (`exa.language_server_pb.*`). We accept the same risk class as `CodexSource` against `chatgpt.com/backend-api/wham/usage`. The probe is strictly read-only — no method we call mutates LSP state.
- **The schema may shift**. Antigravity 2 ships major updates on a monthly cadence; if the LSP renumbers or removes a field, the probe returns nil and the tile cleanly falls back to Tier 2 / Tier 3 instead of crashing. The fixture test pins the field numbers explicitly so CI catches the drift.
- **Why ship this at all**: the protobuf reverse-engineering (4 candidate gRPC method names trialed against a live LSP, 8 sibling services scanned for usage-related verbs, schema decoded down to the `field 15.2.1` resets_at level) is the hard part. Pinning it to a fixture in CI means the next person to address sandbox-discovery doesn't repeat that work.

Bumps `MARKETING_VERSION` 0.26.5 → 0.26.6, `CURRENT_PROJECT_VERSION` 134 → 135.

## [0.26.5 build 134] - 2026-05-24 — Hotfix: drop macOS-only gate on ClawdmeterRealHome so iOS target builds (`fix/clawdmeter-real-home-ios-compat`)

v0.26.4 shipped the Mac DMG cleanly but the iOS target failed to archive: `UsageHistoryLoader.swift:60: error: cannot find 'ClawdmeterRealHome' in scope`. `UsageHistoryLoader` is in the Shared module so the iOS target compiles it, but `ClawdmeterRealHome.swift` was wrapped in `#if os(macOS)`. iOS users on this version couldn't get a new build at all.

### Fixed

- **`ClawdmeterRealHome.swift`** drops the `#if os(macOS)` gate. `getpwuid` is POSIX and ships on every Darwin platform — on iOS/watchOS it returns the app container home (same value `NSHomeDirectory()` would have returned), which is exactly what we want there (no sandbox container to bypass on iOS, since every iOS app is sandboxed by definition and the user's "real home" isn't a meaningful concept on a phone).

Bumps `MARKETING_VERSION` 0.26.4 → 0.26.5, `CURRENT_PROJECT_VERSION` 133 → 134.

## [0.26.4 build 133] - 2026-05-24 — Repo count + spend chart wired through ClawdmeterRealHome; suppress libopentui Gatekeeper popup (`fix/usage-tab-completeness`)

After v0.26.2 unblocked the Codex provider tile, the Usage tab still showed three regressions: `0 repos tracked` in the top status bar, an empty `SPEND OVER TIME` chart, and an empty `SPEND BY REPO` panel — even though `~/.claude/projects/` had 112 entries and `~/.codex/sessions/` had hundreds of rollouts on disk. Root cause: two more sandbox-blind call sites that v0.26.2 missed.

`RepoIndex.refresh` and `UsageHistoryLoader.performLoad` are the only feeders for those three surfaces, and both built their roots from `FileManager.default.homeDirectoryForCurrentUser` / `NSHomeDirectory()` — APIs that resolve to the sandbox container in Release. So they enumerated `~/Library/Containers/com.clawdmeter.mac/Data/.claude/projects/` and `…/.codex/sessions/`, found nothing, and silently returned empty arrays. The v0.26.2 entitlements granted access to `/.codex/` and `/.gemini/` but path resolution still pointed at the container, and `/.claude/` wasn't on the entitlement list at all.

### Changed

- **`RepoIndex.refresh`** ([apple/ClawdmeterMac/AgentControl/RepoIndex.swift](apple/ClawdmeterMac/AgentControl/RepoIndex.swift):110) now derives its `home` from `ClawdmeterRealHome.url()` instead of `homeDirectoryForCurrentUser`. The "X repos tracked" status pill reflects every `~/.claude/projects/<cwd>/` directory + every `~/.codex/sessions/**/*.jsonl` cwd again.
- **`UsageHistoryLoader.init`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryLoader.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryLoader.swift):54) same swap — `home` is now `ClawdmeterRealHome.url()` instead of `NSHomeDirectory()`. Re-enables SPEND OVER TIME + SPEND BY REPO across Claude, Codex, and Antigravity data.
- **`ClawdmeterMac-Release.entitlements`** adds two more read-only sandbox exceptions:
  - `/.claude/` — Anthropic CLI's `projects/` jsonls (the v0.26.2 entitlement list covered `/.codex/`, `/.gemini/`, `/.local/share/opencode/`, and `/Library/Application Support/Antigravity/` but missed Anthropic entirely because Claude itself had been working — turns out *only* via the `PastedAnthropicTokenProvider` keychain path, while `RepoIndex` and `UsageHistoryLoader` silently lost Claude data).
  - `/Library/Application Support/Clawdmeter/` — Continuum's own pre-sandbox sessions.json + workspaces.json. Users who ran an earlier non-sandboxed build have 90+ tracked sessions in the real path; the new sandboxed app now reads them instead of starting fresh in the container.

- **`apple/ClawdmeterMac/Info.plist`** sets `LSFileQuarantineEnabled = false`. The bundled `Contents/Resources/Vendor/opencode/opencode` is a Bun single-file executable that extracts an ad-hoc-signed `libopentui.dylib` to the app's sandbox tmp dir on every launch (under a content-hashed name like `.bbb6fbfdedbffead-00000000.dylib`). With the default LaunchServices behavior, macOS auto-stamps `com.apple.quarantine: 0086;<ts>;Clawdmeter;` on that file; opencode then dlopens it and Gatekeeper trips with "Apple could not verify '.bbb6fbfdedbffead-00000000.dylib' is free of malware" — fired on every Code-tab session start. Opting out of LSQuarantine is the standard fix for apps that host their own trusted bundled runtime (browsers, IDEs, language runtimes all do this); the app itself stays sandboxed so blast radius is unchanged.

### Known limitation

The Antigravity tile still reads 0% when (a) the Antigravity 2 desktop app isn't running AND (b) `~/.gemini/oauth_creds.json` doesn't exist. `AntigravitySource.poll()` ships with an `lsQuotaProbe` hook for the Tier-1 LS-local probe (queries the running language_server on a loopback port), but `AppRuntime.swift:149` constructs `AntigravitySource(tokenProvider:)` with the probe defaulted to nil. Wiring the probe needs a pgrep/lsof discovery pass + an HTTPS-over-loopback client — substantial enough to deserve its own ship. Until then, open Antigravity 2 once after auth to seed `~/.gemini/oauth_creds.json`, or run `gemini auth login` from a terminal.

Bumps `MARKETING_VERSION` 0.26.3 → 0.26.4, `CURRENT_PROJECT_VERSION` 132 → 133.

## [0.26.3 build 132] - 2026-05-24 — Code V2 follow-ups: cross-platform Watch build, app-scoped outbox, composer routing, test isolation (`darshanbathija/code-v3`)

Seven tidy-ups against the v0.26.0 Code V2 ship that surfaced in post-merge review. The first five close the "next session would hit this" risks the user flagged after the initial Code V2 merge; the last two were caught by an adversarial review pass and are the more dangerous of the bunch — both pre-existed v0.26.0 but became user-visible in this build because the new composer routing made the outbox the main delivery path.

### Fixed

- **`MobileCommandOutbox` retry deadlock** ([apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift:230-245](apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift)): the prior `deliver()` held the envelope key in `inflight` via a `defer` block until after `reschedule()` returned, but `reschedule` called `schedule(current)` mid-flight which early-returned because the key was still in `inflight`. Net: offline sends silently stuck in `.queued` with no automatic retry. Pre-existed v0.26.0, but became user-visible in this build because composer routing made the outbox the main delivery path for the user's main flow. Fix: clear `inflight` + `retryTasks` before the retry path, not in defer.
- **Per-WindowGroup-scene outbox on iPad** ([apple/ClawdmeteriOS/ClawdmeteriOSApp.swift](apple/ClawdmeteriOS/ClawdmeteriOSApp.swift)): the v0.26.0 hoist landed at `IOSRootView`, but `WindowGroup` creates a fresh `IOSRootView` per scene, so iPad multi-window opens N parallel outboxes, each loads `outbox.json` fresh into memory, each `persist()` rewrites disk from in-memory state — cross-window enqueues race + the later write drops the earlier window's commands. Real hoist: `@StateObject MobileCommandOutbox` lives on `ClawdmeteriOSApp` (process scope), threaded through `ContentView` → `IOSRootView` → `IOSSessionDetailView` as `@ObservedObject`. `AgentControlClient` also hoisted to App scope so the outbox dispatches through one stable client and multi-window iPad doesn't open N parallel WS connections to the daemon.
- **watchOS build failure in `PermissionPromptCard`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Chat/Views/PermissionPromptCard.swift:153-161](apple/ClawdmeterShared/Sources/ClawdmeterShared/Chat/Views/PermissionPromptCard.swift)): the shared card referenced `Color(uiColor: .secondarySystemBackground)` inside `#if os(iOS)` but had no fallback for watchOS. The card is rendered in the watch's plan-approval flow, so the Watch target broke at the embedded-binary copy step in CI. Added a `#elseif os(watchOS)` branch using `Color(white: 0.11)` (matches the dark glass aesthetic the watch already uses).
- **watchOS build failure in `AntigravityUsageParser`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/AntigravityUsageParser.swift:89](apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/AntigravityUsageParser.swift)): the SQLite-backed `AntigravityDBUsageParser` is only available on macOS and iOS (the watchOS SDK ships no SQLite3 module). The caller branch on `pathExtension == "db"` is now gated by `#if os(macOS) || os(iOS)` with a byte-estimator fallback on watchOS so the parser still produces a non-zero record when the conversation is db-only.
- **`OpencodeAuthFileTests.test_removeProvider_idempotentWhenMissing` test isolation** ([apple/ClawdmeterMac/AgentControl/OpencodeAuthFile.swift](apple/ClawdmeterMac/AgentControl/OpencodeAuthFile.swift)): `migrateLegacyEntriesIfNeeded` read from `NSHomeDirectory()` directly, which under XDG_DATA_HOME-scoped test runs pulled in the real user's `~/.local/share/opencode/auth.json` (when present) and clobbered the test fixture. Skips migration when `XDG_DATA_HOME` is set — production paths still see it, test runs are now self-contained. Belt-and-braces against the test ordering flake noted in the v0.26.0 review.

### Changed

- **`MobileCommandOutbox` truly process-wide** ([apple/ClawdmeteriOS/ClawdmeteriOSApp.swift](apple/ClawdmeteriOS/ClawdmeteriOSApp.swift), [ContentView.swift](apple/ClawdmeteriOS/ContentView.swift), [IOSRootView.swift](apple/ClawdmeteriOS/Tahoe/IOSRootView.swift)): the outbox + `AgentControlClient` are now created at App scope and observed down through every window/scene. One outbox owns the queue for the whole process; pending/failed envelopes survive session navigation; multi-window iPad sees one consistent queue.
- **iOS composer send / refine / approve-plan now route through the outbox** ([apple/ClawdmeteriOS/Tahoe/IOSSessionDetailView.swift](apple/ClawdmeteriOS/Tahoe/IOSSessionDetailView.swift)): the three highest-traffic write paths used to call `agentClient.sendPrompt` / `agentClient.approvePlan` directly, so offline sends were silently dropped and the new `iOSOutboxPane` was effectively dead UI for the user's main flow. All three now use `outbox.enqueueSend(sessionId:text:asFollowUp:)` / `outbox.enqueueApprovePlan(sessionId:)`. Composer text clears immediately on enqueue (optimistic UI); if the dispatch fails, the envelope shows up in the outbox pane with swipe Retry / Cancel — the same contract every other write path already had. Removed the dead `sending` state that the v0.26.0 routing left behind; added an `approving` rapid-tap guard on the Approve button (2s hold-time so the daemon's respawn + WS push that flips `hasRealPlan` lands before the guard re-arms).

### Documentation

- **`CLAUDE.md` synced with v0.26.0 architecture**: added Code V2 section covering wire v16 protocol bump, `WorkspaceStore` semantics, `MobileCommandOutbox` server-side actor + iOS retry queue, MagicDNS pairing preference + `clawdmeters://` scheme plumbing, and the six-tab `IOSSessionDetailView` workbench refactor (`SessionWorkbenchTab` enum + chip strip). Linked from the existing Sessions v1/v2 sections so a fresh Claude Code session bootstraps without re-reading the diff.
- **`README.md` updated with new daemon endpoints + iOS surfaces**: `GET /workspaces`, `PATCH /workspaces/:id`, the `clawdmeters://` URL scheme, the per-session outbox badge in iOS nav bar, and the conditional-visibility rules for the six workbench tabs.
- **`TODOS.md` Code V2 follow-up brief moved to "Completed v0.26.x"**: the four items I shipped (workspace store, outbox, MagicDNS, workbench tabs) plus the seven follow-ups in this build. Remaining open items (APNS-driven outbox flush, server-side TLS termination, workspace archive UI) stay in the "v0.6 / v1.0 deferrals" section.

Bumps `MARKETING_VERSION` 0.26.2 → 0.26.3, `CURRENT_PROJECT_VERSION` 131 → 132.

## [0.26.2 build 131] - 2026-05-24 — Sandbox read-only exceptions for provider state dirs (`fix/sandbox-readonly-exceptions`)

After v0.26.1, the menu-bar Usage tab still showed Codex / Antigravity / OpenCode at `0% / "resets in —"` even though Claude rendered fine. The Mac unified log surfaced repeated `[AppModel.codex] Re-auth required.` errors. Root cause: the Release build is sandboxed (deliberate, per the security comment in `ClawdmeterMac-Release.entitlements`), which means `NSHomeDirectory()` resolves to the app's container — *not* `/Users/<you>/`. Every provider source then tries to read `~/.codex/auth.json`, `~/.gemini/antigravity/conversations`, `~/.local/share/opencode/auth.json`, or the Antigravity 2 desktop app's data dir, finds nothing in the container, throws `.unauthenticated`, and never reaches the parser. Debug builds masked this because their sibling entitlements file has sandbox OFF; users who only ever launched the Debug-built `.app` from Xcode never saw the bug.

The v0.23.5 OpenCode hotfix already supplies `clawdmeterRealUserHome()` (a `getpwuid` shim that returns the real home path), but the path resolution is only half of the problem — the sandbox kernel still blocks the read syscall when the resolved path is outside the container.

This ship adds narrow, **read-only** `com.apple.security.temporary-exception.files.home-relative-path.read-only` entitlements for exactly the four directories the provider polls need.

### Changed

- **`ClawdmeterMac-Release.entitlements`** ([apple/ClawdmeterMac/ClawdmeterMac-Release.entitlements](apple/ClawdmeterMac/ClawdmeterMac-Release.entitlements)) grants read-only sandbox exceptions for:
  - `~/.codex/` — Codex CLI auth bundle (`auth.json`), session rollouts (`sessions/*.jsonl` — the `rate_limits` source the v0.26.1 parser fix targets), `config.toml`, `projects/`.
  - `~/.gemini/` — Gemini CLI + Antigravity sidecar (`antigravity/conversations` SQLite DB, `config/projects`, `tmp/`).
  - `~/.local/share/opencode/` — OpenCode CLI auth + per-provider state (honors `XDG_DATA_HOME` if set; this is the default).
  - `~/Library/Application Support/Antigravity/` — Antigravity 2 desktop app's native conversation DB + `brain/`.
- **Containment scope preserved everywhere else.** ~/Documents, ~/Pictures, ~/Library/Mail, ~/Library/Messages, browser cookies, SSH keys, and the rest of the user home remain outside our blast radius — a worst-case RCE in our process (e.g. via a compromised bundled Node) can read these four provider state dirs but cannot exfil the user's mail, browser session, or shell credentials.
- **Read-only is enforced.** No write entitlement is granted; auth rotation, session writes, and SQLite mutations are all performed by the upstream CLIs in their own processes. RCE in Continuum can observe provider state but cannot plant trojan auth tokens or alter session history.

### Notes

- The previously documented trade-off (sandbox ON → Claude Keychain reads blocked → users must use `PastedAnthropicTokenProvider`) is unchanged. Pasted Anthropic tokens continue to work; this PR only opens read access to the *other* providers' state dirs.
- v0.26.1's `CodexSource` parser fix (skip null-primary shutdown markers + walk recent rollouts) was correct and remains intact; it just couldn't help while the sandbox blocked the read entirely. Together with this PR, the full Codex path is now exercised.

Bumps `MARKETING_VERSION` 0.26.1 → 0.26.2, `CURRENT_PROJECT_VERSION` 130 → 131.

## [0.26.1 build 130] - 2026-05-24 — Codex JSONL parser ignores CLI shutdown markers (`fix/codex-null-rate-limits`)

After installing v0.26.0, the menu-bar Codex tab dropped to `5h session 0% / resets in —` and `Weekly 0% / resets in —` even though earlier rollouts in `~/.codex/sessions` still recorded the user's real usage (96% session, 54% weekly). Root cause: Codex CLI 0.132 started emitting an extra `rate_limits` event at the end of every session with `limit_id: "premium"`, `primary: null`, and `secondary: null` — a credits-only marker that carries no usage data. The previous parser took the textually-last `rate_limits` line in the rollout, which meant the shutdown marker clobbered the real `limit_id: "codex"` event that came moments earlier.

### Fixed

- **`CodexSource.parseLatestUsage`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/CodexSource.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/CodexSource.swift)) now skips JSONL lines whose `payload.rate_limits.primary` is null or missing and keeps the latest line that actually carries usage data. The parsing logic moved to a new static `parseUsageFromJSONLBytes(_:sourceName:now:)` so it can be exercised by unit tests without filesystem fixtures.
- **`CodexSource.poll` JSONL fallback** now walks up to 8 recent rollouts (via the new `recentSessionFiles(limit:)` helper) instead of only the freshest one. If the newest file is entirely shutdown markers, the parser drops back to the next-newest rollout and surfaces real usage from there. The previous "most-recent-mtime-only" rule lost data whenever the freshest session was a short shell that wrote one null event and exited.
- **Distinct contract-violation messages** for the two empty cases: "rate_limits events but all primary buckets are null" (shutdown-marker-only file) vs. "no rate_limits entries yet" (brand-new session that hasn't yet hit the model). Makes the macOS unified log usable for diagnosing whether the issue is "CLI never reported" or "CLI reported, but we filtered the line out".

### Added

- **`CodexSourceJSONLNullRateLimitsTests`** (5 cases): pins the bug with a real two-event fixture (codex usage → premium null marker → expect 96% session / 54% weekly), an interleaved variant, the all-null and no-rate_limits contract-violation paths, and a single-event happy-path sanity check.
- **`CodexSource.recentSessionFiles(limit:)`**: `internal` helper that returns the N most-recently-modified jsonl files sorted DESC. Open for tests + future Path 2 enhancements that need to walk the rollout history.

Bumps `MARKETING_VERSION` 0.26.0 → 0.26.1, `CURRENT_PROJECT_VERSION` 129 → 130.

## [0.26.0 build 129] - 2026-05-23 — Code V2 control plane + persisted workspaces + mobile command outbox + MagicDNS pairing + iOS workbench tabs (`darshanbathija/code-v2`)

Code V2 lands as one coordinated ship. The Mac daemon now owns durable workspace records keyed by canonical repo root, a real idempotency-key outbox that prevents iOS retries from double-sending, and a MagicDNS-first pairing flow that survives sleep/wake and Wi-Fi switching. iOS gets a six-tab workbench (Chat, Plan, Diff, PR, Terminal, Files) embedded inside session detail — the pane views existed before but weren't actually wired into the navigation. Wire protocol bumps v15 → v16; every change is additive so older Macs keep decoding via `decodeIfPresent`.

Persisted workspace store. New `WorkspaceStore` writes `~/Library/Application Support/Clawdmeter/workspaces.json` with atomic writes and a v1 schema. On first launch it migrates from existing `sessions.json` by grouping sessions by canonical repo root and seeding provider defaults from the newest session in each group. The daemon exposes `GET /workspaces` + `PATCH /workspaces/:id`. iOS new-session flow can inherit the per-repo defaults so the user doesn't re-pick the model and effort every time they spawn an agent in the same repo. 10 unit tests cover migration, upsert semantics, deterministic-UUID stability across launches, and concurrent write isolation.

Mobile command outbox with real receipt dedup. Server side: a bounded LRU (256 entries, 24h TTL) of idempotency-key → response receipts. Every write endpoint (send, approve-plan, interrupt, change-model, change-effort, change-mode, autopilot, pick-winner, create-pr, merge) routes through a `tryReplayIdempotent` / `sendCommandResponse` wrapper. A retried request with the same key replays the cached response instead of re-executing the side effect — no double-send, no double-merge. Receipts persist via a new `mobile-commands.jsonl` audit stream that the outbox replays on startup, so a daemon restart still dedups in-flight retries. iOS side: a `MobileCommandOutbox` ObservableObject with persistent queue (`outbox.json`) and exp backoff `[1s, 4s, 15s, 60s, 5min, 30min]` for delivery. Failed envelopes surface in a new `iOSOutboxPane` with swipe Retry / Cancel and a per-session badge in the session detail nav bar.

MagicDNS/TLS pairing preference. `TailscaleHost.resolve()` reordered so MagicDNS hostnames come first when `clawdmeter.pairing.preferMagicDNS` is on (default true). The pairing QR survives IP changes — no more re-scanning after sleep/wake. Settings → Pairing gains two toggles: "Prefer MagicDNS host in pairing QR" and "Use TLS for pairing (advanced)". With TLS preferred + MagicDNS host present, the QR emits `clawdmeters://` scheme; iOS `PairingScannerView` accepts both schemes and persists a `useHTTPS` flag on `PairingChallenge`. Server-side TLS termination is explicitly deferred — daemon still listens on plain HTTP today; the scheme + iOS flag are forward-compat plumbing for when `tailscale cert` wiring ships separately.

Full iOS workbench tabs. `IOSSessionDetailView` refactored from a single ScrollView into a chip-strip tab bar above content. Six tabs — Chat (custom thread + composer), Plan (`iOSPlanTrackerView`), Diff (`iOSDiffView`), PR (`iOSPRPane`), Terminal (`iOSTerminalTabsView`), Files (`iOSArtifactsPane`). The pane views existed as standalone files but were never embedded; this ship wires them up. Tabs have conditional visibility (Plan only when a plan exists, Terminal only when panes are spawned, Files only when artifacts are present) and the last-selected tab persists per session in UserDefaults. `iOSPlanTrackerView` gained an `onApprove` callback so the parent routes through `AgentControlClient`.

Other fixes during review. iOS outbox dispatch was returning `true` unconditionally for `.interrupt`, `.approve`, `.setAutopilot` because the matching client methods were non-throwing `async -> Void` — offline failures were falsely acknowledged. Three client methods upgraded to `@discardableResult async -> Bool`. OpenCode and Codex SDK send paths were bypassing the idempotency record helper, meaning retries would re-execute the side effect; both now route through `sendCommandResponse` so dedup actually applies.

### Added

- **`WorkspaceStore`** ([apple/ClawdmeterMac/AgentControl/WorkspaceStore.swift](apple/ClawdmeterMac/AgentControl/WorkspaceStore.swift)): @MainActor file-backed registry of `CodeWorkspaceRecord` per canonical repo root. Atomic writes, one-shot migration from `sessions.json`, deterministic SHA-256 UUIDs for stable IDs across launches.
- **`MobileCommandOutbox` (Mac)** ([apple/ClawdmeterMac/AgentControl/MobileCommandOutbox.swift](apple/ClawdmeterMac/AgentControl/MobileCommandOutbox.swift)): server-side actor with bounded LRU cache + 24h TTL + audit-log replay. Wraps every write endpoint via `tryReplayIdempotent` + `sendCommandResponse` helpers.
- **`MobileCommandOutbox` (iOS)** ([apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift](apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift)): @MainActor queue with persistent `outbox.json`, exp backoff retry, per-kind dispatch through `AgentControlClient`.
- **`iOSOutboxPane`** ([apple/ClawdmeteriOS/Workspace/iOSOutboxPane.swift](apple/ClawdmeteriOS/Workspace/iOSOutboxPane.swift)): list view of pending + failed envelopes with swipe Retry / Cancel.
- **`SessionWorkbenchTab`** enum + tab strip in `IOSSessionDetailView`: chip row above content switching between 6 panes, last-selected tab persisted per session.
- **`AuditLog.recordMobileCommand`**: new JSONL stream at `~/.clawdmeter/audit/mobile-commands.jsonl` with hashed payload fingerprints (no PII).
- **`GET /workspaces` + `PATCH /workspaces/:id`**: new daemon endpoints; iOS reads via `AgentControlClient.listWorkspaces()` and `updateWorkspaceDefaults(workspaceId:defaults:)`.
- **`InterruptRequest`** + **`UpdateWorkspaceDefaultsRequest`** + **`WorkspaceListResponse`** in Protocol.swift.
- **`MobileCommandKind`** cases: `changeModel`, `changeEffort`, `changeMode`, `setAutopilot`, `pickWinner`, `updateWorkspace`.
- **`PairingChallenge.useHTTPS`**: optional flag indicating the pairing URL used the `clawdmeters://` TLS-preferred scheme.
- **`WorkspaceStoreTests`** (10 cases): round-trip, migration, upsert, idempotency, deterministic-UUID stability.
- **`AgentControlClient.createPR`** + **`merge`** + **`listWorkspaces`** + **`updateWorkspaceDefaults`**: typed write methods replacing ad-hoc URL building in iOS panes.

### Changed

- **`TailscaleHost.resolve()`** now prefers MagicDNS hostnames when `clawdmeter.pairing.preferMagicDNS` is true (default).
- **`PairingQRPopoverContent.pairingURLString()`** emits `clawdmeters://` scheme when `preferTLS` is on AND host is MagicDNS-resolved.
- **`PairingSettingsView`** gains a Connectivity section with two new toggles.
- **`PairingScannerView.parse`** accepts both `clawdmeter://` and `clawdmeters://`; the latter sets `PairingChallenge.useHTTPS = true`.
- **`AgentControlClient`** methods `interruptSession`, `setAutopilot`, `approvePlan` upgraded to `@discardableResult async -> Bool` so the outbox can detect offline failures.
- **`AgentControlServer.handleSendPrompt`** OpenCode + Codex SDK delegate paths now route through `sendCommandResponse` to record idempotency receipts.
- **`AgentControlServer.handleInterrupt`** / `handleApprovePlan` now accept an optional `InterruptRequest` body carrying the idempotency key.
- **Wire version** bumped 15 → 16. `workspacesMinimum = 16` and `mobileOutboxMinimum = 16` gate the new endpoints.
- **`MobileCommandReceipt`** gains a `jsonDictionary` helper for inlining receipts into ad-hoc JSON response bodies.
- **`IOSSessionDetailView`** refactored: composer + nav bar preserved, body switches across 6 panes via `SessionWorkbenchTab`.
- **`iOSPlanTrackerView`** gains `onApprove: (() async -> Void)?` callback.

### Fixed

- **iOS outbox falsely acknowledged offline interrupts / approvals / autopilot toggles** (`apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift:259, 263, 287`): `dispatch()` returned `true` for void client methods. Now reads `Bool` from the upgraded client signatures.
- **OpenCode + Codex SDK send paths bypassed idempotency record** (`apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:4467, 4611`): retries would re-execute the side effect. Threaded `idempotencyKey` + `payloadHash` through and wired success paths through `sendCommandResponse`.

### Notes

- Originally targeted v0.24.0, but two parallel-worktree ships landed first: broadcast chat at v0.24.0 and the in-app update flow at v0.25.0. Rebumped to v0.26.0 + build 129 during the second merge to preserve linearity.

## [0.25.0 build 128] - 2026-05-23 — In-app update flow (GitHub Releases API checker) (`darshanbathija/in-app-update-flow`)

The Mac app now surfaces a small "Update X.Y.Z" chip in the titlebar when a newer release ships on GitHub. Click the chip to read the release notes inline and open the release page in Safari, where you download the new DMG and drag it into `/Applications` like before. No silent install in v0.25.0 — that's parked as a phase-2 Sparkle migration once a paid Apple Developer ID account is in play (see `TODOS.md`).

### Added

- **`UpdateCoordinator` + `UpdatesUI` + `GitHubReleaseConstants`** (`apple/ClawdmeterMac/Updates/`). The coordinator polls `https://api.github.com/repos/darshanbathija/Clawdmeter/releases/latest` once 8 seconds after launch + every 24 hours while running. Tag-pattern parsing is strict: `v<MAJOR>.<MINOR>.<PATCH>-mac` only, so experimental tags don't fire the chip until channel support exists. Version comparison is numeric, not lexicographic — `0.23.10 > 0.23.9` (the bug that lexicographic comparison would produce is locked out by a regression test).
- **Per-version dismissal cooldown.** Click "Later" and the chip stays hidden for 24 hours for that exact version. A newer version surfaces immediately (the cooldown is per-version, not blanket).
- **Translocation detection.** When Continuum is run directly from the DMG mount or `~/Downloads` (Gatekeeper translocates the bundle to a randomized `/private/var/folders/…` path), the chip turns yellow and reads "Move to Applications" — Sparkle and any in-place install would fail anyway, so we surface the actionable explanation instead of nagging the user with an update prompt they can't follow through on. Popover has a "Show in Finder" button so the user can drag the bundle to `/Applications` and reopen.
- **Manual `Check now` button** in the popover, debounced 5 seconds so rapid clicks don't burn the GitHub API rate-limit budget.
- **Debug feed-URL override.** `defaults write com.clawdmeter.mac ClawdmeterDebugReleasesURL "https://…"` points the coordinator at a static fixture URL — used by QA to test the chip against a feature-branch JSON without rebuilding the app.
- **20 unit tests** in `ClawdmeterMacTests/UpdateCoordinatorTests.swift` covering version comparison, tag parsing, dismissal cooldown (× 3), debug URL override, translocation detection, debounce, API errors, GitHub release decoding (× 2), `chipState` pure function (× 3), and the centralized URL constants (× 3). Mocked URLSession via a `URLProtocol` subclass — no network, runs in <1 second.

### Privacy

- The daily check sends your IP + a `Clawdmeter/<version>` User-Agent to `api.github.com`. No app version is sent in the request body, no unique identifier is collected. Equivalent to visiting the GitHub releases page once a day in Safari.

### Notes

- Originally targeted v0.24.0, but a parallel-worktree ship landed broadcast chat at v0.24.0 first. Rebumped to v0.25.0 + build 128 during the merge to preserve linearity.
- The original plan was Sparkle 2.x auto-update. Outside-voice review surfaced that Sparkle's silent-install value-add is conditional on notarization (Gatekeeper re-prompts on the freshly-installed un-notarized bundle anyway), and personal-team XPC + sandbox on macOS 26 is an unverified combination with a high probability of failure. We pivoted to the lightweight API checker so v0.25.0 ships now; the full Sparkle plan lives in `TODOS.md` for phase 2 when a paid Developer ID account is acquired.

Bumps `MARKETING_VERSION` 0.24.0 → 0.25.0, `CURRENT_PROJECT_VERSION` 127 → 128.

## [0.24.0 build 127] - 2026-05-23 — Broadcast Chat V3: side-by-side Claude / Codex / Antigravity (`darshanbathija/chat-v3`)

Chat tab gets a broadcast mode. Pick 2-3 providers, send one prompt, see
the answers side-by-side with per-provider tokens and cost. Star the
better answer per turn. Continue from a winner to demote the broadcast
group to a Solo chat that keeps the winning transcript.

### Added

- **Broadcast comparison surface** — Mac dashboard now has a left history sidebar, mode toggle (Solo vs Broadcast), provider summary chips above the chat, and a horizontally-scrollable column-per-provider transcript. iOS gets a compact version: provider pills above the selected-reply card, swipe between providers. Both surfaces ship with the Tahoe glass aesthetic from the standalone Continuum redesign.
- **Frontier wire protocol** (`Protocol.swift`) — `CreateFrontierRequest` / `CreateFrontierResponse` / `FrontierGroupSnapshot` / `FrontierSendRequest` / `FrontierTurnWinner` and new endpoints `POST /chat-sessions/frontier`, `POST /chat-sessions/frontier/:groupId/send`, `POST /chat-sessions/frontier/:groupId/pick-winner`, `POST /chat-sessions/frontier/:groupId/turn-winner`, `POST /chat-sessions/frontier/:groupId/retry-slot`. WebSocket subscription op `frontier-subscribe` streams live per-child turn state on a 100ms debounce.
- **Per-turn winner metadata** — non-destructive star markings for each turn. Continue-from-winner is the destructive variant: archives losers and promotes the winner out of the Frontier group so follow-ups go through the regular `/sessions/:id/send` path.
- **Deep Research toggle** — creation-time setting that propagates to every child in a Frontier group (Codex sandbox flag and Claude system prompt).
- **`/chat-providers` gating** — surfaces per-provider availability so the broadcast mode picker can disable providers that aren't configured (e.g. Antigravity not running, Codex creds missing).

### Changed

- **Pre-landing review fixes** ([apple/ClawdmeterMac/AgentControl/AgentControlServer.swift](apple/ClawdmeterMac/AgentControl/AgentControlServer.swift), [apple/ClawdmeterMac/AgentControl/AgentSessionRegistry.swift](apple/ClawdmeterMac/AgentControl/AgentSessionRegistry.swift), [apple/ClawdmeterMac/Workspace/ChatV2/MacChatV2View.swift](apple/ClawdmeterMac/Workspace/ChatV2/MacChatV2View.swift), [apple/ClawdmeteriOS/Workspace/ChatV2/IOSChatV2View.swift](apple/ClawdmeteriOS/Workspace/ChatV2/IOSChatV2View.swift)):
  - **Continue-from-winner actually leaves broadcast** — server now clears the winner's `frontierGroupId`/`frontierChildIndex` so the sidebar treats it as a regular Solo chat. UIs flip `openTarget` to `.solo(winner.id)` on the callback. `frontierGroupChildren(includeArchived:)` defaults to live-only so Frontier send fan-out + the WebSocket snapshot can never hit archived losers.
  - **Broadcast first-send minimum** — `CreateFrontierResponse.hasMinimumBroadcast` (≥ 2 successful spawns) gates the broadcast surface. A single-success response surfaces every failed slot's `reason` instead of silently degrading to a one-agent "broadcast."
  - **Per-child attachments** — `FrontierSendRequest.perChildText` map lets each Frontier child reference its own daemon-side staging path. Same bytes uploaded once per child via `uploadAndBuildPerChildPrompts`; legacy `SendPromptRequest` shape still accepted for back-compat.
  - **Search/history hydration** — opening a search hit for a Frontier group that has < 2 live children (e.g. after pick-winner archived the losers) now reopens the matched session as Solo instead of a read-only transcript.
- **OpenCode legacy auth merge restored** ([apple/ClawdmeterMac/AgentControl/OpencodeAuthFile.swift](apple/ClawdmeterMac/AgentControl/OpencodeAuthFile.swift)) — `migrateLegacyEntriesIfNeeded` no longer bails when the canonical file exists. It reads canonical, merges any legacy provider entries that canonical was missing, and writes back. Malformed canonical files are still left untouched so users with salvageable bytes don't lose them.

### Fixed (adversarial review)

- **Mid-fan-out archive race** — Frontier send fan-out now re-checks `archivedAt` immediately before each per-child send. A concurrent `/pick-winner` archiving a loser during another child's `await` can no longer let the prompt leak to the just-archived loser.
- **Double-tap continue button** — both Mac `ProviderColumn` and iOS `FrontierTranscript` gate the continue-from-winner button with a `continuing` state, so a fast double-tap can't fire two `/pick-winner` POSTs (the second would 404 against the already-promoted winner).

### Test coverage

- 11 new unit tests: 4 in `WireV9Tests` (broadcast minimum + per-child round-trip), 1 in `OpencodeAuthFileTests` (canonical preservation across migration probe), 6 in new `AgentSessionRegistryFrontierTests` (frontierGroupChildren archived filter + clearFrontierGroupBinding).
- Total: 643 ClawdmeterShared tests pass, 190 Mac tests pass.

## [0.23.11 build 126] - 2026-05-23 — Real Antigravity token counts from .db step_payload + Keychain SDK key reader + LSP gRPC client (`darshanbathija/usage-page-edits`)

Antigravity analytics went from $0.026/day (a 60×-too-low estimate) to real per-turn token counts. PR #70 had landed the right pricing for `gemini-3.5-flash` but the loader was ignoring 45% of the desktop corpus (SQLite `.db` files), 100% of the agy CLI corpus, and the bytes-÷-4 token estimator was reading 175 KB of `*.md` instead of the actual 10.84 MB of conversation content nested in `.system_generated/messages/*.json` + `transcript.jsonl`. This PR closes every gap.

The dominant fix is reverse-engineered UsageMetadata extraction from `.db` step_payload BLOBs. Phase 0.5 had already proved those payloads are plaintext protobuf; this PR's `AntigravityDBUsageParser` walks the recursive proto structure looking for a strict signature (`f1>0, f2/f3 token-shaped varints, f6 in 1..1000`) and pulls real per-turn input/output/cached/reasoning/tool-use token counts. Validated against the user's real corpus: 22 records summing 371K input + 8K output + 662K cached for one 19-turn conversation. The byte-estimator stays as the fallback for `.pb` files (still encrypted) and for any .db where the signature doesn't match (future schema renumber).

SDK mode is unblocked. `AntigravityLSPClient` talks to the locally-running `language_server` process via gRPC over HTTP/2 with self-signed-cert TLS bypass and CSRF-token auth (the token rotates per LSP restart and is also embedded in the process argv as `--csrf_token`). `discover()` finds the listening port via `lsof`, `ping()` round-trips `HasAuthToken`, `getCascadeTrajectory(conversationID:)` fetches the live trajectory protobuf for an active cascade — same UsageMetadata shape inside.

`AntigravityKeychainKeys` exposes both Keychain items: the Electron Safe Storage 16-byte base64 key (used by the IDE shell for cookies/Local Storage) and the Gemini Safe Storage protobuf bundle (two 32-byte AES keys + active-key ID). The `.pb` decryption capability is ready to wire up; the encryption envelope itself isn't standard Electron safeStorage (no `v10` magic prefix), so reverse-engineering Google's wrapper format is documented as deferred — but the key is now accessible if someone wants to crank.

`tools/refresh-pricing.sh` now merges `tools/pricing-overrides.json` on top of the LiteLLM snapshot. Re-running the refresh no longer blows away `gemini-3.5-flash` / `gemini-3.1-pro` overrides when LiteLLM is still on stale provisional rates.

### Added

- **`AntigravityDBUsageParser`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/AntigravityDBUsageParser.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/AntigravityDBUsageParser.swift)): static SQLite reader + proto walker that extracts real `UsageMetadata` from `.db` step_payload BLOBs. Self-contained `ProtoReader`, strict signature match, fail-soft fallback when zero records found.
- **`AntigravityLSPClient`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AntigravityLSPClient.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AntigravityLSPClient.swift)): async gRPC client for `localhost:54765`. `discover()` via lsof, CSRF-token auth, TLS skip-verify (localhost-only), generic `unary(fullMethod:requestBody:)`, plus `ping()` and `getCascadeTrajectory(conversationID:)` conveniences.
- **`AntigravityKeychainKeys`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AntigravityKeychainKeys.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AntigravityKeychainKeys.swift)): reads both Antigravity-owned Keychain items. Parses the Gemini Safe Storage proto bundle into a typed `GeminiKeyBundle` with active-key resolution.
- **`tools/pricing-overrides.json`**: manual rate overrides applied on top of LiteLLM during `refresh-pricing.sh`. Currently carries the three Google I/O 2026 entries.
- **`gemini-3.1-pro`** in pricing.json: tiered rate card ($2/$12 ≤200K, $4/$18 >200K, $0.20/M cached).
- **`MODEL_PLACEHOLDER_M134 → gemini-3.1-pro`** in `AntigravityStateReader.knownModelTokens`.
- **iOS Analytics tab + Mac dashboard `By Repo` list** now show real Antigravity totals.

### Changed

- **Token estimator** (`ConversationProtoParser.estimatePlaintextTokens`): walks the brain dir recursively, counts `.md/.txt/.json/.jsonl/.log`, excludes `*.metadata.json` sidecars. Measured 10.84 MB total content where the old top-level `*.md`-only scan saw 175 KB.
- **`UsageHistoryLoader`** desktop walk: ingests both `.pb` (legacy) and `.db` (current) extensions, dedupes by UUID, prefers newer mtime. Adds the agy CLI corpus walk at `~/.gemini/antigravity-cli/conversations/`.
- **`AntigravityUsageParser.parse`**: routes `.db` files through `AntigravityDBUsageParser` for real token counts, falls back to byte-estimate on zero matches. `.pb` files always use the byte estimate. New `dedupPrefix` parameter (`antigravity` vs `agy`) prevents brain-UUID collision between surfaces.
- **`AntigravityLSPClient.discover()`**: portable lsof parser (the macOS `lsof -c <name>` flag matches the wrong process — we filter manually).
- **`tools/refresh-pricing.sh`**: merges manual overrides from `tools/pricing-overrides.json` so re-running doesn't clobber I/O 2026 rates.
- **`AnalyticsCache.currentVersion`**: bumped 9 → 11 in two phases (.md→all content recursive, then .db real-token-extraction). Forces a one-time cold reparse on first launch so users immediately see the corrected numbers.

### Fixed

- **Antigravity weekly $ figure**: the menubar/dashboard tooltip went from `$0.026/day` to plausible per-turn dollar amounts. Root cause was three independent bugs compounding (47% of desktop corpus invisible + 100% of CLI corpus invisible + estimator measuring wrong file types). PR #70 fixed the pricing; this PR makes the numbers it multiplies against trustworthy.
- **`MODEL_PLACEHOLDER_M134`** no longer falls through `Pricing.shared.cost` as unknown ($0). Frontier-Pro sessions now price at the correct I/O 2026 rates.
- **`refresh-pricing.sh`** no longer clobbers manual pricing entries. The override file is the audit trail with `_note` fields and a documented retirement policy.

### Tests

Suite went 635 → 672 (+37 new). New test files: `AntigravityDBUsageParserTests` (8 tests covering proto match, multi-record sum, signature rejection, garbage tolerance, SQLite WAL handling), `AntigravityLSPClientTests` (9 tests covering gRPC framing, varint encoding, live-LSP ping, real-trajectory fetch), `AntigravityKeychainKeysTests` (7 tests covering proto bundle parse, active-key lookup, case-insensitive hex). Extended `AgyConversationReaderTests`, `AntigravityStateReaderTests`, `ConversationProtoParserTests`, `PricingTests`, `UsageHistoryTests` with the new behaviors. Mac scheme builds clean; live LSP tests gracefully skip on CI / fresh machines.

### Deferred

`.pb` decryption format reverse-engineering, .db proto schema-stability monitor, gemini-3.1-pro-thinking variant, and SDK-mode wiring into the analytics loader. All documented in [TODOS.md](TODOS.md) under the new "Antigravity analytics — open follow-ups" section.

## [0.23.10 build 125] - 2026-05-23 — Unify Settings → Providers into a single 4-row card and add the OpenCode logo (`darshanbathija/providers-rows-and-opencode-logo`)

v0.23.9 collapsed each provider's chrome but left Codex SDK and Antigravity SDK in their own standalone `SettingsCard`s with separate titles, subtitles, and inline view bodies. That broke the visual rhythm with Claude Code + OpenCode, which sit as rows inside one Providers card. This pass inlines Codex SDK and Antigravity SDK as matching rows so all four providers share the same row shape: glyph + title + one-line status + single trailing toggle.

Also: the OpenCode logo asset was missing from every catalog in the repo. `AgentKindUI.assetName(for: .opencode)` returned `"OpencodeLogo"`, `TahoeProvider.opencode.logoAssetName` returned `"tahoe-opencode-mark"`, but neither asset existed — every OpenCode glyph in Settings, chat, and analytics rendered as a blank rounded tile. This PR adds the missing PNG to all three catalogs so the brand mark renders.

### Changed

- **Settings → Providers card** ([apple/ClawdmeterMac/Tahoe/MacSettingsView.swift](apple/ClawdmeterMac/Tahoe/MacSettingsView.swift)): now one card containing four rows — Claude Code, OpenCode, Codex SDK, Antigravity SDK — separated by `TahoeHair()`. Card subtitle simplified to "External agent runtimes Continuum can drive." The previous standalone "Codex SDK" and "Antigravity SDK" `SettingsCard`s are gone; their toggle logic + provisioning + error handling moved verbatim into new private `CodexSDKProviderRow` and `AntigravitySDKProviderRow` structs that match the row shape of `OpencodeProviderRow` / `ClaudeCLIProviderRow`.

### Added

- **OpenCode logo asset** at three locations: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/Tahoe.xcassets/tahoe-opencode-mark.imageset/` (drives `TahoeProviderGlyph` on every platform), `apple/ClawdmeteriOS/Assets.xcassets/OpencodeLogo.imageset/` (drives `ProviderBadgeImage` on iOS chat + analytics), `apple/ClawdmeterMac/Assets.xcassets/OpencodeLogo.imageset/` (drives `ProviderBadgeImage` on Mac analytics). Source PNG was cropped from a 2400×1350 export by detecting the fake-transparent checker pattern (opaque pixels at exact RGB `(19,16,16)` / `(37,33,33)`), converting them to true alpha=0, then auto-bounding-boxing to the actual mark and re-canvasing to 256×256 with 18% padding.

### Removed

- `apple/ClawdmeterMac/CodexSDKSettingsView.swift` and `apple/ClawdmeterMac/AntigravitySDKSettingsView.swift`. Their toggle bodies are now `CodexSDKProviderRow` / `AntigravitySDKProviderRow` inside `MacSettingsView.swift`. The underlying `CodexSDKManager` / `AntigravitySidecarManager` wiring is unchanged.

Bumps `MARKETING_VERSION` 0.23.9 → 0.23.10, `CURRENT_PROJECT_VERSION` 124 → 125. All 635 `ClawdmeterShared` tests pass; Mac scheme builds clean; new asset confirmed in compiled `Assets.car` via `xcrun assetutil --info`.

## [0.23.9 build 124] - 2026-05-23 — Collapse Settings → Providers chrome to one toggle per row (`darshanbathija/settings-toggle-cleanup`)

Settings → Providers was three rows of engineer-speak: status pills, mono auth-status lines, a 4-item Manage menu on OpenCode, a duplicate inline header + `@openai/codex-sdk` paragraph + Status grid (Mode / Provisioned / SDK version / Install path) + Open install folder / Wipe SDK install buttons + "How auth works" footer on Codex SDK, and the same shape plus a "What changes when SDK mode is on" / "What stays the same" bullet list on Antigravity SDK. Customer can't act on any of that — the actual question on every row is binary: on or off.

### Changed

- **OpenCode provider row** ([apple/ClawdmeterMac/Tahoe/MacSettingsView.swift](apple/ClawdmeterMac/Tahoe/MacSettingsView.swift)): collapses to title + one-line status + a single trailing control. Off-state (binary missing OR no key) shows an "Activate" button that reprobes for the CLI then opens the OpenRouter API key sheet. On-state (binary present AND ≥1 provider configured) shows a `TahoeToggleView` plus a small "Edit API key" button; toggling off calls `OpencodeAuthFile.removeProvider` for every entry, equivalent to a global sign-out.
- **Codex SDK card** ([apple/ClawdmeterMac/CodexSDKSettingsView.swift](apple/ClawdmeterMac/CodexSDKSettingsView.swift)): rewritten to a single `TahoeToggleView` with a customer-facing status line ("Streaming live. Token usage updates in real time." / "Off. Updates lag a couple of seconds behind the CLI."). Inline progress chip during provisioning + error chip on failure. Card subtitle in `MacSettingsView` updated from "Observation mode toggle + diagnostics for the Codex provider." to "Live token usage and reasoning for Codex sessions."
- **Antigravity SDK card** ([apple/ClawdmeterMac/AntigravitySDKSettingsView.swift](apple/ClawdmeterMac/AntigravitySDKSettingsView.swift)): same shape as Codex. Card subtitle updated from "Antigravity 2 native runtime — bundled IPC bridge + plan-mode hand-off." to "Live token usage and reasoning for Antigravity sessions."

### Removed

- OpenCode row: status pill, mono `Signed in: openrouter: ...` auth-status line, "Sign in with browser" small button, 4-item "Manage" menu (Add API key / Sign in with browser / Diagnostic / Sign out), bottom "Open docs" link, and the `OpencodeSetupSheet` wiring in this row. OAuth flows + diagnostic remain reachable via the API key sheet's provider picker and the upstream `opencode` CLI.
- Codex SDK card: duplicate inline title + `@openai/codex-sdk` engineering paragraph, "Enable SDK mode" / "disk-mode JSONL tail polling" wording, Status grid (Mode / Provisioned / SDK version / Install path), "Open install folder" + "Wipe SDK install" buttons, "How auth works" educational footer.
- Antigravity SDK card: duplicate inline title + sidecar/brain explainer, "SDK mode (recommended for paid Antigravity users)" toggle label, "What changes when SDK mode is on" bullet list naming internal agents, "What stays the same" bullet list naming `.gemini/antigravity/brain/<uuid>/` paths, `StatusPill` row showing the literal UserDefaults backing key.

Bumps `MARKETING_VERSION` 0.23.8 → 0.23.9, `CURRENT_PROJECT_VERSION` 123 → 124. Net diff: 212 insertions / 510 deletions across three Swift files. All 635 `ClawdmeterShared` tests pass; Mac scheme builds clean.

## [0.23.8 build 123] - 2026-05-23 — Refresh root README for current Continuum repo shape (`darshanbathija/rewrite-readme`)

### Changed

- **Root README now describes the current product and repository.** Reframes Continuum from the old Apple-only Claude/Codex meter into the current multi-surface agent control app: Mac Tahoe workbench, iPhone and Watch companions, Linux port, shared analytics, provider runtimes, Open Design, OpenCode, and tool sidecars.
- **Build and verification docs are current.** Documents the Apple and Linux build entry points, bundled runtime scripts, docs-only verification expectations, repo layout, provider integrations, and key runtime notes for tmux, OpenCode, Antigravity agentapi, Tailscale pairing, and sandboxed release builds.
- **Shared Linux builds keep using the compatibility shims.** Guards the remaining unconditional `OSLog` and `Combine` imports in shared AgentControl/Chat files so Linux CI can fall back to `LoggingCompat.swift` and `CombineCompat.swift`.

Bumps `MARKETING_VERSION` 0.23.7 → 0.23.8, `CURRENT_PROJECT_VERSION` 122 → 123.

## [0.23.7 build 122] - 2026-05-23 — Gemini chat unblock + Antigravity 2.0.6 ingestion polish (`fix/gemini-chat-binaryNotFound`)

Gemini chat sessions stopped working after v0.23 — every `POST /chat-sessions {"provider":"gemini"}` returned 500 with `LanguageServerClientError error 3`, which we initially misread as `binaryNotFound`. Root cause: Swift's `Error`→`NSError` bridging orders payload-carrying enum cases before payload-less ones, so error code 3 is actually `.malformedResponse(String)`. The agentapi response decoder was looking for `conversationId` at the top level or one level deep under `response`, but Antigravity 2.0.6 nests it at `response.newConversation.conversationId`. Verified by running a standalone `swift` script against the enum (`binaryNotFound -> code=5`, `malformedResponse -> code=3`) and by capturing real daemon stdout via wider error logging.

Then closed the v0.9.x ingestion gaps the now-unblocked send path surfaced: WAL stream never finished (state stuck at `.streaming`), step-type mapping was stale (Antigravity 2.0.0 used 8/9/13; 2.0.6 disperses tools across 5/7/8/9/21/132), and Gemini's natural-language replies live in `step_type=101` `[Message]` blocks that the parser ignored.

### Fixed

- **`LanguageServerClient.newConversation` decoder** ([apple/ClawdmeterMac/AgentControl/LanguageServerClient.swift](apple/ClawdmeterMac/AgentControl/LanguageServerClient.swift)) now accepts all three observed envelope shapes (top-level `conversationId`, `response.conversationId`, `response.newConversation.conversationId`). Phase 0 captured the wrong shape; live 2.0.6 stdout proved the nested layout. Chat session create now returns 201 with a populated `AgentSession`.
- **Error logging** at the catch site ([apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:1607](apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:1607)) uses `String(describing: error)` instead of `error.localizedDescription` so future Swift `Error` enum misdiagnoses surface the associated value (stdout preview, stderr, exit code) instead of just a case index. The lazy-URL workaround comment in `LanguageServerClient.swift` now records the real root cause so the next reader doesn't chase the same ghost.

### Added

- **`AntigravityChatIngestor` turn-end watchdog** ([apple/ClawdmeterMac/AgentControl/AntigravityChatIngestor.swift](apple/ClawdmeterMac/AgentControl/AntigravityChatIngestor.swift)). `AntigravityConversationDB.subscribe()`'s AsyncStream never finishes on its own — Antigravity keeps the WAL open for the conversation's lifetime — so `currentTurnState` was stuck at `.streaming` forever. New 6-second quiescence watchdog runs alongside the consumer via `withTaskGroup`; whichever fires first cancels the other. State now correctly flips to `.completed` after the WAL goes quiet.
- **Antigravity 2.0.6 step_type remapping.** Tool calls now render with names for step_types 5 (`write_to_file`/`replace_file_content`), 7 (`grep_search`), 8 (`view_file`), 9 (`list_dir`), 21 (`run_command`), and 132 (`list_permissions`/`manage_task` and other agent-control tools). Was only handling 8/9 + a non-existent 13 from the 2.0.0 schema.
- **`ConversationProtoParser.scrapeMessageBlocks` + `MessageBlock`** ([apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/ConversationProtoParser.swift](apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/ConversationProtoParser.swift)). Antigravity routes Gemini's natural-language replies through ASCII `[Message] timestamp=… sender=… priority=… content=…` records embedded in `step_type=101` payloads. The scraper finds the marker, reads forward to the next protobuf wire boundary, and classifies the sender: `system` (user-prompt echo — swallowed; composer already showed it), `<conv>/task-N` (internal agent signal — swallowed), `<bare-uuid>` (Gemini agent prose reply — rendered as `.assistantText`). Verified across 15 production conversation DBs.
- **Regression tests.** `LanguageServerClientRewriteTests.test_newConversationDecoder_acceptsNewConversationNestedShape` pins the real 2.0.6 stdout. `ConversationProtoParserTests` gains 6 tests covering agent vs system vs task-completion sender classification, multi-block payloads, malformed-shape rejection, and end-to-end `DecodedStep.messages` population. ClawdmeterShared suite goes 629 → 635; LanguageServerClientRewriteTests stays at 28/28.

### Known limitation

Antigravity 2.0.6's agentapi is agent-only — short chat-style prompts like "say hi" trigger an agentic loop (list_dir, view_file) rather than a prose `[Message]` block from the agent. `tools/smoke-chat-v2.sh gemini` now reaches `currentTurnState=completed` cleanly but the assistant-text criterion still fails for short prompts (verified across three smoke runs against fresh WAL DBs). The `[Message]` extraction path is verified and will render correctly for any future Gemini turn that emits prose — those exist in production DBs we inspected (substantive review / summary turns).

Bumps `MARKETING_VERSION` 0.23.6 → 0.23.7, `CURRENT_PROJECT_VERSION` 121 → 122.

## [0.23.6 build 121] - 2026-05-23 — Chat V2 — function-first rebuild (Mac + iOS) (`feat/chat-v2`)

Rebuilds the Chat tab from scratch as `MacChatV2View` + `IOSChatV2View` with live snapshot-bound surfaces. Wire v14 schema adds `TurnState` + `currentTurnState` + `deepResearch`. Per-backend Stop dispatch (tmux ESC / Codex AbortController / Gemini agentapi `/cancel`). Honest Deep Research across all three providers gated by `tools/verify-deep-research.sh`. Plan-approval store rollover fix (audit P0 #4) + `AgentControlClient` force-unwrap fix. Lifts `PermissionPromptCard` to Shared with `PermissionResponder` protocol. T16 cuts 8 legacy chat surfaces. T15 adds wire-v14 + ChatV2Store + DR argv tests. Smoke-tested round-trip green for Claude (3-4s) and Codex (15s) solo with `currentTurnState` lifecycle propagating cleanly through wire to client.

Bumps `MARKETING_VERSION` 0.23.5 → 0.23.6, `CURRENT_PROJECT_VERSION` 120 → 121.

## [0.23.5 build 120] - 2026-05-23 — OpenCode auth.json sandbox-home hotfix (`fix/opencode-auth-real-home`)

v0.23.4 saved API keys to `~/Library/Containers/com.clawdmeter.mac/Data/.local/share/opencode/auth.json` instead of the real `~/.local/share/opencode/auth.json` because `NSHomeDirectory()` resolves to the App Group container path even when the sandbox entitlement is `false`. opencode reads from the real `~`, so saved keys never took effect — the row stayed in the un-authed state with no error surfaced.

### Fixed

- **`OpencodeAuthFile.dataDirectoryURL`** now resolves the user's *real* home directory via `getpwuid(getuid())->pw_dir` (POSIX password database lookup) which bypasses sandbox/container redirection entirely. Falls back through `NSHomeDirectoryForUser($USER)` and `NSHomeDirectory()` defensively, but the primary path is the canonical one.
- **Migration**: on first read, `OpencodeAuthFile.readEntries()` checks the legacy container path (`NSHomeDirectory()/.local/share/opencode/auth.json`) for any v0.23.4 entries stranded there, copies them into the real location, and removes the legacy file. Idempotent — re-running is safe. Net effect: anyone who saved a key in v0.23.4 has it automatically picked up the first time v0.23.5 reads the auth state.

Bumps `MARKETING_VERSION` 0.23.4 → 0.23.5, `CURRENT_PROJECT_VERSION` 119 → 120.

## [0.23.4 build 119] - 2026-05-23 — Native API-key sheet for OpenCode (`feat/opencode-native-auth`)

Replaces the embedded `opencode auth login` terminal pane with a native SwiftUI sheet for the common API-key paste-and-go flow. The terminal sheet (`OpencodeSetupSheet`) stays available for OAuth providers that need a browser handoff (Anthropic Pro, GitHub Copilot, ChatGPT OAuth) and for sign-out / diagnostic.

### Added

- **`OpencodeAuthFile`** (actor, `apple/ClawdmeterMac/AgentControl/`) — read/write opencode's credentials at `~/.local/share/opencode/auth.json` (or `$XDG_DATA_HOME/opencode/auth.json`). Schema mirrors upstream `packages/opencode/src/auth/index.ts` — `{ providerID: { type: "api", key: "<key>", metadata?: {} } }`. File mode forced to 0600; directory to 0700. Writes go through a sibling tempfile + atomic `moveItem` so an interrupted write never leaves a half-formed credentials file. Provider-ID normalization matches upstream's trailing-slash strip.
- **`OpencodeAPIKeySheet`** (`apple/ClawdmeterMac/Tahoe/`) — SwiftUI sheet with a curated provider picker (OpenRouter, Anthropic API, OpenAI API, Moonshot, Google AI Studio, Mistral, Groq, xAI, DeepSeek, plus "Custom…" for arbitrary provider IDs). `SecureField` for the key with a show/hide toggle. Direct-link button to the upstream provider's API-key dashboard. On save: writes the credentials file → triggers `OpencodeProcessManager.shared.reprobe()` → dismisses.
- **`OpencodeAuthFileTests.swift`** — 15 tests covering schema, normalization, file mode 0600, atomic write, directory 0700, idempotent remove, malformed-JSON tolerance. Each test gets an isolated temp `XDG_DATA_HOME` so the real credentials file is never touched.

### Changed

- **`OpencodeProviderRow`** (in `MacSettingsView.swift`) — primary CTA is now **Add API key** (opens the native sheet); secondary **Sign in with browser** falls back to the terminal-based `OpencodeSetupSheet` for OAuth flows. Manage menu adds an **Add API key…** item alongside the existing browser-OAuth / Diagnostic / Sign out entries. CQ3 ASCII state diagram in the row's header comment updated to reflect the dual-path action surface.

Bumps `MARKETING_VERSION` 0.23.3 → 0.23.4, `CURRENT_PROJECT_VERSION` 118 → 119.

## [0.23.3 build 118] - 2026-05-23 — OpenCode mirror + tests (P1-05 + T10) (`feat/opencode-mirror-and-tests`)

Two follow-throughs from the v0.23.2 ship:

### Added — P1-05: cross-device OpenCode dollar values

- **`UsageHistoryStore.scheduleOpencodeMirrorRefresh`** — when a live `.opencodeUsageRecorded` notification lands, kick a debounced analytics-snapshot rebuild (10s minimum gap). The loader reads opencode's SQLite, folds the new rows into `byProvider[.opencode]`, AppRuntime mirrors the snapshot into iCloud KV via `UsageCloudMirror.writeAnalyticsSnapshot`. Net effect: a paired iPhone sees OpenCode dollar deltas within seconds of the Mac processing the SSE `usage` event, instead of waiting up to 60s for the next periodic refresh tick.

### Added — T10 test coverage for OpenCode send (v0.23.2)

- **`OpencodeSSEAdapterTests` — extended**: `parseMessageAdded(properties:)` round-trips across all wire shapes (plain string, text-only array, `tool-call`/`tool_use`, `tool-result`/`tool_result` text + isError, empty content, missing role/id). `opencodeSessionId(for:)` lookup before/after register/stop. `chatStoreAccessor` is invoked on `message.added` only when the opencode session id is registered.
- **`OpencodeSendTests.swift` — new**: the public surface of the T6 send path. BidirectionalMap gate for the 503 `opencode_session_not_registered` envelope, request body shape (`{"parts":[{"type":"text","text":"…"}]}`) JSON round-trip with multi-line + Unicode prompts, error envelope JSON validity for all three error codes, user-bubble echo ChatMessage shape, parser/echo symmetry for the dedupe layer.
- **`DaemonChatStoreRegistryRoutingTests` — extended**: opencode sessions never route into the agentapi `.db` layout.

Bumps `MARKETING_VERSION` 0.23.2 → 0.23.3, `CURRENT_PROJECT_VERSION` 117 → 118.

## [0.23.2 build 117] - 2026-05-23 — OpenCode send end-to-end (P1-04) (`feat/opencode-send`)

Sending into an OpenCode session + streaming the reply back now works through the same chat composer that drives Claude / Codex / Antigravity sessions.

### Added

- **`AgentControlServer.sendOpencodePrompt`** — replaces the 501 `opencode_send_not_implemented` stub at line 1313. Looks up the opencode session id via `OpencodeSSEAdapter.opencodeSessionId(for:)`, POSTs the prompt to opencode serve's `/session/<id>/message` endpoint, echoes the user bubble into the SessionChatStore immediately so the composer clears its sending state without waiting on the SSE round-trip.
- **`OpencodeSSEAdapter.chatStoreAccessor`** — closure injected by `AgentControlServer` on every spawn that maps `Clawdmeter session UUID` → `SessionChatStore`. `handleMessageAdded` now parses opencode's `message.added` payload into a `ChatMessage` (text, tool-call, tool-result content parts all handled) and calls `store.appendSDKMessages([msg])` — the chat-subscribe WS broadcast picks it up and streams to iOS / Mac in real time.
- **`OpencodeSSEAdapter.opencodeSessionId(for:)`** — convenience accessor wrapping the existing bidirectional map.
- **`DaemonChatStoreRegistry.createStore` opencode branch** — opencode chat sessions get an sdkOnly `SessionChatStore` + `SDKChatTranscriptMirror` replay, same shape as the agentapi Gemini branch.

### Error surfaces

- `503 opencode_session_not_registered` — `session.created` SSE event hasn't landed yet; iOS retries
- `503 opencode_server_unreachable` — opencode serve down; supervisor will restart
- `502 opencode_send_failed` with `upstreamStatus` — opencode returned non-2xx

Bumps `MARKETING_VERSION` 0.23.1 → 0.23.2, `CURRENT_PROJECT_VERSION` 116 → 117.

## [0.23.1 build 116] - 2026-05-23 — OpenCode setup lives in the Mac app (`feat/opencode-end-to-end`)

Zero-Terminal install + auth flow for OpenCode under Settings → Providers. Bundled binary, embedded interactive terminal sheet, 4-state row that actually does something.

### Added

- **Bundled `opencode` v1.15.7** ship-in-the-DMG via `tools/download-bundled-opencode.sh` + `project.yml` preBuildScripts. SHA-256 verified against pinned digest; `codesign --verify` + `spctl --assess` baked into `tools/build-mac-dmg.sh` so Gatekeeper rejection fails the build, not the user's first launch.
- **`OpencodeSetupSheet`** — interactive terminal pane embedded directly in Settings. Spawns `opencode auth login` (or `logout` / diagnostic) via tmux, captures exit code via a sentinel tempfile, blocks sheet dismiss while OAuth is in-flight (scans pane scrollback for the OAuth URL).
- **`MacInProcessTerminalView`** — new SwiftTerm wrapper that pipes bytes directly to/from `TmuxControlClient` (no WebSocket round-trip). Mirrors `TerminalWebSocketChannel:117-123` ESC-safe key routing so the opencode provider-picker arrow keys actually work.
- **OpencodeProviderRow rewrite** — 4-state machine (bundle-missing / activated-no-auth / signed-in / running). Sign in button when unauthed. Manage menu (Add provider / Diagnostic / Sign out) when signed-in.

### Changed

- **`OpencodeProcessManager.locateBinary()`** — PATH-first lookup (Homebrew / `$PATH`) with the bundled binary as fallback (O4). Brew users keep their managed version; bundle exists for first-launch users. Every candidate gated by `isExecutableFile` (A1) so corrupt bundles fall through.
- **`OpencodeProcessManager.reprobe()`** — new method that restarts `opencode serve` when binary path OR auth providers change. Without this, signing in via the embedded sheet didn't propagate to the already-running serve process (opencode reads creds at start, not per-request).
- **`AgentControlServer` autopilot inactivity sweep** — pre-existing compile error landed in PR #69 (`Bool` literal in `[String: String]` payload + `self?.serverLogger` reference to a file-private free var). Merge from `origin/main` brought in PR #71's fix.

### Out of scope (deferred to follow-up)

- **`opencode send` daemon implementation** — `AgentControlServer.swift:1313` still returns 501 `opencode_send_not_implemented`. Sending into an OpenCode session + streaming the reply back requires coordinated changes across `AgentControlServer`, `OpencodeSSEAdapter`, and `DaemonChatStoreRegistry` — those layers are being actively reworked in `feat/chat-v2`. Lands when that PR settles.
- **`UsageCloudMirror` opencode mirroring** — verified existing `writeAnalyticsSnapshot` path already keys on `UsageRecord.Provider.opencode`, so opencode usage flows through to iCloud automatically. No new code needed.

Bumps `MARKETING_VERSION` 0.23.0 → 0.23.1, `CURRENT_PROJECT_VERSION` 115 → 116.

## [0.23.0 build 115] - 2026-05-23 — Cross-platform audit sweep: ~70 P0/P1/P2 fixes (`darshanbathija/bug-audit-2026-05-23`)

A focused bug-audit + fix pass that closes findings across every platform. Code-only changes, no new features. Pairing and release builds get safer, pre-existing crash paths in the shared library get caught, the polyglot tools/ sidecars get input validation and HTTP timeouts. Some user-visible behavior changes flagged below.

### Behavior changes (read first)

- **Mac shipped builds are now sandboxed.** New `ClawdmeterMac-Release.entitlements` (sandbox on, network-client + network-server, same App Group / Keychain access groups as before) is selected for the Release configuration. Debug keeps the unsandboxed entitlements so devs can still read Claude Code's Keychain entry locally. Shipped DMGs no longer ride out unsandboxed.
- **iOS App Transport Security is scoped, not disabled.** `NSAllowsArbitraryLoads` is now `false`. Plain HTTP/WS is allowed only to `*.ts.net` (Tailscale MagicDNS), `localhost`, and link-local / loopback via `NSAllowsLocalNetworking`. Bare-IP Tailscale CGNAT (`100.64.0.0/10`) URLs are NOT covered — turn on MagicDNS on the Tailscale dashboard if not already.
- **Pairing rejects untrusted hosts and bad tokens.** `PairingScannerView` now refuses anything outside loopback, Tailscale CGNAT (`100.64.0.0/10`), or `*.ts.net`. Tokens have to be base64url shape, 16-256 chars; ports have to be 1-65535.
- **OpenCode sessions return a clean 501 instead of an opaque 500** on `POST /sessions/:id/send`. The real send-branch lands in a follow-up; the 501 lets iOS render "OpenCode is read-only in this build" honestly.
- **AppImage `LD_LIBRARY_PATH`** no longer ends with a trailing colon — that was a CWD-injection footgun for users launching the AppImage from shared dirs.

### Fixed — Shared library (Apple)

- Force-unwraps that could crash widget extensions and SwiftUI views: empty `applicationSupportDirectory` in `FirstPromptCache`, `TaskGroup.next()!` in `AgentControlClient`, `TahoeDemo.liveData[.claude]!` fallback in `TahoeBindings`, fragile `latest!` comparison in `BrainPlanParser.latestMTime`.
- `PastedAnthropicTokenProvider.deleteFromKeychain` now clears the in-memory cache on every status path including locked-Keychain failures — sign-out is no longer a no-op when the Keychain returns `errSecInteractionNotAllowed`.
- `UsageCloudMirror` adds `NSLock` around every read-modify-write of the iCloud KV provider list. Concurrent Claude+Codex+Gemini polls can no longer clobber each other's registrations.
- `UsageStore` / `UsageCloudMirror` envelopes now use `convertFromSnakeCase` and carry a sub-second `writtenAtPrecise` field so legacy snake_case snapshots still decode and tied-second timestamps stop colliding.
- `AnalyticsRepoList` keeps cost shares in `Decimal` end-to-end. Per-repo rows actually sum to 100%.
- `SessionFileResolver.geminiLinks` cache is now populated on first lookup. Previously the reader had no writer; every legacy gemini JSONL lookup missed.
- `WatchTokenBridge.handleContext` surfaces decode failures instead of silently dropping malformed `usageByProvider` payloads.
- File / JSON / Keychain `try?` sweep across `FirstPromptCache`, `BrainPlanParser`, `CityNamer`, `AntigravityProjectResolver`: failures now hit OSLog instead of vanishing.

### Fixed — Mac

- Five `process.terminate()` sites in the process managers (`CodexSubscriptionRelay`, `AntigravitySidecarManager`, `CodexSDKManager` x2, `OpencodeProcessManager` x2) now pair with `Task.detached { proc.waitUntilExit() }`. No more accumulated zombie PIDs across long sessions.
- `OpencodeProcessManager.handleUnexpectedExit` resets state to `.stopped` before calling `ensureRunning()`. Previously the manager left state at `.running` after a crash, so `ensureRunning()` returned early and the server never restarted.
- `OpenDesignDaemonManager` terminates + reaps the orphaned daemon and clears the cached port when `/health` times out, instead of leaving stale state for the next `ensureRunning()`.
- `MenuBarGaugeView.scaledImage`: `as!` on `NSImage.copy()` replaced with `as?` + fallback. That was crashing every menu-bar refresh tick when the source was a proxy image.
- `AppModel.deinit` invalidates `clockTimer` so a replaced model (sign-in switch) doesn't keep firing through `[weak self]` against a zombie instance.

### Fixed — Mac security boundary

- `POST /sessions` now calls `isValidRepoKey` BEFORE either dispatch branch. A paired client can no longer post `/tmp` or a symlink-escaping path and have the Mac spawn an agent rooted there.
- `POST /design/import-folder` now constrains `baseDir` to paths that pass `isValidRepoKey` plus an explicit `.ssh` / `.gnupg` / `.aws` / `Library/Keychains` deny-list. The bridge marks every call `fromTrustedPicker: true`, so a paired iPhone could have asked Open Design to ingest sensitive folders without this guard.
- `CodexSubscriptionRelay` logs op/thread-id/byte-length/cwd-basename at `.public` and routes full prompt/stdout/stderr to `.private`. Prompts routinely contain secrets — they no longer end up readable in Console.app / sysdiagnose.
- `AgentControlServer.start()` starts a 30s autopilot-inactivity sweep that disables sessions idle for >15 min and emits `statusChanged`. The 15-min safety guardrail described in the eng review was previously dead code.

### Fixed — Mac plan approval

- `DaemonChatStoreRegistry.snapshotStore` extends the file-swap check to `.code` sessions (previously only `.chat`). Codex plan-mode approve-plan writes a new rollout JSONL; without the swap, iOS chat-subscribe WS clients saw no execution turns. The fix preserves the chat-specific resolution path (`newestCodexJSONLMatching` scoped to cwd + createdAt). Early `/review` caught a regression where the broadened version downgraded Codex chat sessions to global newest and that's been fixed.
- `SessionsView.chatStore(for:)` does the same swap-or-rebuild check on the Mac UI's cached store so the chat thread doesn't freeze on the plan after approve.

### Fixed — iOS / Watch

- `UsageModel.deinit` invalidates the daemon refresh timer.
- `iOSChatTranscriptView` replaces the racy `DispatchQueue.main.asyncAfter(0.15)` re-scroll with a cancellable `Task` + `onDisappear` hook.
- `PairingScannerView` validates host (loopback / Tailscale CGNAT / `*.ts.net`), ports, and base64url token shape. See "Behavior changes" above.
- `IOSSessionDetailView.sendComposer` / `sendRefine` clear the composer text only when `sendPrompt` returns `true`. Offline / 4xx / archived-session paths no longer silently lose what the user typed.
- `AgentControlClientSessionObserver` drops the Codex short-circuit. Every Codex session was being marked "waiting" even mid-generation, which trained users to ignore the Watch complication. Now requires non-empty `planText`.
- Watch complication refresh cadence is dynamic. 1 min when an approval is pending, 30 min when idle. Approvals clear off the wrist promptly instead of sitting up to 30 min stale.
- Watch "Voice reply" button is hidden behind a feature flag set to `false`. The watch sent the op over WCSession but iOS only logged it. The button was dead UI that misled users.

### Fixed — Linux

- `HummingbirdPeerFilter.decide` strips the `::ffff:` IPv4-mapped IPv6 prefix before checking 127.* / 100.64-127 / `fd7a:115c:a1e0:`. On dual-stack listeners, IPv4 peers arrive as `::ffff:127.0.0.1` and every legitimate pairing was being rejected.
- `LinuxConfigPaths` treats empty / non-absolute XDG env vars as unset, per the Freedesktop spec.
- `LinuxUsageStore.loadIfNeeded` self-heals on a corrupt `usage-store.json`. Log, delete the bad file, reset the cache, mark `loaded = true`. Previously a single decode error left `loaded = false` and the dashboard stuck at "no data" forever.
- `LinuxUsageStore.writeSnapshot` routes through `UsageData.shouldReplace` so an older reset epoch can't clobber freshly-reset post-quota state. Matches the Apple-side guard.
- `LinuxSecretServiceTokenProvider.writeFallbackFile` and `PairingTokenStore+SecretService.writeFallbackFile` drop the process-wide `umask()` dance. Permissions are set explicitly via `setAttributes([.posixPermissions: 0o600])` so concurrent file writers (Hummingbird sockets, observer writes) can't race.
- `AppIndicatorTray.setIcon` funnels through `DispatchQueue.main.async` so future Phase-4 GTK / AppIndicator C calls can't land on `TrayPollLoop`'s background actor thread. GTK is strictly not thread-safe.
- `LinuxUIWidgetTests` switched from the now-banned `LinuxUI.adapter = StubAdapter()` to `LinuxUI.configure(adapter:)`.
- AppImage and `.deb` packaging CI jobs gated to tag pushes only since the underlying scripts are still Phase 0 stubs that exit 2.

### Fixed — Tools / sidecars

- **bridge-host**: `sanitizeBaseDir` refuses paths outside `$HOME` and refuses `.ssh` / `.gnupg` / `.aws` / `Library/Keychains` subtrees on both `/sign-import-token` and `/import-folder`. HTTP server gets explicit `setTimeout(30s)`, `headersTimeout 10s`, `keepAliveTimeout 5s`, `maxConnections 16`.
- **codex-sdk**: `safeWorkingDirectory` constrains cwd to `$HOME` and refuses null bytes / relative paths; `safePrompt` caps prompt at 256 KB; `readline` drops `crlfDelay: Infinity` and enforces a 1 MB per-line cap so a stuck sender can't OOM the sidecar; the dynamic SDK import races a 5s deadline; `ready` payload is now consistent shape from both SDK and skeleton paths.
- **clawdmeter-agents** (Python): traceback preserved in `sdk_import_failed`. observer.py factors `_emit_exc()` helper, folds the 2s polling sleep into `select()` (kills the busy-spin + slow-shutdown pattern), and explicitly checks for SDK schema-mismatch attributes instead of silently defaulting tokens to 0.
- **open-design plugin**: every `postMessage` now forwards a per-session `__CLAWDMETER_HANDOFF_NONCE__` so the native receiver can verify the call really came from this renderer context; `projectId` is shape-validated; toolbar selector failures log a one-time warning + emit `plugin-error` to the native side; `MutationObserver` is teardown-aware via `window.__clawdmeterPluginTeardown` to stop accumulating observers across plugin reloads.

### Fixed — CI / release

- `linux.yml` gets a default `permissions: contents: read`. `SwiftyLab/setup-swift` is now SHA-pinned to v1.14.0 (no more `@latest`). `release-upload` widens to `contents: write` only on tag pushes.
- `tools/download-bundled-node.sh` fetches and verifies `SHASUMS256.txt` (optionally GPG-verifies the signature when release keys are imported). `tools/download-bundled-uv.sh` fetches and verifies the per-artifact `.sha256`. The DMG build can no longer ship a trojaned Node or uv from a network-path compromise.
- AppImage `AppRun` guards `LD_LIBRARY_PATH` against the trailing-colon CWD-injection footgun.
- `deb/prerm` switches `pkill -f` → `pkill -x` so it doesn't kill editors that happen to have "clawdmeter" in their command line.
- Fastlane `Appfile` typo fix: `com.clawdmeter.mac.widget` → `widgets`.
- Fastlane `Fastfile` `release` lane now picks the DMG by exact `Clawdmeter-#{market}-arm64.dmg` path instead of `Dir[...].sort.last` (lexicographic sort preferred `0.9.2` over `0.22.32`).

### Added

- `docs/BUG-AUDIT-2026-05-23.md` — consolidated audit report (~110 findings across 4 independent audits) that informed this release. Kept in-repo as a forensic record.

### Notes

Three explicitly deferred items (called out in the audit doc):
- OpenCode `POST /sessions/:id/send` real implementation + SSE-backed snapshot store. Current release returns a clean 501.
- Linux libsecret Phase 3 C bridge. Current release uses a hardened file fallback (no `umask` race; `setAttributes(0o600)`) but doesn't talk to GNOME Keyring yet.
- macOS / iOS / watch Xcode CI lane. Linux CI green; Apple targets still need their own workflow.

## [0.22.32 build 113] - 2026-05-23 — Fix: wire button controls to backend behavior (`darshanbathija/clawdmeter-button-wiring`)

This pass keeps the current UI and wires visible controls to real daemon/client paths, or gates controls that cannot honestly work yet.

### Fixed

- **iOS Chat** — broadcast now uses Frontier create/send routes, solo mode uses chat create/send, history rows reopen real sessions/groups, and production rendering reads live chat snapshots instead of demo transcript data.
- **Backend control routes** — adds client/server support for provider refresh, full diff hunks, persistent terminal pane rename, and immediate session refreshes after chat/frontier actions.
- **Session detail and terminal controls** — iOS Session Detail opens the real controls sheet, removes inert plus/mic affordances, loads real transcript state, and persists terminal renames through the daemon.
- **Capability gates** — OpenCode is hidden or disabled in unsupported chat/frontier/auto-revive actions, pairing no longer shows a stale scannable QR payload, and iOS diff rows fetch full hunks on demand.
- **Initial attachments** — first-send Gemini/Antigravity composer paths stage attachments before spawning so the initial agentapi message keeps file references.
- **Usage history test isolation** — the empty-directory loader test no longer reads the developer machine's real OpenCode database.

Bumps `MARKETING_VERSION` 0.22.31 → 0.22.32, `CURRENT_PROJECT_VERSION` 112 → 113.

## [0.22.18 build 99] - 2026-05-22 — Fix: Antigravity usage tab no longer shows demo quota data (`darshanbathija/gemini-usage`)

Antigravity usage now renders honest live-state data instead of borrowing SwiftUI preview fixture values.

### Fixed

- **Usage tab Antigravity quota state** — production Tahoe usage rows no longer fall back to demo percentages when a provider has not returned live usage yet, so the Usage tab stops showing fake Antigravity 5h/weekly values.
- **Antigravity weekly and auto-revive UI** — weekly bars remain hidden for providers without a real weekly bucket, and auto-revive controls now only render when the provider actually supports revive.
- **iOS usage rows** — iOS Tahoe bindings use the same honest empty/live behavior instead of demo data when snapshots are missing.

Bumps `MARKETING_VERSION` 0.22.17 → 0.22.18, `CURRENT_PROJECT_VERSION` 98 → 99.

## [0.22.15 build 96] - 2026-05-22 — Fix: Linux CI can build shared crypto code (`fix/linux-swift-crypto`)

Linux CI can now compile the shared package again after the Design and Watch bridge code started using SHA-256 helpers.

### Fixed

- **`ClawdmeterShared` crypto imports** — Apple platforms keep using native `CryptoKit`; Linux builds now fall back to Swift Crypto's `Crypto` module for the same SHA-256 APIs.
- **`ClawdmeterShared` package graph** — adds `swift-crypto` to the package dependencies so the Linux Swift 5.10 and Swift 6.0 jobs can resolve the crypto module instead of failing at import time.

Bumps `MARKETING_VERSION` 0.22.14 → 0.22.15, `CURRENT_PROJECT_VERSION` 95 → 96.

## [0.22.12 build 94] - 2026-05-22 — Fix: "+ New chat" button actually clears the open chat (`fix/new-chat-button`)

User reported that clicking "+ New chat" still rendered the previous chat's transcript in the middle pane.

Root cause: the `TahoeAccentButton(size: .m) { … }` invocation in `ChatSidebar.body` passed a label-only closure with no `action:` argument. `TahoeAccentButton.init` defaults `action` to `{}` (no-op), so the tap did literally nothing — `openChatId` was never cleared and the activeThread computation kept rendering whatever was previously open.

### Changed

- **`MacChatView.ChatSidebar`** — `TahoeAccentButton(size: .m, action: { openChatId = nil }) { … }`. Combined with the v0.22.11 empty-thread fix (nil openChatId → `ChatThread(title: "", turns: [])`), clicking "+ New chat" now reliably gives the user a clean composer + blank stream pane.

Bumps `MARKETING_VERSION` 0.22.11 → 0.22.12, `CURRENT_PROJECT_VERSION` 93 → 94.

## [0.22.11 build 93] - 2026-05-22 — Fix: clean default chat state + auto-archive idle chats + Code IDE JSONL renders inline (`fix/chat-default-and-jsonl-render`)

User reported:
1. Chat tab opens onto the canned "react-query refactor + tradeoffs" demo data — should be a clean composer instead, and idle chat sessions should auto-archive into history.
2. Clicking a JSONL row in the Code IDE sidebar reveals the file in Finder (v0.22.9 behavior) — should render the transcript inline in the middle pane instead.

### Changed

**`MacChatView.activeThread` — clean default state**
- Previously, when `openChatId` was nil the view fell back to `TahoeDemo.chatThread` (the "react-query refactor" fixture with 2 mocked turns and 3 provider replies). That made the Chat tab look like there was an in-flight conversation on every fresh launch.
- Now returns an empty `ChatThread(title: "", turns: [])` so the stream pane is bare and the composer is the focal point.

**`AppRuntime` — auto-archive chat sessions idle > 5 minutes**
- New 60-second `Timer` walks `agentSessionRegistry.sessions` and calls `archive(id:)` for any chat session (`kind == .chat`) whose `lastEventAt` is older than 5 minutes (and isn't already archived). Idempotent.
- Code-tab sessions are deliberately excluded — they're long-running by nature and users archive them via the IDE.
- Archived sessions remain discoverable via the sidebar's "RECENT" entries (the existing JSONL-recents pipeline picks them up by mtime).

**`MacCodeView` + new `JsonlPreviewHeader` / `JsonlPreviewMsg`**
- `Thread` accepts `previewTranscript: [ChatMessage]?` + `previewJsonlPath: String?`. When `previewTranscript` is non-nil, the view renders a read-only transcript preview header + simple bubble rows for each message (user / agent / tool call / tool result / meta).
- `MacCodeView` adds `@State openJsonlPath: String?` + `@State jsonlMessages: [ChatMessage] = []`. A `.task(id: openJsonlPath)` modifier loads the transcript via `TranscriptLoader.load(from:URL, maxMessages: 500)` off the main actor whenever the path changes.
- New `onOpenJsonl: (String) -> Void` callback threaded through Sidebar → RepoSection → RecentRow. JSONL-only rows now call this instead of the v0.22.9 `NSWorkspace.activateFileViewerSelecting` reveal.
- The preview header surfaces a "Reveal in Finder" action so the prior workflow is still one click away when wanted.

### Notes

- The 5-minute idle threshold matches the user's stated UX preference; raise/lower in `AppRuntime` if you want a different cadence.
- The JSONL preview is intentionally simple (no syntax highlighting, no streaming indicator) — it's a read-only inspector, not the full live chat surface. Full in-app rendering parity with `MacChatView` is tracked for v0.23.

Bumps `MARKETING_VERSION` 0.22.10 → 0.22.11, `CURRENT_PROJECT_VERSION` 92 → 93.

## [0.22.10 build 92] - 2026-05-22 — Fix: Codex 5h reading matches Codex Desktop (window-aware bucket pick) + popover force-polls on open (`fix/codex-5h-usage`)

User reported the menu-bar popover's "Codex 5h session" reading was wildly off — Codex Desktop showed 93% / 12:38, Continuum showed 15% / "resets in —".

Two compounding problems:

### Changed

**`CodexSource.parseLiveUsagePayload` — bucket-pick rewrite**
- Previously: pick the bucket with the highest `primary.used_percent`, then inherit that same bucket's `secondary` as the weekly. That couples session + weekly to the same bucket — wrong when `/wham/usage` returns multiple `(primary, secondary)` pairs (e.g. `codex`, `codex-pro`, `codex-fast`). A user constrained on `codex-pro` (93% on its 5h) but loose on the `codex` bucket (15% on its 5h) would always show 15% because Continuum picked the bucket whose primary was highest among the wrong axis.
- Now: walk every bucket and classify each `(primary, secondary)` pair by `window_minutes`. 5h-class = `window_minutes ≤ 600`; weekly-class = `window_minutes ≥ 1440`. Pick the highest `used_percent` independently for each class. Session and weekly can now come from different limit_ids.
- `BucketView` gained a `windowMinutes: Int?` field decoded from `window_minutes` / `windowMinutes`.

**`ProviderStatusController.togglePopover` — force-poll on open**
- Every status-item click now fires `runtime.claudeModel.forcePoll()` + `codexModel.forcePoll()` + `geminiModel.forcePoll()` before showing the popover, so the gauges always reflect the latest backend reading. Previously the popover rendered whatever cached `model.usage` was in memory — after a long idle, that could be tens of minutes stale even though MenuBarLiveSource correctly propagates updates once a new poll lands.

### Notes

- The window-aware pick falls back to the previous "highest primary" behavior when buckets don't expose `window_minutes` (preserves test fixtures that mocked the older shape).
- The JSONL fallback parser (`parseLatestUsage`) is unchanged — JSONL has exactly one `(primary, secondary)` pair per line so the multi-bucket logic doesn't apply there.

Bumps `MARKETING_VERSION` 0.22.9 → 0.22.10, `CURRENT_PROJECT_VERSION` 91 → 92.

## [0.22.9 build 91] - 2026-05-22 — Fix: keyboard shortcuts + Settings consolidation + composer wiring + multi-select model picker + eager Design daemon (`fix/v0228-followups`)

Nine-issue follow-up after the user reported:
1. Cmd+1..Cmd+5 should switch tabs
2. Design tab "Waking up…" splash on every launch — make it always-on
3. OpenCode "Open docs" button opens a broken URL
4. Codex SDK settings sheet has a lone toggle with no context
5. Cmd+, opens a separate light/dark-broken modal window — collapse everything into the in-app Settings tab
6. Composer chips (paperclip / code / mic / autopilot / model) are all decorative — wire them
7. Drop Broadcast/Solo MODE toggle in favor of a multi-select model picker in the composer
8. Remove the per-model subtitle on the provider hero cards — brand-only is cleaner
9. Code IDE sidebar JSONL rows are disabled — make them actionable

### Changed

**Keyboard shortcuts — `ClawdmeterMacApp.swift` + `MacRootView.swift`**
- `.commands { CommandGroup(replacing: .appSettings) }` intercepts Cmd+, and posts a `.clawdmeterSwitchTab` notification → MacRootView flips `tab` to `.settings` (no more separate Settings modal).
- New `CommandMenu("View")` with Cmd+1..Cmd+5 mapped to Chat / Usage / Code / Design / Settings. Replaces the previous hidden-button keyboardShortcut hack that silently dropped when any TextField had focus.
- New `.clawdmeterSwitchTab` notification name in `ClawdmeterMacApp.swift`.

**Settings consolidation — `ClawdmeterMacApp.swift` + `MacSettingsView.swift`**
- Dropped the entire `Settings { TabView { … } }` scene that opened a separate light/dark-broken modal window.
- `MacSettingsView` now embeds the previously-modal sub-views inline as cards: Codex SDK, Antigravity SDK, Live Activities, Pairing, Diagnostics. All settings live in one comprehensive page in the in-app Settings tab.
- `MacSettingsView.init` threaded `runtime: AppRuntime?` so `PairingSettingsView` can read the live daemon state. Init dropped to `internal` because `AppRuntime` is internal to the Mac target.

**OpenCode docs URL — `MacSettingsView.swift`**
- `https://opencode.ai/docs/auth` 404s. Changed to `https://opencode.ai/docs/` (carries install + auth instructions).

**Provider hero cards — `MacUsageView.swift`**
- Dropped the per-model subtitle ("Sonnet 4.5 / gpt-5 / antigravity-pro") under each provider's brand name. Brand-only label is cleaner; the active model is exposed in the composer's model chip anyway.

**Composer chips wiring — `MacCodeView.swift` + `MacChatView.swift`**
- Wired all five chips that were previously static labels:
  - "Sonnet 4.5" → `Menu` showing the active model (model-swap RPC follows in v0.23)
  - "autopilot" → `Menu` toggling autopilot ↔ plan-mode (drives the existing `onCycle`)
  - paperclip → `NSOpenPanel` file picker; selected paths append as `@/abs/path` mentions in the composer text
  - code → inserts a fenced-code block stub (` ```...``` `) into the composer
  - mic → opens System Settings → Keyboard → Dictation so the user can verify dictation is enabled
- Chat composer's "auto" lightning chip wrapped in a `Menu` for parity (mode toggle is Code-tab-specific so the menu surfaces a brief note).

**Multi-select model picker — `MacChatView.swift` + `MacRootView.swift`**
- `BroadcastChip` was a static label ("Broadcast · 3 models"). It's now a `Menu` with toggleable rows for Claude / Codex / Antigravity. Selection count drives `mode`:
  - 1 selected → `solo`, that provider
  - >1 selected → `broadcast`
- Refuses to clear the last selection (the composer needs at least one recipient).
- Dropped the titlebar `ChatModeToggle` ("MODE [Broadcast] [Solo]") entirely — the chip is now the single source of truth.

**Eager Open Design daemon — `AppRuntime.swift`**
- `openDesignDaemon.ensureRunning()` is invoked during app launch (right after `sessionScheduler.start()`) so the Design tab is warm-ready the first time the user opens it. The lazy `ensureRunning()` in `MacDesignView.onAppear` is now a safety-net; the supervisor is idempotent.

**Code IDE sidebar — `MacCodeView.swift` + `MacTahoeAdapter.swift` + `TahoeBindings.swift`**
- `TahoeCodeRecent` gains a `jsonlPath: String?` field.
- `MacTahoeAdapter` populates it for JSONL-sourced recents.
- `RecentRow.restore()` now branches: for archived sessions, the existing unarchive RPC fires; for JSONL-only rows, the file is revealed in Finder via `NSWorkspace.activateFileViewerSelecting`. The row is no longer `.disabled` for JSONL paths. (Full in-app transcript preview lands in v0.23.)

### Notes

- Cmd+, no longer opens a window. It now lives in the standard `Clawdmeter → Settings…` menu item.
- Cmd+1..Cmd+5 show up in the new `View` menu so users can discover the shortcuts.
- The legacy `PreferencesView` struct in `ClawdmeterMacApp.swift` is now orphan code (no caller); kept for now to make the diff smaller.

Bumps `MARKETING_VERSION` 0.22.8 → 0.22.9, `CURRENT_PROJECT_VERSION` 90 → 91.

## [0.22.8 build 90] - 2026-05-22 — Fix: menu-bar popover container + provider switching + Antigravity demo bleed + real analytics + OpenCode (`fix/menubar-popover-and-ccusage`)

Four-issue follow-up after the user reported:
1. Menu-bar popover designed vs. actual container size mismatch
2. Provider segmented control needs multiple clicks / lags
3. Antigravity data shown is inaccurate
4. Mac Analytics "Spend over time" + "Spend by repo" data is "completely wrong" — wants the latest ccusage logic + OpenCode dollar spend

### Changed

**`MacMenubarPopover.swift`**
- Dropped the outer `TahoeGlass(radius: 18, tone: .panel)` wrapper that
  stacked a second rounded panel inside the NSPopover's native bubble
  (the doubled border the user flagged). The NSPopover bubble is now
  the sole container.
- Extracted `providerTab(_:)` builder with three explicit fixes for the
  "many clicks needed" gripe: (a) `.contentShape(Capsule())` so the
  whole pill is hittable (previously hit-tests fell through between the
  glyph and the label on the first click), (b) selection update wrapped
  in a `Transaction { disablesAnimations = true }` so the active-capsule
  swap is instant, (c) `.animation(nil, value: selected)` on the
  background so the capsule snap is uniform across re-renders.
- `liveRow(model:provider:)` no longer falls back to `.demo(provider)`
  when `model.usage` is nil. The previous fallback dishonestly rendered
  the canned `TahoeDemo.liveData[.gemini]` placeholder — that's where
  the "89% / 61% / resets in 58m / 5d 2h" Antigravity numbers came
  from. Now nil-usage emits an honest "Connecting…" row with
  `hasWeekly` from the real per-provider config, so gemini's weekly
  meter stays hidden even before the first poll completes.

**`Pricing.swift`** — ccusage parity rewrite of the tier-boundary math
- Previously, when `inputTokens + cacheReadTokens > 200k`, ALL rates
  (input, output, cacheCreate, cacheRead) flipped to the above-tier
  variant. Per upstream ccusage (`rust/crates/ccusage/src/cost.rs::tiered_cost`),
  each token kind is tiered **independently** against its own count vs.
  the 200k threshold. The coupled approach overcharged output / cache
  cost when only input crossed the boundary.
- The pricing inflection is now a hard-coded 200_000 constant
  (matching ccusage's `THRESHOLD: u64 = 200_000`). The previous code
  read `max_input_tokens` from the LiteLLM snapshot, which is per-model
  context window (128k for gpt-5) and silently flipped the tier at
  the wrong threshold on non-Claude models.

**`UsageHistoryLoader.swift`** + **new `OpencodeUsageParser.swift`**
- Added an OpenCode disk parser that reads
  `~/.local/share/opencode/opencode.db` (honors `OPENCODE_DATA_DIR`
  env override). SQLite query against the `message` table, JSON
  decode the per-message `data` blob, dedupe by message id, prefer
  the embedded `cost` field when > 0 else fall back to
  `Pricing.cost(...)` with provider-prefix + dot/dash normalization
  candidates. Mac-only (`#if os(macOS)`) — iOS/Watch don't run
  OpenCode locally and their sandbox blocks `~/.local/share/`.
- `UsageHistoryStore.ProviderFilter` adds `.opencode`.

**`MacUsageView.swift` Analytics card** — wire real data
- `AnalyticsRow` previously rendered `TahoeDemo.ranges[range]` —
  hardcoded placeholder ($39.32 / 7d / defx-frontend $17.42 etc.)
  regardless of actual usage. Now drives off
  `UsageHistoryStore.snapshot` via the new `AnalyticsRangeAdapter`
  that buckets per range (24h / 7d / 30d / 90d / all-time) and
  computes per-provider dollar totals + top-4-by-cost repo rollup
  with an "Other" rest bucket.
- `SpendChart` + `RepoList` extended to render a 4th OpenCode segment
  in each bar / row.

### Data shapes

- `TahoeDemo.SpendPoint`, `SpendRepo`, `Totals` gain an `o: Double = 0`
  field (defaulted for back-compat with existing demo fixtures).

### Notes

- The Pricing tier-boundary fix shifts existing Claude session totals
  modestly (lower output/cache cost when the request didn't actually
  cross the boundary on those kinds). Aggregated impact is usually
  within a few percent.
- OpenCode SQLite reads use `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`
  + 100ms busy timeout so we never collide with the OpenCode server's
  writer.

Bumps `MARKETING_VERSION` 0.22.7 → 0.22.8, `CURRENT_PROJECT_VERSION` 89 → 90.

## [0.22.7 build 89] - 2026-05-22 — Fix: flush Tahoe titlebar against the top of the window (`fix/titlebar-top-flush`)

Follow-up to v0.22.6. The native title strip was gone, but the Tahoe
chip was still sitting ~30pt below the top of the window — a visible
dark band hung above it. Two compounding insets caused this:

### Changed

- **`ClawdmeterMacApp.swift`** — dropped `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`.
  Even with no `.toolbar { … }` modifier present, that style reserves
  a thin toolbar band at the top of the window (~28pt), pushing
  everything down. `.windowStyle(.hiddenTitleBar)` by itself is what
  we actually want: SwiftUI content extends to y=0 and the macOS
  traffic lights overlay at their canonical position.
- **`MacRootView.body`** — removed `.padding(.top, 10)` from the
  `MacTitlebar` invocation. The 44pt chip frame now starts at y=0
  and the macOS traffic lights overlay vertically centered against
  it (lights at y≈14..30, chip glass at y≈7..37).

### Result

- Tab chip (Chat / Usage / Code / Design / Settings) at the top edge
  of the window, level with the traffic lights.
- No more empty dark band above the chip.

## [0.22.6 build 88] - 2026-05-22 — Fix: hide native macOS titlebar so the Tahoe chip is the top (`fix/native-titlebar-hide`)

Cosmetic-but-glaring fix to the dashboard window. The Tahoe titlebar
(tab chip + status chips) had been stacking *underneath* the native
macOS title bar, giving the window two visible top bars: an empty
"Continuum" title strip on top, and the real interactive titlebar
below it. The design always intended the Tahoe chip to BE the top of
the window.

### Changed

- **`ClawdmeterMacApp.swift`** — added `.windowStyle(.hiddenTitleBar)`
  and `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` to the
  main `Window("Clawdmeter", id: "dashboard")` scene so SwiftUI hides
  the native title strip. The macOS traffic-light controls (close,
  minimize, zoom) remain functional — AppKit overlays them at the
  top-left of the window content.
- **`MacRootView.MacTitlebar.body`** — dropped the decorative
  `TahoeGlass { TahoeTrafficLights() }` chip that was a non-functional
  Tahoe-themed clone of the real lights. Replaced with a 76pt invisible
  spacer (`Color.clear.frame(width: 76, height: 1)`) so the tab chip
  starts past the real traffic-light cluster instead of colliding with
  it.

### Why

The previous build's `Window` scene didn't apply any `windowStyle`
modifier, so AppKit defaulted to the standard titled window — which
draws its own title strip above whatever SwiftUI puts in `.body`. The
Tahoe titlebar was sitting in the content area beneath it.
`.hiddenTitleBar` is the standard SwiftUI escape hatch for this:
content extends to the top of the window and the system traffic lights
overlay at their canonical position.

### Result

- One titlebar instead of two.
- Real traffic lights (functional, non-collisional with tab chip).
- Tab chip starts at x≈86pt (10pt leading padding + 76pt spacer), past
  the standard 72pt traffic-light cluster width.

## [0.22.0 build 82] - 2026-05-22 — Design tab: Open Design embedded on Mac + iOS (`feat/design-tab-open-design`)

The biggest feature add in months: a fully-functional **Design** tab that
embeds [Open Design](https://github.com/darshanbathija/open-design) v0.7.0
across Mac and iOS, with seamless Code↔Design handoff. ~3000 LOC across
26 source/test files + bundled Node daemon, web build, plugin, and bridge
sidecar (~80MB of vendored runtime artifacts).

### Added

- **Mac Design tab** (`MacDesignView` + `MacRootView` routing) — clickable
  titlebar tab between Code and Settings; live "● project-name" chip in the
  titlebar with health-dot color tied to daemon lifecycle (green=running,
  amber=starting, red=crashed). Loads `http://127.0.0.1:<od-port>/` in a
  WKWebView once the daemon is ready. Cold-start UX uses a Tahoe glass card
  with pulsing sparkles + live status line streamed from the daemon's stdout.
  Bloom-pink accent (`TahoeAccent.bloom`) across the tab chip, sparkles, and
  Open-in-Design CTA.
- **iOS Design tab** (`IOSDesignView`) — replaces the standalone Live tab
  (which folds permanently into Analytics as a header). New 4-tab order:
  Chat / Analytics / Code / Design with `pencil.and.ruler` icon. Loads the
  paired Mac's daemon through the new `DesignPortForwarder` over Tailscale,
  with `WKHTTPCookieStore`-backed auth so subresources keep working.
- **`OpenDesignDaemonManager`** — spawns the bundled Open Design daemon in
  sidecar mode (`apps/daemon/dist/sidecar/index.js` with `--od-stamp-*`
  flags) so the daemon opens its IPC socket. Singleton `flock` on
  `~/Library/Application Support/Clawdmeter/open-design/.daemon.lock` runs
  on a detached task so the blocking `LOCK_SH` syscall never freezes
  MainActor. Atomic rendezvous file (write-temp + `rename(2)`) lets a
  second Continuum instance attach without spawning a duplicate daemon.
  `OD_API_TOKEN` persisted in Keychain, never written to disk. Real
  parent-death tracking via `OD_TOOLS_DEV_PARENT_PID` so `kill -9` of the
  parent reaps the child within ~1s.
- **`DesignPortForwarder`** — `NWListener` TCP byte-pump that fronts the
  loopback daemon for iOS. Parses only the first 8KB header block to
  extract auth, then switches to pure streaming pass-through (SSE, WS,
  multipart, range, abort — all transparent). Cookie injector skips
  1xx + recognizes 101 Switching Protocols as terminal so WebSocket
  upgrades work. Real DNS-rebind defense (loopback, system hostname,
  `.ts.net`, `.local` only). Strips `?token=` from the request line
  before forwarding to keep tokens out of daemon access logs.
- **Code → Design handoff** — File menu **"Open Folder in Design…"**
  (`Cmd-Shift-O`) on Mac picks a folder, calls the bundled
  `clawdmeter-bridge-host` Node sidecar which mints an HMAC-signed
  desktop-import-token and calls Open Design's `/api/import/folder`. On
  success, MacRootView flips to the Design tab and shows a "Switched to:
  <project>" toast (autodismiss 2s; degrades to instant cut under
  `accessibilityReduceMotion`). iOS reaches the bridge via the new
  `POST /design/import-folder` route on AgentControlServer (bearer
  protected, same as every other AgentControl route).
- **Design → Code handoff** — bundled `clawdmeter-bridge` Open Design
  plugin renders an "Open in Code →" button in the artifact toolbar.
  Posts to the WKWebView's native bridge, which routes to a Swift
  `WKScriptMessageHandler` that flips the tab back. Works identically on
  Mac and iOS (iOS wires through a `@Binding tab` cascade).
- **`Cmd-1`..`Cmd-5` keyboard shortcuts** for the Mac titlebar tabs
  (Chat / Usage / Code / Design / Settings).
- **Pairing QR extended** with `&dp=<forwarder-port>&dt=<HKDF(OD_API_TOKEN,
  pairingToken)>` so iOS gets per-pairing-rotated design credentials.
  Revoking the pairing automatically invalidates the design token.
- **Bundled artifacts** under `apple/ClawdmeterMac/Resources/Vendor/open-design/`:
  daemon dist (254KB cli.js + sidecar), Next.js static export (~30MB),
  production node_modules (~80MB total tree), plugin manifest + renderer,
  and the bridge sidecar. `tools/build-bundled-open-design.sh` is
  stamp-gated (skips when source unchanged), forces arm64 native prebuilds
  for `better-sqlite3`, and per-file `codesign`s every `.node` Mach-O
  binary (no `--deep`, no `|| true` swallowing).
- **DMG smoke test** asserts `Vendor/open-design/{daemon,web,bridge}` are
  present in the mounted .app and that DMG size stays under the 350MB
  soft budget (final size: ~330MB measured).

### Changed

- **iOS tab bar reshuffled** to 4 items: Chat / Analytics / Code / Design.
  Live tab folded into Analytics as a permanent `LiveGaugesHeader` so the
  always-on live gauges still surface. `.live` enum case retained for
  binary compat with deep-links.
- **`MacTitlebar` signature** updated to take `runtime: AppRuntime?`
  (matching origin/main's PR #28 refactor) so the Design chip can read
  `runtime.openDesignDaemon.lifecycle` directly.
- **AgentControlServer** gains a `/design/import-folder` route + an
  `attachDesignBridge(bridgePortProvider:bridgeAuthTokenProvider:)` wiring
  method. Two-listener coexistence test (R3) confirms existing `/usage`,
  `/sessions`, `/analytics` routes still work.

### Fixed

- 1 critical race + 3 informational issues caught by `/review`
  (MainActor `flock` deadlock, daemon orphan on `kill -9`, iOS handoff
  no-op, double-kill cosmetic warning).
- 6 P1 + 3 P2 issues caught by Codex adversarial review (forwarder never
  instantiated, bridge had no auth, rendezvous leaked apiToken to disk,
  stale port stamp, missing termination handlers, fake DNS-rebind
  defense, WKUserScript injected into all frames, 101 Switching Protocols
  mis-classified, codesign failures silenced).

### Tests

- 22 new unit tests added (`DesignPortForwarderTests` × 9 + `OpenDesignDaemonManagerTests` × 13)
  covering token-strip, 1xx-skip cookie injection, bracketed-IPv6 host
  validation, `BridgePortAtomic` concurrent stress, HKDF derivation
  determinism. Total Mac test suite: **104 tests, 0 failures**.

### Live verification

- Daemon spawned in sidecar mode against the built bundle; IPC socket
  opened at `/tmp/open-design/ipc/clawdmeter/daemon.sock`.
- Bridge IPC handshake logged `HMAC secret registered with daemon`.
- `POST /import-folder { baseDir: /tmp/od-test-import }` end-to-end:
  bridge minted token → daemon imported folder → project visible in
  subsequent `/api/projects`.

## [0.22.5 build 87] - 2026-05-22 — Fix: iOS chat UX + always-visible pairing CTA

User-reported (consecutive feedback notes):
1. "Chat data on iPhone app is slop. New session button doesn't work,
   there's no view to look at all the chats. Attach button doesn't
   work. Model selector doesn't work. No keyboard collapse on scroll."
2. "There's no connect CTA or tailscale status — blank with nothing
   actionable. iPhone shows 'not connected' with no flow or button
   to connect."

### Always-visible pairing banner (v0.22.5)

- New `IOSUnpairedBanner` view rendered above the floating tab bar
  whenever `agentClient.isConfigured == false`. Visible across
  every tab (Chat / Analytics / Code / Design), not just buried
  inside `LiveGaugesHeader` (the previous only-CTA location).
- Banner CTA "Pair iPhone" pushes the existing `IOSPairingView`
  (Scan QR + Paste URL — wired in PR #28).
- Bottom clearance auto-adjusts (92 → 168) so content doesn't
  slide under the banner.

### iOS chat surface fixes

- **"+" header button** — was decorative `IOSRoundIconBtn("plus")`
  with no action. Now calls `composerController.reset()` so the
  user starts fresh; the next first-send creates a new chat
  session via `.chatCreate`.
- **"archive" header button** — was decorative. Now opens the new
  `IOSChatHistorySheet` listing all `agentClient.chatSessions`
  (filtered to `kind == .chat`, sorted by recency). Solves the
  "no view to look at all the chats" gap.
- **Model selector** — composer's leading "+" attach icon
  (decorative; file/image attach was never wired) replaced by a
  real SwiftUI `Menu` agent picker. Tap to switch between Claude /
  Codex / Antigravity / OpenCode. Picked agent is bound via a new
  `pickedAgent: AgentKind` `@State` on `IOSChatView`; first-send
  routes through the picked provider (was hardcoded to `.claude`).
- **Keyboard dismiss on scroll** — added
  `.scrollDismissesKeyboard(.interactively)` to the chat scroll
  view. Drag-down to dismiss the keyboard while reading.
- **Decorative mic icon retired** — system keyboard already exposes
  dictation via the globe key.

### Known gaps (still v1.2 product surfaces)

- Chat thread still renders `TahoeDemo.chatThread` fixture data
  (full iOS broadcast UI pivots to real `chatStore` data — same
  surface as `MacChatDataAdapter` does for Mac)
- Real file/image attach (composer "+" was never plumbed to a
  backend upload RPC)
- Tapping a row in the history sheet just dismisses (deep-link to
  the open thread needs the chat view to pivot to real data first)

### Tests

- 620/620 shared tests pass; 104/104 Mac tests pass
- Mac + iOS + Watch all build clean

## [0.22.4 build 86] - 2026-05-22 — Fix: menu-bar popover showed demo data instead of real Claude/Codex/Antigravity usage

User-reported bug: opening any menu-bar status item's popover showed
`67% / 4d 6h` for all three providers regardless of actual usage. The
status item label itself (`15% 3h 10m`) was correct, but the popover
hovering below it showed `TahoeDemo.liveData[.claude]` placeholder
values.

### Root cause

`MacMenubarPopover` took its data as a value-typed
`TahoeLiveBindings` snapshot via init parameter. `NSPopover` hosts the
SwiftUI content through an `NSHostingController` that captures the
struct **once at construction time**. Status items are eagerly built
in `AppDelegate.applicationDidFinishLaunching` → `configure(runtime:)`
→ `ProviderStatusController.ensureStatusItem()`, which runs *before*
any of the per-provider `UsagePoller`s has completed its first poll.
At that point `runtime.tahoeLive` returned `.demo` for every provider
without real data. The snapshot stuck there forever — subsequent
polls updated the menu-bar status text (which uses a direct
`model.objectWillChange` subscription) but the popover content never
re-rendered.

### Fix

- New `MenuBarLiveSource` `@MainActor`-isolated `ObservableObject`
  wrapper carries the three `AppModel`s together and forwards each
  one's `objectWillChange` to its own publisher.
- `MacMenubarPopover` adds a production init that takes
  `claudeModel`/`codexModel`/`geminiModel` directly + an
  `@ObservedObject private var liveSource: MenuBarLiveSource`. SwiftUI
  re-renders the popover `body` on every poll because the wrapper's
  `objectWillChange` fires whenever any model's `usage` updates.
- The body computes `liveData: TahoeLiveBindings` per render from
  current `model.usage` values via a new `liveRow(model:provider:)`
  helper that mirrors `MacTahoeAdapter.tahoeLive` for the same
  provider.
- `AppDelegate.ensureStatusItem()` switched to the new production
  init when `runtime` is non-nil; preserves the old `.demo` init for
  the no-runtime test path.
- Existing Preview / demo `data:` init kept as a convenience.

### Tests

- 620/620 shared tests pass; 104/104 Mac tests pass
- Mac + iOS + Watch all build clean

### Verification (manual)

Open menu bar popover → segmented control shows real Claude/Codex/
Antigravity percentages matching the status-item label beside the
popover. Switch between segments → numbers update for each provider.
After ~60s (next poll) → all three providers' meters animate to the
fresh values without re-opening the popover.

## [0.22.3 build 85] - 2026-05-22 — Zero decoration: retire iOS PickWinner + Mac chat empty-state demo (PR #36)

Closes the last 2 by-design no-ops surfaced in the PR #34 audit retro.
After this PR, the Tahoe surfaces have **0 decorative buttons and 0
documented no-ops**.

### Retired

- **`IOSChatView.PickWinnerButton`** (`apple/ClawdmeteriOS/Tahoe/IOSChatView.swift`)
  — was: empty `action: {}`. iOS chat doesn't construct frontier
  (broadcast) sessions yet, so there was no groupId or childIndex to
  fire against. Removed from `IOSReplyCard` + the struct definition
  itself deleted. The Mac surface keeps its wired equivalent
  (`PickWinnerMenu` in `MacChatView`'s ChatStream header) where
  broadcast sessions actually exist. iOS broadcast UI returns the
  button (with proper threading) as a v1.2 surface.
- **`MacChatView.HistoryRow` + `HistorySection`** (`apple/ClawdmeterMac/Tahoe/MacChatView.swift`)
  — was: empty `action: {}` rendered for fixture `TahoeDemo.chatHistory`
  entries in the sidebar empty-state preview. Replaced by a new
  `ChatSidebarEmptyState` informational view that says "No chats yet"
  with clear copy directing the user to the New chat button. Mixing
  real + demo rows confused users; honest empty-state beats a
  fake-looking sidebar.

### Wiring tally

- **100% wired** (up from ~96% post-PR #35)
- 0 decorative, 0 by-design no-ops
- All buttons either call a real RPC, navigate, or have been deleted

### Tests

- 620/620 shared tests pass
- 89/89 Mac tests pass
- Mac + iOS + Watch all build clean

See [`docs/button-wiring-audit.md`](docs/button-wiring-audit.md) for
the final v1.2 audit table.

## [0.22.2 build 84] - 2026-05-22 — Historical sessions: re-open archived (PR #35)

Wires the previously-no-op RecentRow on both Mac and iOS Code surfaces.
Tapping an archived session row now calls the daemon's existing
`POST /sessions/:id/unarchive` endpoint and re-focuses the restored
session in the right column.

### Wired

- **`TahoeCodeRecent.sessionId: UUID?`** — new optional field that
  carries the real `AgentSession.id` when the row represents an
  archived Continuum session. Nil for JSONL-only entries (no
  Continuum session ever existed for those files).
- **MacTahoeAdapter** — merges archived AgentSessions into each repo's
  `recents` list, sorted by `archivedAt` desc. Archived entries take
  priority over JSONL-only ones; combined list capped at 4 rows.
- **IOSTahoeAdapter** — same: per-repo grouping of archived sessions
  with `sessionId` populated. Repo cards now appear even when only
  archived sessions exist for the repo.
- **MacCodeView.RecentRow** — tap handler calls
  `client.unarchiveSession(id:)` + `refreshSessions()`; on success
  invokes the parent's `onOpenRestored` callback to flip `openId` to
  the restored session. Visible chevron when actionable; muted/no-op
  for JSONL-only entries.
- **IOSCodeView recent row** — same flow: tap → unarchive + refresh
  → push session detail. Inline ProgressView during the RPC.

### Backend

No changes — `POST /sessions/:id/unarchive` already existed in the
daemon (G7); `AgentControlClient.unarchiveSession(id:)` was already
on the client. PR #35 just wired the existing surfaces.

### Tests

- 620/620 shared tests pass
- 89/89 Mac tests pass
- Mac + iOS + Watch all build clean

### Wiring tally

- **~96% wired** (up from ~95% post-PR #34)
- 3 remaining by-design no-ops (iOS PickWinnerButton + 2 Mac chat
  empty-state previews) — PR #36 closes those

## [0.22.1 build 83] - 2026-05-22 — Button-wiring audit retro

User-requested audit revealed 9 still-decorative buttons across the
Tahoe surfaces. PR #34 wires 7 of them; the remaining 2 are explicit
v1.2 product surfaces (historical sessions + iOS broadcast UI).

### Audit findings (vs. PR #23 baseline 102/102)

| Status | Count | Notes |
|--------|-------|-------|
| Wired (real backend) | ~95 (95%) | Up from 49 (48%) at PR #23 baseline |
| By-design no-op | 4 (4%) | Documented v1.2 follow-up surfaces |
| Decorative | 0 (0%) | All removed or wired |

### Wired in this PR

- **Mac chat composer broadcast first-send** — was: spawn solo Claude
  + warning. Now: `client.createFrontier(slots:)` with claude/codex/
  gemini → `client.frontierSend(...)` to fan out the prompt to all
  three children. Sibling sessions render in the existing 3-column
  ChatStream via MacChatDataAdapter; pick-winner menu wires to
  `frontierPickWinner`.
- **Mac chat reply card Copy** (D7 retro) — new `CopyReplyButton`
  joins all blocks into one string and writes to NSPasteboard.
  Replaces the unwired `IconBtn(icon: "doc")` placeholder.
- **Mac chat reply card retire** (D7 retro) — drop `IconBtn(refresh)`,
  `IconBtn(arrowR)`, `StarButton`. Per D7 these were never wired,
  never asked for. iOS already dropped these in PR #26.
- **Mac titlebar Usage tab "Sync with iPhone" chip** — was: TODO
  comment. Now: opens `PairingQRPopoverContent` via SwiftUI
  `.popover` anchored to the chip frame.
- **Mac chat sidebar HistoryRow** — was: 7 demo rows always rendered
  with no-op clicks. Now: empty-state preview only (renders the
  demo when `client.chatSessions` is empty, otherwise hidden).

### Remaining by-design no-ops (v1.2 scope)

1. `MacCodeView.RecentRow` — "historical sessions" surface (re-open
   archived sessions) is a v1.2 product feature
2. `IOSCodeView` recent row — same
3. `IOSChatView.PickWinnerButton` — UI is in place but iOS broadcast
   UI hasn't shipped yet; needs groupId/childIndex threaded through
4. `MacChatView.HistoryRow` (empty-state preview only) — renders
   only when no real sessions exist; intentional preview

### Tests

- 620/620 shared tests pass
- 89/89 Mac tests pass
- Mac + iOS + Watch all build clean

See [`docs/button-wiring-audit.md`](docs/button-wiring-audit.md) for
the full updated audit.

## [0.21.0 build 81] - 2026-05-22 — Final v1.1 polish: 4 remaining items shipped

PR #32 closes the remaining v1.1 punch list flagged after PR #31:
repo plumbing on opencode usage, menu-bar dollar variant, and the
Mac chat broadcast multi-pane pivot from TahoeDemo to real data.

### Repo plumbing on opencode usage events

- OpencodeSSEAdapter.register(clawdmeterID:opencodeID:repo:) now
  accepts the repo path; stashed in `repoBySessionID` for the
  `handleUsage` event handler to look up. UsageRecord rows now tag
  with the real cwd instead of "(unknown)".
- AgentControlServer.handleSpawnOpencodeSession passes `req.repoKey`
  on the register call.

### Menu-bar status item dollar variant (A2)

- New `OpencodeStatusController` in AppDelegate — text-only status
  item ("$X.XX") instead of a quota gauge. Subscribes to
  `UsageHistoryStore.$opencodeLiveRecords` so the dollar amount
  updates in real-time as the SSE adapter ingests usage events.
- Default visibility: OFF (opt-in; opencode is not the default
  provider for new users). Pref key `clawdmeter.opencode.menuBarShown`.
- Click → opens dashboard (reuses the existing showDashboardNotification
  plumbing). Tooltip: "OpenCode usage today — click to open the
  dashboard".

### Mac chat broadcast multi-pane fan-out

- New `MacChatDataAdapter` (~170 LOC): builds `TahoeDemo.ChatThread`-
  shaped values from real `[ChatMessage]` streams. Two paths:
  - **Solo**: 1 session id → thread with that provider's replies
  - **Broadcast**: per-provider message dict → thread with all 3
    providers' replies on each turn, zipped by user-prompt index
- MacChatView pivots from `TahoeDemo.chatThread` to live data:
  - Sidebar shows real `client.chatSessions` in a new "Active"
    section (above the legacy demo history sections); broadcast
    groups appear once with a "3×" marker
  - Tapping a session sets `openChatId`, which triggers
    `MacChatDataAdapter` to fold the chat store's messages into the
    thread shape the existing UI renders
  - For broadcast sessions, all sibling child sessions get
    aggregated into one merged ChatThread
- New `PickWinnerMenu` in ChatStream: visible only on broadcast
  sessions with a frontier group; menu items wire to
  `client.frontierPickWinner(groupId:childIndex:)`. The daemon
  archives losers + leaves the winner as the surviving solo session
- `TahoeDemo.ChatReply`, `ChatTurn`, `Attached`, `ChatThread` gain
  public initializers so MacChatDataAdapter can construct them
  cross-target

### Tests

- 620/620 shared tests pass (no regressions — adapters are
  Mac-target only)
- 89/89 Mac tests pass
- Mac + iOS + Watch all build clean

### Known gaps (truly final)

- Tahoe-art for OpenCode brand mark (`tahoe-opencode-mark`) — design
  asset task, falls back to `OpencodeLogo` via AgentKindUI
- Tokenizer-accurate estimateSend (char/4 heuristic ships today)
- iPad-specific layouts for ReviewPane (was always v1.2+)

## [0.20.0 build 80] - 2026-05-22 — OpenCode polish + v1.0 chat finish (PR #31)

PR #31 ships four chunks bundled as the v1.1 polish + v1.0 chat
finish — opencode becomes visually first-class everywhere, settings
surfaces install/auth status, the menu-bar dollar gauge ingests live
cost, and the chat composer's "~$X / send" chip pulls from the real
Pricing rate card.

### Chunk 1 — TahoeProvider.opencode (4th visual lane)

- TahoeProvider gains `.opencode` with violet OKLCH palette (h≈295),
  brand name "OpenCode", template-tinted silhouette asset slot.
- TahoeLiveBindings: 4th `opencode: TahoeLiveRow` stored property +
  row(for:) handler.
- AgentKind → TahoeProvider mappers (MacTahoeAdapter, IOSTahoeAdapter)
  now return .opencode natively (was: .codex fallback).
- ~5 cascading switches updated (Mac usage column, code IDE filter,
  chat agent kind, iOS Live, iOS Analytics).

### Chunk 2 — Settings → Providers panel

- New SettingsCard "Providers" below "Quota & sync".
- OpencodeProviderRow surfaces OpencodeProcessManager state + auth
  list with color-coded state pill (notInstalled / Idle / Starting /
  Running / Failed) and "Open docs" button linking to opencode.ai/docs/auth.
- Refreshes auth on `.task` so signed-in providers appear without a
  manual reload.

### Chunk 3 — OpencodeUsageMapper + dollar gauge (A2)

- New ClawdmeterShared/Analytics/OpencodeUsageMapper.swift (~100 LOC):
  pure mapper from opencode `usage` SSE event → UsageRecord. Lenient
  numeric reader handles Int/Double/NSNumber bridging. Unknown models
  still emit records (attribute to unpriced bucket); all-zero token
  events drop.
- OpencodeSSEAdapter `usage` branch now maps + posts
  `.opencodeUsageRecorded` Notification with the UsageRecord.
- UsageHistoryStore: new `opencodeLiveRecords` @Published bag,
  observer that folds notification payloads in (FIFO-bounded at 5000),
  `opencodeTodayCostUSD` + `opencodeWeekCostUSD` getters.
- MacUsageView: new OpencodeDollarRow strip below the 3 ProviderColumns.
  Shows `$X today` + `$Y this week` per A2 (no rolling 5h window —
  pay-as-you-go).

### Chunk 4 — Pricing.estimateSend + composer chip

- New ClawdmeterShared/Analytics/Pricing+EstimateSend.swift:
  `estimateSend(promptText:agent:model:)` + `estimateBroadcast(...)`.
  char/4 input estimate + 256 notional output tokens for an
  order-of-magnitude chip read.
- MacChatView composer chip now renders live `$X.XXX / send` from
  Pricing.shared. Broadcast mode sums Claude + Codex + Gemini.

### Tests

- 620/620 shared tests pass (up from 613 → +7 PricingEstimateSendTests
  + 9 OpencodeUsageMapperTests landed on PR #30; net +7 here).
- 89/89 Mac tests pass.
- Mac + iOS + Watch all build clean.

### Known gaps (queued for follow-up)

- Repo plumbing on opencode usage events — `handleUsage` currently
  passes `repo: nil`; future polish: stash repo at session.created
  time + look up via sessionMap.
- Mac chat broadcast multi-pane fan-out — pivot from TahoeDemo to
  real `chatStore(for:)` is still scaffolded for solo only; full
  3-pane stream + pick-winner UI is a follow-up.
- Menu-bar status item dollar variant (A2 sole-provider case) —
  lives in AppDelegate.ProviderStatusController; queued.
- Tahoe-art for the OpenCode brand mark (`tahoe-opencode-mark`) —
  AgentKindUI fallback to `OpencodeLogo` ships meanwhile.

## [0.19.0 build 79] - 2026-05-22 — OpenCode runtime: ProcessManager + SSE adapter (D11/D12, P1)

PR #30 lands the runtime that PR #29's wire foundation was designed
for: a singleton `opencode serve` process + an SSE event adapter,
hooked into AgentControlServer so opencode-kind sessions actually
spawn and stream events end-to-end.

### Added

- **OpencodeProcessManager** (`apple/ClawdmeterMac/AgentControl/OpencodeProcessManager.swift`,
  ~300 LOC): P1 singleton per the eng-review decision. Responsibilities:
  - Binary discovery: `/opt/homebrew/bin/opencode`, `/usr/local/bin/opencode`,
    then `$PATH` walk. Surfaces `State.notInstalled` with install hint
    when missing.
  - Free-port allocation via transient `NWListener`.
  - Spawns `opencode serve --port <p> --hostname 127.0.0.1` with a
    per-launch `OPENCODE_SERVER_PASSWORD` token.
  - Healthcheck via `GET /` until 200 lands or 10s deadline.
  - Auth probe via `opencode auth list` (lenient parser handles
    blanks, comments, decorative separators, headers).
  - Restart-on-crash supervisor with exponential backoff
    (1s → 2s → 4s → 8s → 16s), capped at 5 restarts before giving up
    (prevents crash loops eating CPU).
  - Clean shutdown via `stop()`; idempotent.
  - State exposed as `@Published` for the Settings → Providers UI
    (lands in PR #31).
- **OpencodeSSEAdapter** (`apple/ClawdmeterMac/AgentControl/OpencodeSSEAdapter.swift`,
  ~260 LOC): consumes `GET /event` SSE stream + translates events to
  the AgentEventStream shape. Bidirectional UUID map (Continuum ↔
  opencode session ids) + reconnect-with-backoff + Last-Event-ID
  resume. Event handlers:
  - `session.created` → registry hook (synthesis surface logged for now)
  - `message.added` → `.snapshot` event nudge
  - `session.error` → `.statusChanged` with degraded payload
  - `usage` → logged; forwarded to OpencodeUsageMapper in PR #31
  - unknown / empty types → logged + ignored (forward-compat)
- **AgentControlServer.handleSpawnOpencodeSession**: routes opencode
  POST /sessions through the manager + SSE adapter instead of the
  tmux argv path. Mints an opencode session id via the server's
  `/session` POST, registers the bidirectional mapping, creates the
  Continuum-side AgentSession, returns the session JSON. Failure
  surfaces with structured 503 bodies (install hint, spawn detail).
- **AppRuntime.deinit**: tears down ProcessManager + SSE adapter on
  app shutdown.

### Tests

- **OpencodeProcessManagerTests** (11 tests): parseAuthList table-
  driven coverage (single, multiple, blanks, comments, separators,
  headers, malformed lines, colon-in-value), initial state, stop
  idempotency, binary discovery, ensureRunning notInstalled branch.
- **OpencodeSSEAdapterTests** (12 tests): BidirectionalMap round-
  trip + overwrite + removeAll, dispatchEvent robustness (malformed
  JSON, empty, unknown types, missing fields), per-event-type
  handler routing (message.added + session.error registered/unknown
  paths), register idempotency, stop clears map.
- **89/89 Mac tests pass** (up from 66 → +23 opencode tests).
- 604/604 shared tests pass (no regressions).
- Mac + iOS + Watch all build clean.

### Known gaps (queued for PR #31)

- OpencodeUsageMapper + menu-bar dollar gauge (A2)
- Settings → Providers panel UI
- TahoeProvider 4th case + Mac/iOS UI surfaces
- Mac broadcast pipeline + MacChatTranscriptStore (v1.0 chat finish)

## [0.18.0 build 78] - 2026-05-22 — OpenCode adapter foundation (D11/D12 — wire v13)

PR #29 lays the wire + enum foundation for the OpenCode adapter (D11/D12).
This ships the schema migration + cross-version tests so subsequent
follow-up PRs can layer in the runtime (process manager, SSE adapter,
usage mapper, settings panel) against a stable wire.

### Added

- **AgentKind.opencode** (wire v13): new 4th provider case. v12 clients
  fall back to `.unknown` (X3 hardening from PR #28) and render as
  "Other agent"; v13+ clients decode natively.
- **UsageRecord.Provider.opencode**: analytics layer's parallel
  enum. Wired through `AgentKindUI` + `AnalyticsTotalsGrid` +
  `AnalyticsDailyChart` for display name, asset, template flag, and
  cost rollup.
- **AgentControlWireVersion.opencodeMinimum = 13**: new minimum-version
  gate for clients that want to surface OpenCode UI without falling
  back to "Other agent".
- **OpenCode brand styling**: violet accent (`#6B5DD3`) + silhouette
  template asset across both AgentKindUI surfaces (Mac + iOS).
- **Tests**: 2 new tests (native `.opencode` decode + opencodeMinimum
  gate) on top of the updated X3 regression coverage.

### Changed

- `AgentControlWireVersion.current`: 12 → 13.
- `AgentKind.allCases`: now 4 entries (claude/codex/gemini/opencode).
  Pickers + segmented controls render the 4th option natively.
- All ~14 switches on AgentKind across Mac + iOS + Shared get an
  explicit `.opencode` case with the right semantic fallback (no argv
  builder, no JSONL transcript, no warmup choreography — opencode
  sessions route through `OpencodeProcessManager` + SSE adapter when
  those land; the switch fallbacks document the boundary cleanly).
- `IOSAnalyticsView`'s `MergedRepoRow` aggregation skips `.opencode`
  with an explicit comment — the 4th-column UI rewrite is queued for
  the OpenCode analytics polish PR.

### Known gaps (queued for follow-up PRs)

- **OpencodeProcessManager**: P1 singleton (`opencode serve` per-app
  process, binary discovery, port pick, restart-on-crash) not yet
  implemented. Mac dispatcher returns 503 for opencode spawns until
  it lands.
- **OpencodeSSEAdapter**: SSE subscription + event → SessionEventEnvelope
  mapping not yet implemented.
- **OpencodeUsageMapper + menu-bar dollar gauge (A2)**: not yet
  implemented.
- **Settings → Providers row**: install/auth status surfacing not
  yet wired.
- **TahoeProvider**: still 3-case (claude/codex/gemini). Mac +
  iOS visually map opencode → codex as a least-bad fallback; the
  4th-case TahoeProvider refactor is a wider change deferred to a
  dedicated UI PR.

### Tests

- 604/604 shared tests pass (up from 602 → +2 new tests for v13
  opencode decode + opencodeMinimum gate; 3 X3 tests updated for
  the new "future raw" pattern).
- Mac + iOS + Watch all build clean.

## [0.17.0 build 77] - 2026-05-22 — v1.0 polish: X3 + D3 + D4 + Mac chat composer (`feat/v1-polish`)

Closes out the v1.0 polish punch list deferred from PR #26.

### Added

- **X3 forward-compat (wire v12)**: new `AgentKind.unknown` sentinel.
  The lenient decoder folds raws this binary doesn't recognize into
  `.unknown` instead of `.claude` — protects older clients from
  silently mislabeling future kinds (e.g. OpenCode in PR #28). UI
  surfaces render `.unknown` as a neutral "Other agent" tile.
  `allCases` excludes `.unknown` so pickers + segmented controls stay
  clean. `AgentControlWireVersion.current` bumps to 12.
  - 10 regression tests in `AgentKindUnknownTests` cover the decoder
    contract, allCases hygiene, UI fallbacks, and the cross-version
    (v12 client + v13 Mac) regression.
- **D3 IOSPairingView**: replaces the legacy `PairingFlow` surface.
  Buttons now wire to `AgentControlClient.setPairing(...)` — Scan QR
  presents `PairingScannerView` as a sheet, Paste URL presents a
  paste sheet that parses the clawdmeter:// URL via
  `PairingScannerView.parse(urlString:)`. Both paths land on
  `applyChallenge` (byte-for-byte identical to PairingFlow's wire).
  `NewSessionSheet` extracted to its own file. PairingFlow.swift
  deleted.
- **D4 setAutoRevive RPC (wire v12)**: new
  `POST /providers/:id/auto-revive` endpoint on AgentControlServer +
  `AgentControlClient.setAutoRevive(provider:enabled:)` method.
  AppRuntime wires the callback to fan out to the matching
  `AppModel.setAutoReviveEnabled`. iOS Live tab's auto-revive toggle
  now drives the real RPC with optimistic UI (flip local state, fire
  the RPC, don't await).
  - Unknown provider raws + the X3 sentinel return 400 (X3 unknowns
    are never user-toggleable).
  - 4 `SetAutoReviveRequestTests` covering encode/decode/round-trip +
    defensive rejection of malformed body.
- **Mac chat composer wire**: `ChatComposer` rewritten with a real
  `TextField` + `@StateObject ComposerSendController`. First send
  routes through `.chatCreate` (creates session + appends prompt as
  first turn); subsequent sends route through `.solo` for the
  cheaper follow-up path. `SendButton` now takes `enabled`/`sending`/
  `action` so the daemon roundtrip disables the button + spins a
  ProgressView. Broadcast mode degrades to solo-Claude with a soft
  warning until the frontier fan-out wire lands.

### Changed

- `AgentKind.allCases` overrides the auto-synthesized CaseIterable
  conformance to exclude `.unknown`.
- `AgentControlWireVersion.current`: 11 → 12.
- `AgentControlServer.setAutoReviveCallback`: new injection point
  for D4 fan-out.
- `IOSLiveView`: now takes `agentClient: AgentControlClient?` (was
  decorative-only). Auto-revive toggle's setter calls
  `agentClient.setAutoRevive(...)` with optimistic UI.
- `MacChatView`: now takes `loopbackClient: AgentControlClient?` +
  tracks `openChatId: UUID?` for follow-up sends.
- `PairingCTAButtons`: both side-by-side buttons present the same
  IOSPairingView sheet (segmented mode picker removed; new view
  exposes Scan + Paste from one screen).
- All ~20 switches on AgentKind across Mac + iOS + Shared get an
  explicit `.unknown` case with a sensible semantic fallback.

### Removed

- `apple/ClawdmeteriOS/PairingFlow.swift` — replaced by IOSPairingView.
  `NewSessionSheet` (which lived in the same file) extracted to its
  own file at `apple/ClawdmeteriOS/NewSessionSheet.swift`.

### Migration

- Wire version mismatch UX: any v11-or-earlier iOS client paired to a
  v12 Mac sees `WireVersionMismatchBanner` ("Mac is running a different
  version. Update the Mac app."); the banner is non-blocking, the
  app still works.
- `AgentKind.unknown` is intentionally not added to TahoeProvider —
  the iOS Live tab keeps its 3-provider segmented control. Unknown
  AgentKinds map to `.claude` visually as a graceful degradation
  (semantic correctness lives at the AgentKind layer; X3 prevents
  silent mislabeling at the wire decoder).

### Tests

- 602/602 shared tests pass (up from 588 → +14 tests for X3 + D4).
- Mac + iOS + Watch all build clean.

### Known limitations (queued for follow-up)

- Mac ChatStream still renders TahoeDemo.chatThread — the WS-driven
  MacChatTranscriptStore ships in a follow-up PR. The composer
  reaches the daemon today; the assistant's reply stream doesn't
  yet render in the Mac surface (it does on iOS).
- Broadcast chat fan-out degrades to solo-Claude; the full frontier
  slot list wire lands with the transcript store.

## [0.16.0 build 76] - 2026-05-22 — iOS session search + Mac titlebar truth (`feat/wiring-polish` partial)

PR #26 partial — D5 (iOS session search) and D6 (Mac titlebar
wiring). D3 (IOSPairingView replace), D4 (setAutoRevive RPC), and X3
(AgentKind.unknown forward-compat) deferred to a v1.0 follow-up
branch.

### Added

- **iOS session search (D5)**: real `TextField` in `IOSCodeView`'s
  search row, filters repos + sessions by case-insensitive contains
  on title and repo name. Clear button (×) appears when query
  non-empty. Empty query is regression-safe (identical to today).
- **Mac titlebar truth (D6)**: replaced the lying `"Updated 14s ago"`
  label with a live "N repos tracked" pill. "Sync with iPhone" / "iPhone
  paired" chips now reflect real pairing state from
  `PairingTokenStore.shared.hasAnyPaired` (new public property —
  true when a token's been issued and not revoked). Usage-tab chip
  is now a Button (target: QR popover in a v1.0 follow-up).

### Changed

- `PairingTokenStore.hasAnyPaired: Bool` — new public accessor for
  the titlebar (and any future "paired devices" UI).

### Deferred to v1.0 follow-up

- **D3** — `IOSPairingView` rewrite + `PairingFlow.swift` retirement.
- **D4** — `setAutoRevive(provider:enabled:)` daemon RPC + iOS toggle wire.
- **X3** — `AgentKind.unknown` forward-compat for PR #27 safety. **Required
  before PR #27 lands** to avoid mislabeling OpenCode sessions on
  v0.16 clients.
- Mac titlebar "Sync with iPhone" tap → QR popover (currently no-op).

Builds clean on Mac + iOS + Watch.

## [0.15.0 build 75] - 2026-05-22 — iOS chat composer wired + reply icons cleaned up (`feat/chat-pipeline`)

PR #25 partial — D1 (chat pipeline) iOS half + D7 (reply icons
cleanup). Mac chat composer wiring deferred to a v1.x follow-up since
it's parallel work the v1.0 ship doesn't depend on.

### Added

- **iOS chat composer is a real TextField + send button.** Bound
  through `ComposerSendController` (shared module). First send creates
  a chat session via `client.createChatSession(provider:.claude)`
  and dispatches the text as the first turn. ChatGPT-style sendable
  TextField with `.submitLabel(.send)`.
- **Copy reply on iOS assistant cards** — uses `UIPasteboard.general.string`.

### Changed

- **D7 cleanup**: refresh + star reply icons retired (drop on iOS).
  Copy remains (was previously a placeholder `IOSReplyAction(icon:
  "doc")` with empty action).
- `IOSChatView.init` now accepts optional `agentClient` so the
  composer can dispatch through it. Nil disables the composer.
- `IOSRootView` passes the live `agentClient` through.

### Deferred (v1.x follow-up)

- Mac chat composer wiring (the wire is structurally the same; lands
  in a small follow-up PR).
- Broadcast streaming UI with per-provider columns + WS subscription
  (`MacChatTranscriptStore`).
- History row navigation.
- Cost-per-send Pricing helper.
- PickWinnerButton wiring (needs the active session's
  `frontierGroupId`).

Builds clean on Mac + iOS + Watch.

## [0.14.0 build 74] - 2026-05-22 — Mac Code IDE ReviewPane wired end-to-end + sidebar filter (`feat/mac-code-reviewpane`)

PR #24b — the second half of the Code IDE work. After this PR the Mac
Code IDE is feature-complete: every tab in the right ReviewPane shows
real data, the sidebar filter actually filters, and there are no more
demo-only buttons in production.

### Added

- **ReviewPane Diff tab** embeds the existing `GitDiffPane` (633 LOC,
  pre-existing in `apple/ClawdmeterMac/Workspace/`). Reads `git diff
  HEAD` against the session's worktree; renders structured hunks with
  stage/unstage interactions.
- **ReviewPane Sources tab** embeds the existing `SourcesPane`. Reads
  the session's `SessionChatStore` (per-session chat-snapshot path).
- **ReviewPane PR tab** embeds the existing `PRReviewPane` + the
  `PRMirror` singleton (per session). Auto-detects GitHub PR URLs from
  the chat transcript and polls `gh pr view --json` every 30s.
- **ReviewPane Term tab** embeds `MacTerminalView` (SwiftTerm-backed)
  over the local loopback WS. `paneId=nil` connects to the session's
  primary tmux pane.
- **Sidebar filter SwiftUI Menu** (D8): Status / Provider / Sort
  sections, persisted to UserDefaults
  (`clawdmeter.codeIDE.filter.*`). Filter applies before the repo
  ForEach; no-match repos collapse with a helpful empty-state.

### Changed

- ReviewPane no longer hides Diff / Sources / PR / Term in production
  — they show alongside Plan. Demo bindings keep the JSX-fixture
  fallbacks for SwiftUI Previews; production shows in-process embeds
  per X1 (no new HTTP endpoints needed).
- `MacCodeView` now accepts `runtime: AppRuntime?` so ReviewPane
  embeds can reach `agentSessionRegistry`, `sessionsModel`,
  `agentControlServer`, `tmuxClient`. Mac-target-only; nil falls back
  to demo content for Previews.
- `MacCodeView` + its enums + types dropped `public` (internal access
  is sufficient — this view only ever runs inside the Mac app target).

### Test deliverables

The ReviewPane embeds are wrappers around components that already have
their own coverage (`GitDiffStore.parseTests`, `PRMirror` polling
tests, etc.) — the wrapper code is mostly init/teardown plumbing that
XCTest UI tests would cover better than unit tests. UI test scaffolding
deferred to a follow-up branch. Build verification on all three
platforms guards the structural correctness.

Builds clean on Mac + iOS + Watch.

## [0.13.0 build 73] - 2026-05-22 — Mac loopback transport, ComposerSendController, real Code IDE actions (`feat/mac-loopback-transport`)

PR #24a (the first half of the Code IDE work, per the X2 plan split).
Mac now talks to its own daemon over loopback HTTP/WS — same code path
iOS uses — so the Code IDE's plan-approve, refine, send-prompt, and
stop actions all reach the daemon for real. Implements D2 (sessions +
actions surface only; ReviewPane stays in-process in PR #24b per X1),
A1 (synchronous bootstrap), A3 (Edit plan = Refine semantically), and
CQ1 (shared `ComposerSendController` state machine).

### Added

- **`apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AgentControlClient.swift`**:
  relocated from `apple/ClawdmeteriOS/`. Gains a second initializer
  `init(host:httpPort:wsPort:token:)` that holds pairing values
  in-memory per instance (Mac loopback path). Existing zero-arg init
  (UserDefaults-backed) preserved for iOS. `setPairing` /
  `clearPairing` are no-ops on explicit-config instances so they
  cannot corrupt iOS pairing keys.
- **`apple/ClawdmeterShared/Sources/ClawdmeterShared/Composer/ComposerSendController.swift`**:
  shared send-state state machine (CQ1). 4 surfaces consume:
  `text` / `sending` / `lastError` / `canSend` / `send(via: SendKind)`.
  `SendKind`: `.solo` / `.refine` / `.broadcast` / `.chatCreate`.
- **`apple/ClawdmeterMac/AgentControl/MacLoopbackClient.swift`**:
  `@MainActor` factory that builds an `AgentControlClient` for
  `127.0.0.1` + the local server's bound ports + a fresh loopback
  token. Returns nil only when the agent server failed to bind any
  port — surfaces as an `NSAlert` so users aren't left with a
  silently-broken Code IDE.
- **`AgentControlServer.localLoopbackToken`**: per-launch random UUID
  for in-process clients. Auth path now accepts either pairing tokens
  (iOS) or this loopback token (Mac) via a centralized `isAuthorized`
  helper.
- **`AgentControlClientSessionObserver`** (iOS): forwards the new
  `Notification.Name.agentControlSessionsRefreshed` (posted from
  Shared) to `LiveActivityCoordinator` + `WatchPlanBridgeIOS`. The two
  iOS singletons used to be called directly from inside
  `AgentControlClient.refreshSessions()`; they live in the iOS app
  target and couldn't follow the client into Shared.

### Changed

- **Mac Code IDE actions** in `MacCodeView.swift` now reach the real
  daemon:
  - PlanHalo "Approve & run" → `client.approvePlan(sessionId:)`.
  - PlanHalo "Refine" + "Edit plan" → modal Refine sheet (TextEditor)
    → `sendPrompt(asFollowUp:true)`. A3: both buttons share the same
    wire; Edit plan is just Refine with planText pre-filled.
  - Composer (idle) Send button → real `TextField` bound to
    `ComposerSendController.text` → `sendPrompt(asFollowUp:true)`.
  - LiveTicker Stop → `client.interruptSession(sessionId:)` +
    composerState reset.
- **`AppRuntime.loopbackClient`**: optional published property set
  after `agentControlServer.start()` completes its synchronous bind.
- **`AppDelegate.configure(runtime:)`**: surfaces server-bind failure
  via NSAlert (critical-gap fix from the plan's failure-modes table).
- `AgentControlClient.urlHostLiteral` is now `public` so iOS-target
  callers (`GeminiQuotaLiveActivityCoordinator`) can still reach it
  after the relocation.

### Test deliverables (T1)

- **`AgentControlClientInitTests`** (8 tests): regression coverage for
  the two construction modes; UserDefaults isolation verified;
  explicit-config setPairing/clearPairing no-ops verified.
- **`ComposerSendControllerTests`** (9 tests): state-machine coverage
  including the A3 solo/refine wire-share contract.

Builds clean on Mac + iOS + Watch.

## [0.11.0 build 72] - 2026-05-21 — Tahoe Code real data, native `.glassEffect`, legacy retirement (`feat/tahoe-code-and-legacy-retirement`)

Finishes the v0.10 redesign with three substantial follow-ups: real
session data plumbed into the Code tab on both platforms, the native
macOS 26 / iOS 26 / watchOS 26 `.glassEffect()` API in use everywhere,
and the dead legacy view layer retired.

### Added

- **Mac Code IDE — real data.** `MacCodeView` now reads
  `runtime.repoIndex` + `runtime.agentSessionRegistry.sessions` through
  a new `TahoeCodeBindings` value type and a `runtime.tahoeCode`
  adapter. Sidebar repos are the real repo list with per-repo live
  session counts; sessions show real status (`planning` / `running` /
  `paused` / `done` / `degraded`), real model labels, real "X minutes
  ago" subtitles, and a stable hash-derived tint per repo. The Plan
  Halo card parses `AgentSession.planText` into bullet-numbered steps,
  with branch label inferred from `worktreePath`.
- **iOS Code — real data.** `IOSCodeView` consumes the daemon-backed
  `AgentControlClient.sessions` via `client.tahoeCode`. Sessions group
  by repo key with the same tint scheme as Mac. Empty-state copy
  explains the pairing flow ("Sessions started on your Mac will appear
  here once you're paired").
- **Native Liquid Glass.** `TahoeGlass` now uses Apple's
  `.glassEffect(.regular, in: shape)` API on macOS 26 / iOS 26 /
  watchOS 26 (gated by `#available`) with a `.regularMaterial`
  fallback for older OSes. The visual is now the real Tahoe Liquid
  Glass, not a SwiftUI Material approximation.

### Changed

- **Plan Halo step count is dynamic** — was hardcoded to "5 steps" in
  the eyebrow text; now reads from the parsed plan length.
- **Plan Halo commit-branch chip** — was hardcoded
  `fix/settlement-dedupe`; now reads from
  `session.commitBranch` (derived from `worktreePath`).
- **Empty states for both Code surfaces.** No-repo / no-session cases
  render an explanatory card rather than collapsing the layout.
- **Auto-expand new live repos.** Repos that gain a live session while
  the user is on the Code tab auto-expand in the sidebar.

### Production safety (post-codex-review hardening)

The Codex adversarial review caught a class of demo-fallback risks
where the Code surface would show fixture content as if it were real
session data. `TahoeCodeBindings` now carries an explicit `isDemo`
flag; demo-only views are gated on it so production renders
empty-state placeholders instead of fake plans, diffs, or PR checks.

- **Adapters return `.empty`, not `.demo`.** Mac and iOS adapters now
  return `TahoeCodeBindings.empty` when there's no live data — only
  SwiftUI Previews see the demo fixture.
- **`MacCodeView.Thread` placeholders.** Production renders a "Live
  transcript coming soon" card; only `isDemo == true` renders the JSX
  fixture thread.
- **`ReviewPane` hides unfinished tabs.** In production only the Plan
  tab is visible (and it shows an empty-state when no
  `runtimePlanText` exists). Diff / Sources / PR / Term tabs render
  only in demo bindings until their wires ship.
- **Plan Halo only when there's a plan.** Composer state starts
  `.idle` in production and only auto-cycles to `.plan` when the open
  session has non-empty `runtimePlanText`. Approve & Run is disabled
  outside demo until the daemon approval wire lands. The "Will commit
  to `<branch>`" hint only renders for real worktree sessions.
- **iOS session detail uses real data.** `IOSRootView.Screen` is now
  `.sessionDetail(UUID)` carrying the opened session's id;
  `IOSSessionDetailView` looks up the real session and renders its
  actual title / agent / model / status.
- **iOS daemon refresh wired.** `IOSRootView` calls
  `agentClient.refreshAll()` on appear and on pull-to-refresh — the
  Code tab no longer waits indefinitely for the daemon to push.
- **iOS plus buttons wired.** Title-row and per-repo `+` buttons
  present `NewSessionSheet` (made internal — was private — in
  `PairingFlow.swift`).

### Removed

The Tahoe redesign's hot legacy callers finally have replacements, so
the corresponding files retired:

- `apple/ClawdmeteriOS/iOSSessionsView.swift` (1919 LOC) — its inline
  `PairingFlow` extracted to `apple/ClawdmeteriOS/PairingFlow.swift`
  so `PairingCTAButtons` still works.
- `apple/ClawdmeteriOS/iOSChatSoloView.swift` (336 LOC) — the Tahoe
  `IOSChatView` is the only chat surface; `iOSPermissionPromptCard`
  was internal to this file and went with it (the new IOSChatView
  will host its own permission UI when prompt-respond ships).
- `SessionsView` SwiftUI struct deleted from
  `apple/ClawdmeterMac/SessionsView.swift` (file kept because it now
  holds `SessionsModel` + `NewSessionMacSheet`).
- `MenuBarGaugeView` SwiftUI View body deleted from
  `apple/ClawdmeterMac/MenuBarGaugeView.swift` (file kept because
  `AppDelegate.ProviderStatusController` still calls the static label
  renderers).

Net delete: 2 files, ~2,255 LOC removed. The remaining files are now
data-layer / renderer-only — no SwiftUI View structs.

### Risks / Out of scope

- Full chat-thread streaming in `MacCodeView.Thread` not yet wired —
  production now renders a "Live transcript coming soon" placeholder
  instead of demo content. Streaming follows in the next release.
- Mac Chat broadcast send still demo data.
- ReviewPane Diff / Sources / PR / Term tabs hidden in production
  until daemon wires ship; only the Plan tab is exposed.
- Watch IA unchanged (still colors-only Tahoe port).

## [0.10.0 build 71] - 2026-05-21 — Tahoe 26 / iOS 26 liquid-glass redesign (`feat/tahoe-redesign`)

Full visual redesign of the Mac, iOS, and Watch apps to the iOS 26 / macOS 26
Tahoe liquid-glass language. New theme system, new tab structure, real per-provider
data plumbed into the new views, and the entire legacy view layer retired.

### Why

The previous Anthropic-terracotta theme was a build-out from when Continuum was a
Claude-only quota gauge. The product is now a three-provider workspace (Claude /
Codex / Antigravity) with Chat, Code, Usage, Settings, Live Activities, and a paired
iPhone surface. The chrome needed to grow up: Apple shipped Liquid Glass in macOS 26
/ iOS 26, and the redesign brief was explicit — "beat Conductor and Codex in feel,
look like a native Apple app." This release ships that.

### Added

- **Tahoe foundation** (`ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/`): an
  observable `TahoeThemeStore` with appearance × surface × accent × wallpaper ×
  glass-intensity × provider-focus state, OKLCH→sRGB color tokens, glass / pill /
  accent-button / ghost-button primitives, an SF Symbol bridge for every JSX icon
  name, a hand-built 34×22 toggle that matches iOS native geometry, a quota
  pill-bar gauge, and 5 wallpaper backdrops (aurora / dawn / graphite / code /
  studio).
- **Mac surfaces**: `MacRootView` with floating titlebar tabs (Chat / Usage / Code
  / Settings) and a hosted Broadcast/Solo mode toggle inline. `MacChatView`
  (3-column compare, sidebar with collapsible history, brand-striped reply
  cards). `MacUsageView` (3 ProviderColumns + analytics row with range selector,
  stacked spend chart, by-repo bars). `MacCodeView` (sidebar repos + thread +
  Plan Halo hero + LiquidComposer with LiveTicker + ReviewPane × 5 tabs).
  `MacSettingsView` driving the global theme. `MacMenubarPopover` replacing the
  legacy popover with a per-provider segmented + stacked meters.
- **iOS surfaces**: `IOSRootView` with floating glass tab bar (Chat | Live |
  Analytics | Code). `IOSChatView` (broadcast strip, model pills, reply cards).
  `IOSLiveView` (per-provider segmented, hero QuotaBar, Weekly + Auto-revive).
  `IOSCodeView` + `IOSSessionDetailView` with repo expand/collapse + Plan-halo
  mini. `IOSAnalyticsView` (period segmented, total card, mini stacked chart).
  `IOSPairingView` rendering a real `CIQRCodeGenerator` QR with halo brackets.
- **Live data wiring**: `TahoeBindings` value structs + Mac/iOS adapter extensions
  (`MacTahoeAdapter`, `IOSTahoeAdapter`) lower AppRuntime / UsageModel into the
  Tahoe views. Mac Usage + Menu Bar Popover render real per-provider session %,
  weekly %, reset times, and revive state from the running pollers.
- **Watch port**: `ClawdmeterWatch` + `ClawdmeterWatchWidgets` migrated off the
  legacy terra-cotta tokens to `TahoeAccent.halo` / `TahoeProvider.*.halo`,
  keeping the Watch in the same visual language as Mac + iOS.
- **Motion polish**: 1.8s pulse on the ComposerBar accent rim while running,
  smooth state transitions between idle / running / plan, 4s aura breath on
  PlanHalo, fill-in animation on QuotaBar percent changes.

### Changed

- **Deployment targets** bumped: macOS 14 → 26, iOS 17 → 26 (Tahoe / iOS 26
  required for native Liquid Glass APIs). Watch stays on watchOS 10.
- **Tab structure**: macOS gains a new Chat tab as the primary entry point;
  Sessions renamed to "Code" in every user-visible label. iOS gains Live as a
  distinct tab (separated out from Analytics).
- **Mode toggle hosted in the titlebar** on the Chat tab (mac-chat.jsx:175 parity)
  — state lifted from `MacChatView` up to `MacRootView` so the segmented control
  renders inline with the tabs chip instead of as its own row.
- **`AppDelegate` menu bar popover** swapped from the legacy `PopoverView` to
  `MacMenubarPopover`, with `runtime.tahoeLive` passed through so each provider's
  status item opens the same 3-provider segmented popover preselected to the
  clicked provider.
- **iOS shell**: `ContentView` now hosts `IOSRootView(usageModel:)`; background
  refresh, notification manager, and live-activity coordinators preserved.

### Removed

Legacy view files retired and deleted:
- `apple/ClawdmeterMac/DashboardView.swift`
- `apple/ClawdmeterMac/PopoverView.swift`
- `apple/ClawdmeteriOS/iOSChatView.swift`
- `apple/ClawdmeteriOS/iOSChatFrontierView.swift`
- `apple/ClawdmeteriOS/iOSChatProviderPicker.swift`
- `apple/ClawdmeteriOS/iOSAnalyticsView.swift`

`MenuBarGaugeView.swift`, `SessionsView.swift`, `iOSSessionsView.swift`,
`PairingScannerView.swift`, and `iOSChatSoloView.swift` are kept for now — each
still has hot dependencies (status-item icon rendering, NewSessionMacSheet,
PairingFlow, iOSPermissionPromptCard). A follow-up will retire them once their
non-view callers are migrated.

### Verifier loop

Built `apple/tools/tahoe-verify` for screenshot capture and ran a 5-round
recursive Explore-agent audit per surface (foundation + 5 Mac + 7 iOS) against
the JSX source of truth. The agents partially hallucinated comparisons; spot-
checks against the actual JSX confirmed most flagged defects were false
positives, but the loop did surface real fixes that landed in this branch:
iOS tab-bar active state needed a second hairline-stroke shadow layer; iOS
Reply Card padding was symmetric where the JSX is asymmetric (14 top / 16 H /
10 bottom); the CompareIcon in the Mac chat mode toggle had been mapped to
`chart.bar` SF Symbol but the JSX is a custom 3-vertical-bar Path; the iOS Chat
floating composer placement was overlapping the tab bar.

### Risk / out-of-scope

- The Tahoe views use SwiftUI `.regularMaterial` for the glass effect rather than
  the new macOS 26 / iOS 26 `.glassEffect()` API. Visually close; we can swap
  once `.glassEffect` ships in a stable SDK without availability gates.
- Mac Chat broadcast send and iOS Code session list still render demo data —
  real `AgentControlClient` wiring lands in a follow-up.
- Watch is a colors-only Tahoe port; the Watch app's information architecture is
  unchanged.

## [0.9.2 build 70] - 2026-05-21 — SDK chat transcript mirror (`feat/chat-v0.9.x.1`)

Fixes the "chat history vanishes after 5 min idle" bug for Codex SDK and
Antigravity agentapi chats.

### Why

`sdkOnly` chat sessions (Codex SDK + Antigravity agentapi) have no
JSONL transcript on disk — chat state lives in the daemon's
SessionChatStore in memory + the provider's server-side thread/DB.
When `DaemonChatStoreRegistry` idle-evicted a store after 5 min of no
subscribers, the visible chat thread was lost. Re-opening the chat
created a fresh empty store; even though Codex SDK could still
`op:"resume"` into the same server-side thread via the persisted
`codexChatThreadId`, the iOS-visible chat thread started blank.

### Fix

New `SDKChatTranscriptMirror` writes every `appendSDKMessages` write
as one JSON-line in
`~/Library/Application Support/Clawdmeter/sdk-chat-transcripts/<sessionId>.jsonl`.
On store re-create, `replay(into:)` reads the mirror and pushes the
messages back through `appendSDKMessages(suppressMirror: true)` so
the snapshot rebuilds without double-writing.

- `SessionChatStore.appendSDKMessages` gains an optional
  `suppressMirror: Bool = false`. When `sdkOnly && !suppressMirror`,
  every appended batch is also written to the mirror file.
- `DaemonChatStoreRegistry.createStore` calls
  `SDKChatTranscriptMirror.replay` after `store.start()` for all
  sdkOnly paths (Codex SDK, Claude-no-JSONL-yet fallback,
  Codex CLI-no-rollout-yet fallback, Gemini agentapi, default
  sdkOnly fallback). StagingParser's id-based dedup means replay is
  idempotent against any messages the live ingestor already saw.
- `handleDeleteSession` calls `SDKChatTranscriptMirror.removeMirror`
  alongside chat-cwd cleanup so deleted chats don't leak history.

### Limitations

- New mirror files start empty — sessions created BEFORE v0.9.2 won't
  have history available even after upgrade (the prior turns weren't
  mirrored). Mitigation: any chat session that survives one new turn
  on v0.9.2+ gets full mirror coverage from that turn forward.
- Mirror is per-machine; cross-device sync would need iCloud (out of
  scope here).

## [0.9.1 build 69] - 2026-05-21 — Chat v0.9.x polish (`feat/chat-v0.9.x`)

Closes the v0.9.0 polish list: iOS Frontier UI, Royal Frontier sidebar
entry, full ChatProviderProbe actor + ChatProviderAuthObserver, iOS
NSUserActivity Handoff for chat sessions, and the
`frontier-subscribe` WS channel.

### Added

- **iOS `iOSChatFrontierView`** — segmented control across the top (one
  tab per child), shared composer fans out to all panes via
  `POST /chat-sessions/frontier/:groupId/send`. Long-press → pick-winner
  action sheet archives the other panes. Per-pane chat surface reuses
  `iOSChatSoloView` so transcripts + permission cards inherit unchanged.
- **"Royal Frontier" sidebar inbox entry on iOS.** New top-level Section
  in the Chat tab list when one or more Frontier groups are live; tap
  navigates to `iOSChatFrontierView`. Hidden when no groups are live so
  the sidebar stays clean for solo-chat users.
- **`AgentControlClient` Frontier methods**: `createFrontier`,
  `frontierSend`, `frontierPickWinner`, `frontierChildren(groupId:)`,
  `liveFrontierGroupIds`.
- **`ChatProviderProbe` actor (P1)** replaces the inline binary checks
  in `handleGetChatProviders`. 60s TTL cache + in-flight Task de-dup
  (Codex P1 thundering-herd defense — 6+ iOS clients all asking at
  app-launch now share one underlying probe). Per-provider auth
  overrides drive the response when an AuthObserver hook flips one.
- **`ChatProviderAuthObserver` (CM3)** — actor with 4 hooks called
  from the existing ingest/send paths: `recordClaudeAuthError`,
  `recordCodexCLIAuthError`, `recordCodexSDKAuthError`,
  `recordAntigravityAuthError`. Wired into `sendAntigravityMessage`'s
  401 catch (the rest will be wired through their respective parsers
  in v0.9.x.1). Each hook flips the matching ChatProviderProbe
  override to `authenticated=false` with a CTA-grade `reason` string.
- **iOS NSUserActivity Handoff for chat sessions** (NEW-E6 from v0.8
  plan). iOS advertises `com.clawdmeter.continue-chat-thread` for any
  open chat surface; Mac AppDelegate broadcasts
  `continueChatSessionFromHandoff` Notification on receive, and the
  Chat workspace observer focuses the matching pane.
- **`frontier-subscribe` WS channel.** New op routed by
  `AgentControlServer.routeWSSubscription`. The
  `FrontierWebSocketChannel` acquires every child's chat store,
  observes them in parallel via Combine, and emits one typed
  `FrontierGroupSnapshot` envelope on each debounced 100ms commit
  window. Mac Frontier UI already gets the same data via per-child
  `chat-subscribe` streams; this channel exists for iOS / future
  3-pane Mac variants that want a single update tick.

### Plumbing

- `WSSubscription` envelope: new optional `groupId: String?` field for
  the `frontier-subscribe` op (additive — non-frontier ops ignore).
- `AppDelegate` adds `continueChatSessionFromHandoff` notification name
  alongside the existing `continueCodexThreadFromHandoff`.

### Test coverage

- 571/571 swift tests passing (unchanged from v0.9.0). The new files
  are server-side infrastructure (probe/observer/WS channel) +
  client-side UI; integration tests for them land in v0.9.x.1.

### Deferred to v0.9.x.1+

- AuthObserver hooks for Claude JSONL `error.type` + Codex JSONL
  `payload.error` + Codex SDK stderr `code: "auth"`. The hooks exist;
  they need to be called from the matching parser/stderr sites.
- "Royal Frontier" sidebar inbox entry on **Mac** (iOS ships here;
  Mac UI lands in v0.9.x.1).
- New-Frontier sheet (currently the only way to start a Frontier is
  via the daemon endpoint or `MacComposerSender.createFrontier`).

## [0.9.0 build 68] - 2026-05-21 — Gemini chat via agentapi + Frontier UI (`feat/chat-v0.9`)

The first Continuum release where the Chat tab actually has 3 working
providers — Claude, Codex, and Gemini (via Antigravity 2's HTTP-RPC
`agentapi`). Frontier compare also goes live: 2-3 chat panes side-by-side
sharing one composer, with per-pane "Pick winner" archiving the others.

### Added

- **Gemini chat via Antigravity 2 agentapi.** `POST /chat-sessions
  {provider: "gemini"}` lifts the v0.8 501 stub. The daemon-side
  `handlePostGeminiChatSession` picks the first available Antigravity
  project as a scratch workspace (chat has no `repoKey`), creates a
  placeholder conversation via `agentapi new-conversation`, persists
  `geminiBackend=.agentapi` + `antigravityConversationId` +
  `antigravityProjectId` on the session, and warms the chat store.
  503 with structured CTA bodies when Antigravity isn't installed,
  not signed in, not running, or has no projects open.
- **AntigravityChatIngestor** subscribes to the SQLite WAL DB
  Antigravity writes per conversation at
  `~/.gemini/antigravity/conversations/<id>.db`, waits for the file
  to appear (up to ~30s), backfills history, then tails newSteps and
  forwards each row as a `ChatMessage` through
  `SessionChatStore.appendSDKMessages`. Mirrors the
  `CodexSDKEventIngestor` pattern; chat-subscribe WS clients see
  identical snapshot shapes across all three providers.
- **Frontier compare endpoints (live).** All 4 routes that v0.8
  shipped as 501 stubs are now real handlers:
    - `POST /chat-sessions/frontier` spawns 2-3 sibling chat sessions
      sharing a `frontierGroupId`, per-slot results so a partial
      Frontier (D10) still ships the live slots + the failure
      reasons. CM5 idempotency via `clientRequestId`.
    - `POST /chat-sessions/frontier/:groupId/send` fans out the
      prompt to every child via `forwardFrontierChildSend` (agentapi
      for Gemini, CodexSubscriptionRelay for Codex SDK, tmux for CLI).
    - `POST /chat-sessions/frontier/:groupId/retry-slot` tears the
      failed child and respawns at the same childIndex.
    - `POST /chat-sessions/frontier/:groupId/pick-winner` archives
      the non-winning children, returns the winner.
- **Mac `ChatFrontierView`** — 3-pane HSplitView showing all live
  children side-by-side with a shared composer + per-pane "Pick
  winner" button. The per-pane chat surface reuses the existing
  `ChatSoloView`, so transcript rendering + permission cards inherit
  unchanged. `MacComposerSender` gains `frontierSend`,
  `frontierPickWinner`, `frontierRetrySlot`, `createFrontier`.
- **Wire protocol v10 → v11.** `antigravityChatMinimum = 11` (set in
  v0.8.1 with the daemon path deferred) is now reachable.
  `supportsAntigravityChat(serverWireVersion:)` flips true at v11.
- **Schema additions.** `AgentSession` gains optional
  `antigravityProjectId: String?` — additive via `decodeIfPresent`,
  no formal schema bump. Persisted at create-time on Gemini chat
  sessions; `sendAntigravityMessage` prefers it over the v0.8.1
  repoKey-based resolver.
- **`AgentSessionRegistry.setAntigravityChatBinding(id:conversationId:projectId:)`**
  for the two-phase create (chat-cwd needs to exist before the
  conversation id is known, session record needs to exist before
  chat-cwd is stored).
- **`AgentSessionRegistry.frontierGroupChildren(groupId:)`** returns
  all children sorted by `frontierChildIndex` — used by the daemon's
  Frontier handlers + the Mac Frontier view.

### Tests

- **`WireV11Tests.swift`** (8 cases): pins `current=11`, asserts
  `antigravityChatMinimum=11` is reachable, asserts the gate opens at
  v11, `AgentSession` round-trip with `antigravityProjectId`,
  decode-without-projectId tolerance, prior minimums unchanged.
- **`WireV10Tests`** updated: `currentWireVersionIsTen` →
  `currentWireVersionIsAtLeastTen` (>=10), `supportsAntigravityChat`
  test renamed to `gatedAtV11`.
- **`SessionsV2Tests` + `WireMixedVersionPairingTests`** pin
  `current >= 11` so future bumps don't keep tripping these.
- 571/571 swift tests passing (was 490 in v0.8.0).

### Observability — `frontier.send.divergence_ms` runbook note

Mixed-backend Frontier groups (SDK + CLI on the same prompt) see a
measurement artifact: SDK events arrive ~50ms ahead of CLI events
through JSONLTail because the SDK has no JSONL write step. Treat
`frontier.send.divergence_ms` between SDK and CLI children as
informational, NOT a per-backend latency comparison — the difference
is observation-layer skew, not actual provider response time.

### Deferred to v0.9.x

- **iOS `iOSChatFrontierView`** (segmented control) — Mac UI ships
  in v0.9.0; iOS surface follows.
- **"Royal Frontier" sidebar inbox entry** (Mac + iOS).
- **Full `ChatProviderProbe`** (P1 actor + in-flight de-dup +
  thundering-herd coordination). v0.9 ships minimal probe surface
  (binary on PATH + `CodexSDKManager.isProvisioned` + Antigravity
  install enum).
- **`ChatProviderAuthObserver`** (CM3 — CLI stderr observer for
  `oauth-expired`, `token-expired`, agentapi 401).
- **iOS NSUserActivity Handoff for chat sessions** (NEW-E6 from
  v0.8 plan).
- **`frontier-subscribe` WS channel** — the Mac MVP relies on each
  child's own `chat-subscribe` stream; a typed `FrontierGroupSnapshot`
  envelope is the next polish.

## [0.8.1 build 65] - 2026-05-21 — AGY migration (`feat/agy-migration`)

Google replaced the standalone `gemini` CLI (v0.42, runnable in a tmux
pane) with Antigravity 2's Electron IDE backed by an embedded Go
`language_server` binary that talks HTTP-RPC via `agentapi`. v0.8.1
migrates Continuum's Gemini surface to match — no more spawning a
TUI in tmux for Gemini, no more log-file-scrape discovery, no more
encryption-blocked conversation files. Built on `feat/agy-migration`;
v0.8.0 build 64 belongs to the parallel `chat-tab` branch (the agy
work skipped 0.8.0 to leave that SKU intact).

### Phase 0 + 0.5 verification (docs/agentapi-runtime-notes.md + docs/agentapi-event-catalog.md)

- Confirmed `agentapi` is HTTP-RPC one-shot, NOT a streaming CLI.
  `language_server agentapi new-conversation --model={flash_lite|flash|pro} <prompt>`
  returns `{conversationId}` in ~70ms. No `--approval-mode`, no
  `--thinking-budget` argv.
- Confirmed 3 mandatory env vars: `ANTIGRAVITY_LS_ADDRESS=http://127.0.0.1:<port>`,
  `ANTIGRAVITY_CSRF_TOKEN=<uuid>`, `ANTIGRAVITY_PROJECT_ID=<uuid>`.
- Confirmed conversation storage is SQLite WAL (`<id>.db` + `.db-wal` +
  `.db-shm`); the legacy v0.7-era encrypted `.pb` files are gone.
- Confirmed `step_payload` blobs are plain protobuf (hex dump shows
  visible "list_dir" / "view_file" strings) — decodable without
  swift-protobuf via a minimal wire-format reader.
- Confirmed Antigravity.app's running language_server argv is parsable
  via `ps -p <pid> -o command=` (extracts `--csrf_token=<uuid>`), and
  its listening ports via `lsof -nP -iTCP -sTCP:LISTEN -p <pid>`. Both
  are random per app launch — D13 always re-discovers (~50ms/call).
- Confirmed Antigravity project mapping lives in
  `~/.gemini/config/projects/<project-uuid>.json` at
  `projectResources.resources[].gitFolder.folderUri`.

### Added

- **`LanguageServerClient` REWRITE** — pgrep+ps+lsof process-table
  discovery replaces v0.7's log-file scrape; HTTP-RPC methods
  `newConversation` / `sendMessage` / `getConversationMetadata` spawn
  `language_server agentapi <args>` with the 3 env vars set. Three-tier
  model mapping (`AgentapiModelTier.from`) collapses every ModelCatalog
  Gemini id onto `flash_lite` / `flash` / `pro`. v0.7 `currentModel()`
  preserved for back-compat with existing Plan-pane logic.
- **`AntigravityProjectResolver`** — scans
  `~/.gemini/config/projects/*.json`, parses `gitFolder.folderUri` +
  `gitFolder.allowWrite`, canonicalizes via `RepoIdentity.normalize`,
  caches `[RepoKey: ProjectInfo]`. Backs the project-ID env var for
  every agentapi call.
- **`AntigravityInstall.preflight(...)`** — short-circuits through
  `.absent` / `.installedNotSignedIn` / `.appOnlyNotRunning` /
  `.noProjectForRepo` / `.ready`. Each non-ready state surfaces a
  user-facing CTA in the composer.
- **`AntigravityConversationDB`** — `actor` SQLite WAL reader that
  observes `<id>.db` for new `steps` rows. Primary path is a
  `DispatchSource` file-system observer on `<id>.db-wal` (fires inside
  ~1ms of writer commits); 5s polling Task catches missed FS events.
  `allSteps()` / `newSteps()` for cursor-advancing reads, `subscribe()`
  for AsyncStream backpressure.
- **`ConversationProtoParser.decode(_ data:) -> DecodedStep`** —
  plain protobuf wire-format reader for `step_payload` blobs. Extracts
  `stepType` + `stepStatus` + `toolCallId` + `toolName`. Avoids the
  swift-protobuf dependency.
- **`AntigravitySource` replaces `GeminiSource`** — 3-tier quota
  fallback (D9): LS-local `/v1internal:fetchUserInfo` probe →
  cloudcode-pa `retrieveUserQuota` → empty placeholder. Wire-level
  `providerID` STAYS `"gemini"` for back-compat; v8/v9 clients keep
  decoding via the dual-key bridge.
- **Antigravity-aware spawn dispatch in `SessionsView`** — D4 hard-
  stop: Gemini sessions ONLY spawn when Antigravity 2 is installed +
  running + signed in + has a project for the current repo. New
  `SpawnError.antigravityNotReady(String)` carries the CTA inline.
  No tmux pane is created; `AgentSession.geminiBackend = .agentapi`
  + `antigravityConversationId = <returned UUID>` are persisted.
- **Wire v10** — `AgentControlWireVersion.current = 10` (skips v9
  which `chat-tab` took). New fields `AgentSession.geminiBackend:
  GeminiBackend?` + `AgentSession.antigravityConversationId: UUID?`
  in schema v6 with decoder-tolerant defaults. Dual-key bridge in
  `Protocol.UsageEnvelope.usageData(for:)` rewrites `gemini ↔
  antigravity` for cross-wire-version compat.

### Changed

- **`AgentSessionRegistry.create`** accepts optional
  `geminiBackend` + `antigravityConversationId` — defaulted to nil so
  every Claude/Codex callsite stays untouched.
- **`DaemonChatStoreRegistry.defaultResolveURL`** routes agentapi
  sessions to `~/.gemini/antigravity/conversations/<id>.db` instead
  of the v0.7 Codex-newest-JSONL fallback.

### Removed

- **`apple/.../Sources/GeminiSource.swift`** — replaced by
  `AntigravitySource.swift`. `AppRuntime.geminiModel` constructs the
  new class.

### Tests

- 415 → 539 (+124) tests passing in `ClawdmeterShared`.
  + WireV10Tests (15)
  + AntigravityProjectResolverTests (16)
  + AntigravityInstallTests rewritten (30)
  + ConversationProtoParserTests (8 new decode cases)
  + AntigravityConversationDBTests (9, real SQLite fixtures incl.
    concurrent-writer stress)
  + AntigravitySourceTests (7)
- ClawdmeterMacTests:
  + LanguageServerClientRewriteTests (24)
  + DaemonChatStoreRegistryRoutingTests (5)

### Deferred to v0.8.2 / v0.9

- Full `AntigravityConversationDB.subscribe()` → `SessionChatStore`
  ingest. T9 wires the URL resolution; the chat pane for agentapi
  sessions renders blank until v0.8.2's polymorphic chat store lands.
- PermissionModeChip "show Antigravity's actual security preset" (D10).
- LS `/v1internal:fetchUserInfo` response-shape verification + real
  tier-1 quota wiring (probe is plumbed; closure remains nil by
  default until Phase 0 ground-truth lands).
- Python sidecar deletion (`tools/clawdmeter-agents/`, `Vendor/uv/`,
  the SDK toggle UI) — v0.8.2 cosmetic sweep alongside the iOS/Watch
  "Gemini" → "Antigravity" label flips.
## [0.8.0 build 66] - 2026-05-21

### Added

- **New Chat tab on iOS + Mac.** Non-coding chat with Claude or Codex
  via your existing subscription auth (Anthropic Pro/Max or ChatGPT
  Plus/Pro) — no API tokens, no per-token billing. Each chat runs
  in plan-mode in a fresh empty cwd at
  `~/Library/Application Support/Clawdmeter/chat-sessions/<uuid>/`,
  so no filesystem mutation, no shell exec, no network beyond the
  provider. iOS tab order is **Chat / Analytics / Code**; Mac dashboard
  gains a `Chat` tab next to `Code`.

- **Codex chat backend choice — SDK or CLI, per-session.** New
  Settings-driven default (`SDK` recommended, matches the existing
  `Codex SDK observation mode` provisioning toggle). Per-chat
  override at create time. SDK backend uses
  `@openai/codex-sdk` through `CodexSubscriptionRelay` —
  multi-subscriber Combine, typed events, server-side thread state
  that survives evict (NEW-T13 spike verified `op:resume`
  reconstructs history). CLI backend runs `codex --sandbox read-only`
  in a tmux pane — uniform with Claude chat. The backend choice is
  pinned to the AgentSession at spawn time so resume + future
  re-opens always use the original backend even if the global
  default flips later.

- **Wire protocol v8 → v9.** Additive bump with new minimums:
  `chatMinimum = 9` (gates POST `/chat-sessions`, GET
  `/chat-providers`, schema v5 fields), `frontierMinimum = 9` (gates
  forward-compat Frontier endpoints), `codexChatBackendMinimum = 9`
  (gates the per-request backend override). All prior minimums
  unchanged. New helpers
  `supportsChat/supportsFrontier/supportsCodexChatBackend` mirror the
  `supportsAntigravityPlan` pattern. iOS Chat tab gates on
  `serverWireVersion >= chatMinimum` and surfaces
  "Update Continuum on Mac" on older daemons.

- **Schema v4 → v5.** `AgentSession` gains five optional fields —
  `kind` (`.code` default; `.chat` for the Chat tab), `frontierGroupId`,
  `frontierChildIndex`, `codexChatBackend`, `codexChatThreadId` —
  plus `repoKey` flips from `String` to `String?` (chat sessions run
  in an empty chat-cwd, not a git repo). v3 and v4 `sessions.json`
  files decode cleanly into v5 via the existing `decodeIfPresent`
  pattern; round-trip tests cover both directions.

- **New daemon endpoints.** `POST /chat-sessions`, `GET /chat-providers`
  (per-provider availability + auth state; Codex carries `sdk` and
  `cli` sub-rows; Gemini hardcoded `available: false, reason: "v0.9"`
  until Antigravity replacement ships). Frontier endpoints
  (`POST /chat-sessions/frontier/*`) ship as 501 stubs in v0.8 for
  forward-compat — full UI lands in v0.9 with the agy + Gemini-chat
  bundle so the Royal Frontier ships as the original 3-pane design.

### Changed

- **Nav reshuffle on iOS.** The standalone "Live" tab is dissolved
  into the Analytics tab's header (`LiveGaugesHeader`) — the same
  3-way provider toggle + gauges, just embedded above the analytics
  charts. Frees the tab slot for Chat. "Sessions" tab renamed to
  "Code" on iOS + Mac dashboard + Mac workspace sidebar header.
  Mac Settings sub-tab "Sessions" stays (it's settings-related).

- **`AgentSession.repoKey` optional.** Chat sessions have no repo.
  Migrated 9 cwd-resolution sites across `AgentControlServer.swift`
  to a new `AgentSession.effectiveCwd` helper (precondition-fails
  loudly if daemon ever creates an invalid session). Handlers that
  read `repoKey` directly (autopilot trust, Antigravity Plan,
  WorktreeManager.delete) now gate on `session.kind == .code` and
  short-circuit chat sessions where the action doesn't apply.

- **DELETE `/sessions/:id` is kind-aware.** Code sessions still go
  through `WorktreeManager.delete` (which requires a clean git status
  — chat-cwds aren't git repos and would have thrown). Chat sessions
  cleanly remove their `chat-sessions/<uuid>/` directory via
  `ChatCwdManager.remove()`. SDK chat sessions additionally tear down
  the `CodexSubscriptionRelay` sidecar + `CodexSDKEventIngestor` sink.

### Fixed

- **`AgentSession.with(...)` helper preserves all v5 fields on
  mutation.** Before this fix, any `updateStatus` / `setPlanText` /
  similar call on a chat session would have silently converted it
  back to a code session because the v5 fields fell back to their
  init defaults. Now the helper passes through `kind`,
  `frontierGroupId`, `frontierChildIndex`, `codexChatBackend`,
  `codexChatThreadId` unchanged. New `setCodexChatThreadId(id:threadId:)`
  registry method lets the SDK ingestor persist the threadId after
  the first `thread.started` event for resume-after-evict.

### Hardening (post-review)

- **Codex CLI cross-rollout contamination** — `newestCodexJSONL()`
  was returning the absolute newest rollout under `~/.codex/sessions/`,
  so any concurrent Codex run (another chat, another worktree, manual
  `codex` in Terminal) would swap its transcript into the Chat tab.
  New `newestCodexJSONLMatching(cwd:after:)` peeks each rollout's
  `session_meta.cwd` and only accepts ones whose cwd matches the
  session AND whose mtime is ≥ `createdAt`.
- **Permission continuation leaked on delete.** End-chat while a trust
  prompt is on screen now wakes the daemon-side continuation via a
  `cancelledPermissionOptionId` sentinel before the session is torn
  down, instead of leaving the warmup task parked forever.
- **Idle eviction now refuses to drop a store with a pending
  permission prompt** (`pendingPermissionPrompt != nil`), so a chat
  that trust-prompts and then sits idle 5min keeps the prompt's
  `@Published` value alive and the next send doesn't hang on a
  vanished continuation.
- **`handleDeleteSession` evicts the chat-store registry entry**
  alongside the registry-record delete, so the store doesn't linger
  until the next sweep tick.
- **Codex SDK sidecar termination** — process-side
  `terminationHandler` now clears the active-sidecar map on natural
  EOF in addition to the explicit `stop()` path.
- **Permission-prompt id mismatch** — `/permission-respond` validates
  `promptId` against the active map and returns 409 on stale resends.
- **iOS permission card** — same floating bottom tray as the Mac
  surface (mirror of `AskUserQuestion`), so trust prompts surface on
  iOS chats instead of falling through to a silent stall.

### Deferred to v0.9

- **Gemini chat.** Gemini CLI is being replaced with Antigravity (agy)
  in a parallel thread; the Chat tab spawn path lands then.
- **Frontier compare UI.** Schema fields, endpoints, and WS channel
  all ship in v0.8 for forward-compat; the 3-pane UI lands in v0.9
  once Gemini joins to make the matrix complete.
- **Full ChatProviderProbe / ChatProviderAuthObserver (CM3).** v0.8
  surfaces minimal probe state (binary on PATH + `CodexSDKManager.isProvisioned`);
  P1 in-flight actor + CLI-output auth-error observer land in v0.8.x
  polish.

## [0.7.18 build 64] - 2026-05-21

### Added

- **"Bypass permissions" now appears in the empty-state composer's
  Mode menu.** v0.7.16 made bypass actually reach the spawned CLI
  (via `autopilot:` on `spawnSession` + auto-trust via
  `AutopilotState.trustRepo` on first-send), but the empty-state mode
  menu was still hiding `.bypass` from the option list. The
  `availablePermissionModes` switch in `ComposerInputCore.swift` now
  returns the full `[.ask, .acceptEdits, .plan, .bypass]` array for
  both bound + empty-state composers — same `⇧⌘4` shortcut as the
  bound chip. The auto-trust flow lands the spawn with
  `--dangerously-skip-permissions` (Claude) /
  `--dangerously-bypass-approvals-and-sandbox` (Codex) /
  `--approval-mode yolo` (Gemini) on the very first turn.

## [0.7.17 build 63] - 2026-05-21

### Added

- **Gemini 3.5 Flash (Thinking) + Gemini 3 Flash (Thinking) in the
  model picker.** Google ships a Standard / Extended thinking-level
  toggle in the Antigravity UI; Continuum's catalog only carried the
  Standard variant, so users had no way to pick the Extended thinking
  budget. Two new `ModelCatalog.bundled.gemini` entries:
    - `gemini-3.5-flash-thinking` — "Gemini 3.5 Flash (Thinking)",
      CLI alias `flash-3.5-thinking`, badge "Thinking",
      `supportsThinking: true`. Recommended for: Complex problem solving.
    - `gemini-3-flash-thinking` — "Gemini 3 Flash (Thinking)", same
      shape. Mirrors the 3.5 Flash split.
  Both variants ride the same `-m <model>` flag the gemini CLI
  already accepts; the upstream API enables the higher thinking_budget
  configuration when it sees the `-thinking` suffix. Pricing entries
  added in `pricing.json` matching the base model's per-token rates
  (with a note that thinking tokens bill at the output rate per
  Google's thinking_config spec). Provisional `~` marker stays on
  Gemini analytics cells until Google publishes an official rate.

## [0.7.16 build 62] - 2026-05-21

### Fixed

- **"Thinking…" indicator no longer overlaps the last message.** The
  `<Ns> · thinking…` pill at the bottom-leading of the chat thread was
  rendered as a floating overlay (`VStack { Spacer(); HStack {…} }` on
  top of the ScrollView with `.allowsHitTesting(false)`). When the
  user scrolled to the tail, the pill sat on top of the last 1-2 lines
  of the most recent message bubble — visually unreadable, especially
  with the asterisk spinner pulsing over the text. Indicator is now a
  footer row inside the List itself, taking its own ~32pt band below
  the last chat bubble. It still self-hides when the agent has been
  idle ≥30s, so quiet sessions get zero vertical space.

## [0.7.15 build 61] - 2026-05-21

Real Antigravity SDK provisioning + composer Bypass mode that actually
bypasses.

### Added

- **Bundled `uv` binary** (Astral's Python package manager, pinned to
  0.5.11, ~28MB arm64 static Mach-O). Lives at
  `Contents/Resources/Vendor/uv/uv` in the .app, downloaded by
  `tools/download-bundled-uv.sh` (mirrors the Node script pattern).
  Pre-build hook ensures it's present before the resources phase runs.
- **Real `AntigravitySidecarManager.enableSDKMode()` implementation.**
  Replaces the v0.7.14 skeleton. On first-enable:
    1. Runs `uv venv --python 3.13 ~/Library/Application Support/Clawdmeter/python`
       to create a sealed venv (~10s cold). Subsequent enables reuse it.
    2. Runs `uv pip install --python <venv-python> google-antigravity~=0.0.3`
       (~5s on warm pip cache). Captures stderr so install failures
       surface the actual pip error in Settings → Antigravity, not a
       generic "probe failed".
    3. Probes the sidecar — spawns the venv's Python against
       `clawdmeter-agents/main.py` which does `import google.antigravity`
       inside its first JSON line. The Swift side reads
       `sdk_import_ok: true|false` to confirm the import actually worked.
  Progress is reported through `provisioningStep` so the Settings sheet
  shows "Creating Python 3.13 venv (~10s)…" / "Installing
  google-antigravity (~5s)…" / "Probing sidecar…" instead of a 15-second
  blank spinner.
- **Real `tools/clawdmeter-agents/main.py` + `observer.py`** — replaces
  the v0.6.0 skeleton. `main.py` does the import-check + dispatches to
  the observer agent; `observer.py` calls `Connection.local()` and polls
  `total_usage` every 2s, emitting JSON-line `{"type":"usage", uuid,
  totals:{input, output, cached, thoughts, total}}` deltas the daemon
  side can map onto `AntigravityObservation.sdk`.
- **Yellow accent on the Bypass mode chip** — the v0.7.13 uniform-grey
  styling was wrong for a destructive mode where the agent has carte
  blanche over the workspace. Bypass now renders as a yellow capsule
  with a soft border + semibold label; Ask/Edits/Plan stay neutral.

### Fixed

- **Bypass mode picked in the empty-state composer now actually
  bypasses.** `spawnSession` was hardcoding `autopilot: false` (lines
  557 + 566 of `SessionsView.swift`), so picking "Bypass permissions"
  from the chip before the first message silently downgraded the
  spawned CLI argv back to `--permission-mode ask`. The fix:
  - Adds `autopilot: Bool` parameter to `spawnSession()`. Threaded
    through to `claudeArgv` / `codexArgv` / `geminiArgv` — Claude now
    gets `--dangerously-skip-permissions`, Codex gets
    `--dangerously-bypass-approvals-and-sandbox`, Gemini gets
    `--approval-mode yolo`.
  - `EmptyStateCenteredComposer.firstSend()` records per-repo trust via
    `AutopilotState.shared.trustRepo(repoKey)` when bypass is picked, so
    subsequent sessions in the same repo skip the confirmation sheet.
    Seeds `PermissionModeStore.setBypass(true, sessionId:)` so the
    bound chip + analytics row both reflect bypass mode immediately.
  - Bound-session flips (the sheet flow already worked) are unchanged.
- **The Antigravity SDK toggle now points at a venv-aware probe** —
  previously the Swift probe used `/usr/bin/env python3` which would
  pick up system Python (where `google-antigravity` is not installed)
  even after uv had successfully populated the venv. Probe now uses
  the venv's `bin/python` directly so the import check exercises the
  package that was just installed.

### Known limitation

- `google-antigravity~=0.0.3` may not exist on PyPI yet (Google's
  Antigravity 2.0.0 spec'd the SDK but hasn't published as of
  2026-05-21). The provisioning surfaces uv's actual stderr in
  Settings → Antigravity when the install fails, so users see the
  real error ("No matching distribution found for google-antigravity"
  or similar) and can wait for Google to publish. The toggle reverts
  to OFF, Disk mode stays as the default — zero degradation for users
  who don't care about SDK observation.

## [0.7.14 build 60] - 2026-05-21

### Fixed

- **Antigravity SDK toggle now reaches its (skeleton) sidecar.**
  Settings → Antigravity → "SDK mode" was reporting "Sidecar probe
  failed: SDK mode not provisioned: sidecar main.py not found" on
  the released .app, because `AntigravitySidecarManager.locateSidecarMain()`
  walked up from CWD looking for `tools/clawdmeter-agents/main.py` —
  which only works from a dev checkout. The .app's CWD is `/` so the
  walk never finds anything. The Codex SDK sibling solved this same
  problem in v0.7.1 by reading `Bundle.main.resourceURL`; the
  Antigravity sibling was left as a TODO comment.
  - `project.yml` now bundles `tools/clawdmeter-agents/` as a folder
    reference under `Contents/Resources/clawdmeter-agents/` (mirrors
    the `Vendor/node` pattern). All five `.py` files + `pyproject.toml`
    + `README.md` come along, so v0.6.1's eventual full uv-provisioning
    work doesn't need a second bundling pass.
  - `locateSidecarMain()` now checks `Bundle.main.resourceURL/clawdmeter-agents/main.py`
    first, falls back to the repo walk for dev builds. Matches
    `CodexSDKManager.locateMainMJSSource()` shape.
  - Result: toggling SDK mode ON now reaches the Python sidecar,
    which returns the **honest** v0.6.0 skeleton message — "SDK mode
    skeleton — full impl ships in v0.6.1. Toggle SDK mode off in
    Settings to dismiss this warning." — and the toggle reverts to
    OFF as designed. Disk mode (the default) is unaffected.

### Known limitation (deferred follow-up)

- The Antigravity SDK toggle is still a skeleton in v0.7.14. Real
  uv-Python provisioning + `pip install google-antigravity` + the
  full observer.py impl is the v0.6.1 work that was scoped in the
  original plan but never landed (the v0.7.x line shipped Codex SDK
  parity instead). Users who want live Gemini token streaming via
  the official Antigravity SDK will need that follow-up; Disk mode
  remains the default and reads `~/.gemini/antigravity/brain/`
  directly without any Python dependency.

## [0.7.13 build 59] - 2026-05-21

### Changed

- **Permission-mode chip now matches the model+effort chip visually.**
  The "Ask / Edits / Plan / Bypass" pill on the composer bottom bar
  was wearing its own design language — a leading SF Symbol icon plus
  a mode-specific tinted background (secondary / accent / yellow). It
  now renders identically to the right-side `Opus 4.7 (1M) · Max`
  chip: same `Color.secondary.opacity(0.10)` Capsule, same 11pt-medium
  primary text, same 8pt-semibold chevron, same padding. No icon, no
  tint. The popover already shows the active mode via the checkmark
  on the row, so the chip itself doesn't need to encode it twice; the
  payoff is a balanced bottom bar instead of chip-soup. Same ⌘⇧1-4
  keyboard shortcuts, same Menu popover, same `Section("Mode")`
  structure with the numbered shortcut hints on each row.

## [0.7.12 build 58] - 2026-05-21

### Changed

- **Reverted the v0.7.11 segmented permission picker.** Back to the
  Menu chip that opens a "Mode" popover with numbered ⇧⌘<N>
  shortcuts and a checkmark on the active row — matches Claude
  Code's compact "Auto ▾" pattern the user pointed at. The chip's
  color still encodes the active mode (ask → secondary, edits →
  accent, plan → accent, bypass → yellow). v0.7.11's
  `PermissionModeSegmented.swift` removed.

## [0.7.11 build 57] - 2026-05-21

### Changed

- **Permission-mode picker is now a segmented control.** The "(?) Ask"
  chip on the composer bottom bar used to be a compact menu — one
  active label with a chevron hiding the other modes. It now renders
  as a segmented picker matching the Claude / Codex / Gemini agent
  strip's visual weight: Ask · Edits · Plan side by side, with the
  active mode highlighted at a glance. Bound sessions include the
  Bypass segment; the empty-state composer hides it (no session yet
  to trust-gate). Same ⌘⇧1-4 keyboard shortcuts.

## [0.7.10 build 56] - 2026-05-21

### Fixed

- **Composer agent toggle now resets the model + effort chip.**
  Switching from Claude → Codex → Gemini in the empty-state composer
  was leaving the model chip on "Opus 4.7 (1M) · Max" no matter the
  pick. The chip now flips to each agent's default — Codex →
  GPT-5.5 · Max, Gemini → Gemini 3.5 Flash (effort hidden, since
  Gemini doesn't support per-call effort). Same fix applied to the
  iOS New Session sheet's agent picker, which used to leave the
  model picker on a stale id when the user toggled agents.

### Added

- **`ComposerStore.ChipDefaults.for(agent:catalog:)`** — sources the
  default model from the first entry per agent's catalog slice, so
  the catalog stays the single source of truth. Effort clears when
  the picked model's `supportsEffort` is false.
- **`ComposerStore.resetChipsForAgent(_:)`** — bound to the
  composer's agent Picker. One call flips agent + modelId + effort
  to the new defaults atomically.

## [0.7.9 build 55] - 2026-05-21

Worktree-by-default + city-named branches.

### Changed

- **New sessions land in a worktree by default**, every time. The
  Local / Worktree / Cloud chip is gone from the composer (Mac
  empty-state composer + bound chip strip), the New Session sheet
  (Mac + iOS), and the segmented Run-mode picker on iOS. Every new
  session now runs in `<repo>/.claude/worktrees/<city>/` on a fresh
  branch named after the same city. SessionMode enum stays for
  back-compat with persisted v3 sessions; mid-session Local↔Worktree
  swap is still reachable through the Session detail header.
- **Worktree branches are named after a city.** `WorktreeManager.add`
  now accepts a `branchName` and runs `git worktree add -b <branch>
  <path>`. The branch + worktree folder use the same name. Cities
  come from the existing `CityNamer` (assigned per session id,
  deduplicated across the live set, persisted to
  `~/Library/Application Support/Clawdmeter/city-assignments.json`).
  Multi-word cities collapse to kebab-case via
  `WorktreeManager.slug(city:)` (e.g. "Cape Town" → `cape-town`,
  "São Paulo" → `sao-paulo`).
- **Default flipped on `NewSessionRequest.useWorktree`** to `true`.
  Older v6/v7 paired Macs that omit the field now opt into worktrees
  automatically — same behaviour as the v0.7.9+ UI.

### Implementation notes

- `WorktreeManager.slug(city:)` strips diacritics, lowercases,
  collapses non-alphanumerics to `-`, and trims edge `-`.
- `WorktreeManager.add` detects branch-name collisions via
  `git branch --list` and mirrors the worktree-path suffix
  (`cape-town-2`) so worktree dir + branch stay 1:1.
- City mint happens in the spawn path BEFORE `git worktree add`,
  using a `provisionalSessionId`. On worktree-create failure the
  daemon releases the city back to the pool via
  `CityNamer.shared.release(_:)`.
- Mid-session Worktree swap (`SessionsView.switchMode`) reuses the
  session's already-assigned city so the sidebar label stays
  consistent.

## [0.7.8 build 54] - 2026-05-20

Codex SDK parity ship. Closes the three surfaces Antigravity SDK has
and Codex SDK didn't: Plan pane on Mac, Plan tab on iOS, task
complication on watchOS. Also fixes a v0.6.0 oversight where
`AntigravityTaskComplication` shipped but was never registered in
the WidgetBundle.

### Added

- **`CodexTodoItem` Codable model.** Preserves the structured todo
  list from Codex SDK `todo_list` stream events instead of flattening
  to a meta chat row. Status field kept as a raw string (`pending` /
  `in_progress` / `completed`) so a future SDK release adding a new
  status decodes cleanly.
- **`ChatSnapshot.codexTodos` field.** The CodexSDKEventIngestor
  now writes parsed todos through `SessionChatStore.setCodexTodos`
  which propagates them via the existing 16ms staging commit. Empty
  for non-Codex / pre-todo_list sessions.
- **`WireChatSnapshot.codexTodos` field.** Wire-level pass-through
  with `decodeIfPresent` back-compat so v6/v7 paired clients reading
  a v8 payload still decode (the field defaults to empty).
- **Mac `CodexPlanPane`.** New Plan tab content for Codex sessions
  in SessionWorkspaceView. Renders the structured todos grouped by
  status (In progress / Pending / Done) with a count badge in the
  header. Non-Codex sessions keep the existing `PlanTrackerPane`.
- **iOS `iOSCodexPlanView`.** Matching Plan tab content for Codex
  sessions in `SessionDetailView`. Reads
  `iOSChatStore.snapshot.codexTodos`; no new daemon endpoint —
  the chat-subscribe pipeline already carries the data.
- **Watch `CodexTaskComplication`.** `.accessoryCorner` widget that
  shows the first 18 chars of the active Codex SDK session's
  in-progress todo (falls back to first pending). Reads the
  `clawdmeter.watch.codexCurrentTodo` App Group key written by
  `WatchPlanBridge`. New iOS-side `activeCodexTodoHeadline()` picks
  the most-recently-active Codex session's chat-store snapshot.
- **`WatchPlanBridge.Payload.codexCurrentTodo` field.** Mirror of
  the v0.6.0 `currentTaskHeadline` field with the same encode/decode/
  hash plumbing. Added to the SendGate content hash so a stable todo
  doesn't wake the Watch.

### Fixed

- **`AntigravityTaskComplication` now registered in WidgetBundle.**
  The widget file shipped in v0.6.0 but the bundle registration was
  missed — the complication never appeared in the watch face picker.
  Fixed alongside the new `CodexTaskComplication` registration.

## [0.7.7 build 53] - 2026-05-20

Closes every remaining v0.6.0 plan deferral and every v0.7.4
audit-track follow-up. Five themed blocks:

### Added (v0.6.0 plan D3 completion)

- **Settings → Antigravity tab.** `AntigravitySDKSettingsView` makes
  the `clawdmeter.antigravity.sdkMode` toggle discoverable. Mirrors
  `CodexSDKSettingsView`'s shape so the two SDK modes feel symmetric.
  All plumbing already existed (`AntigravitySidecarManager.shared` +
  backing UserDefaults bool + daemon-read); v0.7.7 adds the UI.

### Added (v0.6.0 plan T3 completion)

- **`SidecarAskCoordinator` + `/internal/sidecar-ask/<uuid>/decide`.**
  Cross-surface `ask_user(...)` race protection for the Antigravity
  SDK helper agents. First decision wins; second returns HTTP 409
  with `{prior, priorSource}`; 60s timeout defaults to `deny`. Mac
  inline calls the actor directly; iPhone surface POSTs. Decisions
  recorded to `AuditLog` under the new `sidecar-ask` kind.

### Refactored (audit-track consolidation)

- **`PathValidator`** in `ClawdmeterShared` — consolidates the three
  near-clone validators (`isValidRepoKey`, `isValidJsonlPath`,
  `isSafeArtifactPath`) into a single composable helper. Mac daemon
  + iOS client delegate now ~3 lines each.
- **`FireOnce`** in `ClawdmeterShared` — consolidates the two
  near-clone NSLock+bool primitives that lived as `ResumeOnce`
  (ShellRunner) and `BGTaskCompletionGuard` (ClawdmeteriOSApp).
  Mac's `ResumeOnce` is now a typealias; iOS's
  `BGTaskCompletionGuard` is a thin wrapper.

### Added (audit-track test coverage)

- **Mac XCTest target** (`ClawdmeterMacTests`). New xcodegen target
  hosted by ClawdmeterMac; closes the v0.7.4 deferral that flagged
  "4 Mac-only regression tests need a new XCTest target". 29 tests
  across 4 suites:
  - `PathValidatorMacTests` (11) — daemon-side path safety,
    including the codex-7 symlink-escape regression.
  - `TailscaleWhoisIpOnlyTests` (4) — the load-bearing
    bare-IPv6 round-trip case that guards the P2-Mac-4 rollback.
  - `TmuxControlClientValidationTests` (9) — control-byte rejection
    for the P1-Mac-6 tmux command-injection guard. Extracts
    `validateArgs` as a static so the test can run without a PTY.
  - `SidecarAskCoordinatorTests` (5) — first-wins, lost-on-second,
    timeout-defaults-to-deny, late-decide-loses, unknown-prompt.

  ClawdmeterShared swift-test count unchanged at 460. Mac XCTest
  adds 29 → 489 total across the project.

### Added (v0.7.4 deferral — cross-device handoff)

- **NSUserActivity Handoff for "Continue on Mac"** on the Codex
  resume sheet. iPhone advertises
  `com.clawdmeter.continue-codex-thread` while the sheet is up;
  Mac's NSApplicationDelegate continues the activity, brings the
  dashboard forward, and broadcasts a notification with the
  threadId. Uses Continuity (same Apple ID + same Wi-Fi); no
  apple.com domain or Universal Links setup required. "Copy
  thread ID" demoted to a secondary button.

### Plan status after v0.7.7

| v0.6.0 plan item | Status |
|---|---|
| 10 commits (1-10) | All shipped (v0.6.0) |
| T1 extract-antigravity-proto.sh | Moot (proto path abandoned) |
| T2 LanguageServerClient.discoverLive | Shipped (v0.6.0) |
| T3 SidecarAskCoordinator | Shipped (v0.7.7) |
| T4 BrainLinkCache LRU-2 | Shipped (v0.6.0) |
| T5 BrainPlanParser awaitingFirstTurn | Shipped (v0.6.0) |
| T6 LanguageServerClient loopback TLS | Shipped (v0.6.0) |
| T7 typed WatchPlanBridge.Payload | Shipped (v0.6.0) |
| T8 pytest framework | Shipped (v0.6.0) |
| T9 bounded transcript 1KB read | Shipped (v0.6.0) |
| T10 ConversationDecodeScope.totalsOnly | Moot (proto pivot) |
| D3 Settings SDK toggle UI | Shipped (v0.7.7) |

| v0.7.4 deferral | Status |
|---|---|
| Mac-only regression tests (4) | Shipped (v0.7.7) |
| Path-validator consolidation | Shipped (v0.7.7) |
| Fire-once helper consolidation | Shipped (v0.7.7) |
| Cross-device Continue-on-Mac | Shipped (v0.7.7) |

## [0.7.6 build 52] - 2026-05-20

### Added

- **`gemini-3.5-flash` in the model catalog.** Antigravity 2's default
  model (resolves from the `MODEL_PLACEHOLDER_M133` opaque token in
  `~/.gemini/antigravity/antigravity_state.pbtxt`). Now first in
  `ModelCatalog.bundled.gemini` so new Gemini sessions default to it.
  `pricing.json` already carried the rate row — only the catalog entry
  was missing. Also added `gemini-3-pro` (2M context window) for the
  pricing.json model id that didn't have a catalog row.

### Fixed

- `AgentSpawner.geminiArgv` comment no longer claims `gemini-3.1-pro-high`
  vs `gemini-3.1-pro-low` is the effort-tier example — `gemini-3-pro` vs
  `gemini-3.5-flash` is the modern shape.

## [0.7.5 build 51] - 2026-05-20

### Fixed

- **Mac composer: Gemini agent now shows Gemini models.** The
  composer's `ModelEffortChip` filtered the catalog via a 2-way
  ternary that defaulted everything-not-Claude to Codex, so picking
  Gemini in the chip strip surfaced GPT-5.x entries instead of the
  three bundled Gemini models (`gemini-3.1-pro-high`, `gemini-3.1-pro-low`,
  `gemini-3-flash`). Same fallthrough also leaked into the standalone
  `ModelPicker` section header (rendered "Codex" for Gemini). Both
  sites now switch over `AgentKind` exhaustively — adding a future
  provider will fail at compile time instead of silently aliasing
  to Codex.

## [0.7.4 build 50] - 2026-05-20

The deferred v0.7.3 codex-sdk feature work, now landed cleanly on top
of the audit campaign. Plus the TOCTOU fix flagged in /review and the
first regression-test suite from the audit-track follow-ups.

460 swift tests (was 457). Mac + iOS + Watch all `BUILD SUCCEEDED`.

### Added

- **Multi-subscriber Codex SDK relay.** `CodexSubscriptionRelay` now
  exposes `subscribe(sessionId:) -> AnyPublisher<CodexRelayEvent, Never>`
  alongside the legacy AsyncStream. Each session gets a
  PassthroughSubject under the hood so the Mac chat ingestor, the iOS
  WebSocket channel, and ad-hoc subscribers can all observe the same
  session's events without contending for the single AsyncStream slot
  the v0.7.2 relay had. New `event.rawDict()` accessor.
- **`CodexSDKEventIngestor` — SDK events into the chat pipeline.**
  Subscribes to the relay for one session and translates the SDK's
  typed item events (agent_message, reasoning, command_execution,
  file_change, mcp_tool_call, web_search, todo_list, error) into
  `ChatMessage` records via the new public
  `SessionChatStore.appendSDKMessages` method. `turn.completed` token
  usage flows through as a zero-message staging tick so the cost
  ticker updates. Result: SDK observation rides the existing
  `chat-subscribe` WebSocket pipeline — iOS sees SDK-observed turns
  in the same chat feed that already carries Claude + Codex CLI.
- **`codex-stream-subscribe` WebSocket op.** Optional raw-event
  channel for clients that want the unprocessed SDK event stream
  (debug overlays, future Plan-mode-style trackers). Sends a typed
  envelope per event: kind + threadId + subscriptionId + receivedAt
  + raw payload. Coexists with the chat-side ingestor — both
  subscribe via the multi-subscriber subject.
- **iOS handoff UX for Codex SDK resume.**
  `.deliveredWithCodexResume(threadId, response)` no longer silently
  dismisses the New Session sheet. Now presents
  `CodexResumeResultSheet` with the SDK response inline + a "Copy
  thread ID" button so the user can paste it into a follow-up draft
  to continue the same turn. Cross-device focus-on-Mac is deferred
  (needs Handoff or Universal Links setup with an apple.com domain).

### Fixed

- **`handleGetArtifact` TOCTOU race.** Was: validate-then-read had a
  window between `resolvingSymlinksInPath` (validation) and
  `Data(contentsOf:)` (read) where an agent with worktree write
  could replace the validated regular file with a symlink. Now uses
  `open(O_RDONLY | O_NOFOLLOW)` so ELOOP at the final component fails
  immediately (HTTP 403), then `fstat` the live fd to enforce the
  50MB cap on the inode we actually have open, and reads from that
  fd. Size check and read operate on the same inode — no race window.
  Refuses non-regular files defensively. Flagged by the /review
  security specialist on `bugfix/audit-fixes-v2`.

### Tests

- **`PastedAnthropicTokenProviderTests` (3 cases).** Regression suite
  for the P1-Shared-2 + codex-2 invariants:
  - `shared()` returns the same instance (singleton).
  - `setToken("")` clears the in-memory cache (so "Sign out" doesn't
    leak the stale token to the daemon).
  - Whitespace-only tokens are treated as empty (the trim guard).
  Skips gracefully when the test environment doesn't have an
  accessible Keychain (CI without unlocked login keychain). 457 → 460
  passing in `ClawdmeterShared`.

### Not landed (still deferred to a future branch)

The remaining four regression tests from /review need either a new Mac
test target in `apple/project.yml` (`isValidJsonlPath`,
`isValidRepoKey`, `TailscaleWhois.ipOnly`) or architectural surgery
(`TmuxControlClient` argv validation + lifecycle tests need an
extracted static helper + PTY mocking). Path-validator + fire-once
helper consolidation also remains on `TODOS.md`. None of these block
v0.7.4 shipping.

## [0.7.3 build 49] - 2026-05-20

Audit-track hardening release. 46 atomic fix commits across Mac, iOS,
Watch, Linux, and shared, addressing P0/P1/P2 findings + Codex
adversarial pass (codex-1..9) + Codex structured review (P1/P2 rounds
1-3). Zero new features; the entire release is correctness + lifecycle
+ security hardening on top of v0.7.2's Codex SDK ship.

457/457 swift tests pass. Mac, iOS, Watch all `BUILD SUCCEEDED`.

### Fixed (security + sandbox)

- **Browser PTY paste sanitization** (P0). `InAppBrowser.sendComment`
  now drops ASCII control bytes (incl. CR/LF) and caps length before
  pasting into the agent's tmux pane. A page that controls the DOM can
  no longer terminate the prompt line and inject shell commands into
  the agent. URL scheme whitelist now also rejects `data:`/`javascript:`/
  `file:` schemes in `loadCurrentURL`.
- **tmux command CR/LF injection** (P1-Mac-6). `TmuxControlClient.command()`
  validates every arg and throws `TmuxError.invalidArgument` on any C0/DEL
  byte. Without this, a newline in any arg terminates the control-mode line
  and lets a caller inject a second tmux command.
- **Artifact path traversal — daemon** (validated). `handleGetArtifact`
  two-stage canonicalize (`standardizingPath`) + symlink-resolve
  (`resolvingSymlinksInPath`) + worktree prefix check on both. Blocks
  `?path=../../../etc/passwd` and symlinks-out planted inside the worktree.
- **Artifact path traversal — iOS client** (codex-1 walkback of P2-iOS-7).
  `isSafeArtifactPath` rejects empty + `..`/`.` traversal segments before
  the HTTP request. Absolute paths now allowed (the agent's `Write` tool
  routinely emits them). Daemon-side sandbox stays the real defense.
- **JSONL session-id extraction allowlist** (codex-7). `continue-readonly`
  daemon endpoint now validates `jsonlPath` against an explicit allowlist
  (`~/.claude/projects/`, `~/.codex/sessions/`, `~/.codex/projects/`,
  `~/.gemini/`) before extracting a session id; symlink-resolves before
  the allowlist check so symlinks-out fail closed.
- **Repo-key sandbox escape** (P1-Mac-7 + codex-7). `isValidRepoKey` now
  resolves symlinks before the `$HOME` prefix check; symlinks pointing
  outside `$HOME` can no longer pass through to `tmux.newWindow`.
- **WKScriptMessageHandler retain cycle** (P1-Mac-13). `dismantleNSView`
  removes the script handler and clears nav/UI delegates, breaking the
  WebView + Coordinator leak on every tab change.
- **tmux supervisor restart correctness** (P1-Mac-3). `markExited` now
  resets PTY/readTask/outputSinks/command state so a subsequent
  supervisor `start()` actually re-spawns instead of silently no-op'ing.
- **HTTP listener accepts loopback** (P1-Mac-8). Drop
  `requiredInterfaceType = .other` on the HTTP listener so Mac composer
  POSTs to 127.0.0.1 reach the accept handler. WS listener was already
  loose; align them. `isAllowedPeer` remains the actual gate.

### Fixed (lifecycle + races)

- **BGTask double-complete race** (codex-5). New `BGTaskCompletionGuard`
  wraps `setTaskCompleted` so the in-flight refresh and the expiration
  handler can't both call it. iOS lifecycle violation eliminated.
- **iOS chat-store cancellation** (codex-6, P2-iOS-4, P2-iOS-5). Foreground
  resync now cancels the subscription Task, not just the WS task; sleep
  is cancellable; loop exits cleanly on client dealloc.
- **AVCaptureSession serialization** (P2-iOS-3). Pairing scanner moves
  capture-session lifecycle to a dedicated serial queue. No more main-
  thread stalls during scan startup.
- **ShellRunner termination** (P2-Shared-2 + codex-structured-P1 round 3).
  Set `process.terminationHandler` BEFORE `process.run()` so very short-
  lived commands (`true`, `which`, small git probes) don't exit before
  the handler is wired. `ContinuationBox` bridges the cont reference
  installed later by `withCheckedContinuation`. No more hangs in fast-
  exit paths.
- **ShellRunner cancellation** (codex-structured-P2). `withTaskCancellationHandler`
  bridges caller cancellation to synchronous process termination.
- **AgentEventStream subscriber wake** (P2-Mac-1). `recordEvent` wakes
  subscribers immediately instead of waiting for the next poll.
- **PastedAnthropicTokenProvider singleton + cache** (P1-Shared-2 + codex-2).
  `shared()` is a true singleton (one Keychain key for all callers).
  `setToken("")` clears the in-memory cache unconditionally — even when
  Keychain delete fails — so "Sign out" can't leave a stale token
  serving the daemon, iPhone, and Watch.

### Fixed (network + IPv6)

- **IPv6 port-strip walkback** (codex-4 rollback of P2-Mac-4). The earlier
  "strip ≤5 digit numeric tail after last colon" heuristic broke bare
  IPv6 addresses where the final hextet is numeric (`fd7a:115c:a1e0::1`
  → `fd7a:115c:a1e0::`). Pass unbracketed IPv6 through unchanged; bracket
  per RFC 3986 if you need IPv6+port.
- **IPv6 bracketing in Live Activity push register** (P1-Mac-19). Bracket
  IPv6 hosts so APNS push token registration works on IPv6-only Tailscale.

### Fixed (Linux daemon)

- **Linux build breakers** (codex-structured-P1 + round 2). Daemon target
  now declares `ClawdmeterLinux` as a dependency (HummingbirdTransport +
  LinuxPairingTokenStore live there). `Duration` cast fixed in daemon
  main.swift.
- **OSLog cross-platform gate** (P2-Linux-2 + codex-structured-P1).
  `#if canImport(OSLog)` around `import OSLog`; Linux falls back to a
  stderr-print helper. Same pattern applied to all shared SwiftUI views
  via `#if canImport(SwiftUI)` (P1-Linux-1).
- **HummingbirdTransport wiring** (P1-Linux-4). Daemon entrypoint now
  constructs and starts HummingbirdTransport.
- **runtimeDir ownership + adapter lock** (P1-Linux-5 + P1-Linux-6 + codex-3).
  Daemon validates runtimeDir mode, ownership, non-symlink before use.
  Adapter lock acquisition fails loud on contention.
- **Packaging scripts fail loud** (P1-Linux-3). AppImage + .deb scripts now
  exit non-zero when no artifact is produced.
- **replaceItem first-run crash** (P0). Switched `replaceItem(at:)` to
  `Data.write(to:options:.atomic)` in `LinuxUsageStore` + `CairoGaugeRenderer`
  — Swift Corelibs Foundation throws when the destination doesn't exist.
- **Visual tests degrade gracefully** (P1-Linux-2). Skip visual baselines
  when not committed; `CLAWDMETER_VISUAL_TEST_STRICT=1` to enforce strictly.

### Fixed (rendering + analytics)

- **MarkdownRenderer source cache** (P1-Mac-12). Parsed source cached
  alongside chunks; eliminates re-parse cost on every assistant turn.
- **Markdown stale parse + event replay + fd leak** (codex-structured-P2
  round 3). Three independent bugs in the same family caught by the
  structured Codex pass.
- **Pricing input split** (codex-structured-P2). Long-context tier check
  now correctly splits input tokens.
- **Gemini analytics tier check** (P1-Shared-1). `Pricing` now includes
  cache-read tokens in the 200k long-context tier threshold (mirrors how
  Anthropic counts them).

### Fixed (UI + status)

- **GitDiffPane FD double-close + space-in-path** (P1-Mac-14). Stop closing
  the same fd twice; diff header now handles paths containing spaces.
- **iOS SessionDetailView live state** (P1-Mac-20). Reads live session
  from the client instead of stale cache.
- **Notification ack scope** (P1-Mac-21). Only ack notifications that were
  actually delivered.
- **Pairing revoke truly disables** (P1-Mac-17). Revoked tokens stay
  revoked until explicit regenerate, not just until next process restart.
- **Gemini token refresh** (P1-Mac-10). `refreshIfNeeded` throws on
  expired refresh instead of returning a stale token.

### Fixed (Watch + iPhone bridge)

- **WatchPlanBridge merge** (P1-Watch-4). Bridge context payload merge no
  longer drops fields when an older watch reads a newer payload.
- **Widget reload + approval ack fallback** (P1-Watch-1, P1-Watch-2).
  Complications reload on approval; ack path falls back when WCSession is
  cold.
- **sessionsSummaryJSON decode logging** (P2-Watch-2). Surfaces silent
  decode failures so future schema drift doesn't disappear.
- **Tmux path on iPhone bridge** (P1-Tools-1). Honor `$PATH` instead of
  hardcoding `/opt/homebrew/bin/tmux`.

### Fixed (resolution + repo)

- **Relative gitdir resolution** (P2-Shared-1). `RepoIdentity` resolves
  relative `gitdir:` paths against the `.git` file's parent (worktrees
  with relative pointers now canonicalize correctly).

### Fixed (P2 batch)

- BGTask expiration timing tightened; paste trim normalizes trailing
  whitespace; deb control file version aligned; `.desktop` `Exec` line
  uses absolute path.

### Docs

- `TODOS.md` gains an "Audit-track follow-ups" section tracking the
  three env-flagged stub bypasses, five missing regression tests, and
  the path-validator / fire-once duplication for future cleanup.
- `.gstack/qa-reports/qa-report-clawdmeter-bugfix-audit-fixes-v2-2026-05-20.md`
  captures the /qa run that fixed the TmuxError exhaustiveness gap.

### Not included

The v0.7.3 codex-sdk-v073 feature work (CodexSubscriptionRelay
multi-subscriber refactor + CodexSDKEventIngestor) was attempted on a
separate branch but conflicted heavily with this audit campaign's diff.
It will land on a clean follow-up branch once the audit landing settles.

## [0.7.2 build 48] - 2026-05-20

Codex SDK observation — the user-visible glue. v0.7.0 shipped
scaffolding, v0.7.1 shipped real provisioning + observer/resume
subcommands; v0.7.2 plugs the SDK into actual product surfaces:
Mac Settings tab with toggle + diagnostics, daemon relay that ingests
observer events, and X1 cross-Apple compose-draft → resume wire.
Auth contract unchanged: `~/.codex/auth.json` chatgpt OAuth, no
per-token billing.

Shipped as 4 commits on `feat/codex-sdk-v072`, fast-forward merged
to `main`. Swift suite 457/457. Mac/iOS/Watch builds all clean.

### Settings → Codex SDK tab

`CodexSDKSettingsView`. The previously-invisible
`clawdmeter.codex.sdkMode` AppStorage toggle now has a real Settings
tab between Sessions and Diagnostics. Renders:
- Header explaining what SDK mode does + the auth contract
- Toggle bound to AppStorage; ON triggers
  `CodexSDKManager.enableSDKMode(progress:)` with a closure that
  surfaces step messages ("Locating node binary…", "Installing
  @openai/codex-sdk (~25s)…", "Probing sidecar…") via a progress
  indicator. OFF calls `disableSDKMode()` synchronously.
- Status grid: mode, provisioned, SDK version, install path (
  Application Support dir, copy-able).
- Actions: "Open install folder" (NSWorkspace.open), "Wipe SDK
  install" with confirmation dialog → `wipeProvisionedState()`.
- Soft-red error banner when `lastProvisioningError` is set.
- Auth note explaining the OAuth piggyback.

Wired into the existing TabView with a `swift` SF Symbol.

### CodexSubscriptionRelay (daemon)

`CodexSubscriptionRelay` is the Mac-side bridge between the Node
sidecar's stdout JSON-lines and the rest of the daemon. Per-session
sidecar lifecycle:
- `start(session:workingDirectory:initialPrompt:threadId?:)` spawns
  Node in observer mode, sends `{agent:"observer"}` then `{op:"start"
  or "resume", prompt, ...}`, returns a `CodexRelaySubscription`
  with an `AsyncStream<CodexRelayEvent>`.
- `forwardPrompt(sessionId:workingDirectory:prompt:threadId?:)` push
  a new turn into an already-running sidecar.
- `stop(sessionId:)` async — sends `{op:"shutdown"}`, waits up to
  3s for graceful exit, SIGTERMs otherwise.
- `stopAll()` test/teardown helper.

`CodexRelayEvent.classify(json:handle:)` parses the sidecar's
`{type:"stream_event",subscriptionId,threadId,event}` envelope into
typed `.threadStarted`, `.turnStarted`, `.item`, `.turnCompleted`,
`.turnFailed`, `.error`, `.streamStarted`, `.streamDone`,
`.streamError`, `.observerReady`, `.unknown` cases. Tracks last-known
`subscription_id` + `thread_id` on the ProcessHandle so subsequent
events without explicit ids still get tagged.

Stdout reader: `FileHandle.readabilityHandler` + line buffer →
AsyncStream with `bufferingOldest(512)` policy so a slow consumer
can't OOM the daemon.

Skeleton-aware: `start()` throws `RelayError.sdkNotProvisioned`
when `CodexSDKManager.isProvisioned == false` with the
"Toggle SDK mode in Settings → Codex SDK" CTA.

### X1 compose-draft → codexThreadId wire

`ComposeDraft` gains optional `codexThreadId: String?` field (wire v8
additive, decodeIfPresent). When iOS posts a compose-draft with this
field set + `suggestedAgent == .codex` + the Mac is provisioned,
the daemon dispatches the prompt to
`CodexSDKManager.runResume(threadId:prompt:workingDirectory:)` —
a Swift wrapper around the sidecar's one-shot resume agent that
calls `codex.resumeThread(id).run(prompt)` and returns the
finalResponse + usage.

The Mac sends back a structured `codex_resume_result` JSON frame
BEFORE the existing "ok" ACK. iOS parses the new frame into a
`ComposeDraftResult.deliveredWithCodexResume(threadId,finalResponse)`
case. WS receive timeout extended from 5s to 130s when codexThreadId
is set, covering the 90s SDK turn ceiling + buffer.

`AuditLog` records the codex_resume dispatch alongside the standard
compose-draft entry.

### Tests

- Swift suite: 457/457 — wire v8 round-trip tests already covered
  the new ComposeDraft Codable shape (via decodeIfPresent default
  behavior).
- Mac/iOS/Watch xcodebuild: all BUILD SUCCEEDED.

### Deferred to v0.7.3

- iOS WS subscriber that consumes CodexSubscriptionRelay events
  live (currently the relay's AsyncStream is one-subscriber-per-
  session; v0.7.3 will multiplex via PassthroughSubject and expose
  a `codex-stream-subscribe` WS op).
- Mapping `agent_message` / `command_execution` / `reasoning` events
  → `ChatItem` records appended to `SessionChatStore` so the existing
  chat-subscribe WS pipeline carries SDK events into the iOS chat UI
  without a separate channel.
- iOS handoff UX for `.deliveredWithCodexResume`: currently the
  sheet dismisses silently; v0.7.3 could surface the response inline
  on the iOS chat pane the user opened the draft from.

## [0.7.1 build 47] - 2026-05-20

Codex SDK observation mode — real provisioning + observer/resume
subcommands + iOS subtitle + bundled Node. v0.7.0 shipped the
scaffolding (skeleton sidecar, manager scaffolds, wire v8 field);
v0.7.1 fills in everything the v0.7.0 CHANGELOG marked "deferred to
v0.7.1". Same auth contract: `~/.codex/auth.json` chatgpt OAuth, no
per-token API billing.

Shipped as 4 commits on `feat/codex-sdk-v071`, fast-forward merged
to `main`. Mac BUILD SUCCEEDED in both with-bundle (`~120MB Node arm64
embedded`) and skip-bundle (`CLAWDMETER_SKIP_BUNDLED_NODE=1` for dev
iteration) paths. Sidecar Node tests still 4/4 passing.

### Real npm install provisioning

`CodexSDKManager.enableSDKMode(progress:)` now actually provisions:

1. Validates a `node` binary is reachable. Preference: bundled →
   Homebrew arm64 → Homebrew Intel → /usr/bin → `which node`.
2. Creates `~/Library/Application Support/Clawdmeter/codex-sdk/`.
   Writes a synthetic `package.json` declaring `@openai/codex-sdk@^0.131.0`.
3. Copies `main.mjs` from `Bundle.main.url(forResource:"main",
   withExtension:"mjs")` (production) or the repo path (dev).
4. Runs `npm install --no-audit --no-fund --no-progress` in the
   AppSupport dir. Cold cache ~25s, warm cache ~3s. Non-zero exit
   surfaces the last 5 lines of stderr in `lastProvisioningError`
   for Settings → Diagnostics.
5. Probes the now-provisioned sidecar with `agent: "probe"`. Expects
   `{type:"ready",version:"0.7.1-sdk"}` + `{type:"probe_ok",
   sdkVersion:"0.7.1-sdk"}` within 30s.
6. On success: persists `clawdmeter.codex.sdkProvisioned = true`,
   records the SDK version, flips the toggle ON. Subsequent ON
   cycles fast-path the install step.

Verified end-to-end against `@openai/codex-sdk@0.131.0`:
`npm install` + probe completed in ~2s on a warm cache.

### Sidecar real-impl: observer + resume

`main.mjs` rewritten as self-bootstrapping. On startup
`await import("@openai/codex-sdk")` — when reachable, emits
`0.7.1-sdk` ready and dispatches real subcommands; when not
reachable, falls back to v0.7.0 skeleton error responses so the
CodexSDKManager probe path still works.

- **observer (long-running)**: accepts `{op:"start"|"resume"|"stop"|
  "shutdown"}` over stdin. Each `start`/`resume` spawns
  `thread.runStreamed(prompt)` and emits every SDK event back as
  `{type:"stream_event",subscriptionId,threadId,event}` JSON-lines.
  Events: `thread.started`, `turn.started`, `item.{started,updated,
  completed}` (agent_message / reasoning / command_execution /
  file_change / mcp_tool_call / web_search / todo_list / error),
  `turn.completed.usage` (input_tokens, cached_input_tokens,
  output_tokens, reasoning_output_tokens), `turn.failed`. Cancellable
  per-subscription via AbortController.

- **resume (one-shot)**: `codex.resumeThread(threadId).run(prompt)`,
  emit `resume_result` with `{finalResponse, items, usage}`. Used by
  the X1 cross-Apple compose-draft flow: iOS posts a threadId + text
  via the WS op, Mac resumes the Codex thread + runs the turn to
  completion without keeping a long-running stream open.

ThreadOptions plumbing: `workingDirectory`, `skipGitRepoCheck`,
`model`, `sandboxMode`, `modelReasoningEffort`, `approvalPolicy`,
`additionalDirectories` all forwarded through from the JSON-lines op.
Undefined fields stripped before passing to the SDK so we don't
override the CLI's defaults.

### iOS Codex subtitle

iOS `CodexSection` footer now renders `"· SDK mode"` or
`"· disk mode"` after the "Synced from Mac …" timestamp when the
paired Mac advertises wire v8+. Field reads from
`usage.codexSDKModeActive`; nil/false → "disk mode", true → "SDK
mode" (monospaced caption, with accessibility label). Older v7 Macs
hide the subtitle entirely (avoids rendering a label users can't
toggle when their Mac doesn't support the feature).

### Bundled Node binary

`tools/download-bundled-node.sh` downloads Node 24.15.0 (Krypton LTS)
from nodejs.org into `apple/ClawdmeterMac/Resources/Vendor/node/`:
- Default: arm64-only (~120 MB)
- `--universal`: lipo'd arm64+x64 (~245 MB) for Intel Mac DMG builds
- npm + npx wrappers shipped alongside (~10 MB), guaranteed to use
  the sibling bundled `node` (never PATH-resolved)

Gitignored (never committed). `project.yml` adds:
- `Vendor/` folder reference as a `Resources` build phase entry
  (xcodegen copies the whole tree into `Contents/Resources/Vendor/
  node/` of the .app)
- `preBuildScripts` hook that auto-runs `download-bundled-node.sh`
  before the Resources copy phase. Skip with
  `CLAWDMETER_SKIP_BUNDLED_NODE=1` for dev iteration where falling
  back to system Node is acceptable.

`CodexSDKManager.locateNode()` preference order updated:
  1. `Bundle.main.url(forResource:"node",subdirectory:"Vendor/node/bin")`
     — bundled, version-pinned, our preferred path
  2. `/opt/homebrew/bin/node`
  3. `/usr/local/bin/node`
  4. `/usr/bin/node`
  5. `which node`

### Tests

- Swift suite: unchanged (no new public surface needing unit tests
  beyond what's covered by CodexSDKManager's end-to-end probe).
- Node suite: 4 tests still passing (skeleton/SDK mode-tolerant
  shape assertions).
- E2E provisioning verified manually: tempdir + npm install + node
  main.mjs probe → ready + probe_ok in ~2s.
- Mac build: clean in BOTH paths (with-bundle 120MB embed + skip-bundle
  fallback).

### Deferred to v0.7.2

- Daemon WS subscriber that ingests observer subscription events and
  pushes them to the existing chat-subscribe channel (right now the
  observer's stream events sit in stdout of the sidecar process —
  AgentControlServer needs a CodexSubscriptionRelay to bridge them
  to clients).
- X1 compose-draft → resume wire: iOS attaching `codexThreadId` to
  the compose-draft envelope, daemon dispatching to
  `CodexSDKManager.runResume()` when present.
- Settings → Codex pane UI for the SDK mode toggle (currently the
  toggle is functional via UserDefaults but no SwiftUI surface;
  toggle ON via `defaults write` for now).

## [0.7.0 build 46] - 2026-05-20

Codex SDK observation mode. v0.6.0 shipped the Antigravity SDK
toggle pattern + v2-native Plan surfaces; v0.7.0 extends the same
opt-in toggle architecture to OpenAI's Codex SDK. **Same auth story:
piggybacks on the user's existing `codex login` ChatGPT OAuth — no
per-token API billing.** Verified against `~/.codex/auth.json` on
the dev machine before designing: `"auth_mode": "chatgpt"` with
OAuth tokens from an active ChatGPT subscription and
`"OPENAI_API_KEY": null`. SDK inherits this on startup.

Shipped as 5 commits on `feat/codex-sdk`, fast-forward merged to
`main`. Suite 438 → 457 Swift + 4 new Node `node --test`. Mac / iOS /
Watch all `BUILD SUCCEEDED`. No breaking changes — wire v8 is
purely additive (single optional UsageData field).

### Why Codex SDK but not Claude Agent SDK

Same evaluation, opposite conclusion. The Codex SDK piggybacks on the
local Codex CLI's `auth_mode: "chatgpt"` OAuth — usage draws against
ChatGPT subscription quota, no extra API billing. The Claude Agent
SDK's own docs explicitly disallow `claude.ai` login in third-party
SDK products and require `ANTHROPIC_API_KEY` (per-token billing) —
Max subscribers would pay twice. v0.7.0 ships the Codex side; the
Claude Agent SDK remains deferred until/unless that policy changes.

### Architecture

Mirrors the v0.6.0 `AntigravityObservation` pattern. Two operating
modes per provider — Disk (default, no extra runtime) + SDK (opt-in
toggle, recommended for paid users). Implementation-agnostic via the
`CodexObservation` protocol so the toggle is a hot swap from Settings.

### Shared package

- **`CodexObservation` protocol** — `isAvailable()`, `latestUsage()`,
  `modeLabel`. Async because SDK mode runs over IPC; Disk mode
  resolves immediately.
- **`DiskCodexObservationProvider`** (Mac actor) wraps the existing
  `~/.codex/sessions/*.jsonl` parsing path. Reads at most 64KB of
  the newest rollout to find the `session_meta` line — bounded so
  long rollouts don't pull multi-MB to extract rate-limit state.
  modeLabel = "disk mode". **No behavior change vs v0.6.0** — this
  is a refactor that puts the existing parser behind the protocol.
- **`SDKCodexObservationProviderStub`** — placeholder until full IPC
  wiring lands in v0.7.1. modeLabel = "SDK mode (provisioning)".
- **`CodexUsageSnapshot`** — coarse DTO decoupled from `UsageData`.
  Disk impl populates from `session_meta` JSONL line; SDK impl
  (v0.7.1) will populate from `turn.completed.usage` event stream.
- **Wire v7→v8**. `AgentControlWireVersion.current = 8`,
  `codexSDKMinimum = 8`, `supportsCodexSDK(serverWireVersion:)`.
  `UsageData` gains optional `codexSDKModeActive: Bool?` field
  (decodeIfPresent — back-compat preserved). v8 is purely additive:
  no new endpoints, no new WS ops. The field rides on the existing
  `/usage` envelope.

### Node sidecar (skeleton)

- `tools/clawdmeter-codex-sdk/main.mjs` — JSON-lines dispatcher.
  Reads `agent` from first stdin line, forwards subsequent ops to
  the chosen subcommand. v0.7.0 skeleton emits
  `{"type":"ready","version":"0.7.0-skeleton"}` then
  `{"type":"error","code":"sdk_not_provisioned"}` so the
  CodexSDKManager fail-soft path exercises end-to-end.
- `tools/clawdmeter-codex-sdk/package.json` — Node 18+ ESM module.
  `@openai/codex-sdk` dep commented out; v0.7.1 will uncomment +
  run `npm install` from CodexSDKManager.
- `tools/clawdmeter-codex-sdk/tests/main.test.mjs` — 4 Node native
  test runner tests: happy-path ready+error, EOF graceful no-op,
  garbage-JSON header errors with code 1, second-op-line dispatched
  cleanly without crash.

**Why Node not Python?** Codex itself ships as `npm install -g
@openai/codex` — Node is on PATH wherever `codex` runs. SDK is
TypeScript-stable / Python-experimental; pick the stable surface.
The Antigravity sidecar stays Python because the Antigravity SDK
is the inverse: Python-stable / TypeScript-not-shipped.

### Mac

- **`CodexSDKManager`** (`@MainActor` singleton). Same toggle-revert-
  on-skeleton-detected flow as `AntigravitySidecarManager`. Reads
  `clawdmeter.codex.sdkMode` UserDefaults. On `enableSDKMode()`:
  locates the sidecar entry point relative to cwd; locates the
  `node` binary across Homebrew + system paths + `which` fallback;
  spawns with a probe header; parses the skeleton response within
  5s; reverts the toggle + stores the error message in
  `lastProvisioningError` for Settings → Diagnostics.

### Deferred to v0.7.1

- Real `npm install @openai/codex-sdk` provisioning into
  `~/Library/Application Support/Clawdmeter/codex-sdk/` from
  CodexSDKManager
- `observer` subcommand: long-running stdio bridge over
  `thread.runStreamed()` emitting `item.completed` + `turn.completed`
  events with token usage
- `resume` subcommand: `codex.resumeThread(threadId).run(prompt)` for
  iOS→Mac spawn handoff via the X1 compose-draft WS op
- iOS subtitle wiring (`"· SDK mode"` on Codex column when
  `codexSDKModeActive == true`)
- Bundled Node binary in Resources (currently relies on system Node)

### Tests

- Swift suite: 438 → 457 (+19 net). CodexObservation × 9 + WireV8 × 10.
- Node suite: 0 → 4 (`node --test`).
- Mac / iOS / Watch xcodebuild: clean across every commit.

### Worktree parallelization

Single lane this time — Codex SDK integration is contained
(no iOS/Watch surface changes in v0.7.0, only Mac + shared).
v0.7.1 will fan out to iOS subtitle work + bundled Node binary
work in parallel.

## [0.6.0 build 45] - 2026-05-20

Antigravity 2 native. v0.5.11 broke silently for users on Google's
Antigravity 2 (announced at I/O 2026; replaces Gemini CLI free/Pro on
2026-06-18): analytics row empty (Antigravity stopped writing
`~/.gemini/tmp/<repo>/logs.json`), Sessions IDE Gemini chat pane empty
(no more `chats/session-*.jsonl`), model catalog stale
(`gemini-3.5-flash` shipped as the new default, not in `ModelCatalog`).
v0.6.0 is the correctness release + the v2-native upgrade path:
**Plan pane** in Mac Sessions IDE, **Plan tab** on iOS, **task
complication** on watchOS, token-aware analytics with `~` provisional
marker.

Locked decisions: D1 v2-only (no Gemini CLI v0.42 path); D2 Plan pane
first-class; D3 two modes — Disk (default, zero Python deps) + SDK
(opt-in toggle, recommended for paid Antigravity users); D5
`usage[id]` dict key stays "gemini" through v7 (NEVER rename to
"antigravity" — strands v6 iOS clients); D6 watchOS task complication
in v0.6.0 (read-only); D7 real `$` Gemini analytics (Disk-mode estimate
with `~` marker; SDK mode gets exact `agent.conversation.total_usage`).

Shipped as 10 bisectable commits on `feat/antigravity-v2`. Suite 335 →
438 (+103 net). Mac / iOS / Watch all `BUILD SUCCEEDED`.

### Architectural deviation discovered mid-implementation

**Antigravity 2 encrypts per-conversation `.pb` files at rest.** Found
empirically against 36 live conversations: every file shows ~58%
non-printable byte ratio — the signature of uniformly-random
ciphertext. swift-protobuf can't decode ciphertext; the app.asar also
doesn't ship `.proto` schema files (language_server is a Go binary
with schemas compiled in). The plan's vendored-proto-decode approach
isn't reachable in Disk mode.

Adaptation in commit 4: `ConversationProtoParser.probe()` detects
encryption via byte-ratio threshold (0.45, well-separated from real
plaintext ~15% and real encrypted ~58%) and falls back to
metadata-derived signals from the plaintext-readable brain dir:
turn count from `*.metadata.json` files, token estimate from
plaintext markdown artifact sizes ÷ 4 chars/token. UI surfaces the
estimate with a `~` provisional marker. SDK mode (v0.6.1) remains
the path to exact totals via the SDK's live decryption.

### Shared package (Mac + iOS + Watch)

- **`AntigravityInstall.detect()`** — probes `/Applications/Antigravity.app/`,
  `~/.gemini/antigravity/`, `~/Library/Application Support/Antigravity/
  bin/agy-node`. Returns `.installed(version:appDataDir:agyNodePath:
  hasRunningServer:)` or `.absent`. Coarse `hasRunningServer` proxy via
  the transient `logs/<TS>/ls-main.log` dir; authoritative check is
  `LanguageServerClient.discoverLive()` (commit 8).
- **`AntigravityStateReader.parse()`** — pure-Swift text-proto line
  parser for `antigravity_state.pbtxt`. Extracts
  `last_selected_agent_model` (opaque `MODEL_PLACEHOLDER_M133` token,
  resolved via lookup map to display name "gemini-3.5-flash"),
  `installation_uuid`, `migrate_convos_into_projects`. Handles
  unknown M-tokens gracefully (passes through to caller).
- **`BrainSummaryIndexer.read()`** — string-scan parser for the
  global `agyhub_summaries_proto.pb` UUID↔cwd index. Bulletproof to
  proto field-number drift (Antigravity has reshuffled at least once
  between 2.0.0 and 2.0.1): scans for `0a 24 <UUID>` anchor, sweeps
  forward for length-delimited `file://`, `https://...git`, and
  branch/owner-repo strings, attributes to the current UUID.
- **`BrainPlanParser.parse(brainURL:)`** — returns `PlanState` enum:
  `.absent` / `.awaitingFirstTurn` / `.ready(BrainPlan)`. The
  explicit `.awaitingFirstTurn` case (eng review 2A fix) avoids
  nil-coalescing — UI renders a spinner + "Antigravity is preparing
  this task…" copy. Plan checklist parsed via Apple's swift-markdown
  0.4.0 with `ListItem.checkbox` (eng review 2C fix), handles nested
  sub-steps + code blocks + prose between lists. Bounded 1KB read on
  `.system_generated/logs/transcript.jsonl` for line-0 cwd (eng
  review 4A fix).
- **`BrainDirWatcher`** — `DispatchSourceFileSystemObject` wrapper.
  Mirrors `.git/index` watcher in `GitDiffPane`. Debounced 100ms
  coalesces partial writes into one re-parse. Owns the fd; closes
  on `stop()` or deinit.
- **`ConversationProtoParser.probe(conversationURL:brainURL:)`** —
  encryption-aware. Byte-ratio threshold detects encrypted vs
  plaintext .pb files. For encrypted (the v2.0.0 production reality),
  emits `ConversationProbe.kind = .encrypted` + metadata-derived
  turn count + token estimate. Caller surfaces with `~` provisional
  marker.
- **`AntigravityObservation` protocol** — abstracts the data source
  for the toggle. `DiskObservationProvider` (Mac) wires together
  AntigravityInstall + AntigravityStateReader + BrainSummaryIndexer
  + BrainPlanParser + ConversationProtoParser with mtime-cached
  brain index. `SDKObservationProviderStub` returns false/.empty/nil
  until v0.6.1's full sidecar IPC.
- **Wire v6→v7.** `AgentControlWireVersion.current = 7`,
  `antigravityMinimum = 7`, `supportsAntigravityPlan(serverWireVersion:)`.
  New DTOs: `AntigravityPlanSnapshot`, `WirePlanStep`,
  `WireBrainArtifact`, `WireTokenUsage`. `UsageData` gains optional
  `antigravityModel: String?` + `sdkModeActive: Bool?` with custom
  Codable (decodeIfPresent — v6 payloads parse into v7 structs with
  nils; v7 encoders omit nil keys via encodeIfPresent). **D5
  contract enforced**: `usage[id]` dict key STAYS "gemini" through
  v7 (regression marker test in WireV7Tests).
- **`AntigravityUsageParser`** — replaces `GeminiUsageParser`. Walks
  `~/.gemini/antigravity/conversations/*.pb`, uses
  `ConversationProtoParser.probe` per file with the matching brain
  dir, emits one `UsageRecord` per conversation:
  `provider: .gemini`, `requestCount = turnCount`, `inputTokens`
  + `outputTokens` apportioned 70/30 from the estimate,
  `model: "gemini-3.5-flash"` (from state file). Dedup key
  `"antigravity:<uuid>"` stable across cache rebuilds.
- **`SessionFileResolver.findAntigravityBrain(for:)`** — bounded LRU
  cache (eng review 1C fix). Cap 200 entries (active session count
  ~20 + history without unbounded growth). Path-exists invalidation
  on every read — Antigravity GC can sweep older brains under us.
  Tier 1 lookup via BrainSummaryIndex cwd→uuid + mtime tiebreaker.
- **`pricing.json`** gains provisional `gemini-3.5-flash`,
  `gemini-3-pro`, `gemini-3-flash` entries. `_provisional: true`
  flag marks estimates pending Google's official pricing API
  (rendered with `~` marker in the UI).
- **`WatchPlanBridge.Payload` typed Codable struct** (eng review 2D
  fix). Replaces v0.5.11's loose-keyed `[String: Any]` dict shape.
  New `currentTaskHeadline: String?` field for the watch task
  complication. `encodedAsDict()` preserves the exact key names
  legacy v5/v6 receivers read — back-compat fully preserved.
- **`WatchPlanBridge.SendGate`** (eng review 4B fix). Diff-before-send
  guard: SHA256 over stable field concatenation (excluding `sentAt`)
  to skip identical WCSession sends. Resettable on WCSession reconnect.

### Mac

- **`LanguageServerClient.discoverLive()`** (eng review 1A fix) —
  walks `~/.gemini/antigravity/logs/<TS>/ls-main.log` newest first,
  parses port + PID + CSRF token from each, validates via `kill(pid,
  0)` AND `lsof -nP -iTCP:<port> -sTCP:LISTEN`. Returns `.live(...)`
  on first pass; `.notRunning` if all stale. Re-discover on
  `NSWorkspace.didActivateApplicationNotification`.
- **Loopback-scoped TLS trust** (eng review 2B fix). URLSessionDelegate
  `didReceive challenge:` accepts serverTrust only for 127.0.0.1 / ::1
  / localhost; non-loopback hits default validation (rejects
  self-signed properly).
- **`GET /sessions/:id/antigravity-plan`** endpoint — returns
  `AntigravityPlanSnapshot`. Resolves brain dir via BrainSummaryIndex
  cwd lookup + mtime tiebreaker. Returns awaitingFirstTurn for empty
  brains; 404 for non-Gemini sessions.
- **`AntigravityPlanPane`** SwiftUI view. Sessions IDE split-view
  sibling of GitDiffPane. Renders task headline + body + step
  checklist (depth-indented) + annotations + footer (token estimate
  with `~` marker + "Open in Antigravity" deep-link via
  `antigravity://brain/<uuid>` URL scheme). 3s HTTP poll cadence
  (WS subscribe ships in a follow-up). Spinner + retry on errors.
- **`AntigravitySidecarManager`** (skeleton). v0.6.0 ships the
  toggle + Settings → Diagnostics integration. The toggle ON path
  probes `tools/clawdmeter-agents/main.py` via `python3`,
  captures the skeleton's `sdk_not_provisioned` response,
  surfaces the error message in Diagnostics, reverts the toggle
  to OFF. Full uv provisioning + observer.py + 3 helper agents
  land in v0.6.1.
- **`GeminiSource` dual-host**. Tries
  `daily-cloudcode-pa.googleapis.com` first (Antigravity 2 channel),
  falls back to legacy `cloudcode-pa.googleapis.com` on network /
  404 / 5xx. Cached `preferredQuotaHost` sticks to the working host
  across polls. Auth / rate-limit / contract errors aren't retried
  on the secondary (not host-related).

### iOS

- **`iOSAntigravityPlanView`** + `iOSAntigravityPlanStore` — Plan tab
  for Sessions detail. Pull-to-refresh, 3s poll, spinner for
  awaitingFirstTurn, error pill with retry. Same content rendering
  as Mac Plan pane. Gated on `serverWireVersion >= antigravityMinimum`
  (v7); older Macs hide the tab.

### watchOS

- **`AntigravityTaskComplication`** `.accessoryCorner` widget.
  Reads the 18-char-truncated headline from App Group UserDefaults
  (`clawdmeter.watch.currentTaskHeadline`); WatchPlanBridge writes
  on every fresh payload arrival. Sparkle glyph + curved label.
  Read-only in v0.6.0 (D6 — Approve/Interrupt deferred to v0.7).

### Python sidecar (v0.6.0 skeleton; v0.6.1 full impl)

- `tools/clawdmeter-agents/{main.py, observer.py, session_summarizer.py,
  cost_pulse_watcher.py, repo_context_extractor.py, pyproject.toml,
  README.md, tests/}`. Each script ships a skeleton that emits the
  `sdk_not_provisioned` JSON-lines error so the SDK toggle's
  fail-soft path exercises end-to-end. 3 pytest tests verify the
  dispatcher's header parsing + happy path.

### Tests

- Suite: 335 → 438 (+103 net). 11 new Swift unit tests deleted with
  GeminiJSONLParser → 442 - 11 + 107 = 438.
- Coverage by commit:
  - C1: 27 (AntigravityInstall × 11 + AntigravityStateReader × 16)
  - C2: 16 (BrainSummaryIndexer)
  - C3: 24 (BrainPlanParser × 19 + BrainDirWatcher × 5)
  - C4: 15 (ConversationProtoParser)
  - C5: 12 (AntigravityObservation)
  - C6: 12 (WireV7 + bumped wire constant audits)
  - C7: -11 (GeminiJSONLParser deletion) + 1 (Antigravity smoke)
  - C8: 0 (Plan pane runtime-tested via build; UI E2E ships in v0.6.1)
  - C9: 8 (WatchPlanBridge.Payload + SendGate)
  - C10: 3 (Python pytest)
- Mac / iOS / Watch xcodebuild: clean across every commit.

### Deferred to v0.6.1

- Full uv provisioning of `~/Library/Application Support/Clawdmeter/python`
- Real `observer.py` via `from google.antigravity import Connection`
- The 3 helper agents (session_summarizer, cost_pulse_watcher,
  repo_context_extractor) wired through launchd
- `SidecarAskCoordinator` actor for first-wins UUID + 409 idempotency
  (eng review 1B fix — depends on sidecar to exist first)
- `antigravity-plan-subscribe` WS op (replaces 3s HTTP polling)
- Antigravity Claude-Code-skill plugin install (cosmetic)
- watch task complication Approve/Interrupt buttons (D6 deferred)
- Bundled `uv` Mach-O binary in Resources

### Worktree parallelization metrics

Foundation (commits 1-6, shared/) ran serialized. Lanes B (Mac) + C
(iOS+Watch) executed sequentially in this session because the
implementation moved commit-by-commit; parallelization would be a
later optimization. Lane D (sidecar) depends on B's
`AntigravitySidecarManager` and ran after.

## [0.5.11 build 44] - 2026-05-19

End-to-end Gemini provider across Mac, iOS, and Watch. v0.5.10 shipped the shared-package scaffolding (`AgentKind.gemini`, `ModelCatalog.gemini`, `GeminiSource`, `GeminiTokenProvider`, `GeminiUsageParser`, `byProvider` snapshot refactor, wire v6). The 0.5.11 work spans three batches — an initial Mac UI wiring pass, an autonomous multiplatform completion pass (iOS Live tab + Watch meter + Live Activity + X3 cross-model fixes), and two medium-severity /qa fixes — all shipped together. Tests 250 → 335 across the cycle. Mac / iOS / Watch schemes all BUILD SUCCEEDED.

### Mac dashboard

- **3rd menu bar item.** `AppDelegate.geminiController` (`NSStatusItem`) tracks the new `clawdmeter.gemini.menuBarShown` AppStorage key. Toggle from the dashboard's "Menu bar:" row.
- **3rd dashboard column with responsive collapse.** ≥1200pt = Claude / Codex / Gemini side-by-side; 800-1200pt = Claude+Codex top, Gemini below; <800pt = single-column vertical. Mirrors the Sessions tab's <1100pt collapse pattern (eng review D10).
- **Gemini column drops the phantom "Weekly limits" card.** cloudcode-pa returns a single `refreshTime` per model — no weekly bucket exists upstream. New `ProviderConfig.hasWeeklyWindow` flag (Claude/Codex = true, Gemini = false) gates the `Weekly limits` VStack so the column stops inventing a window that doesn't exist. iOS GeminiSection already drops its WeeklyCard for the same reason. (Found by /qa; ISSUE-002.)
- **D7 stale-data badge fires on cached fallback.** `GeminiSource.cachedFallbackOrThrow` was emitting with `updatedAt = lastUpdatedAt`, which `UsagePoller.shouldReplace`'s E3 ordering rejected as stale, so `.unknown` status never reached the dashboard. Fix: emit cached fallback with `updatedAt = Date()` so the poller forwards the `.unknown` status and the dashboard renders the orange "Stale · updated Xs ago" badge. `sessionEpoch` still points at the cached reset target so the countdown stays honest. (Found by /qa; ISSUE-001. Regression-tested at the `UsageData.shouldReplace` model layer in `GeminiProviderLaneATests`.)
- **D4 stale-token banner + D8 "Not detected" subtitle.** Orange inline banner with a Copy-command button shown when `model.needsReauth` is true; subtitle reads "Not detected · install gemini CLI" when `~/.gemini/oauth_creds.json` is missing.
- **New "Providers" Settings tab.** `ProvidersSettingsView` between General and Sessions surfaces per-provider connection state plus the same stale-token banner. Gemini is labeled "5h refresh" (not "Session N% · Weekly N%" like the cost-bearing providers).
- **`ProviderConfig.supportsAutoRevive` flag.** Replaces the hardcoded `model.config.id == "claude"` check in `DashboardView.swift` and `PopoverView.swift`. Routes through new shared `AutoReviveSupport.supports(_:)` so the contract is testable. Claude → true; Codex/Gemini → false. (E3 #3 / Codex P1(6) refactor depth.)
- **`MenuBarGaugeView.isTemplateAsset` recognises `GeminiLogo`.** New `GeminiLogo.svg` shipped in Mac `Resources/`, iOS `Assets.xcassets/`, and the Mac/iOS widget extensions.

### iOS Live tab + Live Activity + Settings

- **Live tab Gemini section, gated on `supportsGemini` (X3-A).** `AgentControlClient.hasWireVersionMismatch` rewritten from strict equality to forward-compat semantics — fires only when `serverWireVersion < composeDraftMinimum`. New per-feature flags `supportsGemini` / `supportsChatSubscribe` / `supportsComposeDraft` route through shared `AgentControlWireVersion.supports*(_:)` helpers so the iOS gating contract is testable. v5 Mac paired to v6 iOS hides Gemini correctly; v7 Mac paired to v6 iOS keeps rendering (no false mismatch banner).
- **`ProviderToggleHeader` shows the Gemini logo only when the paired Mac advertises wire v6+.** Falls back to Claude when an older Mac is paired; renders an `UpdateMacForGeminiCard` ("Update Continuum on Mac") inside the pane when the user has the Gemini chip selected but the Mac is too old.
- **`GeminiSection` mirrors the Mac column.** Single 5h-refresh card (no weekly), Google-blue accent (#4285F4), `WaitingForMacCard` empty state when the daemon hasn't shipped the first snapshot.
- **iOS Gemini Live Activity (D5).** New `GeminiQuotaLiveActivityAttributes` + `GeminiQuotaLiveActivityContentState` (shared package) + iOS coordinator + widget bundle entry. Lock-screen pill + Dynamic Island compact/expanded/minimal + always-on dimmed "G" + stale-flag triangle. Coordinator runs in `UsageModel.refreshFromDaemon` whenever a Gemini snapshot lands.
- **`UsageModel` per-provider snapshots.** New `@Published geminiSnapshot: UsageStore.Snapshot?` ingested via the X1 `usageData(for: "gemini")` per-provider fallback path, mirrored to App Group + WatchTokenBridge.
- **Settings sheet documents Mac-mirrored architecture.** New Codex + Gemini explainer sections clarifying that both providers' tokens live on the Mac and forward to iOS via the paired daemon. No iOS paste-token surface for Gemini (mirror-only path).

### Watch

- **`WatchTokenBridge` carries a `usageByProvider` dict alongside the legacy single `usage` field.** v5 watches keep reading the Claude snapshot through the old path; v6+ watches subscribe to the new dict for Codex + Gemini. `WatchUsageModel` gains a `usageByProvider` published property + `codexUsage` / `geminiUsage` accessors and writes per-provider App Group snapshots so complications can pick up Codex + Gemini.
- **Watch `ContentView` adds compact Codex + Gemini meters under the primary Claude gauge.** Each shows `N%` + "Resets X" with the provider's accent color (Codex blue, Gemini Google blue). Single-line by design — cloudcode-pa is single-window.

### X3 cross-model fixes

- **X3-C analytics trunk: `AnalyticsRepoList` is now provider-keyed.** Per-row "+N gem" pill renders when a repo has Gemini requests; ranking folds Gemini into the keyset so Gemini-only repos still surface; ranking falls back to request-count share when total cost is zero. Tooltip lists Claude + Codex + Gemini breakdown.
- **X3-D `ProviderHardcodingAuditTests` regression test.** Scans `apple/` Swift sources for binary `agent == .claude ? "Claude" : "Codex"` patterns and asserts each remaining hit is on a documented allow-list with a justification comment. Catches new provider-specific branches that slip in during implementation. Refactored 6 visible-mislabel sites through the new shared `AgentKindUI` helper (`assetName(for:)` / `displayName(for:)` / `accentRGB(for:)` / `isTemplate(for:)`): iOS sessions list/composer, Mac SessionWorkspaceView, Mac widgets, Mac SessionsView plan-mode help, Mac recentSubtitleRow.
- **`AgentSpawnerGeminiArgvTests`.** Argv-building logic factored into shared `GeminiArgvBuilder.argv(...)` so the test suite (8 cases) locks the exact `gemini -m <model> --approval-mode {plan|auto_edit|yolo} --resume <id>` argv contract, including the plan > yolo > auto_edit precedence rule.

### Wire / Codable / cross-platform

- **`UsageEnvelope` per-provider fallback (X1).** `/usage` HTTP response ships dual-shape: legacy `{claude, codex}` fields plus `usage: [String: UsageData]` dict. Clients call `usageData(for: providerID)` which prefers the dict per-provider and falls back to legacy independently per id. Prevents data-loss when the dict is partial (e.g. server emits `usage: {gemini: …}` while legacy fields carry Claude + Codex). `AgentControlServer.handleGetUsage` emits both shapes; legacy fields removed at wireVersion 7 (future v0.8).
- **`AgentControlWireVersion` static helpers.** New `hasMismatch(serverWireVersion:)` + `supportsGemini` / `supportsChatSubscribe` / `supportsComposeDraft` so the version-check contract is testable from shared (was previously inline in `AgentControlClient`).
- **`TokenTotals.requestCount: Int` Codable back-compat (X2).** Custom `init(from:)` uses `decodeIfPresent(Int.self, forKey: .requestCount) ?? 0` so existing iCloud snapshots + `analytics-cache.json` written before `requestCount` existed decode cleanly without `keyNotFound`.

### Tests

- **335/335 in `ClawdmeterShared`** (was 250 at v0.5.0). New suites cover the contracts shipped in this version:
  - `GeminiProviderLaneATests` (14) — TokenTotals back-compat, byProvider Codable round-trip + legacy v8 migration, compat getters, AgentKind tolerant decoder, per-provider envelope fallback, oauth_creds.json parse + expiry, slash-command filter; plus 2 regression tests for ISSUE-001's `UsageData.shouldReplace` contract.
  - `WireEnvelopeDualShapeTests` (7) — dual-shape per-provider fallback semantics.
  - `WireMixedVersionPairingTests` (6) — v5↔v6 and v6↔v7 forward-compat.
  - `UsageHistorySnapshotCompatGetterTests` (4) — `.empty` returns for missing provider keys.
  - `TokenTotalsRequestCountTests` (4) — Codable back-compat lock.
  - `ProviderConfigAutoReviveTests` (4) — contract for the new `AutoReviveSupport.supports(_:)` source of truth.
  - `AgentSpawnerGeminiArgvTests` (8) — argv flag contract.
  - `GeminiJSONLParserTests` (11) — chat-IDE rendering of `~/.gemini/tmp/<repo>/chats/session-*.jsonl`.
  - `ProviderHardcodingAuditTests` (1) — repo-wide audit for unintended binary provider checks.

### Tooling

- **`tools/refresh-pricing.sh` extended.** Filter regex now matches `gemini-*` and `gemma-*` alongside the existing `claude-*` / `gpt-*` / `o[0-9]+*` / `chatgpt-*` patterns so the embedded `pricing.json` covers Google's model name families.
- **`TODOS.md` v0.7 section.** Eng review deferrals + the two low-severity /qa deferrals (ISSUE-003 menu-bar item race, ISSUE-004 by-repo "+N gem" pill missing). Each has hypothesis + hook + effort estimate.

### Build

- Mac + iOS + Watch schemes all build clean. xcodegen + `xcodebuild build` verified on all three schemes after the QA fixes.
- Pre-existing Swift 6 warnings (NSLock-in-async, `AppModel.consume` actor isolation) inherited from `CodexTokenProvider` / existing `AppModel` patterns; not introduced by this branch.

## [0.5.10 build 43] - 2026-05-19

### Fixed

- **Recent JSONL rows can now actually be renamed too.** v0.5.4 / v0.5.9 wired rename for registered AgentSessions (the rows under the live session list), but the "Recent (last 30 days)" rows in the sidebar use a different renderer — `recentSessionRow` on Mac, `RecentSessionRow` on iOS — and weren't wired up at all. Right-clicking "Rename…" on the `/office-hours` row (or any other Recent JSONL row) silently no-op'd. Surfaced when the user followed up "still not working" after v0.5.9 shipped, with a screenshot of a Recent row. Rename for Recent JSONL rows is now first-class on both platforms.
  - **New `JSONLAliasStore` daemon-side** (`apple/ClawdmeterMac/AgentControl/JSONLAliasStore.swift`) — thread-safe (`NSLock`) Mac-side store keyed by the JSONL's absolute path, persisted to `~/.clawdmeter/jsonl-aliases.json` with atomic write. Survives app restarts; survives `RepoIndex` rebuilds. Singleton (`JSONLAliasStore.shared`); not actor-bound so the actor-owned `RepoIndex` and the `@MainActor` HTTP handlers both call it without isolation hops.
  - **`RecentSession` gains `customName: String?`** (`apple/ClawdmeterShared/.../Protocol.swift`) — decoder-tolerant (`decodeIfPresent`) so older iOS clients reading a newer Mac's response degrade cleanly. `RepoIndex.buildSnapshot` snapshots the alias store once per refresh and folds matching aliases into both the Claude (`~/.claude/projects/`) and Codex (`~/.codex/sessions/`) construction sites.
  - **New `POST /jsonl-aliases/rename` daemon endpoint** with body `{path, name}`. Path is validated to start with `/` and live under one of the two known JSONL roots so a paired-but-malicious peer can't wedge arbitrary keys into the alias file. 200-char cap on `name` matches the session-rename cap. Handler kicks a `RepoIndex.refresh()` after the write so the new name surfaces in the sidebar without waiting for the 60s tick.
  - **New iOS client method `AgentControlClient.renameJSONLAlias(path:name:)`** posts to the new endpoint and refreshes the sessions list.
  - **Mac UI surfaces `customName` in `recentTitle(_)`** with the alias winning over `firstPrompt`. `recentSessionRow` gains a right-click "Rename…" context-menu action that uses the canonical `@State Bool` + `presenting:` payload alert pattern (same fix as the v0.5.9 AgentSession rename). Writes directly to `JSONLAliasStore.shared` — no HTTP loopback needed since the Mac is the daemon.
  - **iOS `RecentSessionRow.title`** also prefers `customName`. Both call sites (the repo-grouped list at `iOSSessionsView.swift:328` and the by-date list at `iOSSessionsView.swift:635`) gain a `.contextMenu` on the inner label (the v0.5.7 fix learning — iOS 17 List swallows context menus attached to the outer NavigationLink) plus a leading swipe action labeled "Rename" for discoverability. Shared parallel `renameJSONLTarget` / `renameJSONLInput` / `showingRenameJSONLAlert` state mirrors the session-rename plumbing.

### Also lands in this build

- **Wire version 4 → 6 — Gemini provider scaffolding.** `AgentKind` extends with `.gemini`, `ModelCatalog` gains a `gemini` array, `/usage` envelope ships dual-shape (legacy `claude/codex` + a new `usage` dict) with per-provider fallback so v6 readers prefer `usage[id]` and fall back to legacy independently per provider (X1 fix — prevents data loss when the dict is partial). `geminiMinimum = 6` gates iOS UI on the new schema. New `GeminiUsageParser` / `GeminiSource` / `GeminiTokenProvider` files surface analytics totals; the chart + totals views gain Gemini's blue accent alongside terra-cotta + slate. There is no `gemini` CLI to spawn yet, so the spawner / approve-plan paths route `.gemini` to the missing-binary surface gracefully.
- **Mac, iOS, Watch schemes build clean** after closing the switch-exhaustiveness gaps the partial Gemini refactor left behind (`AgentControlServer.handleContinueReadOnly` / `handleApprovePlan`, `SessionsView.spawnSession` / `continueOutsideSession` / new-session sheet, `SessionActivityStrip.indicator`, `Workspace/ModelPicker.modelsForAgent`, `Composer/CommandPalette.filter`, `AgentSpawner.argv(for:)` / `respawnArgv`, iOS `RecentSessionRow.badgeBackground`/`badgeForeground`/`providerLabel`/`providerLabelColor`).
- **Two pre-existing test failures fixed too**: `UsageCloudMirrorAnalyticsTests` was constructing `UsageHistorySnapshot` with the v5 `claude:/codex:` init that the Gemini refactor replaced with `byProvider: [.claude: ..., .codex: ...]`. `UsageHistoryTests.test_loaderEmptyDirsReturnsZero` was hitting the user's real `~/.gemini/tmp/` because `geminiDir` default-points there; the test now passes a temp-dir override. 276/276 green.

## [0.5.9 build 42] - 2026-05-19

### Fixed

- **Session rename now actually works on both Mac and iPhone.** v0.5.4's rename alert used `.alert(isPresented: Binding(get: { renameTarget != nil }, set: ...))` to drive presentation off the data target. The closure-captured `renameTarget != nil` read isn't recognized as a SwiftUI dependency, so the binding's `get` never re-evaluates when `renameTarget` flips from nil to non-nil — the alert silently never presents. Both Mac and iPhone hit this; "rename not working" surfaced as nothing happening when the user picked Rename… from the context menu / swipe action. Fixed by moving to the canonical SwiftUI pattern: `@State Bool` for presentation + `presenting:` payload for the data. Trigger sites now also flip `showingRenameAlert = true` after setting the target. Alert presents reliably; Save / Clear name / Cancel buttons fire as expected.

## [0.5.8 build 41] - 2026-05-19

### Added

- **AskUserQuestion tray now renders in the iPhone outside-session view** (Recent JSONL rows the user taps from the sidebar). Previously v0.5.6's tray work only landed in the live `liveChatList` and the Mac `ChatThreadScroll`; `iOSChatTranscriptView` — which serves outside-Continuum Recent JSONLs — used its OWN local `Item`/`toolRunCard` path and didn't pick up the new ChatItem partitioning. Wired in for parity: file-edit pairs render as `EditDiffRow` chips, AskUserQuestion pairs render as `AskUserQuestionTray`, everything else stays in the existing tool-run card.
- **Answer-tap promotes the outside session and forwards the answer.** When the user taps an option + "Send answer" in an outside-session tray, the view fires `client.continueReadOnly(jsonlPath:repoKey:agent:prompt: <answer>)` — same single-shot path the composer uses for typed prompts. Daemon spawns a fresh `--resume` pane with the answer as the seed turn; iOS flips navigation to the new live session. The tray dims out locally on send so the user knows the action fired even before promotion completes.

## [0.5.7 build 40] - 2026-05-19

### Fixed

- **iPhone long-press on session rows now triggers the rename context menu.** Previously the `.contextMenu` was attached to the outer `NavigationLink` which causes iOS 17's `List` to swallow the long-press gesture in favor of NavigationLink's own preview/peek behavior. Moved the modifier inside the `NavigationLink`'s label so it attaches to `SessionRow`'s hit-test surface directly. Both the repo-grouped and date-grouped paths fixed.
- **Rename is now also a leading swipe action** alongside Approve / Interrupt. Discoverable from the same gesture users already know, and works regardless of context-menu quirks.

## [0.5.6 build 39] - 2026-05-19

### Fixed

- **Token-usage "Daily spend" bar chart now renders on the All-time filter.** Previously gated by an `if store.activeWindow != .allTime` in `AnalyticsView`, which hid the chart for any "All time" selection. The `AnalyticsDailyChart.allTime` code path was already correct — walked the union of activity days ascending, zero-filled gaps — the gate just denied it the chance to render. Removed.

### Added

- **Interactive AskUserQuestion tray in chat.** When the assistant emits an `AskUserQuestion` tool_use, the chat thread now renders an answer card (per-question header + question text + tappable option rows with descriptions) instead of folding into "Ran 1 command". Tap an option → tap "Send answer" → the chosen label routes through the daemon's `/sessions/:id/send` endpoint (same path the composer uses) → Claude Code's interactive picker on the Mac receives the answer text + trailing newline, which acts as Enter for the picker. The tray grays out once the matching `tool_result` lands so the user knows it's been consumed.
  - **New `AskUserQuestion` Codable struct in `ClawdmeterShared`** with a `fromToolInput(_:)` factory that parses the `{questions: [{question, header, multiSelect, options: [{label, description}]}]}` shape. Decoder-tolerant via the optional `askUserQuestion: AskUserQuestion?` field on `ChatMessage` — v0 messages decode cleanly.
  - **New `AskUserQuestionTray` view in `ClawdmeterShared/AgentControl/Views/`** with single-select / multi-select support. State persists per tool_use_id across list re-renders.
  - **Wired into both iOS `liveChatList` and Mac `ChatThreadScroll`.** The chat thread now partitions each `toolRun`'s pairs by tool kind (Edit → diff chip, AskUserQuestion → tray, everything else → generic disclosure).
  - **Mac answer-send** uses the existing `MacComposerSender` loopback to the daemon, picking up the same rate-limit + audit-log path as a typed prompt.

## [0.5.5 build 38] - 2026-05-19

### Added

- **Inline edit-diff rows in the chat thread.** `Edit`, `MultiEdit`, and `Write` tool_use calls now render as their own dedicated chip — `Edited <basename> +N -M ›` (or `Wrote <basename> +N ›` for new file writes) — matching Claude Code's CLI rendering. Other tool runs (Bash, Read, Grep, etc.) still fold into the existing "Ran N commands" disclosure group. Tap the chip to expand the full file path and the tool_result body in line.
  - **New `EditStats` struct** in `ClawdmeterShared` with a `fromClaudeInput(_:toolName:)` factory that counts additions / deletions from the tool's `old_string` / `new_string` (Edit), the sum across an `edits` array (MultiEdit), or the `content` length (Write — deletions reported as 0 since the prior content isn't known at parse time).
  - **New `EditDiffRow` view** in `ClawdmeterShared/AgentControl/Views/` renders the chip on both iOS and macOS. Watch fallback is a compact non-disclosure layout since `DisclosureGroup` isn't available on watchOS.
  - **`ChatMessage` gains an optional `editStats: EditStats?` field** populated at parse time in `SessionChatStore`'s tool_use branch. Decoder-tolerant — v0 messages persisted before this field landed decode cleanly with `editStats = nil`.
  - **Chat thread renderers on iOS + Mac** partition each `ChatItem.toolRun`'s pairs into edit pairs (rendered as standalone `EditDiffRow`s) and non-edit pairs (folded into the existing tool-run card). Mixed groups render edits at top, then the other commands beneath.
  - **Codex `apply_patch` is out of scope** for v0.5.5 — only Claude's Edit/MultiEdit/Write are detected. Codex tools still render via the generic tool-run card.

## [0.5.4 build 37] - 2026-05-19

### Added

- **Rename sessions** to anything memorable. New `customName: String?` field on `AgentSession` (optional, decoder-tolerant — v3 files decode cleanly with `customName = nil`). When set, replaces the default sidebar / chat-header label so a session can be "Refactor checkout flow" instead of "Continuum / Claude".
  - **Mac UI**: right-click any session in the sidebar → "Rename…". Alert with a text field; "Save" sets the name, "Clear name" wipes it back to the repo-derived default, "Cancel" discards. Header label + sidebar row + raw-terminal overlay title all pick up the custom name; falls back to goal, then repo name.
  - **iPhone UI**: long-press any session row → "Rename…". Same three-button alert. Navigation title on the session detail view uses the custom name too.
  - **Daemon endpoint**: `POST /sessions/:id/rename` with `{name: String?}`. Empty/whitespace-only strings normalize to nil at the registry; cap of 200 chars for the inbound name so paired peers can't push huge strings into `sessions.json`. iOS client: `AgentControlClient.renameSession(sessionId:name:)`.
  - **Persistence**: `AgentSessionRegistry` schema bumped 3 → 4. Pre-v4 readers silently drop the field; post-v4 reading a v3 file populates `customName = nil`. No migration required.

### Internal

- New `AgentSession.displayLabel` computed property — prefers `customName` (trimmed, non-empty) over `repoDisplayName`. Use this anywhere a session display label is rendered going forward.
- `AgentSessionRegistry.with(...)` helper gains a `customName: String??` parameter following the same `Optional<T>.some(nil)` "explicitly nil out" pattern as `archivedAt`, `effort`, etc.
- New `RenameSessionRequest` DTO in `Protocol.swift` so iOS + Mac share the wire shape.

## [0.5.3 build 36] - 2026-05-19

### Fixed

- **No more cold-cache slowness on first iPhone session-load after Mac restart.** The 2026-05-19 user-reported "session not loading on mobile" (which turned out to be a 10–30s wait while `/transcript` reparsed a 4–30MB JSONL on first request) is fully addressed:
  - **`DaemonChatStoreRegistry` now also serves `/transcript`.** New path-keyed map (`pathEntries: [URL: Entry]`) alongside the existing session-id-keyed map. `snapshotStore(forJSONLPath:)` creates / reuses long-lived `SessionChatStore`s pinned to absolute JSONL paths; the iPhone outside-Continuum session view hits the same warm cache as `/chat-snapshot` instead of reparsing 500 messages on every request. Cold-miss still falls back to legacy synchronous `TranscriptLoader.load`; subsequent requests within the 5-minute idle window are instant.
  - **Daemon startup pre-warms the registry.** New `registry.warm(recentLimit: 5)` scans `~/.claude/projects/` and `~/.codex/sessions/` for the 5 most-recently-modified `.jsonl` files and pre-creates stores for them. Reverse-tail parse runs on a detached background Task post-listener-bind so it doesn't block startup. First iPhone request after Mac restart hits a warm store.
- **`SessionChatStore.ChatSnapshot` exposes `messages: [ChatMessage]`** (the raw chronologically-sorted list) so the `/transcript` envelope can serve it through the same publish cycle that drives `items`. Both fields stay consistent by construction — the snapshot rebuild publishes them together.

### Internal

- Combined sweep + max-cap eviction across session-id and path-keyed entries. Both share the `maxResidentStores = 20` hard cap; idle entries from either map evict after 5 minutes regardless of which key surfaced them.
- Synthesized stable UUIDs for path-keyed stores via a 16-byte mixed FNV-1a hash of the path so OSSignpost logs stay traceable for `/transcript` cache hits.

## [0.5.2 build 35] - 2026-05-19

### Added

- **"Session is still working" indicator on Mac + iPhone chat threads.** New `LiveSessionActivityIndicator` (`apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/Views/LiveSessionActivityIndicator.swift`) renders a provider-branded spinner + elapsed-time badge at the bottom-leading of the chat thread when the session's JSONL has been touched in the last 30 seconds. Claude variant: rotating Anthropic-style asterisk in terra-cotta (`#D97757`). Codex variant: pulsing three-dot sweep in codex blue (`#5C9DFF`). Drives off `chatStore.snapshot.lastEventAt` so no new server-side state is needed. Pre-v0.5.2 there was no visible signal that the agent was still working between tool runs — the user feedback that triggered this was "there's no way to know that the session is still moving forward and claude/codex is working."
- **iPhone composer paperclip works in `.outside` mode** (read-only Recent JSONL rows that the user is about to "Continue here"). Previously the paperclip was hidden for outside-mode because there was no session id to upload against. Now picking an image stages the bytes locally, and `performSend` does a two-phase promote → upload → send dance:
  1. `continueReadOnly(prompt: nil)` — promote the synthetic to a live `--resume` pane without sending anything yet.
  2. `uploadAttachment(sessionId: newSessionId, ...)` for each pending attachment.
  3. `sendPrompt(sessionId: newSessionId, text: <body-with-@paths>)` — fire the actual prompt with the resolved `@<path>` refs.
  Single-shot (no-attachment) path unchanged. Failures on individual uploads degrade gracefully: the prompt still sends with the successful uploads + an inline "some attachments failed" message; the user doesn't lose the whole send to one bad image.

### Removed

- **The "Read-only" pill in the Mac chat header.** The composer's "Continue here" placeholder + the disabled-action menu state already signal read-only mode; carrying a third badge in the header for the same fact doubled visual noise. The pill at [SessionWorkspaceView.swift:992](apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:992) is now an `EmptyView`.

## [0.5.1 build 34] - 2026-05-19

### Fixed

- **"Couldn't resume this session — no session id in the JSONL header" on read-only Continue here.** `JSONLSessionId.extract` was a single 64KB header read; if the kernel hadn't flushed the sessionId-bearing line yet (active write race), or if the JSONL variant carries the field past the 64KB mark, extract returned nil and the Mac composer surfaced the resume error. v0.5.1 streams the file in 64KB chunks up to a 1MB cap, scanning only complete lines per chunk so a partial trailing line in one chunk doesn't poison the parse. Plus a final scan that handles single-line files with no trailing newline. All 10 existing `JSONLSessionIdTests` still pass.
- **The error message now includes the JSONL path** when extract still returns nil — so a genuinely-malformed file is identifiable without grepping logs. Same daemon-error pattern as the other read-only failures.

## [0.5.0 build 33] - 2026-05-19

### Fixed

- **iPhone chat snapshot now arrives via WebSocket push, not 3-second HTTP polling (Phase 2 of the WhatsApp-smooth Sessions plan).** The Mac daemon's existing WS dispatcher gained a `chat-subscribe` op (`apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:421`); the iOS side opens a long-lived WebSocket per `iOSChatStore` and replaces the 3s polling loop. The daemon coalesces `SessionChatStore` snapshot commits at 100ms via Combine `.debounce` and pushes a full `WireChatSnapshot` JSON text frame; iOS replaces its `@Published` snapshot wholesale and the live chat List re-renders.
  - **New file `apple/ClawdmeterMac/AgentControl/ChatStreamWebSocketChannel.swift`** — owns the Combine subscription to a `DaemonChatStoreRegistry`-acquired store, releases on stop, sends WS text frames.
  - **No delta encoding in v1.** Per Codex's outside-voice review (D6), shipping full-snapshot push with the bounded 500-item-per-store cap is acceptable until measurements show bandwidth is a real problem. The `.appendItems` / `.patchLastToolRun` / `.resyncRequired` cases stay deferred to v2.
  - **Failure handling.** Three layers: exponential backoff 1→30s with jitter on transient WS errors; HTTP fallback ladder (`refresh()` for 3 cycles) after the 3rd consecutive WS failure; wire-version gate keeps iOS on HTTP polling for older Macs (wireVersion < 5). `UIApplication.didBecomeActiveNotification` observer triggers a reconnect when the last received frame is >30s stale.
- **Daemon enforces the chat-subscribe wire envelope.** `{op: "chat-subscribe", token, sessionId}` — bearer auth + Tailscale whois gates already cover this path via the existing `routeWSSubscription` dispatcher; no new auth surface.

## [0.5.0 build 32] - 2026-05-19

### Fixed

- **iPhone + Mac chat lists migrated to native `List` (Phase 1 of the WhatsApp-smooth Sessions plan).** Two surfaces touched: `liveChatList` in `apple/ClawdmeteriOS/iOSSessionsView.swift:935` and `ChatThreadScroll.body` in `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1488`. Both moved from `ScrollView { LazyVStack }` with per-row `.id(item.id)` (which defeats cell recycling, Stream benchmarks call this out as ~10x scroll-perf cost at 1k+ messages) to native `List` with `ForEach(items, id: \.id)`. Per-row `.onAppear`/`.onDisappear` pin-tracking pairs (fired on every row as you scrolled) collapsed to a single 1pt `Color.clear` bottom sentinel row whose appear/disappear callbacks drive `pinnedToBottom`. The scroll-on-new-item path now coalesces rapid bumps via a 50ms `Task.sleep` debounce so token-by-token streaming doesn't animate scroll-to-latest on each token. Mac chat thread has a documented fall-back to `LazyVStack`-without-`.id` if AppKit `List` underperforms on very long sessions.

### Removed

- `SessionDetailView.jumpLiveChatToLatest(_:animated:)` and `ChatThreadScroll.jumpToLatest(_:animated:)` — dead after the Phase 1 migration; their callers now scroll-to-sentinel directly via `proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)`.

## [0.5.0 build 31] - 2026-05-19

### Fixed

- **Codex `approve-plan` mid-session no longer breaks iPhone chat continuity (Phase 0b of the WhatsApp-smooth Sessions plan).** New `SessionFileResolver` (`apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/SessionFileResolver.swift`) tracks `(AgentSession.id → Codex rollout URL)` lineage across `approve-plan` boundaries. When the daemon kills the plan-mode pane and spawns a fresh rollout file, the resolver invalidates the cached link so the next `/chat-snapshot` request rescans `~/.codex/sessions/` for the new rollout (newest in the session's activity window). Without lineage tracking the iPhone would silently strand on the dead pre-approve rollout. Belt-to-suspenders: even if `invalidate` isn't called, the resolver auto-promotes to a newer in-window rollout on the next resolve.
  - **Tests.** New `SessionFileResolverTests` (9 cases) covers Claude path delegation, Codex activity-window scanning, cache reuse, the regression-critical respawn lineage (`testCodexApprovePlanRespawnLineage_CRITICAL`), explicit invalidate-after-respawn, cached-file-missing fallback, synthetic-preview fallback, and direct `record(sessionId:rolloutURL:)`.
- **Daemon `/chat-snapshot` cold path now goes through the same resolver.** Previously the cold-miss fallback in `handleGetChatSnapshot` called `newestCodexJSONL()` (global newest) for Codex sessions. After Phase 0b it routes through `SessionFileResolver.resolve(session:)` so the cold path honors session→file identity too.
- **`SessionChatStore.resolveSessionFileURL(repoCwd:)` is now `nonisolated`.** Pure FileManager-based path resolution doesn't need `@MainActor` isolation; marking it nonisolated lets `SessionFileResolver` call it from its `@Sendable` closure without an actor hop.

### Changed

- 267 → 276 shared tests (added 9 in `SessionFileResolverTests`).

## [0.5.0 build 30] - 2026-05-19

### Fixed

- **Daemon /chat-snapshot no longer reparses 500 messages on every request (Phase 0a of the WhatsApp-smooth Sessions plan).** New `DaemonChatStoreRegistry` (`apple/ClawdmeterMac/AgentControl/DaemonChatStoreRegistry.swift`) owns long-lived `SessionChatStore`s on the daemon side. First request to a session JSONL warms the store via reverse-tail; subsequent HTTP polls within the 5-minute idle window read the cached snapshot. Each store evicts after the idle grace period or when `maxResidentStores=20` is exceeded.
  - **Root cause** (surfaced in the /office-hours → /plan-eng-review → Codex outside-voice cycle, verified in code): `iOSChatStore` polls `GET /chat-snapshot` every 3 seconds, and `AgentControlServer.handleGetChatSnapshot` reparsed the full JSONL via `TranscriptLoader.load(maxMessages: 500)` on every call. Tailscale RTT plus a fresh 500-message parse on every tick explained a chunk of "iPhone Sessions tab feels heavy."
  - **Cold-miss fallback preserved.** First request after server boot or after idle eviction falls back to the legacy synchronous reparse so HTTP latency stays bounded; the background store catches up for subsequent calls.
- **`WireChatSnapshot.updateCounter` is now the real chat cursor.** Before this release the field was populated from `session.lastEventSeq` (a session-status counter that bumps on plan/registry events) — Codex's outside-voice pass caught that the wire's "delta cursor" was effectively decoupled from actual transcript state. Phase 0a populates it from the live `SessionChatStore.updateCounter`, which bumps only when chat content changes. Field shape and name are unchanged, so v4 iOS clients keep working; only the semantics shifted.

### Changed

- Wire version `4 → 5`. New `AgentControlWireVersion.chatSubscribeMinimum = 5` constant gates the upcoming Phase 2 `chat-subscribe` WS op so older Macs stay on the existing `/chat-snapshot` HTTP polling path. `composeDraftMinimum` stays at 4.

## [0.4.11 build 29] - 2026-05-19

### Fixed

- **Mac dashboard "Connecting…" → working again.** Two-endpoint poll strategy with the magic header that unblocks the original path.
  - **Root cause.** Anthropic tightened the OAuth surface on `POST /v1/messages` and started returning HTTP 403 `permission_error` "OAuth authentication is currently not allowed for this organization" for Pro/Max OAuth tokens. Every previous build polled `/v1/messages` with a 1-token Haiku request and parsed the `anthropic-ratelimit-unified-*` response headers — that contract held for months and then quietly broke.
  - **Primary fix: `x-anthropic-additional-protection: true`.** The header is the actual gate Anthropic introduced. With it, the original `/v1/messages` path returns HTTP 200 and the full unified rate-limit header set — both 5h and 7d windows in a single response, no separate fetch. The literal value `true` and the matching `x-anthropic-billing-header: cc_version=2.1.143` were lifted from `~/.local/bin/claude`'s binary (the `claude` CLI sends them on every request). All the original header-parsing code is preserved.
  - **Fallback: `GET /api/oauth/usage`.** If `/v1/messages` ever 403s again (Anthropic rotates the additional-protection mechanism, or revokes the org's access to it), `AnthropicSource` falls back to the endpoint `claude` uses for its own rate-limit fetch. Response body's `rate_limit_type` / `utilization` / `resets_at` populates the binding window; the un-binding window is remembered from the last successful primary poll so the gauge doesn't flap to 0%. Strictly poorer data than the primary path (only one window per call) but resilient.
  - **Robustness ride-alongs.** (1) `KeychainTokenProvider` no longer caches the token in memory across polls — Claude Code rotates its OAuth token every few hours, and the cache meant we held the stale copy for the lifetime of the Mac process. Re-reading the Keychain on each poll is sub-millisecond. (2) `allowed_warning` is now treated as `.allowed` (it's what Anthropic returns past the 75% threshold; was being mapped to `.unknown` and confusing the gauge color logic).

### Changed

- 264 → 267 shared tests. `AnthropicSourceTests` now covers the magic-header assertion on the primary path, the `allowed_warning` status, the `/v1/messages` → `/api/oauth/usage` fallback when the primary 403s, and the fallback's three response shapes (multi-window, single-binding, statusline-wrapper).

## [0.4.10 build 28] - 2026-05-18

### Fixed

- **Appearance picker now actually re-themes the app.** v0.4.9 shipped the picker but the toggle did nothing — `ClawdmeteriOSApp.body` was pinning `.preferredColorScheme(nil)` on the `WindowGroup`, and SwiftUI resolves the modifier nearest the App scene as authoritative, so the dynamic value applied deeper inside `ContentView` was being overridden back to `nil` (system). Removed the static modifier and applied the dynamic one — driven by `@AppStorage("clawdmeter.appearance")` — on the root view INSIDE the `WindowGroup`.
- **Settings sheet re-themes in place when the user picks a new theme.** SwiftUI sheets capture `preferredColorScheme` at presentation time and don't pick up later changes from the presenter's `@AppStorage`. Picking `Dark` from inside Settings changed the underlying TabView but the sheet stayed Light until the user dismissed and re-opened it. Applied `.preferredColorScheme` on the sheet's own root in `SettingsView.body` so the sheet re-renders the instant the picker writes a new value.

### Internal

- Cleaned up an unused-binding warning in `iOSModelEffortPill`.

## [0.4.9 build 27] - 2026-05-18

### Added

- **Dark/Light mode toggle on iPhone Settings.** New top-of-Settings `Appearance` section with a menu picker — `System` (default, follows iOS Settings → Display & Brightness), `Light`, or `Dark`. Choice persists via `@AppStorage("clawdmeter.appearance")` and applies app-wide through a `.preferredColorScheme` modifier on the root TabView, so the swap takes effect immediately across every tab, every sheet, and every NavigationStack.

## [0.4.8 build 26] - 2026-05-18

### Added

- **iOS image attachments — paperclip on the composer is live.** The iOS paperclip now opens `PhotosPicker` (up to 4 images at a time). Picked images upload over Tailscale to the Mac daemon's new `POST /sessions/:id/attachments?ext=png` endpoint, which writes them to the same staging directory the Mac drag-drop path uses (`~/Library/Application Support/Clawdmeter/attachments/<sessionId>/<uuid>.<ext>` for Claude/Codex-local, or `<worktree>/.clawdmeter-attachments/` when Codex is in worktree mode). Each upload returns the absolute path on the Mac.
  - **Chip strip** above the text field renders a thumbnail per pending attachment, with a tap-to-remove × and a spinner overlay while the upload is in flight. Failed uploads tint red with an alert glyph.
  - **Send is gated** while any attachment is still uploading so we don't drop bytes mid-flight.
  - **On send**, the composer prepends `@<path>` for each successfully uploaded attachment as its own line, then a blank line, then the user's typed text. Mirrors the Mac drag-drop output so the agent's Read tool resolves the file identically across platforms.
  - **Format sniff** — composer reads the leading bytes to pick the on-disk extension (`png`, `jpg`, `gif`, `heic`); defaults to `.jpg` when unrecognised.
  - **256pt thumbnails** generated client-side for cheap chip rendering. Original bytes go up the wire — the Mac stores the real file.
  - Currently scoped to live sessions. Outside (Recent JSONL) rows hide the paperclip until they promote — outside-then-attach would need a "stage before promote" path the daemon doesn't expose yet.
- **Daemon body-parser cap raised from 1MB → 50MB.** Required for the attachment upload path. Per-handler caps still enforce their own (send stays at 1MB, artifact + attachments at 50MB). Tailscale ACL + bearer auth still gate who can reach the daemon.

## [0.4.7 build 25] - 2026-05-18

### Changed

- **iOS composer matches the Mac chat IDE — controls move inside the composer card.** Until now the iOS composer was a bare text field + send button, and a separate `iOSSessionControlsStrip` sat above the chat with model/effort/plan toggles. v0.4.7 collapses everything into one composer card (Claude Desktop / Codex style):
  - **Single rounded card** wraps the text field + the bottom control row.
  - **`Opus 4.7 · Max ⌄` pill** on the left for live sessions — new `iOSModelEffortPill` opens a Menu with **Models** (Opus 4.7, Opus 4.7 1M, Sonnet 4.6, Haiku 4.5, Opus 4.6, plus Codex catalog for Codex sessions) and **Effort** (Low / Medium / High / Extra high / Max) sections. Picking a model fires `client.changeModel`; picking effort fires `client.changeEffort`.
  - **Outside (Recent JSONL) rows** show the agent name as a static chip in place of the picker — the model/effort are decided at promote time by the daemon's `/sessions/continue-readonly` handler.
  - **Paperclip + mic buttons** join the right-hand cluster next to send. Both surface a polite "Mac-only for now" sheet — iOS-to-Mac attachment upload + on-device dictation need their own endpoints and are flagged as follow-up.
  - The redundant `iOSSessionControlsStrip` above the chat is gone; its model/effort/plan-toggle responsibilities now live inside the composer.

## [0.4.6 build 24] - 2026-05-18

### Changed

- **Recent JSONL rows on the Mac sidebar match the iOS polish.** Provider badge on the leading edge (Claude burst tinted terra-cotta or Codex template silhouette), color-tinted provider name in the subtitle, optional repo chip (`📁 my-repo`) when the row isn't already under a Repo section header (i.e. when the user picks the Date / Status / Agent / None grouping), green `Now` capsule when the JSONL was touched in the last 5 minutes.
- **Active state moved from a corner dot to a green ring** around the provider badge — single high-contrast cue on both Mac and iOS. The corner dot the iOS row had in v0.4.5 is gone.

### Removed

- The trailing eye icon on every Mac Recent row.
- The `· read-only` suffix in the Mac Recent row subtitle.
- The Mac context menu's `Open read-only` action — `Continue here` is the only one that matters now, since the always-on composer made every row continuable.

## [0.4.5 build 23] - 2026-05-18

### Changed

- **iOS Recent JSONL rows — visual refresh.** The old row layout (status dot + title + `"Claude · 52 sec. ago · live now · read-only"` subtitle + trailing eye icon) was both misleading and visually flat. Refreshed:
  - **Provider badge** on the leading edge — circular Claude burst (terra-cotta tinted) or Codex silhouette, 28pt. Live sessions get a green corner dot pulsing on the badge.
  - **Color-tinted provider name** in the subtitle (terra-cotta for Claude, primary for Codex).
  - **Repo chip** with folder icon — the date-grouped list previously hid which repo a row belonged to. `By date` rows now show `Claude · 📁 my-repo · 3 min ago`. `By repo` rows still defer to the section header (no stutter).
  - **Live `Now` badge** in green replaces the inline `· live now` string when the JSONL was touched in the last 5 minutes.
- **Read-only copy + eye icon removed.** v0.4.1 made outside JSONLs continuable from the composer, so calling them "Read-only" was no longer true. The trailing eye icon, the `· read-only` suffix on every row, and the "Read-only" banner in `iOSChatTranscriptView` are all gone.

## [0.4.4 build 22] - 2026-05-18

### Fixed

- **All-time daily-spend chart now renders.** The Mac analytics view's `Daily spend` chart silently bailed when the user picked the `All time` window — there was an explicit `guard window != .allTime else { return [] }` from an earlier plan that wanted the chart hidden for that case. With months of data accumulated, the empty chart space underneath the All-time totals looked broken. `AnalyticsDailyChart.points` now walks the union of every day with activity across both providers (zero-filling internal gaps so the X-axis stays continuous through quiet weeks), sorted ascending. The existing X-axis stride math (`max(1, data.count / 14)`) scales the date labels automatically.

## [0.4.3 build 21] - 2026-05-18

### Changed

- **iOS Sessions tab — `By date` replaces `By status`.** The status buckets (`Needs attention / In progress / Idle / Done / Archived`) weren't earning their slot on mobile — most sessions are "in progress" all day and the rest of the buckets stayed empty. New `By date` grouping mirrors the Mac sidebar's date grouping: **Today** at the top, then **Yesterday**, then **Earlier this week**, then **Last 30 days**, then **Older**. Each header shows a count badge.
- Live sessions (by `lastEventAt`) and Recent JSONLs (by `lastModified`) **interleave** under each date bucket, so a Conductor session you used 20 minutes ago sits next to a Continuum-spawned one with the same timestamp. Recent JSONLs use the existing `OutsideSessionDetailView` so the composer-promote-to-live flow works from any date bucket.
- Search + `Show archived` toggle still apply to the date list.
- The unused `StatusBucket` enum and its bucketer are gone — net deletion.

## [0.4.2 build 20] - 2026-05-18

### Changed

- **iOS Live tab — logo segmented control replaces the toggle row.** v0.4.0 made the whole "Claude" header tappable; v0.4.1 still hid the toggle behind a `↔` glyph. v0.4.2 makes the logos themselves the control: both provider logos sit side-by-side at the top of the Live tab. The active provider's logo is rendered at 48pt full color with the name at 20pt bold and a terra-cotta accent rule underneath; the inactive provider's logo sits at 32pt and 0.35 opacity with a muted 14pt name. Tap either logo to pick that provider directly. Slide direction follows physical layout — Claude (left) slides in from the leading edge, Codex (right) from the trailing edge. The `↔` swap glyph and page dots are gone; the logos themselves communicate selection. Horizontal swipe gesture in the content area still works as a power-user shortcut.
- **Accessibility:** each logo button is its own a11y button. The active one carries the `.isSelected` trait so VoiceOver reads "Claude usage, selected"; inactive ones include the hint "Tap to switch".

## [0.4.1 build 19] - 2026-05-18

### Added

- **iOS Sessions tab — fully working composer.** The mobile app was stuck in view-only mode (Recent JSONLs rendered a transcript but no chat box, and the Chat tab on live sessions was a placeholder). Both surfaces now ship a real composer at the bottom:
  - `iOSComposerBar` — multi-line text field with dashed terra-cotta border, "Continue the session here" placeholder for outside sessions / "Message the agent…" for live sessions, big tap-target ↑ send button. Read-only outside sessions stay read-only until you actually press send — tapping in + typing does nothing to the session.
  - **Live sessions:** send → `POST /sessions/:id/send` (same path the Mac uses).
  - **Outside (Recent JSONL) sessions:** send → new `POST /sessions/continue-readonly` endpoint on the Mac daemon that mirrors `SessionsModel.continueCurrentReadOnly` server-side: parses the JSONL header for the CLI session id, spawns a fresh tmux pane with `--resume <id>` (Claude) or `resume <id>` (Codex), forwards the user's first prompt after the pane is ready, and returns the new `AgentSession.id`. iOS swaps navigation into the live `SessionDetailView` automatically. Failed extraction (truncated JSONL, no session id) surfaces an inline error and preserves the text.
- **iOS live chat rendering — the Chat tab now actually renders chat items.** Previously the Chat tab on `SessionDetailView` was a `PlanCardView` + empty `StructuredEventList` placeholder. New `liveChatList` view reads `chatStore.snapshot.items` (already polled from `/sessions/:id/chat-snapshot`) and renders user/assistant message bubbles + collapsed "Ran N commands" tool-run cards, mirroring the Mac thread style. Plan-mode card stays at the top when `session.planText` is set.
- **Jump-to-latest CTA on the iOS live chat.** Floating capsule appears when the user scrolls away from the tail; `userPinnedToBottom` tracking stops auto-scroll yanking when reading history. Scrolls to the last item's id, not a culled `LazyVStack` sentinel — same fix as the Mac.
- **Shared DTOs:** `ContinueReadOnlyRequest` (jsonlPath, repoKey, agent, prompt) + `ContinueReadOnlyResponse` (sessionId) in `Protocol.swift` so the Mac daemon and iOS client share the wire shape.

### Tests

- 257 in `ClawdmeterShared`. No new tests this point release — wire DTOs are simple Codable structs covered by the existing round-trip patterns; the surface changes are UI-side.

## [0.4.0 build 18] - 2026-05-18

### Added

- **Always-on composer for read-only Recent JSONLs — type to resume in place.** Right-clicking a Recent row and picking "Continue here" wasn't discoverable, and silent-failure modes left the user with no signal. The chat box now renders unconditionally for synthetic read-only sessions with placeholder "Continue the session here  (⌘↩ to send)". Tapping in + typing does **nothing** to the session — only Cmd+↩ triggers `continueCurrentReadOnly`, which extracts the CLI session id from the JSONL header, spawns a live `--resume`/`resume` pane, waits ~600ms for tmux readiness, then posts the prompt to the new live session id. Failed extraction surfaces "Couldn't resume this session — no session id in the JSONL header." inline; user's text is preserved. Mode/Model/Effort `.onChange` handlers are guarded with `!isReadOnly` so the synthetic session never tries to respawn a tmux pane that doesn't exist.
- **Claude-Code-style mode picker — `Ask / Accept edits / Plan / Bypass`.** Replaces the standalone autopilot pill + plan toggle with a single pill on the bottom-bar left. Click → menu with `⌘⇧1-4` shortcuts. Color cues: secondary (Ask), accent (Accept edits, Plan), yellow (Bypass). Each mode maps to verified CLI flags — `--permission-mode acceptEdits` / `--permission-mode plan` / `--dangerously-skip-permissions` for Claude; `-s read-only` / `--dangerously-bypass-approvals-and-sandbox` for Codex. Bypass keeps the per-repo trust gate (existing `AutopilotState` path). Empty-state composer hides Bypass (no session to trust-gate yet). Backed by new `PermissionMode` enum (shared, lenient decoder for forward compat) + new `PermissionModeStore` (Mac-local UserDefaults, parallel to `AutopilotState`). `SessionConfigChanger.swap` reads both stores on respawn so mid-session mode changes work via the existing kill-pane + respawn-with-new-argv flow.
- **New ReasoningEffort case: `.max`.** Maps to `claude --effort max`; folds into `xhigh` for Codex (no equivalent override). Effort dial gains the 6th segment; popover-style effort picker shows "Max" as the highest tier. Lenient decoder on the enum means older Macs reading a `max` value from sessions.json get `.xhigh` instead of a Codable failure.
- **Defaults: new sessions land on Opus 4.7 1M + Max effort.** `ComposerStore.ChipDefaults.default` now seeds `claude-opus-4-7-1m` + `.max` so empty-state spawns inherit Claude Code's standard. `NewSessionMacSheet.startSession` and `continueCurrentReadOnly` thread the same defaults; Codex sessions fall back to `gpt-5.5` from the first catalog entry.
- **Terminal as a first-class review pane tab.** Added `case terminal` to `RightPaneTab` between Browser and PR. Renders the same `TerminalTabContainer` the `Cmd+T` overlay shows, but inline — chat and raw shell side-by-side without juggling a sheet. The gutter chips auto-include it via `RightPaneTab.allCases`.
- **Two-chip composer split (model+effort vs context+usage).** Previous unified `UsageStatusChip` opened a single mega-popover. Split into two independent right-side pills: `ContextUsageChip` (ring + `N%` label → context-window / session-cost / 5-hour limit / weekly rows) and `ModelEffortChip` (`Opus 4.7 (1M) · Max ⌄` → models list with `⌘1-5` shortcuts + effort list). Bottom-bar now reads `[Mode] [📎] [🎤] | [Local|Worktree|Cloud] … [◯ 12%] [Opus 4.7 · Max ⌄]`.
- **Context window math fix — was reporting 1500%, now correct.** Root cause: the chip was summing cumulative `totalInputTokens + totalOutputTokens + totalCacheCreationTokens + totalCacheReadTokens` — cache reads re-count on every turn, so a long session ballooned to hundreds of millions of tokens. New `ChatSnapshot` fields `lastInputTokens / lastOutputTokens / lastCacheCreationTokens / lastCacheReadTokens` are overwritten (not summed) on each ingest with the newest-by-timestamp usage. New `contextWindowUsedTokens` returns `last input + last cache_creation + last cache_read` — the model's actual working-memory size for the next turn. Chip now resolves the model via `session.model` (the user's explicit selection) instead of `snapshot.modelHint`. Output: e.g. `28.4k / 1.0M (3%)`.
- **Big, prominent input box with dashed border.** TextField bumped to `minHeight: 120`, `lineLimit(4...24)`, 14pt font, 12pt rounded card with dashed terra-cotta border that solidifies on drag-target.
- **"Jump to latest" floating button + scroll fix.** Auto-scroll-to-bottom was hitting a `Color.clear` sentinel inside `LazyVStack` that could be culled before realisation. Fixed by scrolling to the **last item's id** every time. New floating capsule chip appears bottom-right whenever the user has scrolled away from the tail. Bound to `⌘↓` on Mac. Same pattern in `iOSChatTranscriptView`. Auto-scroll stops yanking when `userPinnedToBottom` is false (tracked via per-row `.onAppear`/`.onDisappear`).
- **iOS Live tab — tap-the-logo provider toggle.** Claude and Codex analytics no longer stacked vertically forcing scroll. New `LiveProvider` enum (`.claude / .codex`) + `ProviderToggleHeader`: tap logo+name (or swipe horizontally 50pt threshold) to swap. Spring-animated slide transition; new content slides from the swipe direction. Page dots + `↔` icon hint at the toggle. Selection persists across launches via `@AppStorage("clawdmeter.live.selectedProvider")`. Each provider fits one screen.
- **Sidebar grouping + sorting + status filter (Mac).** Linear-style filter chip in the Sessions sidebar header. Tap the `≡` icon → menu with three sections: **Status** (All / Active / Done / Archived), **Group by** (Repo / Date / Status / Agent / None), **Sort by** (Recency / Created / Name). Icon turns filled terra-cotta when any non-default selection is active. "Reset filters" appears when customised. `Group by Date` buckets Today / Yesterday / Earlier this week / Last 30 days / Older; `Group by Status` runs Running / Planning / Paused / Degraded / Done; `Group by Agent` shows Claude / Codex (Recent JSONLs surface here via `provider`). Backed by new `SessionSidebarGrouper` (pure logic, testable from shared) + shared enums (`SessionGrouping`, `SessionSorting`, `SessionStatusFilter`) ready for iOS adoption.

### Changed

- **Composer bottom-bar layout (Claude-Code style).** Input box on top with dashed border; controls live in a single line below. Left cluster: `[Mode pill] [📎] [🎤]`. Middle: `[Local | Worktree | Cloud]` (mode-toggle), `[Agent picker]` + `[Plan toggle]` for empty state. Right cluster: Approve-plan CTA when applicable, then the two new chips. Paperclip + mic moved out of the input row.
- **Read-only session header drops the green "Read-only" capsule.** The composer's always-visible state communicates the same thing more honestly (placeholder + send-promotes-to-live). The old footer view is removed.
- **Bypass-mode confirm sheet copy.** Previously framed as "Enable autopilot?" — now framed as "Enable bypass mode?" and reads through the new mode picker's mental model.

### Tests

- 251 → 257 in `ClawdmeterShared`. Added: `PermissionMode` round-trip + lenient decoder + `displayName` / `requiresTrust`; `SessionGrouping` / `SessionSorting` / `SessionStatusFilter` case-completeness + display labels. Updated `ChipDefaults.default` test for the new `claude-opus-4-7-1m` + `.max` seed. Updated `ReasoningEffort.claudeFlagValue` + `codexConfigValue` tests for the new `.max` case (Codex folds to xhigh).

## [0.3.0 build 17] - 2026-05-18

### Added

- **Mac chat IDE — five-wave rewrite of the Sessions tab.** The Mac dashboard's Sessions tab is now a first-class chat workbench instead of a session manager. New `apple/ClawdmeterMac/Workspace/Composer/` module owns the experience.
  - **Wave A — Continuable sessions.** Recent JSONL rows get a right-click "Continue here" that parses the CLI's own `sessionId` (Claude) / `payload.id` (Codex) out of the file header via the new `JSONLSessionId` helper and spawns a fresh tmux pane with `--resume <cli-id>` / `resume <cli-id>`. The new session pins to the same JSONL so the chat history is continuous. `SessionsModel.spawnSession` gains `resumeSessionId`, `model`, `effort`, and `pinnedJSONLURL` parameters.
  - **Wave B — Tmux-as-chat first-class.** The `[Chat | Terminal]` segmented picker is gone; chat is the only mode. Raw tmux is demoted to a `Cmd+T` overlay reusing `TerminalTabContainer`. The Mac send path moves from direct `tmuxClient.pasteBytes` to the daemon's `POST /sessions/:id/send` via a new `MacComposerSender` loopback HTTP client, so audit + rate-limit + `sendKeys`/`paste-buffer` heuristics apply uniformly. Send button transforms into a stop button (`/sessions/:id/interrupt`) when the session is running.
  - **Wave C — Powerful composer.** New `ComposerStore` (in `ClawdmeterShared/Composer/`) owns text/attachments/chip state with a `SendError` enum and locked semantics (text preserved on error, attachments preserved on error, trailing-newline always appended for tmux `paste-buffer`). `ComposerInputCore` SwiftUI view binds it: paperclip wired to `.fileImporter` + `.onDrop(.fileURL/.image/...)` + `NSPasteboard` clipboard image paste. Image-paste-as-PNG, drag-drop from Finder, and file picker all route through new `AttachmentStaging` which writes to `~/Library/Application Support/Clawdmeter/attachments/<sessionId>/<uuid>.<ext>` for Claude or Codex local, OR into `<worktree>/.clawdmeter-attachments/<uuid>.<ext>` when Codex is in worktree mode (so files live inside its sandbox root). Mic still routes to `SpeechDictation`. `QLThumbnailGenerator` previews on each chip; 50MB hard cap with toast.
  - **Wave D — Centered empty state.** "Pick a session to open it here" replaced by a Codex-style centered composer with `What should we work on in <repo>?`, a repo picker chip, and full Mode/Model/Effort/Plan chips. First send spawns a session via `model.spawnSession`, waits for pane readiness, then posts the prompt as the opening user turn.
  - **Wave E — Polish.** Worktree-branch chip (`arrow.triangle.branch` + last path component) on the chat header when `session.mode == .worktree`. Tool-run groups default-collapsed so the chat reads like prose. Read-only footer rewritten to point at the new "Continue here" context-menu.
- **Slash-command palette (X4 reframe).** Typing `/` at the start of a line opens a popover that lists installed Claude Code skills walked from `~/.claude/skills/<name>/SKILL.md` (global) + `<repo>/.claude/skills/<name>/SKILL.md` (project-local) for Claude sessions, or a small built-in `/clear`/`/compact`/`/model`/`/help`/`/quit` list for Codex. Up/Down/Enter/Esc navigation; substring fuzzy filter; selecting a row inserts `/<name>` and submits. New `SkillCatalog` runs the 127-file scan + YAML frontmatter parse on a `Task.detached` background thread with a 30s TTL + dir-mtime invalidation, so the palette opens without ever stalling the main thread. The frontmatter parser lives in shared `SkillFrontmatter` so tests can exercise every branch.
- **`@`-mention picker (scope-cut).** Typing `@` opens a popover listing open sessions + agent-cited files in this session (`SourceEntry`) + recent JSONLs across sessions. Selecting inserts `@<absolute-path>` (or `@session:<uuid>` for cross-session references). Full repo-file walker deferred to follow-up.
- **Autopilot chip + respawn machinery (T12).** New chip in the composer chip row, between Mode and Model. Tapping opens a confirm sheet that warns the toggle interrupts the current turn. Repos not on the autopilot trust list show "Trust this repo for autopilot?" with the repo path and a stronger warning; the CTA flips to "Trust repo + enable autopilot" and calls `AutopilotState.trustRepo(repoKey)` before `setAutopilot`. Accepting respawns the agent CLI via `SessionConfigChanger.swap` with `--dangerously-skip-permissions` (Claude) or `--dangerously-bypass-approvals-and-sandbox` (Codex).
- **Running-session cost ticker.** Composer footer shows `~$X • Y K tokens` from `SessionChatStore.snapshot` × `Pricing.shared.cost(for:tokens:)`. Soft-red `⚠︎ weekly cap N%` badge at ≥95% for Claude sessions; Codex sessions get no cap badge (Anthropic's weekly cap doesn't map to Codex usage). `NumberFormatter` cached as a static `let` so per-keystroke recompute is free.
- **X1 cross-Apple compose-draft handoff.** New WS op `compose-draft` on the daemon's existing dispatcher. iOS new-session sheet ships an "Open on Mac" button that opens a one-shot WebSocket, posts a `ComposeDraft` envelope (text + suggested repo/agent/model/effort), awaits the daemon's 1-byte ACK, then closes. Mac dashboard listens via `NotificationCenter` and pre-fills the centered empty-state composer. Wire version bumped 3 → 4 with `composeDraftMinimum=4`; iOS gates `postComposeDraft` on `serverWireVersion >= composeDraftMinimum` and surfaces "Update Continuum on the Mac" for older Macs. Inbound text capped at 64KB; AuditLog records every draft.
- **iPhone "Mac unreachable" diagnostics.** The Sessions empty state on iOS now shows the actual stored host, the last polling error from the daemon client, and a hint when the stored host is `127.0.0.1`. A new "Re-pair…" button re-opens `PairingFlow`. iOS URL builder bracket-wraps IPv6 host literals.

### Changed

- **Pairing URL host resolution rewritten.** Old code shelled out to `/opt/homebrew/bin/tailscale` only; when the binary lived elsewhere (App Store install, Intel `/usr/local/bin`, manual install), the URL silently fell back to `127.0.0.1` and iPhones couldn't reach the Mac. New `TailscaleHost.resolve()` reads the Tailscale interface address directly via `getifaddrs(3)` (no shell-out, no path assumptions); falls back to `tailscale status --json` across three known install locations; detects `BackendState != "Running"` so the Mac surface can warn "Tailscale installed but not running" instead of letting you scan a dead URL.
- **`Pairing iPhone` popover + `Settings → Sessions` pane** now display the resolved host kind. Both surfaces show an explicit warning row when host is loopback or the Tailscale backend is down.
- **Wire version 3 → 4.** Adds `compose-draft` WS op. Older Macs reject the unknown op via `.unsupportedData` close, so iOS gates the post on `serverWireVersion` and shows an upgrade alert.
- **`AgentControlServer` WS decoder uses `.iso8601` strategy.** `ComposeDraft.createdAt` encodes as ISO-8601 string on iOS; without setting the strategy on the daemon's decoder, the whole envelope failed silently. Fixed.
- **`handleSetAutopilot` enforces per-repo trust at the wire.** Returns HTTP 403 when `req.enabled` is true and the repo is not on `AutopilotState.trustedRepoKeys`. A bearer-token-holding peer can't bypass the UI confirm sheet by hitting the endpoint directly.
- **`SessionWorkspaceView` composer area replaced.** The 86-line inline `composerArea` is gone; `ComposerInputCore` (with `ComposerStore`) takes its place. `centerEmpty` view replaced by `EmptyStateCenteredComposer`.

### Fixed

- **iPhone "Mac unreachable" at `127.0.0.1`.** Root cause of the "I paired but nothing works" symptom. See pairing-URL rewrite above.
- **Five build warnings.** `Protocol.swift` decoder's dead `??` branch; unused `session` binding in `AgentControlServer.handleChangeMode`; `AppDelegate.dashboardWindowTitle` Sendable-closure violation (marked `nonisolated`); `AgentSessionRegistry.setModel` dead `??` from double-optional promotion; `LiveActivityCoordinator` deprecated `update(using:)` on iOS 16.2+ and a dead `await` on a same-isolation property read.

### Tests

- `ClawdmeterShared`: 215 → 250. New `JSONLSessionIdTests` (10), `SkillFrontmatterTests` (10), `ComposerStoreTests` (+15 cases for state/render/error/empty-state behavior), `SessionsV2Tests` wire-version assertion bumped 3 → 4.

## [0.2.0 build 16] - 2026-05-17

### Added
- **WCAG AA across v2 surfaces (T35).** Every interactive element on
  the v2 surfaces (effort dial, model picker, controls strip, activity
  strip, diff view, PR pane, plan tracker, terminal tabs, artifacts
  pane, Watch list, Mac chips) gets explicit `accessibilityLabel` +
  value + hint. Effort dial adds `accessibilityAdjustableAction`
  (swipe up/down) and collapses into a Menu with 44pt rows once
  Dynamic Type ≥ accessibility3. Long-form labels in `accessibilityValue`
  so synthesized speech says "Extra high" instead of "xHigh".
  Decorative icons hidden from VoiceOver. Touch targets ≥44pt.
- **End-to-end wire round-trip test (T16).** New
  `SessionsV2E2ETests.swift` (19 cases) walks the full
  create-session → swap-model → effort → mode → send → approve →
  diff → PR-create → merge → preflight → A/B-pair → autopilot cycle
  through the Codable DTOs. Catches protocol drift between iOS and
  Mac without needing a real daemon.
- **RepoIdentity.normalize smoke test (T30).**
  `test_canonicalRepo_claudeWorktreeWithRealGitParent` creates a real
  `.git` directory on the parent and asserts worktree sessions bucket
  back to the canonical parent path (not "(other)"). Guards the
  analytics layer's bucketing through `repo/.claude/worktrees/<slug>`.
- **fastlane scaffolding (T27).** `apple/fastlane/{Appfile,Matchfile,Fastfile}`
  + `apple/Gemfile`. Lanes: `match_dev`, `match_release`,
  `build_mac_dmg`, `ios_testflight`, `release` (bumps build, archives
  Mac, archives iOS, uploads to TestFlight, drafts a GitHub release).
  Env-var-gated so a fresh checkout can't accidentally hit Apple's
  signing infra.
- **Phase 5 swipe quick-actions.** Leading-edge swipe on a session
  row reveals Approve (when the session is in plan mode) and Interrupt
  (when running). Trailing edge keeps Archive / Unarchive / End.
- **Sidebar by-status grouping (Phase 5 status groups).** New
  segmented picker above the Sessions list flips between repo-grouped
  (default) and status-grouped (Needs attention / In progress / Idle /
  Done / Archived). Status buckets adopted from Conductor's split.

### Changed
- **Motion specs centralized (T36).** New
  `SessionsV2Theme.disclosureToggle(reduceMotion:)` replaces ad-hoc
  `easeInOut(duration: 0.18)` calls on v2 surfaces; honors Reduce
  Motion (collapses to `.linear` at instant duration). Mac
  `SessionActivityStrip` pulses now route through the existing
  `pulseAnimation(for:reduceMotion:)` helper instead of hardcoded
  durations.
- **Interaction-state coverage filled (T37).** iOSSessionsView splits
  "no sessions yet" from "Mac unreachable" based on
  `client.lastPolledAt > 60s`; the unreachable branch ships a Retry
  CTA. iOSPRPane's `checksRollup` renders distinct glyph + color
  paths for success / failure / pending / neutral / unknown (pending
  uses the warn color instead of being lumped with failure).

### Tests
- `ClawdmeterShared`: 195 → 215 (+20 from T16 e2e + T30 smoke).

## [0.2.0 build 15] - 2026-05-17

### Added
- **Phase 8: real cost banner.** The iOS new-session sheet now shows a
  soft-warn cost estimate + projected weekly-cap consumption backed by
  real numbers from `UsageHistorySnapshot`. `LiveCostCalculator.estimate`
  reads per-repo past-7d `TokenTotals` from
  `UsageHistorySnapshot.totals(for:).past7d.byRepo`, divides by the
  count of active days in `ProviderTotals.byDay` to derive an average
  per-session, scales by the effort multiplier
  (minimal 0.4 / low 0.7 / medium 1.0 / high 1.8 / xhigh 3.0), adds
  prompt tokens estimated from goal length, and prices via
  `Pricing.shared.cost(for:tokens:)`. Returns nil for repos with no
  history so the UI can show "No history yet" instead of misleading $0.
  `wouldCap` triggers at 95% projected weekly usage; banner CTA flips
  the model to `suggestedSwap`. Daemon `GET /sessions/preflight`
  endpoint now parses every query param and returns the full response.
- **Phase 10: APNS push for the aggregate Live Activity (D9 narrow
  scope).** New "Live Activities" tab in Mac Settings hosts the
  one-time setup wizard: pick a `.p8` auth-key file, enter Team ID +
  Key ID + iOS bundle ID + environment (sandbox/production), Save
  writes the PEM to Keychain (`com.clawdmeter.apns.p8`) and deletes
  the source file from disk. `MacAPNSPusher` actor signs ES256 JWTs
  using CryptoKit (`P256.Signing.PrivateKey(pemRepresentation:)` —
  no third-party deps), caches them for 45 minutes, and POSTs
  ActivityKit content-state updates to `api.push.apple.com` /
  `api.sandbox.push.apple.com`. Handles 410 (BadDeviceToken) by
  auto-unregistering tokens. iOS `LiveActivityCoordinator` observes
  `Activity.pushTokenUpdates` (iOS 16.2+) and POSTs each new token to
  `POST /live-activities/push-token` on the paired Mac. `AppRuntime`
  subscribes to `agentSessionRegistry.$sessions`; whenever the
  Live-Activity-relevant fingerprint changes (status, planText,
  active-set), it hands a fresh `APNSContentStatePayload` to the
  pusher.

### Changed
- **iOS NewSessionSheet** wires `.task(id: preflightInputs)` to refresh
  the preflight estimate whenever repo / agent / model / effort / goal
  length changes. Form-binding edits invalidate the task naturally,
  giving free debouncing.
- **Mac Settings** gets a new "Live Activities" tab next to
  Diagnostics. The Sessions tab is unchanged.
- **AgentControlClient** gains `fetchPreflight(query:)` returning
  `PreflightResponse?` (nil on any failure path so the UI hides the
  banner gracefully). New iOS `CostBannerView` component for the soft
  warn UI.

### Tests
- ClawdmeterShared: 193 → 195 (+6 `PreflightTests`, +2 iOS-only
  `LiveActivityWireTests`).

## [0.2.0 build 14] - 2026-05-17

### Added
- **iOS multi-pane terminal tab strip.** Session detail's Terminal tab
  is now a horizontal chip strip. Tap `+` to spawn a new tmux pane via
  `POST /sessions/:id/terminals`; long-press a non-primary chip to
  delete. Each pane carries its own WebSocket; pane switches force a
  clean teardown + reconnect via SwiftUI `.id()`.
- **iOS Artifacts pane.** SessionDetail overflow menu → "Artifacts (N)"
  opens a list backed by a new `GET /sessions/:id/artifact?path=…`
  daemon endpoint. Bytes stream to a per-session tmp dir keyed by
  SHA-256 of the remote path (preserves extension, no basename
  collisions) and preview via `QLPreviewController`. Cap 50MB.
- **Settings → Diagnostics tab on Mac.** Two surfaces:
  - **Audit Log viewer (T17):** segmented picker over sends / swaps /
    autopilot streams in `~/.clawdmeter/audit/*.jsonl`, text +
    session-ID filters, tap-to-expand raw entry, "Open in Finder"
    affordance.
  - **Wire Inspector (T18):** toggleable rolling buffer of HTTP req/res
    bodies for debugging client/server skew. Off by default; capped at
    500 entries. Body capture honors the same plaintext opt-in flag as
    the audit log, so flipping the inspector on doesn't silently mirror
    prompts.
- **AuditLog event-kind discriminators.** New `recordEffortChange`,
  `recordModeChange`, `recordPlanApprove` write distinct `kind` values
  (`swap-effort` / `swap-mode` / `plan-approve`) instead of cramming
  everything into `recordSwap` with synthetic effort tags.
- **Codex JSONL parser in `ClawdmeterShared`.** Pure-value transforms
  for `response_item` payloads (`message`, `function_call`,
  `function_call_output`, `reasoning`). 34 new tests cover every tool
  name, payload variant, env-context filter, 4KB truncation, JSON
  envelope unwrap.

### Changed
- **RateLimiter + AuditLog wired into the daemon's send/swap/autopilot
  handlers (T12 + T13).** Infrastructure shipped in v2.0; v2.0.1
  closes the call sites. `POST /sessions/:id/send` rate-limited to
  1/sec; model / effort / mode / autopilot / approve-plan all
  rate-limited to 1/5sec per session. Every successful write records
  to the matching JSONL stream.
- **429 responses now carry a real `Retry-After` header** (1s for
  sends, 5s for swaps) and a structured JSON body with
  `retryAfterSeconds` as a number. Two factory variants
  (`tooManyRequestsSend` / `tooManyRequestsSwap`).
- **Wire Inspector outbound entries now carry the request method +
  path** via a per-connection map in `dispatch()`, so the Diagnostics
  viewer correlates request → response. Previously every outbound
  row showed `— —`.
- **Audit-log directory hardened.** `~/.clawdmeter/audit/` created
  with mode `0o700` and JSONL files written with `0o600`. Default
  umask exposed peer IPs + repoKeys to other local users on a
  multi-user Mac.
- **iOS Sessions sidebar collapses by repo** via `Section(isExpanded:)`
  with rotating chevron + per-repo count badge. Default expanded for
  live/active repos, collapsed for stale; manual taps persist.
- **Pairing front-and-center on Mac.** New terra-cotta "Sync with
  iPhone" button in the dashboard header opens a QR popover with a
  Copy URL CTA. On iOS, every paired-state empty screen shows the
  shared `PairingCTAButtons` (Scan QR / Paste URL) pre-targeted to the
  matching tab.
- **Plan mode works for Codex.** `codexArgv` accepts `planMode: Bool`
  and emits `-s read-only`. `handleApprovePlan` branches on
  `session.agent` and respawns with `claudeArgv` (`acceptEdits`) or
  `codexArgv` (`workspace-write`). "Claude only" copy removed from
  the New Session sheets and the iOS controls strip.
- **Codex chat renders.** `SessionChatStore.ParsedLine.from` decodes
  `response_item` lines via the new `CodexJSONLParser`. Codex's
  auto-injected `<environment_context>` user turns and
  `role: developer` wrappers filtered out. `TranscriptLoader` reuses
  the same parser, so iOS gets Codex chat for free.
- **Codex sub-agents hidden from sidebar.** `RepoIndex.readCodexSessionMeta`
  drops rollouts tagged `payload.thread_source == "subagent"`. Parent
  rollouts still surface as Recent rows.
- **Analytics totals + chart show provider logos.** New
  `ProviderBadgeImage` handles the AppKit / UIKit `.isTemplate`
  asymmetry; `AnalyticsTotalsGrid` header + custom `AnalyticsDailyChart`
  legend use it.
- **WireInspector hot-path skip when disabled.** `sendResponse` checks
  a `nonisolated(unsafe)` fast flag before constructing the detached
  Task + body retain. For the 50MB `/artifact` endpoint, this avoids
  pinning the full payload behind a Task that the actor would just
  drop inside.
- **Build number bumped 7 → 14** in `apple/project.yml`. See CLAUDE.md
  "Sessions v2.0.1 polish" section for the per-build narrative.

### Fixed
- **iOS multi-pane delete sent the wrong ID.** `deleteTerminal` posted
  the tmux pane id (`%14`) but the daemon's `handleDeleteTerminal`
  matches on `TerminalPaneRef.id` (UUID). Result: every long-press
  delete 404'd silently and the chip stuck around.
  `AgentControlClient.deleteTerminal` now takes `terminalRefId: UUID`;
  `iOSTerminalTabsView.deletePane` passes `pane.id`.
- **Path traversal via symlink in the new `/artifact` endpoint.**
  `NSString.standardizingPath` does not resolve symlinks despite a
  misleading code comment. An agent with worktree write access could
  symlink to `/etc/passwd`, `~/.ssh/id_rsa`, or
  `~/.claude/.credentials.json` and read it via the daemon. Fix:
  two-stage check — both canonical path AND symlink-resolved path
  must live under the canonical repo root. Empty / non-absolute
  `repoKey` now rejected at handler entry.
- **`handleApprovePlan` audit log fired before the respawn attempt.**
  A failed approve-plan left a misleading "plan-approve" entry in
  the swaps stream. Moved to the success branch.
- **iOS Artifacts cache claimed "fast on reopen" but re-downloaded
  every tap.** Caching is now real (`fileExists` short-circuit) AND
  the cache filename hashes the full remote path so artifacts in
  different remote dirs with the same basename don't collide.
- **iOS Rename Pane Save button was dead UI** — just dismissed without
  updating anything. Now mutates the local `panes` array so the chip
  label updates immediately. Daemon-side persistence remains a future
  endpoint; copy is honest about it.
- **`SessionChatStore` ID dance for Codex parser** — the extracted
  `CodexJSONLParser` decoupled from the Mac-side `stableId` helper via
  an `idForSuffix` closure, so the parser stays pure and unit-testable.

### Tests
- `ClawdmeterShared`: 153 → 187 (+34 new). New
  `CodexJSONLParserTests.swift` covers all four `response_item`
  payload variants, every Codex tool name in `summarizeInput`,
  `expandedDetail` non-nil branches, env-context filter, 4KB
  truncation, JSON-envelope unwrap, non-JSON args fallback,
  empty / unknown skips.
- `tools/tmux-cc-probe`: 19/19 (unchanged).
- All three platform schemes (Mac / iOS / Watch) build clean.

## [0.2.0 builds 7–13] - 2026-05-17

Documented retrospectively in `CLAUDE.md` under
"Sessions v2.0.1 polish (2026-05-17 same-day follow-up)". Highlights:

- Sessions v2 mobile-native control plane shipped (build 7).
- Codex JSONL chat rendering, pairing QR popover + iOS CTAs, sub-agent
  sidebar filter, sidebar collapsible sections, analytics provider
  logos (builds 8–13).

## [0.2.0 build 7] - 2026-05-17

Initial Sessions v2 ship. See `docs/designs/sessions-v2.md`.
