# TODOs

Deferred work from Sessions v2 (2026-05-17). Each entry is a self-contained
follow-up that didn't make the v2.0 ship but is worth picking up.

## v2.0.1 — visible-polish follow-ups

### iOS Live Activity APNS push (D9 narrow scope)
- **What**: One-time setup wizard in Mac Settings → Live Activities
  that takes a `.p8` APNS auth-key file, stores it in macOS Keychain
  (`com.clawdmeter.apns.p8`), deletes the source file. Mac daemon signs
  JWTs and pushes ActivityKit content-state updates to `api.push.apple.com`
  whenever a session's status changes.
- **Why**: Without APNS push, the aggregate Live Activity only refreshes
  when the iOS app is foregrounded OR when BGAppRefreshTask fires
  (every 15-30 min). Background staleness defeats the wedge.
- **Status**: `SessionLiveActivityAttributes` + `LiveActivityCoordinator`
  shipped in v2.0. iOS app starts/updates activities in-process.
  Push tokens require D9 narrow-scope APNS wiring.
- **Context**: D9 decision in CEO review reopened the D15 APNS rejection
  narrowly — ActivityKit push tokens are per-activity, ephemeral, scoped
  (can't send arbitrary notifications). Keychain custody is the
  load-bearing mitigation.
- **Effort**: ~6hr CC.

### Multi-pane terminal tab strip on iOS (T33)
- **What**: Wrap `iOSTerminalView` in a `TabView` so the user can spawn
  additional tmux panes per session via the `POST /sessions/:id/terminals`
  endpoint (already wired). Long-press a tab → Rename / Delete.
- **Why**: The Mac has multi-pane via `TerminalTabContainer`. iOS
  currently shows a single pane only.
- **Status**: Daemon side wired. iOS UI single-pane today.
- **Effort**: ~6hr CC.

### iOS artifacts pane (Phase 4 carryover)
- **What**: Port `apple/ClawdmeterMac/Workspace/ArtifactsPane.swift` to
  iOS — thumbnail grid + `QLPreviewController` for PDFs/images/etc.
  Wire to a new `GET /sessions/:id/artifacts` endpoint.
- **Why**: Phase 4 plan called for it; v2.0 ships diff/PR/plan but not
  artifacts.
- **Effort**: ~4hr CC.

### Settings → Diagnostics (T17 + T18)
- **What**: Two new panels in Mac Settings:
  1. **Session Event Timeline**: JSONL viewer reading from
     `~/.clawdmeter/audit/*.jsonl`, filterable by session id + event kind.
     Mirrors dmux's logs popup pattern.
  2. **Wire Inspector**: toggle to log all HTTP/WS payloads to a rolling
     buffer; off by default. Helpful when debugging client/server skew.
- **Why**: Audit log is being written in v2.0; users need a viewer.
- **Status**: `AuditLog` (write) + `appendix files` exist. Reader UI pending.
- **Effort**: ~6hr CC (timeline) + ~4hr CC (wire inspector).

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

### Cost-banner full calculation (Phase 8)
- **What**: Wire `LiveCostCalculator` to read per-repo per-model
  historical `TokenTotals` from `UsageHistorySnapshot.totals(for: .anthropic)`,
  apply effort multiplier, compute estimated USD via
  `Pricing.shared.cost(for: model, tokens: scaled)`. Wire
  `RateLimitChecker` to read live `UsageData` and project the weekly
  cap. Show soft-warn banner in iOS new-session sheet.
- **Why**: D3 expansion accepted in CEO review. v2.0 ships the wire
  shape + stub; this lands the real math.
- **Effort**: ~4hr CC.

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
