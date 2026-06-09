# Clawdmeter Codebase Bug Audit — 2026-06-06 (main)

**Date:** 2026-06-06
**Branch:** `main`
**Commit:** `2fac7aaaba9222745d8513243ddad31b7111f1b1`
**Version:** `0.30.0` (build 198 per `apple/project.yml`)
**Prior audits:** `docs/BUG-AUDIT-2026-06-05.md`, `docs/BUG-AUDIT-2026-05-23.md`

**Methodology:** Read-only static review on `main` after merge of PR #249 (relay transport, Track B) and PR #248 (Claude PTY host). Re-verified all eight P0s from the 2026-06-05 audit with targeted `grep` + file reads. Spot-checked relay/PTY landing commits against June 5 P1 themes. No source edits, no test runs.

**Severity scale:** P0 = crash, corruption, security boundary failure, or core feature broken in normal use; P1 = real misbehavior, silent data loss, or reliability failure without adversarial setup; P2 = hardening, diagnostics, or edge cases.

---

## Executive summary

| Category | Count |
|----------|------:|
| **P0 still open** (from June 5) | 8 |
| **New P0** (this audit) | 1 |
| **New P1** | 9 |
| **New P2** | 5 |
| **June 5 P1/P2 still open** (condensed) | ~130+ |

Track B relay transport and Claude PTY host landed substantial **security and reliability fixes** (loopback token rebuild, relay subscribe allowlist, LAN fingerprint gate, PTY review P1s, relay-default cutover). None of those changes close the eight pre-existing P0s from June 5 — analytics truth, Mac CenterThread session binding, markdown-document file read, Linux platform declaration, Watch WCSession delegate contention, and read-only→live send corruption all remain reproducible from code inspection.

The **highest new risk** is **P0-R1**: fresh relay-QR pairing never writes Tailscale `host`/`token` into `UserDefaults`, so `AgentControlClient.isConfigured` stays false and `makeRequest` returns `nil` before `runRequest` can route over `relayRequestClient`. Mux-backed chat/events may work, but sessions list refresh, send, spawn, settings gates, and most HTTP APIs silently no-op.

Secondary relay risk (P1): with `relayDefault` on, `TransportResolver` and mux-backed stores prefer relay and **do not fall back** to Tailscale when relay is down but legacy pairing keys exist.

**Top actions:** (1) fix relay-only HTTP gate (P0-R1), (2) CenterThread composer/PR rebind (P0-3 + P0-7), (3) markdown-document containment (P0-4), (4) relay degradation ladder (N-P1-1–4), (5) Codex analytics + WCSession (P0-1, P0-6).

---

## P0 status table (June 5 re-verification)

All eight June 5 P0s remain **OPEN** on `2fac7aa`.

| ID | Title | Status | Evidence on main |
|----|-------|--------|------------------|
| **P0-1** | Codex analytics double-count on cumulative counter reset | **OPEN** | `CodexUsageParser.swift:84-103` — non-monotonic cumulative sets `delta = cumulative` |
| **P0-2** | Cache drops history when JSONL missing on dedup reparse | **OPEN** | `UsageHistoryLoader.swift:831-851` — `try? Data(contentsOf:)` skip leaves cache unmerged |
| **P0-3** | CenterThread composer/PR mirror wrong session after tab switch | **OPEN** | `CenterThread.swift:59-80` init-only `@ObservedObject`; `.onChange(of: session.id)` at 160-175 resets `@State` only; `SessionWorkspaceView` removed `.id(session.id)` for perf |
| **P0-4** | Arbitrary file read via markdown-document | **OPEN** | `AgentControlServer.swift:3283-3359`, `standardizedMarkdownDocumentPath` ~7968-7987 — absolute paths allowed, no worktree prefix check after open |
| **P0-5** | Linux package cannot build on Linux | **OPEN** | `linux/Package.swift:14-17` — `platforms: [.macOS(.v14)]` only |
| **P0-6** | Watch/iOS WCSession double delegate | **OPEN** | iOS: `WatchTokenBridge.swift:71`, `WatchPlanBridgeIOS.swift:34,43`; watchOS: `WatchPlanBridge.swift:44` — each sets `WCSession.default.delegate = self` |
| **P0-7** | Read-only→live promotion corrupts pending send | **OPEN** | `CenterThread.swift:1093-1121` — recovery queued on `promotedTarget.id` but `chatStore = model.chatStore(for: session)` uses synthetic session |
| **P0-8** | Dedup collision uses Claude-only parser | **OPEN** | `UsageHistoryLoader.swift:844-846` — collision reparse always via `ClaudeUsageParser` |

**Note:** Relay adversarial-review P0s from commit `9a7ace44` (Mac reconnect seq reset, bridge re-open, loopback envelope hardening) are **fixed** on main — they are distinct from the table above and are listed in §6.

| ID | Title | Status | Evidence on main |
|----|-------|--------|------------------|
| **P0-R1** | Relay-only iOS users blocked from all HTTP API calls | **NEW OPEN** | `AgentControlClient.init` sets `isConfigured` only from UserDefaults host+token (`104-105`); relay pairing uses `RelayPairingStore` + Keychain (`IOSRelayClientCoordinator.spinUpFromPersistedRecord` sets `relayRequestClient` but never `setPairing`); `makeRequest` `guard let host, let token else { return nil }` (`539-540`); ~31 call sites `guard let request = makeRequest(...) else { return }`; `RelayTransportFlag.relayDefaultEnabled` defaults **true** when key unset (`28-31`) |

---

## NEW findings (2026-06-06)

### P0-R1. Relay-only pairing cannot reach daemon HTTP despite wired relay request client

**Priority:** P0
**Location:** `AgentControlClient.swift:99-105`, `539-540`, `618-626`; `IOSRelayClientCoordinator.swift:144-190`; `RelayTransportFlag.swift:28-31`
**Description:** B5 cutover makes relay the default transport on fresh install. Relay QR pairing persists credentials in `RelayPairingStore` / Keychain and spins up `relayMux` + `relayRequestClient`, but legacy Tailscale keys (`clawdmeter.agent.host`, `clawdmeter.agent.token`) are never written. `isConfigured` remains false; UI gates (`IOSRootView`, `NewSessionSheet`, `SettingsView`, notifications) treat the app as unpaired. Every HTTP helper begins with `makeRequest`, which requires non-nil `host` and `token` computed from UserDefaults — so `runRequest`'s relay branch never runs.
**Impact:** Default fresh-install relay path: chat/events may update via mux, but session list, spawn, send, diff, interrupt, workspace onboarding, and settings-driven refresh silently fail. Users see "paired" in relay UI but broken Code/Sessions surfaces.
**Fix:** Treat transport as ready when `relayRequestClient != nil` (or `relayService.hasActivePairing`). Change `makeRequest` to synthesize a placeholder URL from path only when relay client is set (relay mux ignores host). Mirror `isConfigured` to that predicate. Add regression test: relay record present, no UserDefaults host, `refreshSessions()` succeeds.

---

### N-P1-1. Relay-default mode removes Tailscale fallback from transport selection

**Priority:** P1
**Location:** `apple/ClawdmeterShared/Sources/ClawdmeterShared/Relay/TransportResolver.swift:29-38`
**Description:** When `relayDefaultEnabled` is true, `TransportResolver.resolve` returns only `.lanDirect` (verified Bonjour) or `.relay`. It never returns `.tailscaleDirect`, even when LAN is unreachable and relay is down.
**Impact:** Users on relay-default who lose Cloudflare DO connectivity cannot fall back to the previously working Tailscale pairing URL path; mobile surfaces appear "paired but dead" until relay recovers.
**Fix:** When relay health check fails (or mux connect errors persist), degrade to `.tailscaleDirect` if a valid Tailscale host + token exist. Document the precedence in `TransportResolverTests`.

---

### N-P1-2. Relay-backed chat subscription has no HTTP/WS fallback ladder

**Priority:** P1
**Location:** `apple/ClawdmeteriOS/AgentControl/iOSChatStore.swift:174-184`, `runRelaySubscription`
**Description:** If `relayMux` or `IOSRelayClientCoordinator.shared.muxClient` is non-nil, `runSubscriptionLoop` calls `runRelaySubscription` once and returns — the legacy WS + HTTP fallback loop (lines 185+) is skipped entirely.
**Impact:** Chat transcript freezes or goes stale when the relay socket is connected but the Mac bridge is down, or when subscribe frames are dropped, with no 3s HTTP polling safety net.
**Fix:** Mirror the WS failure ladder: after N relay errors or stale frames (>30s), temporarily drop mux and run `runHTTPFallbackCycles` / direct Tailscale WS until relay recovers.

---

### N-P1-3. Relay-backed HTTP requests have no direct URLSession fallback

**Priority:** P1
**Location:** `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AgentControlClient.swift:618-626`
**Description:** When `relayRequestClient` is set, **all** daemon HTTP traffic routes through `runRequestViaRelay` with no attempt to fall back to Tailscale `URLSession` on relay timeout or 5xx.
**Impact:** Send, interrupt, diff fetch, and other one-shot commands fail entirely during relay outages even if the Mac daemon is reachable on `100.x`.
**Fix:** On relay correlator failure, retry once on direct URL (same as pre-B1 behavior) before surfacing error to outbox.

---

### N-P1-4. Relay-backed desktop event sync has no Tailscale WS fallback

**Priority:** P1
**Location:** `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/AgentControlClient.swift:804-811`
**Description:** `runDesktopEventSyncLoop` parks on `runEventsViaRelay` when `relayMux` is set, skipping the exponential-backoff Tailscale WS loop.
**Impact:** Session list / live dots / registry updates stop updating on iOS when relay path fails; user sees stale "N active sessions" until app restart.
**Fix:** Same degraded-mode pattern as N-P1-2: fall back to direct WS after relay staleness threshold.

---

### N-P1-5. Misleading comment claims composer is re-keyed per session

**Priority:** P1 (documentation / maintenance — causes wrong fixes)
**Location:** `apple/ClawdmeterMac/Workspace/CenterThread.swift:158-159`
**Description:** Comment states "composer/transcript/prMirror are already keyed per session via caches" but `composerStore` and `prMirror` are `@ObservedObject` values set only in `init` (lines 79-80), not updated in `.onChange(of: session.id)`.
**Impact:** Engineers may believe P0-3 is fixed and skip rebind work; perpetuates wrong-session sends.
**Fix:** Correct comment; implement rebind or restore `.id(session.id)` on CenterThread with perf mitigation elsewhere.

---

### N-P1-6. Claude PTY host silently drops sends when not running

**Priority:** P1
**Location:** `apple/ClawdmeterMac/AgentControl/ClaudePtyHost.swift:170-171`, `187-189`
**Description:** `submitPrompt` and `writeBytes` return immediately when `!isRunning || masterFD < 0` with no error surfaced to caller or session registry.
**Impact:** When PTY host flag is enabled, race between spawn readiness and first send can drop user prompts with no UI feedback.
**Fix:** Propagate failure to `SessionCommandRouter` / send handler (429 or structured error); log at warning level.

---

### N-P1-7. PTY trust-folder warmup auto-accepts without user consent

**Priority:** P1
**Location:** `apple/ClawdmeterMac/AgentControl/AgentControlServer.swift:1681-1697`
**Description:** `warmupClaudePtyHost` polls output for trust prompts and sends Down/Up/Enter to accept, mirroring tmux path. Runs for code sessions in new worktrees when PTY host is on.
**Impact:** Bypasses explicit user trust decision for Claude folder prompts — security/UX mismatch vs interactive tmux flow.
**Fix:** Gate on user setting or surface in-app approval; disable auto-keypress when session is user-visible.

---

### N-P1-8. Relay bearer token in WebSocket query string

**Priority:** P1
**Location:** `apple/ClawdmeterMac/AgentControl/RelayClient.swift:692-735`
**Description:** Mac relay connect URL includes `?token=<macTok>` in query items (comment notes relay expects it). Bearer material appears in URL logs, proxy history, and crash reports.
**Impact:** Token leakage via logs/CDN; June 5 P1-A10 theme persists on relay path.
**Fix:** Move to `Authorization` header only (relay server must accept); redact in client logging.

---

### N-P1-9. `RelayTransportFlag` file header contradicts B5 default-on behavior

**Priority:** P1 (product / rollout)
**Location:** `apple/ClawdmeteriOS/AgentControl/RelayTransportFlag.swift:10-11` vs `28-31`
**Description:** Header comment says "Default OFF until B5 cutover"; implementation returns `true` when UserDefaults key is unset.
**Impact:** Engineers and QA assume relay is opt-in; fresh installs hit relay-default + P0-R1 without legacy Tailscale keys.
**Fix:** Align comment with code or revert default to false until P0-R1 is fixed.

---

### N-P2-1. Stale `codex-stream-subscribe` references in docs/comments

**Priority:** P2
**Location:** CHANGELOG / design comments (not in `RelaySubAllowlist.allKnownWSOps` or `routeWSSubscription`)
**Description:** Track B B2 gate enumerates six WS ops (`chat-subscribe`, `terminal`, `events`, `frontier-subscribe`, `lifecycle-subscribe`, plus exempt `compose-draft`). `codex-stream-subscribe` is not implemented on the daemon router.
**Impact:** Integrators may expect a relay path that does not exist; silent feature gap.
**Fix:** Remove stale references or implement the op + allowlist entry + test.

---

### N-P2-2. IOSRelayClientCoordinator runs warm relay socket alongside legacy Tailscale

**Priority:** P2
**Location:** `apple/ClawdmeteriOS/AgentControl/IOSRelayClientCoordinator.swift:22-29`
**Description:** When a pairing record exists but `relayDefault` is off, both relay warm socket and Tailscale `AgentControlClient` run side-by-side.
**Impact:** Duplicate connections, battery use, ambiguous source of truth for "connected" debug UI.
**Fix:** Gate warm socket on `relayDefault` or mux wiring; document single primary transport in settings.

---

### N-P2-3. `compose-draft` listed in allowlist comment drift

**Priority:** P2
**Location:** `RelaySubscribe.swift:59-69` vs `allKnownWSOps`
**Description:** `compose-draft` is in `allKnownWSOps` as exempt one-shot but explicitly excluded from long-lived `ops` set — correct, but easy to misread in audits.
**Impact:** Low; audit noise only.
**Fix:** Cross-link comment to `routeWSSubscription` one-shot handler.

---

### N-P2-4. Relay chat path lacks foreground stale-frame reconnect parity

**Priority:** P2
**Location:** `iOSChatStore` relay branch vs WS branch (`UIApplication.didBecomeActiveNotification` observer on WS path)
**Description:** WS subscription loop forces reconnect when last frame >30s stale on foreground; relay parked path may not share that observer.
**Impact:** After backgrounding, chat may stay stale until manual tab switch.
**Fix:** Share stale-frame watchdog between mux and direct WS paths.

---

### N-P2-5. `IOSRelayClientCoordinator` header stale post-B1

**Priority:** P2
**Location:** `apple/ClawdmeteriOS/AgentControl/IOSRelayClientCoordinator.swift:22-29`
**Description:** File header still states relay "does not replace the direct Tailscale path" while B1 wires mux + `relayRequestClient` into `AgentControlClient` when relay default is on.
**Impact:** Audit and onboarding confusion only.
**Fix:** Update header to describe mux/request routing and dual-transport coexistence.

---

## Still open from June 5 (condensed)

The June 5 audit listed **88 P1 + 51 P2** (147 total). Spot-check on `2fac7aa` confirms the major themes remain unless noted in §6:

| Theme | Representative IDs | Status |
|-------|-------------------|--------|
| Idempotency / outbox gaps | P1-A1–A3 (`create-pr`, `merge`, `review-pr` skip `tryReplayIdempotent`; `handleCreatePR` ~3002 still has no replay wrapper) | **OPEN** |
| Pairing / auth hardening | P1-A9–A10 (token not bound to Tailscale identity; bearer in query string) | **OPEN** |
| Analytics (beyond P0) | P1-S1–S6 (OpenCode/Antigravity repo bucketing, pricing) | **OPEN** |
| Mac Sessions UX | P1-M* (stale closures, wrong chat store, checkpoint restore races) | **OPEN** (P0-3/7 are worst) |
| iOS mobile | P1-I* (outbox bypass on some Chat V2 paths, WS foreground reconnect partial for relay) | **PARTIAL** |
| Linux port | P1-L* (OAuth persistence, empty bearer, transport stubs) | **OPEN** |
| CI / tests | P2-C* (XCTSkip false-green; security regression tests in TODOS.md) | **OPEN** |

For the full row-level list, see `docs/BUG-AUDIT-2026-06-05.md`. This main audit did not re-execute all 147 items line-by-line; relay/PTY landings did not systematically close the June 5 P1 table.

---

## Fixed since June 5 (with evidence)

| Area | What shipped | Evidence |
|------|--------------|----------|
| **Relay adversarial P0s** | Mac reconnect seq reset, bridge re-open, loopback token rebuild | Commit `9a7ace44` ("B1 review fixes: 2 P0 + 2 P1") on main |
| **Relay subscribe security** | Server rebuilds loopback WS envelope with daemon token; op allowlist | `RelaySubscribe.swift`, `RelaySubAllowlist.ops` / `loopbackEnvelope` |
| **Relay coverage gate (B2)** | New WS ops must appear in `allKnownWSOps` or tests fail | `RelaySubscribeCoverageTests`, `RelaySubAllowlist.allKnownWSOps` |
| **LAN-direct auth (B3)** | Bonjour fingerprint + challenge-response MAC on requests | `RelayLanAuth`, `TransportResolver` + tests in `TransportResolverTests.swift` |
| **Relay default + creds (B5a)** | Default transport flag, 30-day credential semantics | Settings + coordinator wiring (`IOSRelayClientCoordinator`) |
| **Claude PTY host P1s** | Nine P1 fixes from PTY code review | Commit `5aaf6613` ("fix(track-a): resolve all 9 P1s from the PTY-host code review") |
| **PTY routing** | Session commands can target Claude PTY host | `SessionCommandRouter.swift`, `ClaudePtyHost.swift`, `ClaudePtyRegistry.swift` |
| **Live relay host allowlist** | Production relay host allowlisting | Commit `58c04b19` |

**Not fixed (explicit):** June 5 P0-1 through P0-8; **P0-R1** (relay-only HTTP gate); most June 5 P1 idempotency and analytics items; markdown-document path traversal (P0-4).

---

## Recommended fix order

1. **P0-R1** — Relay-only `isConfigured` / `makeRequest` gate (blocks default fresh-install iOS; fix before widening relay rollout).
2. **P0-3 + P0-7** — CenterThread session binding and read-only promotion (user-visible wrong-target sends; fix together in `CenterThread.swift` + `SessionsModel`).
3. **P0-4** — markdown-document path canonicalization under session cwd (security; small handler change + test).
4. **N-P1-1 → N-P1-4** — Relay degradation ladder (transport resolver + mux fallbacks for chat/events/HTTP) after P0-R1.
5. **P0-6** — Single WCSession delegate multiplexer (iOS + watchOS).
6. **P0-1, P0-2, P0-8** — Analytics loader/parser correctness (ccusage parity).
7. **P0-5** — Linux `Package.swift` platform declaration or disable Linux CI until shippable.
8. **N-P1-6, N-P1-7** — PTY send errors + trust warmup (when `clawdmeter.claude.ptyHost.enabled` is on).
9. **P1-A1** — Route `create-pr` / `merge` / `review-pr` through idempotent outbox (June 5 carryover).
10. **N-P1-5, N-P1-8, N-P2-*** — Comment/doc cleanup and relay observability hardening.

---

*Report generated read-only. No Swift or project files were modified.*
