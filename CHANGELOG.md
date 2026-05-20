# Changelog

All notable changes to Clawdmeter are recorded here. Marketing version
is `MARKETING_VERSION` in `apple/project.yml`; build number is
`CURRENT_PROJECT_VERSION` in the same file (source of truth for the DMG).

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
- **`ProviderToggleHeader` shows the Gemini logo only when the paired Mac advertises wire v6+.** Falls back to Claude when an older Mac is paired; renders an `UpdateMacForGeminiCard` ("Update Clawdmeter on Mac") inside the pane when the user has the Gemini chip selected but the Mac is too old.
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

- **AskUserQuestion tray now renders in the iPhone outside-session view** (Recent JSONL rows the user taps from the sidebar). Previously v0.5.6's tray work only landed in the live `liveChatList` and the Mac `ChatThreadScroll`; `iOSChatTranscriptView` — which serves outside-Clawdmeter Recent JSONLs — used its OWN local `Item`/`toolRunCard` path and didn't pick up the new ChatItem partitioning. Wired in for parity: file-edit pairs render as `EditDiffRow` chips, AskUserQuestion pairs render as `AskUserQuestionTray`, everything else stays in the existing tool-run card.
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

- **Rename sessions** to anything memorable. New `customName: String?` field on `AgentSession` (optional, decoder-tolerant — v3 files decode cleanly with `customName = nil`). When set, replaces the default sidebar / chat-header label so a session can be "Refactor checkout flow" instead of "Clawdmeter / Claude".
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
  - **`DaemonChatStoreRegistry` now also serves `/transcript`.** New path-keyed map (`pathEntries: [URL: Entry]`) alongside the existing session-id-keyed map. `snapshotStore(forJSONLPath:)` creates / reuses long-lived `SessionChatStore`s pinned to absolute JSONL paths; the iPhone outside-Clawdmeter session view hits the same warm cache as `/chat-snapshot` instead of reparsing 500 messages on every request. Cold-miss still falls back to legacy synchronous `TranscriptLoader.load`; subsequent requests within the 5-minute idle window are instant.
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
