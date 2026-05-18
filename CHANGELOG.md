# Changelog

All notable changes to Clawdmeter are recorded here. Marketing version
is `MARKETING_VERSION` in `apple/project.yml`; build number is
`CURRENT_PROJECT_VERSION` in the same file (source of truth for the DMG).

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
- Live sessions (by `lastEventAt`) and Recent JSONLs (by `lastModified`) **interleave** under each date bucket, so a Conductor session you used 20 minutes ago sits next to a Clawdmeter-spawned one with the same timestamp. Recent JSONLs use the existing `OutsideSessionDetailView` so the composer-promote-to-live flow works from any date bucket.
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
- **X1 cross-Apple compose-draft handoff.** New WS op `compose-draft` on the daemon's existing dispatcher. iOS new-session sheet ships an "Open on Mac" button that opens a one-shot WebSocket, posts a `ComposeDraft` envelope (text + suggested repo/agent/model/effort), awaits the daemon's 1-byte ACK, then closes. Mac dashboard listens via `NotificationCenter` and pre-fills the centered empty-state composer. Wire version bumped 3 → 4 with `composeDraftMinimum=4`; iOS gates `postComposeDraft` on `serverWireVersion >= composeDraftMinimum` and surfaces "Update Clawdmeter on the Mac" for older Macs. Inbound text capped at 64KB; AuditLog records every draft.
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
