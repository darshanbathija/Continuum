# TODO — P2 Backlog (Consolidated Audit, 2026-06-06)

> P2 = material correctness / hardening / edge-case / latent issues with bounded blast radius.
> These are the deferred (non-P0/P1) items from the consolidated bug audit. The project's larger
> running engineering list is **`TODOS.md`**; this file is the focused P2 fix backlog the user asked for.
> Full evidence + fix sketches: `.context/p0-p2-bug-audit-v2.md` (v2), `.context/p0-p2-bug-audit.md` (prior),
> `.context/CONSOLIDATED-FIX-PLAN.md` (P0/P1 plan). Verified net-new external P2s carry their EXT id.

**Totals:** 73 (v2 audit) + 14 (prior audit) + 18 (net-new, verified from external audits) = **105** P2 items.

---

## A. From the v2 granular audit (73)

- [ ] **P2-1** `RelayChunkReassembler` has no global memory bound across concurrent messages — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Relay/RelayMux.swift:181-208`
- [ ] **P2-2** `RelayPlaintext.encodeCanonicalJSON` comment claims it validates `data` is JSON, but it does not — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Relay/RelayFrameCodec.swift:154-173`
- [ ] **P2-3** `RelayMuxClient.handleInbound` `.error` JSON parse failure is indistinguishable from a real error and loses the cause — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Relay/RelayMuxClient.swift:126-131`
- [ ] **P2-4** `RelayPairingStore.loadRecord` migration drops the legacy on-disk secrets even when the Keychain write fails — `apple/ClawdmeterShared/Sources/ClawdmeterShared/RelayPairing/RelayPairingStore.swift:92-101`
- [ ] **P2-5** First-peer bootstrap can race two connects and reset audit counts (connect-time TOCTOU) — `infra/relay/src/durable-object.ts:126-179`
- [ ] **P2-6** Attacker-controlled `ttlSeconds` is unbounded, defeating the absolute-expiry guard — `infra/relay/src/auth.ts:140-149`
- [ ] **P2-7** `framesReceived` counter is incremented but never persisted or read (dead audit field) — `infra/relay/src/durable-object.ts:66-67, 198-204, 268, 297-304`
- [ ] **P2-8** Per-device rate limit is structurally bypassable by an authenticated sender, allowing unbounded KV growth and APNS forwarding — `infra/apns-gateway/src/index.ts:122-185`
- [ ] **P2-9** Audit KV entries can be overwritten/suppressed via attacker-controlled `x-request-id` — `infra/apns-gateway/src/index.ts:422`
- [ ] **P2-10** First-to-bind device-token poisoning lets any authenticated peer lock out the legitimate owner — `infra/apns-gateway/src/index.ts:104-151`
- [ ] **P2-11** Opt-out signature has no expiry/nonce and the endpoint skips kill-switch + rate-limit — `infra/apns-gateway/src/index.ts:329-387`
- [ ] **P2-12** Doc/code mismatch on opt-out signature message will steer a future fix into breaking auth — `infra/apns-gateway/src/schema.ts:36-42`
- [ ] **P2-13** `APNSPushDeviceTokenStore` never prunes stale tokens despite documenting a 30-day TTL — `apple/ClawdmeterMac/AgentControl/APNSPushDeviceTokenStore.swift:42-52, 96-110`
- [ ] **P2-14** `MacAPNSPusher.pruneStale()` is never called — Live Activity token registry can grow unbounded — `apple/ClawdmeterMac/AgentControl/MacAPNSPusher.swift:38-48, 71-81`
- [ ] **P2-15** APNS JWT cache key omits the `.p8` body — stale token served for up to 45 min after same-keyId key rotation — `apple/ClawdmeterMac/AgentControl/MacAPNSPusher.swift:165-194`
- [ ] **P2-16** `compose-draft` WS cap counts graphemes, not bytes, and silently no-ops on a nil draft — `apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:630-667`
- [ ] **P2-17** `shouldEnterDegraded()` reuses last-success timestamp, flipping to degraded on the first drop after a long healthy session — `apple/ClawdmeterMac/AgentControl/RelayClient.swift:410`
- [ ] **P2-18** Torn-down `pumpLoop` / `SnapshotCoalescer` can deliver a stale frame or spurious `subEnd` to a re-opened opId — `apple/ClawdmeterMac/AgentControl/RelaySubscriptionBridge.swift:101-169`
- [ ] **P2-19** archive() leaves the surviving A/B sibling pointing at an archived session (asymmetric link) — `apple/ClawdmeterMac/AgentControl/AgentSessionRegistry.swift:613-624`
- [ ] **P2-20** Replayed `.failed` receipts lose their original HTTP status and error message and get a synthetic 500, masking the original 4xx — `apple/ClawdmeterMac/AgentControl/MobileCommandOutbox.swift:255-262`
- [ ] **P2-21** iOS outbox `dispatch` treats undecodable persisted payloads as retryable, not terminal — a malformed envelope burns the full retry schedule before parking — `apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift:300-364`
- [ ] **P2-22** `command()` timeout tears down the entire shared tmux control client, collapsing every live pane — `apple/ClawdmeterMac/AgentControl/TmuxControlClient.swift:667-679`
- [ ] **P2-23** Control-mode line buffer is unbounded — a newline-free `%output` burst grows memory without limit — `apple/ClawdmeterMac/AgentControl/ControlModeParser.swift:37-63`
- [ ] **P2-24** `HarnessProcessReaper.liveComm` blocks the main actor with a synchronous `ps` + `waitUntilExit()` per orphan at startup — `apple/ClawdmeterMac/AgentControl/HarnessProcessReaper.swift:54-85,117-130`
- [ ] **P2-25** CodexAppServerDriver never clears currentTurnId after a turn completes — `apple/ClawdmeterMac/AgentControl/CodexAppServerDriver.swift:42`
- [ ] **P2-26** CodexAppServerDriver leaks pendingApprovals entries; never cleared on close() — `apple/ClawdmeterMac/AgentControl/CodexAppServerDriver.swift:45`
- [ ] **P2-27** Grok headless driver can drop the final partial NDJSON line via an unordered finishTurn race at EOF — `apple/ClawdmeterMac/AgentControl/GrokHeadlessDriver.swift:91-102`
- [ ] **P2-28** Grok per-turn prompt temp files leak on close()/cancel() and on back-to-back prompts — `apple/ClawdmeterMac/AgentControl/GrokHeadlessDriver.swift:60-74`
- [ ] **P2-29** LanguageServerClient port heuristic mislabels HTTP vs HTTPS when the LS holds more than two listening ports — `apple/ClawdmeterMac/AgentControl/LanguageServerClient.swift:139-156`
- [ ] **P2-30** OpencodeAuthFile cross-process read-modify-write can clobber a concurrently-written provider entry — `apple/ClawdmeterMac/AgentControl/OpencodeAuthFile.swift:192-219`
- [ ] **P2-31** OpencodeSSEAdapter legacy parser drops text + trailing tool parts on mixed-content message.added events — `apple/ClawdmeterMac/AgentControl/OpencodeSSEAdapter.swift:351-427`
- [ ] **P2-32** JSONL rotation re-opens at a stale byte offset and can skip transcript content — `apple/ClawdmeterMac/AgentControl/JSONLTail.swift:97-110,151-161`
- [ ] **P2-33** Rollover-during-`acquire` of an sdkOnly store loses the subscriber refcount — `apple/ClawdmeterMac/AgentControl/DaemonChatStoreRegistry.swift:109-126,213-223`
- [ ] **P2-34** SDK chat transcript mirror is append-only and fully re-read on every store re-create — `apple/ClawdmeterMac/AgentControl/SDKChatTranscriptMirror.swift:63-124`
- [ ] **P2-35** `DoneDetector.isSuccessfulGitCommit` over-broad substring match would mis-fire if it were reachable — `apple/ClawdmeterMac/AgentControl/DoneDetector.swift:150-165`
- [ ] **P2-36** Frontier aggregate reports archived loser children as live after pick-winner — `apple/ClawdmeterMac/AgentControl/FrontierWebSocketChannel.swift:81-102, 146-182`
- [ ] **P2-37** OrchestrationEventStore replay aborts entirely on an unknown command kind, contradicting its forward-compat contract — `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/OrchestrationEventStore.swift:954-960`
- [ ] **P2-38** Initial chat push races the first debounced push, so shell/detail frame ordering is not actually guaranteed — `apple/ClawdmeterMac/AgentControl/ChatStreamWebSocketChannel.swift:104-130, 142-208`
- [ ] **P2-39** `branchTitle` git-dir traversal follows a repo-controlled `gitdir:` pointer outside the repo when reading HEAD — `apple/ClawdmeterMac/AgentControl/RepoIndex.swift:608-638`
- [ ] **P2-40** Autopilot enabled-state is in-memory only; a daemon restart strands a running bypass CLI as un-expirable and mislabeled — `apple/ClawdmeterMac/AgentControl/AutopilotState.swift:15-54`
- [ ] **P2-41** `ChatProviderProbe.invalidate()` / `setAuthOverride` don't cancel the in-flight probe, so a stale pre-invalidation result can overwrite the cache — `apple/ClawdmeterMac/AgentControl/ChatProviderProbe.swift:64-95`
- [ ] **P2-42** `PlanProgressTracker` fallback comment inverts the actual behavior, steering a future fix wrong — `apple/ClawdmeterMac/AgentControl/PlanProgressTracker.swift:90-99`
- [ ] **P2-43** `PermissionModeStore.acceptEditsSessionIds` is persisted to UserDefaults and never pruned — unbounded growth — `apple/ClawdmeterMac/AgentControl/PermissionModeStore.swift:40-50`
- [ ] **P2-44** `searchChatHistory` percent-encodes the query with `.urlQueryAllowed`, leaving `&`/`=` unescaped — query-param injection / wrong results — `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AgentControlClient.swift:1674-1675`
- [ ] **P2-45** `OrchestrationEventStore` replay aborts the entire log when a single persisted `ProviderRuntimeEvent` has an unknown `Payload` case — `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/ProviderRuntimeEvent.swift:114-164`
- [ ] **P2-46** `Decimal(Double)` conversion of OpenCode embedded cost reintroduces binary-float drift the Decimal design exists to avoid — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/OpencodeUsageParser.swift:184`
- [ ] **P2-47** `tokensByModel(in:)` window has an upper `day <= today` bound the dollar-chart windows lack, so future-dated records diverge between the two surfaces — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistorySnapshot.swift:102`
- [ ] **P2-48** Antigravity per-file cache keys on the conversation file's mtime/size but the legacy `.pb` token estimate comes from the separate brain dir, risking stale cached tokens — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryLoader.swift:748-757`
- [x] **P2-49** AutoReviver sets `lastFireAt` before the no-token guard, poisoning the cool-off on a no-op attempt — completed in v0.31.4 by disabling prompt-based auto-revive until a non-consuming keepalive exists.
- [ ] **P2-50** `ComposerStore.attach` 50MB cap is bypassed when the caller can't read the file size (`?? 0`) — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Composer/ComposerStore.swift:118-131`
- [ ] **P2-51** `ChatV2Store.toggleVendor` comment claims "no upper cap" but silently caps broadcast selection at 3 — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Chat/ChatV2Store.swift:264-275`
- [ ] **P2-52** `ComposerSendController.sendCustomOptimistic` silently loses a failed message if the user starts typing during the in-flight window — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Composer/ComposerSendController.swift:155-167`
- [ ] **P2-53** applyVisibilityFromPrefs references a non-existent opencode controller — `apple/ClawdmeterMac/AppDelegate.swift:42, 288-305`
- [ ] **P2-54** Popover open force-polls Claude/Codex/Gemini but not Cursor, despite a live Cursor tab — `apple/ClawdmeterMac/AppDelegate.swift:504-508`
- [ ] **P2-55** Per-session checkpoints grow unbounded in WorkbenchState and are persisted on every mutation — `apple/ClawdmeterMac/Workspace/WorkbenchState.swift:421-424`
- [ ] **P2-56** `attachImage` paste/drop path silently swallows write failures — `apple/ClawdmeterMac/Workspace/Composer/ComposerInputCore.swift:916-927`
- [ ] **P2-57** LRU cache eviction undercounts when protected sessions aren't resident — `apple/ClawdmeteriOS/AgentControl/iOSChatStore.swift:585-593`
- [ ] **P2-58** Dead `registerBackgroundTask()` would crash via duplicate BGTask identifier registration — `apple/ClawdmeteriOS/iOSNotificationManager.swift:63-76`
- [ ] **P2-59** "Forget Mac pairing" leaves the relay pairing record and warm relay socket intact — `apple/ClawdmeteriOS/SettingsView.swift:241-248`
- [ ] **P2-60** Two singletons fight over the single `WCSession.default.delegate` on watchOS; current correctness depends on implicit init ordering — `apple/ClawdmeterWatch/WatchPlanBridge.swift:42-48`
- [ ] **P2-61** Watch plan goal can linger after a session swap because `apply()` never clears `latestGoal` when the key is absent — `apple/ClawdmeterWatch/WatchPlanBridge.swift:68-79`
- [ ] **P2-62** iOS→Watch context push bypasses the built-and-tested `SendGate` diff-guard and pushes unconditionally — `apple/ClawdmeteriOS/WatchPlanBridgeIOS.swift:54-91`
- [ ] **P2-63** Reauth state is masked by a stale `usage` on the watch — `apple/ClawdmeterWatch/WatchUsageModel.swift:95-112`
- [ ] **P2-64** Runtime-dir parent under world-writable `/tmp` is never ownership-validated; symlink redirection survives the leaf-only check — `linux/Sources/ClawdmeterLinux/Storage/LinuxConfigPaths.swift:82-105`
- [ ] **P2-65** Bearer-token file fallback is written through the process-umask temp file during the atomic-rename window (TOCTOU on 0600) — `linux/Sources/ClawdmeterLinux/Storage/PairingTokenStore+SecretService.swift:92-107`
- [ ] **P2-66** IPv6 Tailscale-ULA allowlist uses textual prefix match, not byte-range — diverges from the byte-accurate /48 the file claims parity with — `linux/Sources/ClawdmeterLinux/Transport/HummingbirdPeerFilter.swift:55-57`
- [ ] **P2-67** `VisualTestHelper.pixelDiffPercent` indexes `Data` by zero-based offset; would crash on a sliced `Data` — `linux/Tests/ClawdmeterLinuxTests/Visual/AssertImageEqual.swift:83-94`
- [ ] **P2-68** Linux peer filter omits the Tailscale-whois identity check the Mac filter requires for non-loopback peers — `linux/Sources/ClawdmeterLinux/Transport/HummingbirdPeerFilter.swift:30-60`
- [ ] **P2-69** Empty-`Data` gauge PNG is written and reported as success on Linux (invalid icon file handed to AppIndicator) — `linux/Sources/ClawdmeterLinux/Tray/CairoGaugeRenderer.swift:43-76`
- [ ] **P2-70** No CI builds or tests the Mac daemon, iOS, or watchOS apps — the core product ships untested — `.github/workflows/`
- [ ] **P2-71** VERSION file is not the single source of truth it claims to be — Mac DMG and Linux artifacts can drift — `VERSION:1`
- [ ] **P2-72** build-mac-dmg.sh version fallback yields a literal `$(MARKETING_VERSION)` in the DMG name, not 0.1.0 — `tools/build-mac-dmg.sh:68-78`
- [ ] **P2-73** Linux release-upload runs only the linux-pkg gate, not the ClawdmeterShared Swift tests, before publishing artifacts — `.github/workflows/linux.yml:84-92,156-210`

## B. From the prior audit (14) — release / identity / Linux / infra

- [ ] **P2-001** Worktree provisioning can hang forever in raw git helper
- [ ] **P2-002** Per-session rate-limit maps are never released
- [ ] **P2-003** Relay `/stats` endpoint is unauthenticated and leaks session metadata
- [ ] **P2-004** Relay accepts bearer tokens in URLs and echoes bearer subprotocols
- [ ] **P2-005** APNS opt-out signatures are timeless and not bound to the current token owner
- [ ] **P2-006** APNS audit KV entries can be overwritten via client-controlled `x-request-id`
- [ ] **P2-007** Mac APNS device-token store persists raw tokens in JSON
- [ ] **P2-008** APNS `statusChanged` notifications default on despite being documented opt-in
- [ ] **P2-009** iOS relay requests hang until timeout when the socket drops
- [ ] **P2-010** Legacy LAN pairing token is stored in plain UserDefaults
- [ ] **P2-011** Settings "Files to copy" rows synchronously read repo files during SwiftUI body build
- [ ] **P2-012** Linux config path hardening accepts non-directories and group/world-readable secret dirs
- [ ] **P2-013** Linux tray support detection and dialog cannot produce correct runtime state
- [ ] **P2-014** Codex SDK sidecar validates `workingDirectory` but passes `additionalDirectories` unchecked

## C. Net-new, verified from external AI audits (18)

- [ ] **EXT AN-3** Dedup-collision reparse hard-codes ClaudeUsageParser — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryLoader.swift:841-849` _(partial/narrower than claimed)_
  - Real hard-coding, but the branch is only reachable when `dedupKeys` collide: Codex records carry `dedupKey: nil` (never collide), OpenCode runs through a separate `accumulate` path (lines 402-438, nev…
- [ ] **EXT AN-4** OpenCode events not repo-normalized — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/OpencodeUsageParser.swift:202`
  - OpenCode cwds bypass git-root canonicalization, so worktree/Conductor-branch dirs of one repo split into separate by-repo buckets (Claude/Codex normalize, OpenCode does not)
- [ ] **EXT AN-5** Antigravity repo path not normalized — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/AntigravityUsageParser.swift:153-159` _(partial/narrower than claimed)_
  - The missing-normalize is real, but the claimed symptom is backwards: non-normalized paths never collapse to "Other" (only `normalize` produces `RepoKey.other` at RepoIdentity.swift:120)
- [ ] **EXT AN-6** Antigravity estimated/fabricated token counts get priced — `AntigravityUsageParser.swift:134-147`
  - Confirmed but inherent and intended for the encrypted `.pb` / no-match `.db` fallback — these are surfaced as provisional (`~`) per the file header; the cost is a best-effort estimate, not a correctne…
- [ ] **EXT AN-7** Antigravity drops toolUseTokens — `AntigravityDBUsageParser.swift:56,132,141`
  - Real under-count: tool-use prompt tokens are extracted then discarded
- [ ] **EXT AN-9** Pricing prefix matching over-charges models — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/Pricing.swift:235-272` _(partial/narrower than claimed)_
  - The longest-prefix-first ordering means it returns the most-specific matching key, not an arbitrary higher-priced one, so the worst case is a never-seen custom model whose name shares a leading prefix…
- [ ] **EXT AN-10** Loader ignores injected Pricing instance — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryLoader.swift:83`
  - The injected `pricing` parameter is dead — tests passing a custom Pricing instance silently run against prod `Pricing.shared`; impact is test-fidelity only (prod always passes `.shared`)
- [ ] **EXT AN-11** OpenCode default DB path uses NSHomeDirectory() — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/OpencodeUsageParser.swift:57` _(partial/narrower than claimed)_
  - Real inconsistency, but the auditor's "zero OpenCode history in sandboxed Release" premise is currently false — `ClawdmeterMac-Release.entitlements:41-42` ships with `app-sandbox = false` (v0.29.35), …
- [ ] **EXT AN-15** PricingUpdater runtime fetch has no TLS pinning / signature validation — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/PricingUpdater.swift:46,69-116` _(partial/narrower than claimed)_
  - True that there's no integrity check beyond HTTPS, but the realistic threat is low — transport is TLS (a passive MITM can't tamper; an active one must break the GitHub cert), the blast radius is only …
- [ ] **EXT UI-2** Read-only → live session promotion corrupts pending send state — `apple/ClawdmeterMac/Workspace/CenterThread.swift:900-925,1093-1122` _(partial/narrower than claimed)_
  - Real but much narrower than "frozen/misrouted sends" — the draft IS recovered into the live session via `queueFirstSendRecovery`/`applyPendingFirstSendRecovery`; only the inline failed-pending bubble …
- [ ] **EXT UI-4** Mac Chat V2 composer bypasses the outbox — `apple/ClawdmeterMac/Workspace/ChatV2/MacChatV2View.swift:1800,1916` _(partial/narrower than claimed)_
  - "Bypasses rate-limit/audit/writes directly to connection" is wrong (it goes through the daemon HTTP endpoint with both); only the no-idempotency-key part is real, so a manual retry of a perceived-fail…
- [ ] **EXT UI-5** Mac composer sends lack idempotency keys — `apple/ClawdmeterMac/Workspace/Composer/MacComposerSender.swift:41-47`
  - Real but low-impact — daemon dedup (`tryReplayIdempotent`) is inert without a key, so a user manual-retry after an ambiguous failure can re-send; loopback makes ambiguous failures rare
- [ ] **EXT R-2** Relay-default removes the Tailscale fallback in TransportResolver — `apple/ClawdmeterShared/Sources/ClawdmeterShared/Relay/TransportResolver.swift:34-37` _(partial/narrower than claimed)_
  - The resolver's logic is exactly as the auditor describes (never `.tailscaleDirect` when relay is on), but it's unwired dead code, so it isn't the live mechanism that strips the Tailscale fallback — th…
- [ ] **EXT D-1** Payload-hash idempotency gate is bypassable — `apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:8059-8087` _(partial/narrower than claimed)_
  - Real but the mechanism differs from the claim — handlers DO *record* the hash (via `respondWithSession`/`sendCommandResponse`); they just never *pass* it to the replay check, so a same-key/different-b…
- [ ] **EXT D-4** TailscaleWhois caches FAILURES for 60s — `apple/ClawdmeterMac/AgentControl/TailscaleWhois.swift:50-52`
  - Real availability defect — a transient `tailscale whois` error (e.g
- [ ] **EXT D-6** Pairing token not bound to Tailscale node identity — `apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:136-139`
  - Real defense-in-depth gap (token isn't bound to a node/user identity), but exploiting it needs token theft AND tailnet membership, and tailnets are ACL-controlled — P2 hardening, not P0
- [ ] **EXT L-3** Linux OAuth secret token never persisted (writeFallbackFile never invoked) — `linux/Sources/ClawdmeterLinux/Storage/LinuxSecretServiceTokenProvider.swift:115-141` _(partial/narrower than claimed)_
  - Real but narrower than "token lost on exit" — the OAuth provider is read-only by design (it reads tokens the Mac mirrors / Phase-3 libsecret), so there is no write path to lose; our v2 audit already f…
- [ ] **EXT L-5** Empty bearer token accepted on Linux — `linux/Sources/ClawdmeterLinux/Transport/HummingbirdBearerAuth.swift:31-38` _(partial/narrower than claimed)_
  - Real defensive gap (the auth predicate should reject empty expected/presented), but NOT an exploitable bypass against the real Linux store, which never yields an empty token — and the transport that w…
