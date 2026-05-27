# TODOs

> **2026-05-23 update (Antigravity analytics autonomous run)**: PR #70's
> follow-ups landed plus two new capability surfaces. Antigravity analytics
> went from $0.026/day (broken) to real per-turn token counts pulled from
> .db `step_payload` protobuf — see `AntigravityDBUsageParser.swift`. SDK
> mode unblocked: `AntigravityLSPClient` talks gRPC to the running
> `language_server` on `localhost:54765` (CSRF auth, TLS skip for the
> self-signed cert) and `GetCascadeTrajectory` round-trips. `.pb`
> decryption attempted but format is non-standard (not Electron
> safeStorage; tried AES-GCM/CBC/CTR/ChaCha20 across multiple nonce
> placements with both Keychain keys — no scheme produced plausible
> plaintext). Deferred items below.

## Conductor parity — setup scripts (2026-05-26)

### Optional setup/run scripts for prepared worktrees
- **What**: Conductor can run repository setup and run scripts inside each
  workspace after the Git worktree exists. Clawdmeter now creates the branch,
  writes the ownership marker, and copies configured ignored files first, but
  it does not execute `conductor.json` setup/run scripts.
- **Why deferred**: the no-popup session path needs branch/file-copy parity
  without adding a new execution surface that can hang, prompt, or mutate
  dependencies unexpectedly.
- **Expected shape**: add an explicit opt-in script runner with timeout,
  streaming audit output, cancellation, and no blocking modal prompts.

## Antigravity analytics — open follow-ups (2026-05-23)

### .pb decryption — DEFERRED indefinitely
- **What**: legacy `.pb` files in `~/.gemini/antigravity/conversations/`
  are encrypted with a Gemini-specific scheme. We have the Keychain
  keys (`AntigravityKeychainKeys.geminiKeyBundle()` returns the two
  32-byte AES keys + active key ID) but the encryption envelope isn't
  documented and didn't match any common AEAD pattern.
- **Why this matters less than it sounds**: `.pb` is the OLD format.
  All new desktop sessions are `.db` (SQLite + plaintext step_payload),
  which we now extract real token counts from. `.pb` files only matter
  for archived legacy sessions, and even there the byte-÷-4 estimator
  is the fallback.
- **If you want to crank**: try Tink AEAD with various key-prefix
  schemes, or extract Google's encryption key derivation from the
  `language_server` Go binary via objdump / Ghidra. The struct tags
  for the key envelope are likely findable in the binary.

### .db proto field stability monitor
- **What**: `AntigravityDBUsageParser.matchUsageMetadata` is reverse-
  engineered. The signature it checks (`f1>0 && f6 in 1..1000 && f2/f3
  varint`) is strict enough to reject random data but loose enough that
  Google could renumber fields in a future Antigravity release.
- **Watch for**: when Antigravity 2.1+ ships, run the test suite. The
  `test_parseUsage_realConversation_producesNonZeroCounts` test will
  skip if no .db has matching UsageMetadata — that's the canary for a
  schema rewrite.
- **If it breaks**: rerun `/tmp/find-usage.py` against a fresh
  trajectory captured from `AntigravityLSPClient.getCascadeTrajectory`
  and update the field-number table in `AntigravityDBUsageParser.swift`.

### LSP-mode usage extraction (live conversations only)
- **What**: `AntigravityLSPClient.getCascadeTrajectory(conversationID:)`
  fetches the live trajectory protobuf for a conversation. The same
  proto-field walker that handles .db step_payloads finds the
  UsageMetadata sub-messages in the trajectory response.
- **Status**: LSP client + getCascadeTrajectory ship in this PR.
  Usage extraction from the trajectory response is **not wired into
  UsageHistoryLoader** — adding it is mostly a few lines that route
  the trajectory bytes through `AntigravityDBUsageParser.extractUsageMetadata`.
- **Why not in this PR**: the LSP only serves LIVE conversations; old
  archived ones return `grpc-status: 2` (NotFound). The .db file path
  already covers historical data, so LSP mode is mostly redundant
  belt-and-suspenders for the current session. Worth wiring in if we
  ever want sub-second live refresh of the active session's totals.

### Gemini-3.5-flash thinking + 3.1-pro thinking variants
- **What**: pricing.json has `gemini-3.5-flash-thinking` but no
  `gemini-3.1-pro-thinking`. If a frontier-Pro session uses extended
  thinking the model name might be `gemini-3.1-pro-thinking` and
  fall through Pricing as unknown.
- **Cleanup**: add the entry to `tools/pricing-overrides.json` with
  same rate card as `gemini-3.1-pro` (Google bills thinking tokens at
  the output rate, not a separate rate). Re-run `tools/refresh-pricing.sh`.

## Sessions v2 follow-ups (carry-over)

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

> **2026-05-19 update (v0.5.0 build 33)**: WhatsApp-smooth Sessions
> v1 SHIPPED across four phases — Phase 0a (DaemonChatStoreRegistry +
> real chat cursor), Phase 0b (SessionFileResolver + Codex respawn
> lineage), Phase 1 (iPhone + Mac chat lists → native `List`), Phase 2
> (chat-subscribe WS push + iOS HTTP-fallback ladder). The plan was
> rescoped midway via Codex outside-voice review: APNS push,
> ConversationFilter, and the cross-platform shared container all
> deferred to v0.6 / v1.1 follow-ups below.

## Audit-track follow-ups — MOSTLY RESOLVED in v0.7.7 (2026-05-20)

Five sub-items, four resolved in v0.7.7:

- **Stub-flag escape hatches** — STILL OPEN (Phase 3/4/7 work).
- **5 missing regression tests** — 4 shipped in v0.7.7 via new Mac
  XCTest target; 5th (`PastedAnthropicTokenProvider`) shipped in v0.7.4.
- **Path-validator duplication** — RESOLVED via `PathValidator` in
  ClawdmeterShared (v0.7.7).
- **Fire-once duplication** — RESOLVED via `FireOnce` in
  ClawdmeterShared (v0.7.7).
- **`handleGetArtifact` TOCTOU** — RESOLVED in v0.7.4 (O_NOFOLLOW +
  fstat-from-fd).

Original deferral text retained below for historical reference.

### Stub-flag escape hatches
- **What**: three env-flagged bypasses landed during the campaign without a
  tracker:
  - `CLAWDMETER_DAEMON_ALLOW_STUB` (`linux/Sources/ClawdmeterDaemon/main.swift`)
    — defers Phase-3 transport wiring.
  - `CLAWDMETER_PACKAGING_ALLOW_STUB` (`tools/build-linux-appimage.sh`,
    `tools/build-linux-deb.sh`) — defers Phase-4 packaging completion.
  - `CLAWDMETER_VISUAL_TEST_STRICT` (`linux/Tests/.../Visual/AssertImageEqual.swift`)
    — skips visual-baseline tests when baselines aren't committed.
- **Why**: each one is a known temporary backdoor. Without an entry here,
  they survive every search-and-destroy pass after the campaign closes.
- **Cleanup**: `grep -RE 'ALLOW_STUB|VISUAL_TEST_STRICT' linux/ tools/` at the
  end of each phase. Delete the flag + the bypass it gates.

### Missing regression tests (5 high-value gaps from `/review`)
- `isValidJsonlPath` + `isValidRepoKey` symlink-resolve (AgentControlServer)
- `TailscaleWhois.ipOnly` IPv6 round-trip (regression for the P2-Mac-4 rollback)
- `TmuxControlClient` CR/LF / control-byte rejection (requires extracting
  `validateArg` as static helper)
- `TmuxControlClient.markExited` → `start()` re-spawn lifecycle
- `PastedAnthropicTokenProvider.setToken("")` unconditional cache-clear (requires
  Keychain-deleter override in test init)

All five have ready-to-drop XCTest stubs in the `/review` artifact at
`~/.gstack/projects/CCWatch/...test-outcome-*` from 2026-05-20.

### Path-validator + fire-once duplication
- **Three near-clone path validators** (`isValidRepoKey`, `isValidJsonlPath` in
  AgentControlServer.swift; `isSafeArtifactPath` in iOSArtifactsPane.swift).
  Pull a shared `PathValidator` helper into ClawdmeterShared with composable
  predicates (rejectControlBytes, rejectTraversal, requireUnder(roots:)). Eliminates
  the copy when the next validator is added.
- **Two near-clone fire-once primitives** (`ResumeOnce` in ShellRunner.swift,
  `BGTaskCompletionGuard` in ClawdmeteriOSApp.swift). Lift a single `FireOnce` helper
  into ClawdmeterShared.

### TOCTOU between artifact path-validate and read
- `AgentControlServer.handleGetArtifact` resolves symlinks at validation time,
  then re-opens the path via `Data(contentsOf:)`. An agent with worktree-write
  can swap the file for a symlink between the check and the read. Practical
  exploit value is limited (the agent already has shell access), but the fix
  is small: open by fd with `O_NOFOLLOW` after the prefix check, or `fstat()`
  the opened fd and re-verify device+inode against the pre-validate `lstat()`.

## v0.7 — Gemini provider follow-ups (2026-05-19)

Triaged from /plan-ceo-review D13 + /plan-eng-review X3-C. The Mac UI for
Gemini shipped in v0.5.11 on top of v0.5.10's shared-package work. These
are the explicit deferrals.

### OpenRouter integration (next branch)
- **What**: 4th provider — live model catalog from `/api/v1/models`, API key
  + "use ours (coming soon)" toggle, model selector tray with featured
  models highlighted (DeepSeek V4, Kimi K2.6, Nemotron 3 Free, Gemma Free),
  composer send-path.
- **Why**: Half of the original 2026-05-19 user ask (D1 in CEO review
  deferred OpenRouter to its own design pass). OpenRouter's send-path is
  its own non-trivial design (HTTP → OR, SSE streaming parse, tool-use
  mapping, abort), so a separate feature branch is right.
- **Hook**: Replay the Antigravity-discovery pattern — OR exposes
  `/api/v1/auth/key` + `/api/v1/credits` for usage. Reuse the v6
  byProvider dict + `/usage` dual-shape envelope from v0.5.10/v0.5.11.
- **Effort**: M with CC (composer send-path is the chunk).

### Antigravity unified-quota slice (Claude/GPT-OSS)
- **What**: Surface Antigravity's own allocated Claude / GPT-OSS quotas
  as a separate "Antigravity" provider (distinct bucket from
  AnthropicSource's Max plan + CodexSource's ChatGPT plan).
- **Why**: For users paying for Antigravity, those budgets matter and
  aren't visible elsewhere — Antigravity's screenshot showed unified
  quota across Gemini + Claude + GPT-OSS.
- **Hook**: Same `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  endpoint already used by GeminiSource. Just don't filter on `gemini-*`.
- **Effort**: S with CC.

### Per-request token estimation for Gemini cost
- **What**: When Google publishes per-request token telemetry (or we
  synthesize via `gemini -o stream-json` line-level token counts), compute
  $cost for Gemini analytics rows. Removes the "Gemini = N reqs / no $"
  schema-split.
- **Why**: Gemini cells currently show "N reqs" — inconsistent with the
  $cost surface on Claude/Codex cells.
- **Hook**: `GeminiUsageParser` already emits `UsageRecord` per request;
  plumb token counts through `TokenTotals` (the `requestCount` field is
  already there; add `inputTokens`/`outputTokens` whenever discoverable).
  Pricing.swift's LiteLLM snapshot now covers `gemini-*` and `gemma-*`
  model keys (see v0.5.11 refresh-pricing.sh extension).
- **Effort**: S with CC once Google publishes the telemetry.

### iOS Gemini section in Live tab + Settings paste-token
- **What**: iOS Live tab grows a 3rd Gemini section reading the
  Mac-mirrored OAuth token (via iCloud Keychain) OR an iOS paste-token
  fallback. iOS Settings gains a "Gemini token" section after the
  Anthropic-token section.
- **Why**: iOS users currently see Claude + Codex in the Live tab; the
  Mac-side v0.5.11 update introduces a 3rd provider that iOS doesn't
  surface yet. Analytics tab already picks Gemini up automatically via
  the shared `AnalyticsTotalsGrid` refactor.
- **Hook**: `UsageModel` extends to own a `geminiModel` parallel to the
  existing `anthropicModel`. `PastedGeminiTokenProvider` (iCloud Keychain
  paste, mirrors `PastedAnthropicTokenProvider`). Wire-version gate on
  `serverWireVersion >= geminiMinimum`.
- **Effort**: M with CC.

### Watch Gemini meter + complications
- **What**: Watch app gains a 3rd Gemini meter alongside Claude + Codex;
  complications carry `geminiUsage` gated on wireVersion.
- **Hook**: `WatchUsageModel` extends. `WatchTokenBridge` carries
  per-provider tuples (token + UsageData) instead of single-provider.
- **Effort**: S with CC.

### Gemini iOS Live Activity (D5, accepted via SELECTIVE EXPANSION)
- **What**: Lock screen + Dynamic Island compact/expanded + always-on
  Live Activity for Gemini's daily quota. Push triggers on 80% / 95% /
  100% threshold crosses.
- **Hook**: Reuses `LiveActivityCoordinator` + `MacAPNSPusher` patterns.
  New `GeminiLiveActivityAttributes` struct mirrors
  `SessionLiveActivityAttributes`. Mac-side pusher gains a Gemini
  fingerprint (similar to `AppRuntime.liveActivityFingerprint`).
- **Effort**: M with CC.

### AgentSpawner.geminiArgv + Sessions runtime (E3 #2, Codex P1(4))
- **What**: `AgentSpawner` gains a Gemini case so the chat composer can
  spawn a `gemini` CLI session in tmux. Includes `GeminiJSONLParser` for
  `gemini -o stream-json` output and Composer model picker extension.
- **Hook**: Mirrors `claudeArgv` / `codexArgv` patterns. The user already
  has `gemini` CLI 0.42.0 at `/opt/homebrew/bin/gemini` with stream-json
  output format support.
- **Effort**: L with CC.

### Adversarial Google quota endpoint test fixtures (D3 declined)
- **What**: Mock cloudcode-pa with 401/403/429/500/malformed-body/
  missing-quota-field fixtures. Catches Google rotating the endpoint
  shape before users see broken gauges.
- **Why**: D3 was declined in CEO review but the eng review's Codex
  outside-voice flagged this as the most-likely failure mode. If we
  ship and Google rotates, retro-actively add the fixtures.
- **Effort**: S with CC.

### ISSUE-003 — Codex/Gemini menu bar items don't appear after toggle (deferred from /qa 2026-05-19)
- **What**: Toggling the "Menu bar Codex" or "Menu bar Gemini"
  checkbox in the dashboard header flips AppStorage but no new
  `NSStatusItem` materializes — only the Claude burst gauge stays
  visible. Reproducible when an older Clawdmeter instance is
  already running (the user's pre-existing menu-bar app), which
  hints at a multi-instance race for the AppStorage key + status
  item registration.
- **Severity**: Low (cosmetic — quota numbers still surface in the
  dashboard window; menu bar gauges are a convenience surface).
- **Why deferred**: hard to repro in isolation, needs `osascript` /
  Accessibility Inspector to introspect NSStatusBar at runtime, and
  only bites users who run multiple Clawdmeter builds simultaneously.
- **Hook**: `AppDelegate.applyVisibilityFromPrefs()` +
  `ProviderStatusController` lifecycle. Likely fix: when AppStorage
  flips on, force-rebuild the controller's status item even if the
  one we already own is in a torn-down state. Add a unit test that
  toggles the key + asserts `NSStatusBar.system.statusItem` for the
  provider exists.
- **Effort**: M with CC (~30 min once isolated).

### ISSUE-004 — AnalyticsRepoList missing "+N gem" pills despite Gemini activity (deferred from /qa 2026-05-19)
- **What**: Token-usage row shows "4 reqs · All time" for Gemini and
  the Daily-requests chart correctly renders a bar on the active
  day, but the By-repo list shows zero "+N gem" pills across any
  repo. The X3-C trunk refactor in `AnalyticsRepoList.swift` is
  wired to `geminiRequests` per row, but `geminiByRepo` ends up
  empty.
- **Root cause hypothesis**: `GeminiUsageParser` writes
  `UsageRecord(repo: <slug>, ...)` but `UsageHistoryLoader` may not
  be routing those records through the same `byRepo` aggregation as
  Claude/Codex. Could also be that records land in the right shape
  but `RepoIdentity.normalize` slugifies the `tmp/<repo>` dir name
  differently from Claude's projects-dir slug, so they bucket into a
  separate "Other" or new ghost repo.
- **Severity**: Low (top-level Gemini totals + Daily-requests chart
  still surface activity; only the per-repo attribution is missing).
- **Hook**: Trace one fixture record through `UsageHistoryLoader`
  with a print to verify (a) Gemini record reaches `byProvider[.gemini]
  .byRepo`, (b) the RepoKey matches what Claude/Codex use for the
  same source dir. Add an integration test alongside
  `UsageHistoryByProviderTests`.
- **Effort**: S with CC (~20 min).

## v0.6 / v1.1 — WhatsApp-smooth Sessions follow-ups (2026-05-19)

### APNS plan-mode push + UNNotificationAction (deferred from v0.5.0 D6)
- **What**: lock-screen "plan ready" push for Claude sessions with
  Approve / Reject `UNNotificationAction`s that POST directly to
  `/approve-plan` or `/reject-plan` without app foreground. Bearer
  token moves from `UserDefaults` to a shared App Group keychain so
  the notification-action extension can read it.
- **Why deferred (Codex D6 P1)**: reverses documented prior decision
  D15 (`apple/ClawdmeterMac/AgentControl/NotificationDispatcher.swift:9`
  literally says "D15 dropped APNS; iOS polls `GET /sessions/needs-attention`").
  `MacAPNSPusher` is built for Live Activity push *tokens*, not
  regular APS notification delivery — those are different APNS topics
  with different infrastructure. The "<1s lock-screen Approve" gate
  also can't be hit reliably on Tailscale-only transport without
  cellular wake handling. Phase 2 WS-while-foreground already covers
  the "I check on it while walking with the app open" case which is
  most of the real usage.
- **Scope when revisited**: design pass first to spec the regular-APS
  provider key wiring (separate from the Live Activity key) and the
  App Group keychain migration. Then code.

### ConversationFilter / Texting mode (deferred from v0.5.0 D6)
- **What**: project `[ChatItem] → [ConversationTurn]` filter that
  hides standalone `tool_use` / `tool_result` blocks behind a tiny
  "ran 12 tools" footnote per turn. Tapping the footnote routes to
  the Diff tab. Chat tab default flips to `.conversation`; other
  tabs keep `.full`.
- **Why deferred (Codex D6 P1)**: product change disguised as perf
  work. The current Mac + iOS chat surfaces intentionally show
  grouped tool runs inline because that's the surface where users
  verify agent behavior. Cutting visibility of tool calls reduces
  traceability. Decide whether the right product is "opt-in clean
  mode toggle in Settings" (probably) vs "Texting mode default + opt
  into terminal mode" (riskier).

### Cursor delta envelope — `appendItems` / `patchLastToolRun` (deferred from v0.5.0)
- **What**: replace Phase 2's full-snapshot-per-commit WS push with a
  delta-event envelope. New `WireChatEvent` enum:
  `.snapshot(WireChatSnapshot)` | `.appendItems(baseRevision, revision, items, totals, lastEventAt)` |
  `.patchLastToolRun(baseRevision, revision, runId, pairs)` |
  `.resyncRequired(latestRevision)`. Server emits resync on
  `baseRevision` mismatch, 256-event ring buffer overflow, or
  non-tail mutation. Client applies deltas locally.
- **Why deferred**: per Codex D6, full-snapshot push with the bounded
  500-item-per-store cap is acceptable in v1. Bandwidth savings of
  deltas don't justify the resync-state-machine bug surface until
  measurements prove fast-streaming sessions actually saturate the
  current path.
- **Trigger to revisit**: if `WireInspector` shows fast-streaming
  sessions pushing >500KB/sec in coalesced frames, or if iPhone
  scroll fps drops below 50fps on a long agent run, this becomes the
  next architectural investment.

### Materialized chat-lane projection store — Codex lateral (deferred to v2)
- **What**: Mac daemon writes a compact append-only conversation
  projection on disk beside the JSONL — pre-grouped bubbles, turn
  boundaries, chat revision ids, notification previews. Chat /
  notifications / Watch read the projection; Diff / PR / Terminal
  keep reading raw JSONL.
- **Why deferred**: 3–4 weeks of net-new on-disk artifact plus sync
  semantics. Reconsider after Phase 0 + 2 measurements; if v1 hits
  the WhatsApp gate, projection isn't needed.

### Mac repo-grouped sidebar List migration (deferred from v0.5.0 Phase 1)
- **What**: migrate the Mac dashboard sidebar at
  `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:414` from
  `ScrollView + LazyVStack` to native `List`. Same anti-pattern Phase 1
  fixed on the chat thread.
- **Why deferred**: scope reduction; chat thread is the surface the
  user actually scrolls fast. Lift if Mac dashboard history scroll
  feels off in real use.

### Shared cross-platform chat-row rendering / pinning logic (deferred from v0.5.0 Phase 1)
- **What**: extract the chat-bubble layout + pin-to-bottom
  `ScrollViewReader` plumbing into a shared component. iOS uses
  `liveChatList` in `iOSSessionsView.swift:935`; Mac uses
  `ChatThreadScroll.body` in `SessionWorkspaceView.swift:1488`. They
  share ~70% of the code today.
- **Why deferred (Codex D6 P1)**: the right shared surface is row
  rendering + scroll position logic, not the container itself.
  SwiftUI `List`'s scroll-anchor behavior diverges between iOS and
  AppKit so a single cross-platform container is the wrong boundary.
  Lift when duplication starts costing real bugs.

### `/transcript` endpoint should use `DaemonChatStoreRegistry` (or a parallel parsed cache)
- **What**: today `handleGetTranscript` (`AgentControlServer.swift:1695`)
  calls `TranscriptLoader.load(from: url, maxMessages: maxMessages)`
  on every request — no cache. iPhone outside-Clawdmeter session
  views hit this endpoint via `iOSChatTranscriptView.load()` and pay
  a fresh parse on every reload AND on every Mac restart cold-cache.
- **Symptom that surfaced this**: 2026-05-19 user-reported "session
  not loading on mobile" after Mac upgrade to v0.5.1 — was actually
  a 10–30s wait while `/transcript` reparsed a 4–30MB JSONL on the
  first request after Mac restart, then loaded fine. Phase 0a's
  registry only covers `/chat-snapshot`.
- **Fix**: extend `DaemonChatStoreRegistry` to also expose a
  by-path lookup (`snapshotStore(forJSONLPath:)`) and route
  `handleGetTranscript` through it. The store's `snapshot.items`
  is already the same `[ChatItem]` shape the transcript envelope
  serializes, plus the live JSONLTail keeps it warm for any
  subsequent edit.
- **Effort**: half a day. Want to do this before the v0.6 follow-ups
  because it makes the iPhone outside-session view feel as fast as
  the registered-session view.

### Warm `DaemonChatStoreRegistry` on daemon startup for recent JSONLs
- **What**: on `AgentControlServer.start()`, pre-warm the registry
  with the N most-recently-modified JSONLs across
  `~/.claude/projects/` and `~/.codex/sessions/`. Each store's
  reverse-tail runs in the background; by the time the user's
  iPhone hits its first `/chat-snapshot`, the snapshot is already
  populated.
- **Symptom**: same 2026-05-19 report. Phase 0a's registry helps for
  warm sessions but the very first request after a Mac restart is
  still cold.
- **Trade-off**: a few seconds of startup CPU + ~20MB transient
  memory for ~5 stores. Worth it for the perceived-perf win.
- **Effort**: 1–2 hours.

### Mac + iOS XCTest test targets — gating for 9 plan-spec'd tests
- **What**: add `apple/ClawdmeterMac/AgentControl/Tests/` and
  `apple/ClawdmeteriOS/Tests/` to `apple/project.yml` as XCTest test
  targets so the v0.5.0 plan's `DaemonChatStoreRegistryTests`,
  `LiveChatScrollPinTests`, `ChatSubscribeIntegrationTests`, and
  `iOSChatStoreWSTests` can be written.
- **Why pending**: the v0.5.0 ship landed without these because the
  project only had a `ClawdmeterShared` Swift package test target.
  `SessionFileResolverTests` (the only Phase 0/1/2 tests that fit the
  existing infrastructure) shipped. The other 9 spec'd tests need new
  scaffolding before they can land.
- **Effort**: ~half a day to add the test targets + scaffolding +
  port the 9 spec'd tests. Important enough to do before the next
  refactor of the WS / registry / chat-store code paths so changes
  there don't ship without coverage.

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

### Per-repo model + effort defaults (D7) — SHIPPED 2026-05-23 v0.26.0
- **Shipped via**: `WorkspaceStore.workspaces.json` + `AgentControlServer`
  GET /workspaces + PATCH /workspaces/:id. Storage moved from the spec'd
  `~/.clawdmeter/repo-defaults.json` to the unified
  `~/Library/Application Support/Clawdmeter/workspaces.json` (one
  `CodeWorkspaceRecord` per canonical repo root carrying
  `WorkspaceProviderDefaults`). Migration synthesizes the first record
  per repo from the newest existing session.
- **Carry-over**: surfacing the long-press "Set as default for this
  repo" affordance in the iOS new-session sheet is still TODO — the
  storage and wire surface are ready, the picker UI just needs to
  call `AgentControlClient.updateWorkspaceDefaults`.
- **Completed**: v0.26.0 (2026-05-23, build 129)

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

### Push iPhone install to v0.4.9 (build 27) when reunited
- **What**: v0.4.9 is live on origin/main + the v0.4.9-mac DMG is on
  GitHub Releases, but the iPhone (`E97117A1-DD0C-5B07-94EB-F2F5E3C652D3`,
  "Darshan Bathija") was on a different WiFi during the ship — Apple's
  CoreDevice wireless install bailed with `Browsing on the local area
  network ... has previously reported preparation errors`. The phone
  was reachable over Tailscale at the IP layer, but Xcode's wireless
  device discovery doesn't traverse Tailscale.
- **Workaround when reunited**: same WiFi as the Mac (or USB),
  unlock the phone, then run:
  ```
  cd apple
  xcodebuild -scheme "Clawdmeter (iOS)" \
    -destination 'id=E97117A1-DD0C-5B07-94EB-F2F5E3C652D3' \
    -configuration Release -allowProvisioningUpdates \
    -derivedDataPath /tmp/clawdmeter-ios-device build
  xcrun devicectl device install app \
    --device E97117A1-DD0C-5B07-94EB-F2F5E3C652D3 \
    /tmp/clawdmeter-ios-device/Build/Products/Release-iphoneos/Clawdmeter.app
  ```
- **Why this can't go over Tailscale today**:
  - **Bonjour gating.** Xcode's wireless device protocol relies on
    `_apple-mobdev2._tcp` mDNS advertisements to find the device.
    Tailscale is unicast-only; mDNS is link-local multicast. The Mac
    literally can't see the phone unless they share a broadcast
    domain. No `-destination 'id=…'` trick gets around discovery.
  - **Personal Team cert + 7-day expiry.** Even if discovery worked,
    free-tier ad-hoc distribution caps at 7 days before the embedded
    `.mobileprovision` expires. Weekly re-push isn't a system worth
    building.
  - **No TestFlight on a Personal Team.** Apple's only sanctioned
    over-the-internet install path is App Store Connect /
    TestFlight, which requires the $99/year paid Developer Program.
    The project currently signs with a Personal Team.
  - **AltStore / SideStore** sideload-over-network routes exist but
    require a third-party server in the loop; not worth the risk for
    a personal tool when paying Apple solves it cleanly.
- **The real fix when it matters**: enroll in Apple Developer Program
  ($99/year), set up an App Store Connect API key, ship every release
  via TestFlight. ~1 day of first-time setup + Apple's review for the
  first build; ~30 min per subsequent ship.

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

### v0.23.7 follow-up — Antigravity 2.0.6 smoke prompt gap

- **What**: `tools/smoke-chat-v2.sh gemini` reaches `currentTurnState=completed`
  (turn-end watchdog landed in v0.23.7) but its assistant-text criterion
  still fails for short prompts. Antigravity 2.0.6's agentapi is
  agent-only — `"say hi in one short sentence"` triggers an agentic
  loop (list_dir → view_file) instead of emitting a prose
  `[Message] sender=<agent-uuid>` block.
- **Where**: `tools/smoke-chat-v2.sh` + product decision on what the
  Gemini smoke should exercise.
- **Why**: The `[Message]` extraction path that landed in v0.23.7 is
  verified — it works against 15 production conversation DBs that DO
  contain agent prose for substantive prompts (review/summary turns).
  The current smoke prompt just never exercises that path. Three
  resolutions on the table:
  1. Change `SMOKE_PROMPT` to one that elicits a Gemini agent prose
     summary (e.g., "Read CLAUDE.md and write a 1-paragraph summary").
  2. Add an alternate agentapi RPC channel that fetches assistant
     text directly (e.g., `language_server agentapi get-conversation-messages`).
  3. Rework the smoke to validate tool activity for the Gemini
     provider instead of prose.
- **Effort**: ~30min for option 1 (recommended), ~2-3hrs for option 2,
  ~1hr for option 3.

### v0.25.0 follow-up — Sparkle auto-update migration (phase 2)

- **What**: Replace the GitHub-Releases-API checker shipped in v0.25.0
  (`apple/ClawdmeterMac/Updates/`) with Sparkle 2.x auto-update. Original
  design captured in the eng-review plan file:
  `~/.claude/plans/system-instruction-you-are-working-snoopy-quail.md`
  under "Future work: Sparkle migration".
- **Why**: The API checker requires the user to drag the new DMG to
  /Applications on each update. Sparkle gives one-click "Update &
  Restart." v0.25.0 ships the API checker because Sparkle's value-add is
  conditional on notarization (Gatekeeper re-prompts on un-notarized
  relaunch anyway), and personal-team XPC + sandbox + macOS 26 is an
  unverified combination that the v0.25.0 outside-voice review flagged
  as PRIMARY UNKNOWN with high probability of failure.
- **Prerequisites (HARD)**:
  1. Paid Apple Developer Program account ($99/yr) — required for
     Developer ID signing + notarization, AND for EdDSA key rotation if
     the maintainer key is ever compromised.
  2. Notarization integrated into `tools/build-mac-dmg.sh` (or a new
     `tools/release-mac.sh` that does build + notarize + appcast
     atomically).
  3. **PoC commit FIRST** in a separate PR: add Sparkle framework +
     Info.plist keys + entitlements + an empty coordinator, archive,
     sign, run on a clean macOS install, verify XPC services launch +
     download completes. If PoC fails, do not proceed past it.
- **Scope**: ~17 files (vendored Sparkle.framework under
  `apple/Vendor/Sparkle/`, `SparkleUpdateCoordinator.swift` replacing
  the current `UpdateCoordinator.swift`, Info.plist keys, two
  entitlements files, `tools/sparkle-setup.sh`, `tools/release-mac.sh`,
  `docs/appcast.xml`, README/CHANGELOG/SECURITY docs). New EdDSA key
  in macOS Keychain with documented backup procedure.
- **Sparkle features worth adding in phase 2**:
  `sparkle:phasedRolloutInterval` (10% day-1 → 100% day-7 for
  one-person-shop safety), `SUMinimumSystemVersion` per-item, delta
  updates (free from `generate_appcast` if prior archives persist),
  dSYMs preserved per release for crash symbolication.
- **Sequencing fix**: outside-voice surfaced a real trap in the
  original Sparkle plan where appcast push + DMG upload happen in
  separate manual steps. Phase 2 must include an atomic
  `tools/release-mac.sh` that does build → `gh release create
  --draft` → upload → verify HEAD 200 → `gh release edit --draft=false`
  → regen appcast → commit + push.
- **EdDSA key rotation gotcha**: rotation requires Developer ID re-sign.
  Personal-team builds CANNOT rotate. If the key leaks, every user is
  permanently exposed unless the maintainer migrates to Developer ID
  AND re-signs all future releases. Document this in `docs/SECURITY.md`
  BEFORE shipping Sparkle.
- **Effort**: 2-3 weeks (1 PoC PR + 1 implementation PR + manual QA
  pass + docs).

### v0.24.0 follow-up — Broadcast Chat V3 adversarial-review deferrals

Adversarial review of `darshanbathija/chat-v3` surfaced 13 findings.
Two were fixed in the same PR (mid-fan-out archive race + double-tap
button gate). The rest were classified as edge cases, multi-device
scenarios, or pre-existing system properties and deferred here.

- **WS reconnect after pick-winner hard-closes second client (HIGH)**:
  If a second device has the broadcast surface open at the moment
  pick-winner promotes a winner, `frontierGroupChildren` returns empty
  on reconnect and the WS channel closes with `.unsupportedData`. UI
  treats it as a transport error instead of "group dissolved." Fix:
  emit a final snapshot with `children: []` + a `dissolvedAt` marker
  so the client navigates away cleanly. Affects multi-device viewing
  during the brief promotion window only. **Effort**: ~1h CC.
- **Two-pass FrontierSendRequest decode silently accepts malformed
  bodies (HIGH)**: A client posting `{"text":"hi","perChildText":42}`
  fails first-pass `FrontierSendRequest` decode (perChildText wrong
  type), then succeeds against legacy `SendPromptRequest` (extra
  fields ignored) and broadcasts shared text — hiding the client bug.
  Fix: log the first-pass decode error before falling back so
  malformed clients surface. **Effort**: ~15min CC.
- **Partial broadcast-attachment upload silently degrades (HIGH)**:
  When uploading the same attachment to 3 children, if upload fails
  for one child only, that child's prompt loses the `@<path>`
  reference while the others keep it. User sees asymmetric replies
  without realizing why. Fix: detect `paths.count != stagables.count`
  per child and either retry or refuse the send with a clear error.
  Currently treated as graceful degradation. **Effort**: ~30min CC.
- **OpencodeAuthFile inter-process race during legacy migration
  (HIGH)**: Two daemons (stale + new launch) racing
  `migrateLegacyEntriesIfNeeded` can clobber each other's writes —
  one daemon's freshly-merged canonical can be overwritten by
  another's stale view. Pre-existing system property (the whole
  OpencodeAuthFile actor lacks inter-process locking). Fix: take
  `open(O_EXLOCK)` on `~/.local/share/opencode/.auth.lock` around
  the read-merge-write-delete sequence. **Effort**: ~1h CC.
- **pick-winner double-invocation returns 404 (MEDIUM)**: After the
  first /pick-winner succeeds, a second one for the same childIndex
  returns 404 (winner has been promoted out of the group). UI debounce
  in v0.24.0 prevents the common case (fast double-tap), but a second
  device or replayed request still hits this. Fix: server idempotency
  — look up the already-promoted session and return it. **Effort**:
  ~30min CC.
- **setFrontierTurnWinner fails after pick-winner (MEDIUM)**: Once
  the winner has been promoted, starring the same turn fails because
  the validation uses live-only `frontierGroupChildren`. Edge case
  (after picking continue, why would you star?). Fix: accept against
  `includeArchived: true` or persisted history. **Effort**: ~15min CC.
- **`open(match:)` race with concurrent pick-winner (MEDIUM)**:
  Time-of-check vs time-of-use — `frontierChildren(groupId:).count >= 2`
  passes, but another device's pick-winner lands before the UI
  renders. User opens broadcast surface only to see it dissolve.
  Fix: gate broadcast-target assignment on the first WS snapshot
  rather than the snapshot-time count. **Effort**: ~1h CC.
- **Empty-text guard rejects valid attachment-only sends (MEDIUM)**:
  If a user sends only attachments (empty `base` text) AND uploads
  fail for one child, that child gets `invalid_prompt` while
  siblings succeed. Fix: validate per-child text non-empty at
  composer time before issuing the send. **Effort**: ~30min CC.
- **`includeArchived: Bool = false` naming clarity (LOW)**: Default
  flip changes implicit behavior. Rename to `liveOnly: Bool = true`
  for explicit intent at call sites. **Effort**: ~15min CC.
- **`failedSlots` reasons not surfaced in broadcast header (LOW)**:
  When 2 of 3 broadcast slots succeed, the UI proceeds silently
  without showing why the third failed. Fix: warning chip in the
  broadcast header when `failedSlots.count > 0`. **Effort**: ~30min CC.
- **OpenCode canonical-stale-token edge case (LOW)**: If canonical
  has an entry with the same provider id as legacy but a malformed/
  empty `key` field, merge keeps canonical (which is broken) instead
  of preferring legacy. Fix: prefer legacy when canonical entry's
  `key` is missing or empty. **Effort**: ~15min CC.

## Not In Scope Follow-Ups (Desktop Code Tab, 2026-05-24)

- [ ] iOS/watch Code tab parity.
- [ ] Fake cloud or SSH environments.
- [ ] Cursor plan mode without reliable resumable runtime IDs.
- [ ] Full historical backfill of old transcript rows that lack raw edit payloads.
- [ ] Tree-sitter/SwiftSyntax as a Phase 3 blocker.
- [ ] Replacing `SessionWorkspaceView` with a new workbench shell.
- [ ] Shipping PR/check/run UI that is not backed by real local or daemon state.
