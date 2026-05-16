# Changelog

All notable changes to Clawdmeter are recorded here. Marketing version
is `MARKETING_VERSION` in `apple/project.yml`; build number is
`CURRENT_PROJECT_VERSION` in the same file (source of truth for the DMG).

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
