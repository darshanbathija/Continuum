# TODOs

Deferred work from Sessions v2 (2026-05-17). Each entry is a self-contained
follow-up that didn't make the v2.0 ship but is worth picking up.

> **2026-05-17 update (build 15)**: T17 + T18 (Diagnostics), T33 (iOS
> multi-pane terminal), iOS artifacts pane, T12 + T13 (RateLimiter +
> AuditLog wired), Phase 8 cost banner (real math), and Phase 10
> APNS Live Activity push (with .p8 setup wizard) all SHIPPED in this
> session's autonomous-execution pass. Remaining deferred: Phase 5
> iOS UX polish, T35 full WCAG AA, T36 motion polish, T37 full
> interaction states, T16 e2e smoke test, T27 fastlane, plus the
> v2.1 P3 items (per-repo defaults, voice-first session).

## v2.0.1 — visible-polish follow-ups

### iOS Live Activity APNS push (D9 narrow scope) — SHIPPED 2026-05-17 build 15
- **What**: One-time setup wizard in Mac Settings → Live Activities
  ingests a `.p8` auth-key file, stores it in Keychain
  (`com.clawdmeter.apns.p8`), deletes the source. `MacAPNSPusher`
  signs ES256 JWTs via CryptoKit and POSTs ActivityKit content-state
  updates to `api.push.apple.com` / `api.sandbox.push.apple.com`.
  iOS `LiveActivityCoordinator` observes `Activity.pushTokenUpdates`
  and registers each new token with the paired Mac via the new
  `POST /live-activities/push-token` daemon endpoint. `AppRuntime`
  fingerprints session state and pushes on changes that matter.
- **Status**: SHIPPED. See
  `apple/ClawdmeterMac/AgentControl/APNSCredentialStore.swift`,
  `apple/ClawdmeterMac/AgentControl/MacAPNSPusher.swift`,
  `apple/ClawdmeterMac/LiveActivitySetupView.swift`.

### Multi-pane terminal tab strip on iOS (T33) — SHIPPED 2026-05-17
- **What**: iOSTerminalView now accepts an optional `paneId` parameter
  passed in the WS envelope. `iOSTerminalTabsView` wraps it in a
  horizontal chip strip with `+` to spawn (`POST /sessions/:id/terminals`)
  and long-press → Delete on non-primary panes.
- **Status**: SHIPPED. See `apple/ClawdmeteriOS/Workspace/iOSTerminalTabsView.swift`.

### iOS artifacts pane (Phase 4 carryover) — SHIPPED 2026-05-17
- **What**: Daemon `GET /sessions/:id/artifact?path=…` streams artifact
  bytes (path-canonicalized to prevent worktree escape, 50MB cap). iOS
  `iOSArtifactsPane` lists `chatStore.snapshot.artifactEntries`,
  downloads on tap to tmp dir, previews via `.quickLookPreview`.
- **Status**: SHIPPED. See `apple/ClawdmeteriOS/Workspace/iOSArtifactsPane.swift`.
- **Reached from**: SessionDetail overflow menu → "Artifacts (N)".

### Settings → Diagnostics (T17 + T18) — SHIPPED 2026-05-17
- **What**: New "Diagnostics" tab in Mac Settings hosting two surfaces:
  1. **Audit Log viewer** (T17): segmented picker (sends / swaps /
     autopilot), text + session-ID filter, expand-to-raw JSONL.
  2. **Wire Inspector** (T18): toggleable rolling buffer of HTTP req/res
     bodies; off by default; cap 500 entries (~5MB worst-case).
- **Status**: SHIPPED. See
  `apple/ClawdmeterMac/DiagnosticsSettingsView.swift` +
  `apple/ClawdmeterMac/AgentControl/WireInspector.swift`.

### iOS UX polish (Phase 5)
- **What**: Status groups in the sidebar (Backlog / In Progress / Review
  / Done / Archived) instead of repo-only grouping. Command palette via
  long-press on tab bar. Voice composer with `SFSpeechRecognizer` in the
  session-detail composer. Swipe-action quick-actions on session rows
  (Approve / Interrupt / Archive).
- **Why**: Conductor-grade UX polish that didn't make v2.0.
- **Effort**: ~1 day CC.

## v2.1 — capability deferrals

### Per-repo model + effort defaults (D7)
- **What**: Long-press a model in the picker → "Set as default for this
  repo." Persist per-repo `SessionDefaults` in
  `~/.clawdmeter/repo-defaults.json`. New-session sheet pre-fills from
  the repo default.
- **Why**: Daily friction reduction. Different repos want different
  models (Opus for axtior refactors, Haiku for Defx quick fixes).
- **Status**: User explicitly deferred during EXPANSION ceremony to keep
  the v2 ship bounded.
- **Effort**: ~2hr CC.

### Voice-first new session creation (D6)
- **What**: Speak a sentence like "Start a Claude Opus session in
  axtior-platform to fix the redis connection timeout" — Foundation
  Models on-device intent parse fills the NewSessionSheet's fields.
  Fall back to OpenRouter slug-gen when on-device confidence is low.
- **Why**: Defining UX. Watch crown-press → voice → session is a
  category-defining flow.
- **Status**: User skipped during expansion ceremony to keep v2 ship
  bounded. Voice dictation in the mid-session composer (Phase 5) is the
  next-best step toward this.
- **Effort**: ~1 day CC (NLP parse is the real work; Speech is easy).

### Cost-banner full calculation (Phase 8) — SHIPPED 2026-05-17 build 15
- **What**: `LiveCostCalculator.estimate` reads per-repo past-7d
  `TokenTotals` from `UsageHistorySnapshot.totals(for:).past7d.byRepo`,
  derives average per-session tokens from `ProviderTotals.byDay`
  (past-7d filter), scales by effort multiplier, adds prompt tokens
  from goal length, prices via `Pricing.shared.cost(for:tokens:)`.
  `RateLimitChecker.projectedWeeklyCap` reads live `UsageData.weeklyPct`.
  Daemon `GET /sessions/preflight` parses every query param and emits a
  full `PreflightResponse`. iOS `CostBannerView` (Components/) renders
  estimate + projected weekly + Switch CTA when `wouldCap` at 95%.
- **Status**: SHIPPED. See
  `apple/ClawdmeterMac/AgentControl/LiveCostCalculator.swift`,
  `apple/ClawdmeteriOS/Components/CostBannerView.swift`.

### Full WCAG AA across all 12 surfaces (T35)
- **What**: VoiceOver labels + Dynamic Type + Reduce Motion +
  ≥44pt touch targets on every chip / dial / banner / strip across iOS
  + Mac + Watch. Snapshot tests at AX5 Dynamic Type size.
- **Why**: DSG2 design decision was Full AA but pragmatic v2 ship covers
  critical paths first. Full coverage is the long tail.
- **Effort**: ~1 day CC across all surfaces.

### Motion specs polish (T36)
- **What**: Replace remaining ad-hoc animations with
  `SessionsV2Theme.chipSwapAnimation(reduceMotion:)` /
  `bannerSlideUp(reduceMotion:)` / `pulseAnimation(for:reduceMotion:)`.
- **Why**: Theme defines the tokens; not every callsite uses them yet.
- **Effort**: ~3hr CC.

### Interaction state coverage (T37)
- **What**: Every surface in the Pass 2 interaction-state table needs
  loading + empty + error + success + partial states. Most surfaces
  have happy-path only.
- **Effort**: ~2hr CC.

## Tooling

### fastlane setup (T27)
- **What**: Set up fastlane with `match` for shared certs/profiles.
  Add `release` lane that runs `xcodebuild archive` for iOS + Watch +
  Mac, uploads iOS to TestFlight, pushes a GitHub Release for Mac DMG.
  Coordinate version bumps via a single `VERSION` file at repo root.
- **Why**: Multi-target manual release is fragile. v2.0 shipped
  manually; future releases want automation.
- **Effort**: ~1 day CC + cert/profile setup.

### End-to-end smoke test (T16)
- **What**: New test at
  `apple/ClawdmeterMacTests/SessionsV2E2E.swift` that drives the daemon
  over loopback: create a session, swap model mid-flight, approve a
  plan, fetch the diff, create a PR (mock gh), merge.
- **Why**: 2am-Friday confidence test. Phase 0 wire is complex enough
  to deserve a happy-path integration test.
- **Effort**: ~1 day CC.

### Real-corpus DoneDetector benchmark (carried over from v1 T21)
- **What**: Snapshot ~10 real Claude sessions, anonymize, add the
  precision/recall threshold test.
- **Status**: v1 carryover. The detector + synthetic fixtures are in
  place. The CI-hermetic anonymized-corpus job is one more morning of
  work.

## Long-deferred

### Multi-Mac federation (D8 from 2026-05 plan)
- **What**: One iOS app, multiple paired Macs in the same Tailnet. The
  iOS Sessions tab shows sessions from all Macs grouped by host. Per-Mac
  pairing tokens.
- **Why**: The user has multiple Macs (workspace + laptop). Today they
  pair to one at a time.
- **Effort**: ~1 week CC.

### LaunchAgent daemon survival across Mac app quit
- **What**: The Mac daemon stops when the Clawdmeter Mac app quits.
  A LaunchAgent would keep it running headless.
- **Why**: D15 / Phase 5 from 2026-05 plan deferred this. Today the
  user keeps Clawdmeter running because it's a menu-bar app.

### Watch full 4-complication family
- **What**: `.accessoryCircular` ships in v1. The other three families
  (`.accessoryCorner`, `.accessoryRectangular`, `.accessoryInline`) are
  still unimplemented.
- **Why**: v1 D10 deferred. Different watch faces want different
  complication shapes.

## v0.3 — Mac chat-IDE follow-ups (2026-05-18)

Captured during /plan-ceo-review of the Mac chat-IDE rewrite. The rewrite
itself landed on `feat/mac-chat-ide-2026-05-18`; these are explicitly
deferred items the CEO review identified.

### Cmd+/ tmux→chat selection bridge (X3 deferral)
- **What**: When the user opens the Cmd+T raw-tmux overlay and makes a
  SwiftTerm text selection, Cmd+/ wraps the selection in a fenced code
  block and inserts it into the chat composer ready to send.
- **Why**: Closes the loop between raw tmux and chat without copy-paste
  gymnastics. Easy to backfill now that the Cmd+T overlay is in place.
- **Effort**: ~80 LOC; hooks into SwiftTerm's selection delegate +
  posts to ComposerStore via NotificationCenter.

### SharedComposerKit cross-platform refactor
- **What**: Lift `ComposerInputCore` (currently Mac-only at
  `apple/ClawdmeterMac/Workspace/Composer/`) into the shared package so
  iOS can reuse it instead of maintaining a parallel composer.
- **Why**: iOS already has a richer composer than Mac shipped in this
  PR. Converging the two prevents drift and prepares for the
  cross-Apple compose-draft handoff to feel like the same control.
- **Effort**: ~1 day; requires NSImage/UIImage + NSPasteboard/UIPasteboard
  + onDrop platform splits.

### MentionPicker full repo-file walker
- **What**: The shipped MentionPicker is scope-cut to open sessions +
  agent-cited SourceEntries + recent JSONLs (Codex P1 finding —
  `RepoIndex` doesn't index repo files). Build a proper repo-file walker
  with .gitignore-aware traversal so `@` lists every file in the repo.
- **Why**: Conductor/Codex/Claude Desktop all do full file mention; ours
  is the smaller surface today. The picker's empty state already names
  this limitation.
- **Effort**: ~3hr — add `RepoFileIndex` actor with mtime-cached
  enumeration + .gitignore parsing.

### Per-repo composer chip memory (D7 follow-up)
- **What**: Persist last-used agent/model/effort/mode per repo so
  `EmptyStateCenteredComposer` and `BoundComposerView` pre-fill chips
  with the user's per-repo preference instead of generic defaults.
- **Why**: 4A CEO-review decision picked "reset to repo defaults" rather
  than "remember per repo" to keep this PR bounded; D7 in CLAUDE.md
  TODOS predates this and asks for the same thing.
- **Effort**: ~2hr CC. Store as `~/.clawdmeter/repo-defaults.json`.

### CLI session-id resume bug in SessionConfigChanger
- **What**: `SessionConfigChanger.swap(sessionId:)` passes
  `sessionId.uuidString` (the Clawdmeter UUID) as `--resume <id>` /
  `resume <id>` to the agent CLI. The CLI expects its OWN session id
  (Claude: JSONL `sessionId` field; Codex: rollout `payload.id`), so
  every model/effort/mode swap silently starts a *fresh* session.
  Caught by Codex outside-voice during the chat-IDE plan review.
- **Why**: This is a pre-existing bug that this PR didn't introduce —
  but it's now glaringly visible because the new autopilot chip uses
  the same code path to respawn. Wave A's "Continue here" path fixes
  it for outside JSONL rows; this is fixing the same bug for in-Mac
  swap paths.
- **Effort**: ~1hr CC. Wire `JSONLSessionId.extract(...)` into the
  swap path using the chat store's pinned JSONL URL.
