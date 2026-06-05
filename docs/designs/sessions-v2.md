---
status: PROMOTED
promoted_from: ~/.claude/plans/new-branch-close-vast-thunder.md
promoted_at: 2026-05-17
---
# Sessions v2 — Mobile-native control plane for Claude + Codex

The v2 release extends the v1 Sessions feature with a Conductor/dmux-grade
control surface on iPhone (and a glance-and-go control surface on Watch).
iPhone can now: start a Claude / Codex session in a worktree, pick the
model + effort + plan/code mode, swap model/effort/mode mid-session, view
diffs + PRs + multi-tab terminals, and approve plans from the Lock Screen.

## What shipped

### Wire (Phase 0)
- `Protocol.swift` schema v3: `ReasoningEffort` enum, `ModelCatalog` (5 Claude
  + 5 Codex models bundled), `HealthResponse` with `serverVersion` +
  `wireVersion`, `ChangeModel/Effort/Mode/Send/Autopilot/PickWinner` DTOs,
  `PRStatus`, `CreatePRRequest`, `GitDiffFile` + `GitDiffHunk`,
  `PreflightQuery/Response`, `WireChatSnapshot`. `AgentSession` gains
  `effort`, `abPairSessionId`, `abPairDecidedAt`. v2 decoders accept the
  new fields cleanly via `decodeIfPresent`.
- `AgentControlServer`: route table (T10) replaces the growing
  switch-on-method-and-path dispatch. 19 new endpoints registered.
- `AgentSpawner`: `--effort` flag for Claude (verified against
  `claude --help` 2.1.141), `-c model_reasoning_effort=` config override
  for Codex. `ShellRunner.locateBinary` replaces hardcoded user-specific
  paths.
- `AgentSessionRegistry`: schema v3 + atomic CAS for A/B pair winner-pick
  (E3). Single `with()` helper propagates v3 fields across every
  mutation (T41 audit).
- `AutopilotState`: per-session toggle + per-repo trust list +
  `~/.clawdmeter/autopilot-trusted-repos.json` persistence. NO re-auth (D14).

### Mac UI (Phase 1)
- `SessionsV2Theme` (Shared): single source for color tokens (accent
  `#D97757`, codex blue, surface/text), spacing scale, corner radius,
  animation tokens, pulse timing.
- `ModelPicker` + `EffortDial` in the composer header, alongside the
  existing `ModePicker` chip.
- `SessionConfigChanger`: unifies kill-pane + respawn-with-new-config
  for model / effort / plan-code / mode swap. Falls back to original
  config on resume failure (D12 rescue).
- `SessionsModel.switchModel(sessionId:to:effort:)` /
  `switchEffort(sessionId:to:)` / `switchPlanMode(sessionId:planMode:)`.

### iOS Sessions tab (Phase 2 + Phase 3 + Phase 4)
- `NewSessionSheet` rewrite: Repo → Goal (multi-line) → Agent → Model
  picker → Effort dial → Mode chip → Plan toggle → A/B pair toggle →
  sticky Start. Sends full `NewSessionRequest` with effort + abPair.
- `iOSSessionControlsStrip`: status dot + model + effort + mode chips,
  tap to swap. Plan/Code toggle (Claude only) and Esc Interrupt button.
- `SessionDetailView`: 5-tab structure (Chat / Plan / Diff / PR / Terminal).
  Activity strip + controls strip sit above the tabs.
- `iOSDiffView`: file list with `+/-` counts, per-hunk paginated view
  with green/red line highlighting. T15 LazyVStack rendering.
- `iOSPRPane`: state pill + body + checks + Merge button with D15
  confirm modal ("Merge to main? Open PR instead?").
- `iOSPlanTrackerView`: parses planText via shared
  `ChatMessageOrdering.extractStepCandidates` (12-test coverage already
  in Shared). Checkable step list + Approve & Run.
- `iOSSessionActivityStrip` (T39): per-agent pulsing indicator,
  duration, token totals, best-effort cost (Sonnet 4.6 rate fallback).
- `iOSChatStore` (T40) + `iOSChatStoreCache` (T42 LRU-2 with protected
  sessions): subscribes to WS chat-snapshot stream (Phase 0 wired stub).

### Watch (Phase 6)
- `WatchSessionSummary` (Shared): compact session shape for WCSession.
- `SessionsListView` (Watch): Crown-scrollable list of active sessions
  with status dots, agent-color labels, needs-attention badge.
- `WatchSessionDetailView`: Approve plan / Interrupt / Voice reply
  buttons.
- `WatchPlanBridge` / `WatchPlanBridgeIOS`: extended to push
  `sessionsSummaryJSON` over WCSession applicationContext; handles
  interrupt + requestVoiceReply messages.

### Phase 7: dmux features
- A/B agent pairs: `abPairSessionId` + `abPairDecidedAt` in
  `AgentSession`. Atomic CAS in registry. iOS sidebar shows pair on
  archive of one sibling.
- Autopilot toggle endpoint: `POST /sessions/:id/autopilot`. NO re-auth
  (D14). Audit-log entry per toggle.
- Hooks: **DROPPED** per D10 (RCE vector via repo-shipped scripts).

### Phase 8 cost banner (D3)
- `LiveCostCalculator` + `RateLimitChecker` (Mac): Phase 0 stubs
  returning nil. Phase 8 wires the real LiteLLM-pricing × per-repo
  historical-average calculation using the existing analytics layer.
- Soft-warn banner per D11 (no hard-block).

### Phase 9: city labels
- `CityPool` (Shared): ~200-city pool with deterministic hash → city.
- `CityNamer`: `@MainActor` singleton with persisted session→city
  assignments at
  `~/Library/Application Support/Clawdmeter/city-assignments.json`.

### Phase 10: Live Activity
- `SessionLiveActivityAttributes` (Shared, iOS-only) + content state.
- `LiveActivityCoordinator` (iOS, `@MainActor`): aggregate Live Activity
  per E6 (one activity for the whole app — not per-session). Refreshes
  from `AgentControlClient.sessions` on every refresh.
- Foreground-only updates ship in v2.0. Background APNS push (D9
  narrow scope: ActivityKit-only push tokens) lands in v2.0.1 once the
  one-time .p8 setup wizard is built.

### Phase 11: chime sounds
- `ChimeAudioPlayer` (Shared): 4 pack types (SF Muni, NYC MTA, Bell,
  Fanfare). Quiet-hours window (default 22:00→07:00). Falls back to
  AudioToolbox `AudioServicesPlaySystemSound(1336)` when the bundled
  `.caf` resources are missing.

### Daemon polish
- `AuditLog` (T13): append-only JSONL at
  `~/.clawdmeter/audit/{sends,swaps,autopilot}.jsonl`. Hash-only by
  default (`clawdmeter.audit.includePlaintext` opts in). Rotates at 1MB
  or 7 days (T31).
- `RateLimiter` (T12): 1 send/sec, 1 swap/5sec per session.

## Tests
- 153/153 in `ClawdmeterShared` (was 133 — +20 new tests covering
  ReasoningEffort, ModelCatalog, schema v3, v2-decodes-as-v3,
  ChangeModel/Effort/Mode/Send/Autopilot/PickWinner DTOs, HealthResponse,
  WireChatSnapshot, CityPool, WatchSessionSummary).
- 19/19 in `tools/tmux-cc-probe`.
- All three platform schemes (Mac / iOS / Watch) build clean.

## v2.0.1 polish (same-day, 2026-05-17)

A polish pass landed the same day as v2.0 ship. Driven by the first
hour of real use — Mac DMG re-uploaded to the `v0.2.0-mac` release at
build 13. Source of truth for what's in the DMG is
`CURRENT_PROJECT_VERSION` in `apple/project.yml`.

- **Pairing front-and-center.** `PairingQRPopoverContent` view + a
  terra-cotta "Sync with iPhone" button in the Mac dashboard header
  (`DashboardView.swift`). iOS empty states (Sessions / Analytics /
  Codex "Waiting for the Mac app") all show a shared
  `PairingCTAButtons` with Scan QR + Paste URL pre-targeted via
  `PairingFlow.initialMode`.
- **Plan mode works for Codex.** `AgentSpawner.codexArgv` accepts
  `planMode: Bool` → emits `-s read-only`. `handleApprovePlan`
  branches on `session.agent` and respawns with `claudeArgv`
  (`acceptEdits`) or `codexArgv` (`workspace-write`). Codex sessions
  in plan mode get a synthetic `planText` so existing plan-card UI
  shows the Approve & run button without code changes. "Claude only"
  copy gone from both New Session sheets + iOS controls strip.
- **Codex chat renders.** `SessionChatStore.ParsedLine.from` gained
  `case "response_item":` + `decodeCodexResponseItem` for Codex's
  shape (`message`, `function_call`, `function_call_output`,
  `reasoning`). `<environment_context>` user turns + `role: developer`
  wrappers filtered. Tool-arg summaries via `summarizeCodexInput`
  (`cmd`, `brief`, `apply_patch` variants). `TranscriptLoader` reuses
  the same parser → iOS gets it for free.
- **Codex sub-agents hidden from sidebar.** `RepoIndex.readCodexSessionMeta`
  drops rollouts where `payload.thread_source == "subagent"` or
  `payload.agent_role` is non-empty. Parent rollouts still surface.
- **iOS Sessions sidebar collapses.** `Section(isExpanded:)` (iOS 17+)
  per-repo with rotating chevron + count badge. Default expanded for
  live/active repos, collapsed for stale; `manuallyExpanded` /
  `manuallyCollapsed` overrides stick for the session.
- **Provider logos in Analytics.** New cross-platform
  `ProviderBadgeImage` handles AppKit/UIKit `.isTemplate` asymmetry.
  Used by `AnalyticsTotalsGrid` header and a custom legend in
  `AnalyticsDailyChart` (Swift Charts' auto-legend hidden).
- **Settings → Diagnostics shipped (T17 + T18).**
  `DiagnosticsSettingsView` with a segmented Audit Log / Wire
  Inspector picker. Audit-log viewer reads the JSONL files with
  text + session-ID filter + tap-to-expand-raw. Wire-inspector
  toggles `WireInspector` recording and shows a live tail polling
  every second.
- **iOS multi-pane terminal shipped (T33).** `iOSTerminalTabsView`
  wraps `iOSTerminalView` with chip-strip tabs, `+` to spawn,
  long-press to delete non-primary panes.
- **iOS Artifacts pane shipped.** Overflow menu → "Artifacts (N)"
  opens a list backed by a new `GET /sessions/:id/artifact?path=`
  daemon endpoint. Bytes download into a temp dir and preview via
  `QLPreviewController`.
- **AuditLog + RateLimiter wired into handlers (T12 + T13).**
  Infrastructure was already in place from the v2 ship; this pass
  closed the call sites in send/swap/autopilot.

## What's deferred to v2.0.2+

- **Phase 5 polish**: status groups (Backlog / In Progress / Review /
  Done), command palette, voice composer in mid-session prompt, quick
  actions on swipe.
- **Phase 10 APNS .p8 setup wizard**: Live Activity stays foreground-only
  until this lands.
- **Per-repo model + effort defaults** (D7): long-press a model →
  "Set as default for this repo." Daemon-side defaults persistence.
- **Voice-first new session** (D6): Foundation Models on-device intent
  parse for "Start a Claude Opus session in axtior to fix the redis
  timeout" as one utterance.
- **fastlane setup with Match** (T27).
- **End-to-end smoke test** that drives the full create → swap →
  approve → diff → merge cycle (T16).
- **Full WCAG AA across all 12 surfaces** (T35) — critical paths are
  covered today.
- **Real LiteLLM cost-banner data** (Phase 8): the stubs return nil; the
  full calculation using `UsageHistorySnapshot.totals(for:)` +
  `Pricing.shared.cost(for:tokens:)` lands next.

## How to ship

1. Bump VERSION to 2.0.0.
2. `./tools/build-mac-dmg.sh` produces `dist/Continuum-2.0.0-arm64.dmg`.
3. iOS: xcodebuild archive + manual TestFlight upload (fastlane in v2.0.1).
4. Watch: ships embedded in iOS bundle.

## References
- `~/.claude/plans/new-branch-close-vast-thunder.md` — the full plan with
  all 17+ CEO decisions, 9 eng decisions, 2 design decisions, 25
  main-reconciliation findings, and 42 implementation tasks.
- `~/.gstack/projects/CCWatch/ceo-plans/2026-05-16-sessions-v2.md` —
  the scope-decision audit trail.
- `docs/designs/sessions-control-plane.md` — v1 design (what this
  builds on).
- `docs/designs/sessions-IMPLEMENTATION-STATUS.md` — v1 implementation
  status (will be folded into a single sessions.md doc after v2 ships).
