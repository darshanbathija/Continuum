# Track B — Relay transport + remove Tailscale

**Status:** planned (not started). Successor to Track A (per-session Claude PTY,
branch `feat/claude-pty-host`). Run `/plan-eng-review` on this before implementing.

## Context

Today the phone reaches the Mac daemon over **Tailscale** — a second app + second
login on both devices, a hard onboarding wall, and an external dependency. The app
already ships its own **E2E-sealed Cloudflare relay** (built for APNS): a per-pairing
Durable Object that forwards opaque ciphertext between the two peers, with Hibernation
on. The goal: carry **all** phone↔Mac daemon traffic over that relay (off-network), add
a same-wifi **LAN-direct (Bonjour)** fast path, and **remove Tailscale entirely** — no
VPN, no second login, no fallback to Tailscale.

### Verified current state (this is what makes Track B non-trivial)

- ✅ **Crypto is done.** The relay seals the full stream E2E (X25519 → HKDF-SHA256 →
  XChaCha20-Poly1305; `RelayFrameCodec` in `ClawdmeterShared/Relay/`). The Cloudflare
  Durable Object (`infra/relay/src/durable-object.ts`) sees only ciphertext, forwards
  peer↔peer, Hibernation enabled (`ctx.acceptWebSocket` + 25s keepalive).
- ✅ **Mac inbound is done.** `RelayClient.swift` (E3) dials an outbound WS to the DO and
  bridges inbound frames to the loopback daemon via `RelayRequestDispatcher.swift`.
- ❌ **The dispatcher is request/response ONLY.** `RelayRequestDispatcher` maps each
  inbound frame `op = "<METHOD>.<path>"` → one loopback HTTP call → one `op.response`
  frame. **It has no streaming.**
- ❌ **The live features are WebSocket channels with no relay path:**
  `terminal` (`AgentControlServer.swift:668`), `events` (:702), `chat-subscribe` (:711),
  `frontier-subscribe` (:765), routed by `routeWSSubscription` (:590). Over the relay
  today these simply don't exist → removing Tailscale would strand live chat (HTTP-poll
  fallback at best) and make the remote Terminal tab unreachable.
- ❌ **iOS is keep-warm only.** `ClawdmeteriOS/AgentControl/IOSRelayClient.swift` (E4)
  keeps the socket warm for APNS; it is explicitly **not a transport router**.
  `AgentControlClient` (shared) still builds `http://<host>:<port>` (`:475–479`) and
  `MobileCommandOutbox` still calls it directly.
- ❌ **The peer filter rejects LAN at accept-time.** `AgentControlServer.isAllowedPeer`
  (:887, gate at :562) allows only loopback + Tailscale ranges; `TailscaleWhois`
  re-gates non-loopback (:623, :995) — both run **before** any bearer/pairing-token
  header can be read. So LAN-direct can't connect until this is restructured.
- ❌ **Bonjour is greenfield.** No `NWBrowser`/`NWListener`/`NetService` anywhere.
- **Tailscale removal blast radius:** `TailscaleHost.resolve()` feeds the pairing QR +
  MagicDNS toggles (`PairingSettingsView.swift:84,95`), the `clawdmeters://` TLS scheme,
  `currentTailscaleHostname()` (`AgentControlServer+RepoOnboarding.swift:248,324`), the
  iOS QR parser (accepts only loopback/100.64/`*.ts.net`), and `TailscaleWhois`.

### The central architectural decision

The relay must tunnel **both** request/response (done) **and** server-push
subscriptions (missing). Rather than refactor every `WSChannel` to write to an abstract
sink, **bridge subscriptions through a loopback WebSocket**: the relay dispatcher opens a
`URLSessionWebSocketTask` to the daemon's *own* WS port (127.0.0.1) and pumps each frame
outbound as a relay `subscription-frame`. This reuses 100% of the existing channel stack
(`TerminalWebSocketChannel`, `ChatStreamWebSocketChannel`, `AgentEventStream`,
`FrontierWebSocketChannel`) unchanged — the relay stays a "postal service for opaque
bytes" for streams too, symmetric with how it already tunnels HTTP via a loopback HTTP
client.

## Hard invariants
- **E2E sealing preserved** — reuse `RelayFrameCodec`; Cloudflare never sees plaintext,
  for streams as well as requests.
- **Fail-closed auth** — once the IP allowlist is gone, every non-loopback peer (LAN or
  relay) must present a valid pairing token; reject on missing/invalid/verify-error.
- **No Tailscale fallback** — relay is the off-LAN path; LAN-direct (Bonjour) is the
  same-wifi fast path; nothing falls back to Tailscale.
- **Flag-gated cutover** — `clawdmeter.transport.relayDefault` (default OFF) so the
  Tailscale path stays byte-identical until each piece is proven, then flipped.

## Data flow

```
TODAY                                       TARGET
  iPhone                                      iPhone
    | http://<tailscale-ip>:21731              | AgentControlTransport
    |  (direct, Tailscale VPN)                 |   ├─ DirectHTTPTransport (LAN-direct, Bonjour)   ← same wifi
    v                                          |   └─ RelayTransport (E2E-sealed frames)          ← off wifi
  Mac daemon (NWListener)                      v
    - HTTP routes                            Cloudflare DO (opaque ciphertext, Hibernation)
    - WS: chat-subscribe/terminal/             |  (off-LAN only)
          events/frontier-subscribe            v
                                            MacRelayClient ──► RelayRequestDispatcher
  Relay (APNS only): keep-warm                   ├─ <METHOD>.<path>  → loopback HTTP  → op.response   (exists)
                                                 └─ SUB.<path>       → loopback WS    → subscription-frame*  (NEW: B0)
                                            Mac daemon (unchanged HTTP + WS channels)
```

---

## Phases

### B0 — Subscription-over-relay multiplexing (keystone; everything depends on it)

Extend the relay frame protocol + `RelayRequestDispatcher` so server-push subscriptions
tunnel over the relay, by bridging through a loopback WS.

- **Frame protocol** (`ClawdmeterShared/Relay/` + `infra/relay/src/envelope.ts`): add op
  kinds `subscribe`, `unsubscribe`, `subscription-frame`, `subscription-end`, each carrying
  a `subscriptionId` (uint) so many streams multiplex over the one peer socket. The DO is
  unchanged (still forwards opaque frames); only the peers interpret the new ops.
- **Mac (`RelayRequestDispatcher`):** on `subscribe { subscriptionId, op:"SUB.<wsOp>", payload }`,
  open a loopback `URLSessionWebSocketTask` to `ws://127.0.0.1:<wsPort>` and send the existing
  WS envelope (`{op, token, sessionId/groupId/...}`). For each frame the channel emits, wrap it
  as `subscription-frame { subscriptionId, data }` and send outbound via `MacRelayClient`. On
  `unsubscribe`, relay disconnect, or loopback close → tear the loopback WS down + emit
  `subscription-end`. Track `[subscriptionId: URLSessionWebSocketTask]`. Reuses the loopback
  bearer token already used for HTTP.
- **Backpressure/ordering:** preserve per-subscription frame order (single task per id); the
  existing 100ms snapshot debounce on the channels already bounds frame rate, so no per-token
  storms over the cloud hop.

**Files:** `ClawdmeterMac/AgentControl/RelayRequestDispatcher.swift`, `RelayClient.swift`,
`ClawdmeterShared/Relay/RelayFrameCodec.swift` (+ op enum), `infra/relay/src/envelope.ts`
(header validation for the new ops). **Tests:** loopback-WS bridge round-trip (a fake channel
emits N frames → N `subscription-frame`s arrive in order; `unsubscribe` closes the loopback task).

### B1 — iOS relay transport router

Replace direct-HTTP-over-Tailscale with a transport abstraction; make the relay a real router.

- **`AgentControlTransport` protocol** (shared): `request(method:path:body:) async throws -> (Int, Data)`
  and `subscribe(op:payload:) -> AsyncStream<Data>`. Two impls:
  - `DirectHTTPTransport` — current behavior against a host:port (used for LAN-direct, B3).
  - `RelayTransport` — frames over `IOSRelayClient`: each request gets a unique op-id; await the
    matching `op.response` (request/response correlation); each `subscribe` allocates a
    `subscriptionId` and routes incoming `subscription-frame`s into the right `AsyncStream`.
- **Re-point consumers:** `AgentControlClient` request methods, `MobileCommandOutbox`,
  and the WS subscribers (`iOSChatStore` chat-subscribe, `iOSTerminalView` terminal,
  events, frontier) call the transport instead of building `http://host:port` / opening
  direct `URLSessionWebSocketTask`s. `IOSRelayClient` graduates from keep-warm to the
  RelayTransport backend (keep the APNS keep-warm behavior).
- **Selection:** a `TransportResolver` picks `DirectHTTPTransport` when a LAN-direct peer is
  known (B3), else `RelayTransport`. Behind `clawdmeter.transport.relayDefault`.

**Files:** new `ClawdmeterShared/AgentControl/AgentControlTransport.swift`,
`ClawdmeteriOS/AgentControl/RelayTransport.swift`, edits to `AgentControlClient.swift`,
`MobileCommandOutbox.swift`, `iOSChatStore`, `iOSTerminalView`. **Tests:** request/response
correlation (concurrent requests get the right responses); subscription fan-in to the correct
stream; reconnect/backoff (mirror the existing chat-subscribe ladder).

### B2 — Full coverage gate

Audit + assert that **every** `AgentControlClient` endpoint and **every** WS op round-trips
over `RelayTransport`. A table-driven test enumerates the route table + the 4 WS ops and drives
each through a loopback relay (DO test double or the real staging DO). This is the gate the
outside voices demanded ("verify the Mac dispatches EVERY endpoint") before B4.

### B3 — LAN-direct (Bonjour) fast path

- **Mac:** advertise the daemon over Bonjour (`NWListener` service `_clawdmeter._tcp`,
  TXT record with pairing fingerprint). Bind on the LAN interface.
- **iOS:** `NWBrowser` discovers the paired Mac on the same wifi; resolve to its LAN
  endpoint; `TransportResolver` prefers `DirectHTTPTransport` to that endpoint, falling
  back to `RelayTransport` when absent/unreachable. LAN-direct removes the cloud hop for
  same-network use (latency win for interactive typing).
- **Couples to B4:** LAN-direct can't connect until `isAllowedPeer` accepts LAN — do B3+B4
  in one atomic change so there is never a window where LAN is reachable without auth.

**Files:** new `ClawdmeterMac/AgentControl/BonjourAdvertiser.swift`,
`ClawdmeteriOS/AgentControl/BonjourBrowser.swift`, `TransportResolver`. **Tests:** discover →
LAN-direct selected; absent → relay fallback.

### B4 — Replace the peer filter (fail-closed) + remove Tailscale (atomic with B3)

- **Peer gate:** rewrite `AgentControlServer.isAllowedPeer` + the accept/dispatch path so:
  loopback is always allowed; every non-loopback peer (LAN or relay-loopback) must carry a
  valid pairing token, checked at **dispatch** (headers readable) not accept-time;
  **fail-closed** on missing/invalid/verify-error. Delete the IP allowlist + the
  `TailscaleWhois` gate (:623, :995).
- **Remove Tailscale:** delete `TailscaleHost.swift` + `TailscaleWhois.swift`; update
  `PairingSettingsView` (drop MagicDNS/`clawdmeters://` host resolution → emit the relay URL
  + optional LAN host), `currentTailscaleHostname()`
  (`AgentControlServer+RepoOnboarding.swift`), and the **iOS QR parser** to accept LAN/relay
  hosts (drop the loopback/100.64/`*.ts.net`-only acceptance). Update Settings/onboarding copy
  (no "install Tailscale").

**Tests:** **[SECURITY-REGRESSION]** an unauthenticated LAN peer is REJECTED; valid token
accepted; verify-error → reject. Pairing QR round-trips with a relay URL + LAN host.

### B5 — Cutover + cleanup

Load-test the relay path (reconnect storm, mobile-radio wake, GB-s under Hibernation) before
flipping `clawdmeter.transport.relayDefault` ON. Then remove the dead Tailscale code paths and
the direct-Tailscale host plumbing. Keep `DirectHTTPTransport` (now LAN-direct only).

## Sequencing
`B0` (keystone) → `B1` → `B2` (coverage gate) → `B3 + B4` (atomic) → `B5`. Every step lands
behind `clawdmeter.transport.relayDefault` (OFF) so Tailscale stays the live path until each
piece is proven; PR per phase; build green before advancing.

## Verification (end-to-end)
- **Streams over relay:** with Tailscale off + phone on cellular, chat-subscribe streams a live
  reply; the Terminal tab renders; events fire — all over the sealed relay.
- **LAN-direct:** same wifi → Bonjour discovers the Mac → traffic goes direct (no cloud hop);
  drop to cellular → seamless fallback to relay.
- **Security:** an unauthenticated device on the same wifi is rejected; the relay can't read
  plaintext (sealed).
- **Coverage:** every daemon endpoint + all 4 WS ops verified over the relay (B2).
- **Build:** `xcodegen` + `swift test` + Mac/iOS/Watch (`CODE_SIGNING_ALLOWED=NO`); relay Worker
  unit tests (`infra/relay`).

## Risks
- **Relay cost/latency:** must keep Hibernation + daemon-outbound-client + 25s keepalive (already
  in place) or pay GB-s for idle links; cold-wake + cloud-hop adds interactive-typing latency —
  LAN-direct mitigates; load-test before flipping the default.
- **Subscription multiplexing bugs:** ordering/teardown of many subscriptions over one socket;
  mitigate with per-id loopback tasks + explicit `subscription-end` + the coverage gate.
- **Security window:** never relax `isAllowedPeer` before token-auth is the sole fail-closed gate
  — B3+B4 atomic.
- **Pairing migration:** existing Tailscale-paired users need a re-pair to the relay/LAN QR;
  surface a one-time re-pair prompt.

## NOT in scope
- Track C (cloud Tier 2, Claude-Code-on-web) — separate cycle.
- Server-side TLS termination on the daemon (the relay already provides transport encryption;
  LAN-direct stays plain HTTP but is gated by a **challenge-response MAC bound to the pairing
  key** — the raw bearer token is never sent on the wire; see Eng Review Decision D3).
- Deleting `DirectHTTPTransport` (kept for LAN-direct).

## What already exists (reused, not rebuilt)
- `RelayFrameCodec` (E2E seal), `RelayClient` (Mac outbound + inbound dispatch),
  `RelayRequestDispatcher` (HTTP tunnel — extended for streams), the Cloudflare DO + Hibernation,
  the pairing-token store + relay bearer auth, the 4 existing `WSChannel`s (reused unchanged via
  the loopback-WS bridge), the chat-subscribe reconnect/backoff ladder (mirror for RelayTransport).

## Eng Review Decisions (`/plan-eng-review`, 2026-06-05)

Scope confirmed: **one cycle, all of B0–B5.** Five architecture forks decided via AskUserQuestion; the rest folded as refinements below.

- **D2 — B0 stream transport: loopback-WS bridge.** The relay dispatcher opens a `URLSessionWebSocketTask` to `ws://127.0.0.1:<wsPort>` and forwards frames, so all 4 `WSChannel`s are reused UNCHANGED. Chosen over a `WSChannelSink` refactor: the streams are 100ms-debounced (low frame rate), so the double-hop CPU cost is negligible and not touching 4 working channels is the lower-risk, right-sized diff.
- **D3 — B3 LAN-direct security: challenge-response bound to the pairing key.** LAN-direct must NOT send the raw bearer token over plaintext HTTP (a same-WiFi impostor advertising `_clawdmeter._tcp` could harvest it → RCE on the `--dangerously-skip-permissions` daemon; passive sniff also harvests it). Instead: Bonjour TXT carries `fp = HMAC(K,"id")` that iOS checks against its stored pairing identity; iOS sends a nonce, the Mac returns `HMAC(K, nonce)` to prove possession of the pairing secret `K`; per-request auth is `MAC = HMAC(K, method|path|body|ts)` with a short replay window. The raw token never crosses the wire. (Updates the "NOT in scope" plain-HTTP line.) **Hardened per Codex CB-P1f:** the MAC must bind **role + session-id + endpoint + nonce + timestamp + protocol-version** (not just method|path|body|ts); the daemon caches recently-used nonces and expires challenges fast, so a captured frame can't be replayed against a different role/endpoint or after the window.
- **D4 — B0/B1 multiplex + reconnect: full multiplex + auto-resubscribe.** Every request AND subscription carries an op-id; frames interleave (round-robin) and large frames chunk, so a big snapshot can't head-of-line-block a pending request. On reconnect (iOS background/WiFi switch) the client re-sends all active subscription envelopes and the server replays the current snapshot per stream — nearly free because the channels already emit debounced FULL snapshots. **Hardened per Codex:** (CB-P1b) `opId` is MANDATORY on every request/response/end/error frame, and the daemon rejects a duplicate live opId — `<op>.response` alone can't correlate concurrent same-route requests. (CB-P1c) "chunking" needs a concrete contract: each chunk carries `{messageId, index, count}`, a max-buffered-bytes cap, a reassembly timeout, and in-order delivery — because existing chat frames already exceed the DO's **64 KiB body cap**. (CB-P1a) `terminal` is **bidirectional** — input/resize/title must pump iOS→loopback-WS too, not just server-push; the bridge must be a full-duplex pump, tested both ways.
- **D5 — Relay snapshot cost: throttle + coalesce at the bridge.** Channels stay unchanged (D2); the loopback-WS bridge applies a coarser debounce for the RELAY path only (LAN/loopback keeps 100ms). Bounds Cloudflare GB-s without delta-encoding — explicitly avoiding the delta envelope Chat V2 D6 deliberately cut. **CORRECTED per Codex CB-P1d:** coalescing is **per-channel, not global** — last-write-wins (300–500ms debounce) applies ONLY to replaceable snapshot channels (`chat-subscribe`, `frontier-subscribe`); `events` must use cursor/seq replay (no drop — every event delivered); `terminal` is flow-controlled ordered bytes (no LWW, no drop — coalescing would eat keystrokes/output). A blanket LWW would corrupt terminal + lose events.
- **D6 — B5 cutover gate: live E2E + device drill + staged rollout.** Before flipping `clawdmeter.transport.relayDefault` ON and removing Tailscale: an automated E2E against the **staging DO** (pair → multiplex all 4 streams + requests → kill/resume the socket → assert resync), a **manual device drill** (background, lock, switch WiFi), then a **staged % rollout** (5→25→100). Tailscale code removed only after 100% green. Replaces B5's "load-test" with a real-network gate.

**Folded refinements (not contested — baked into the phases):**
- **B4 fail-closed peer auth** is largely subsumed by D3: the LAN listener requires a valid pairing-key MAC at dispatch (before any handler) — that IS fail-closed peer auth. Remaining adds: bad-auth **rate-limit/lockout** (reuse `RateLimiter`) so removing the IP allowlist doesn't open token brute-force; keep the loopback (127/::1) bearer exception for the Mac's own UI; remove the RFC1918/`TailscaleWhois` allowlist ONLY after the MAC gate is enforced (B3+B4 atomic, as written).
- **DO 2-peer trust:** the DO models one pairing as 2 peer sockets (Mac+iOS). Both peers are authenticated by the pairing; the bridge's loopback WS needs its own loopback bearer (not the pairing token) so a relay frame can't reach the daemon's WS port unauthenticated.
- **Pairing migration:** existing Tailscale-paired users get a one-time re-pair prompt (already noted in Risks); the iOS QR parser must accept relay+LAN hosts and the legacy `clawdmeter://`/`*.ts.net` acceptance is dropped only at B4.
- **Offline behavior:** once relay is default, no-internet + no-LAN = no remote control (expected); the Mac's own loopback UI is unaffected.

## GSTACK REVIEW REPORT

| Review | Trigger | Runs | Status | Findings |
|--------|---------|------|--------|----------|
| Eng Review | `/plan-eng-review` | 1 | CLEAR (PLAN) | 5 architecture forks decided (D2–D6) + 4 refinements folded |
| Codex Review | `codex exec` gpt-5.5 (outside voice) | 1 | ISSUES_FOUND | **2 P0 + 8 P1 + 2 P2** — all folded; 2 P0s verified in-repo |

**Codex outside-voice pass (2026-06-05, read-only, high reasoning) — 2 P0, 8 P1, 2 P2. All folded; the two P0s were verified against the repo and BLOCK the B5 cutover:**

- **CB-P0a — relay credential TTL is 15 min (VERIFIED: `infra/relay/wrangler.toml SESSION_TTL_SECONDS="900"`, all envs).** The 15-min TTL is a *QR-bootstrap* security feature (a leaked QR dies fast), but flipping `relayDefault` ON would evict + strand every paired device idle >15 min. **Fix (new B-prereq):** split the short QR-bootstrap TTL from **long-lived paired-device credentials** with refresh/rotation/revocation. Must land before B5.
- **CB-P0b — reconnect replay-seq asymmetry (VERIFIED: `RelayClient.swift:665 inboundHighSeq = 0` reset; both sides drop `seq <= inboundHighSeq`).** One side resets its seq on reconnect while the peer retains `inboundHighSeq`, so post-reconnect frames are dropped as replays — this directly breaks D4's auto-resubscribe. **Fix:** add a connection-epoch / session-nonce to the replay state (or persist monotonic counters across reconnects). Must land before B5.

- **CB-P1a terminal bidirectional** → folded into D4 (full-duplex pump, tested both ways).
- **CB-P1b opId mandatory + reject duplicate live IDs** → folded into D4.
- **CB-P1c 64 KiB DO cap + concrete chunk reassembly contract** → folded into D4.
- **CB-P1d per-channel coalescing (LWW only for snapshots; events=cursor replay; terminal=ordered bytes)** → **corrected D5** (my blanket-LWW was wrong — it would eat keystrokes + drop events).
- **CB-P1e loopback envelope built server-side** → the bridge overwrites the WS token with the per-launch loopback token and builds the loopback envelope from an allowlisted op schema; it must NOT trust relay-peer-supplied token/op/path. Folded into the "DO 2-peer" refinement (B4).
- **CB-P1f LAN HMAC replay binding** → folded into D3 (bind role/session/endpoint/nonce/ts/version; nonce cache).
- **CB-P1g secrets-in-JSON (raw `macTok`/`iosTok` + derived `K` persisted to the relay JSON record, not Keychain-only)** → new B-prereq: strip `K`/raw tokens from the JSON record + migrate existing records, so the "Keychain-only secret" assumption D3 relies on becomes true.
- **CB-P1h migration insufficiency** → strengthen Risks: require a pre-cutover migration STATE + old-app compatibility behavior + rollback, not just a re-pair prompt; the iOS QR parser keeps accepting legacy `clawdmeter://` until the cutover completes.
- **CB-P2a failed-auth throttle/lockout** → already in the B4 refinement (per-source + per-session backoff + audit + temp bans); confirmed.
- **CB-P2b coverage gate is hand-written** → B2/D6: generate the coverage table from the actual daemon route table (it also has `lifecycle-subscribe` + `compose-draft` WS behavior beyond the 4 streams), not a hand-listed "4 ops."

**CROSS-MODEL:** the inside review owned the architecture forks (transport, LAN crypto shape, multiplex, cost, cutover gate); Codex owned the *concrete protocol + current-state* gaps the forks glossed (TTL, reconnect seq, 64 KiB cap, per-channel coalescing, secret storage). No contradiction — Codex sharpened D3/D4/D5 and added two repo-verified P0 prerequisites.

**UNRESOLVED:** 0 — every finding decided (AskUserQuestion) or folded as a verified correction/prerequisite.

**VERDICT:** ENG CLEARED for B0–B4 implementation. **B5 cutover is GATED** on three now-explicit prerequisites — (1) long-lived paired credentials w/ rotation [CB-P0a], (2) reconnect-epoch replay fix [CB-P0b], (3) secrets-out-of-JSON migration [CB-P1g] — plus the D6 staging-DO E2E + device drill + staged rollout. Sequencing unchanged: B0 → B1 → B2 → B3+B4 (atomic) → B5.

---

## IMPLEMENTATION STATUS (branch `feat/relay-transport`, 2026-06-05)

Built behind `clawdmeter.transport.relayDefault` (default OFF). Flag-off is
byte-identical to the Tailscale path. ~70 new tests; Mac + iOS + shared green
(only the pre-existing `RelayPairingHandshakeTests` ×2 fail — predate this work).

### DONE (committed + tested)

| Item | Commits | What |
|------|---------|------|
| **B0** keystone | `a4ee90fd` `0f062389` `0912719f` | mux envelope (op-id + chunk contract, 64 KiB cap), Mac loopback-WS bridge (server-built envelope, full-duplex, per-channel coalesce), iOS mux client + reconnect resubscribe |
| **B1.1–B1.7** all transport | `c0bd0dd3` `2e26398a` `626652e3` `b23abb26` `ea714885` `d68255da` | chat + terminal + events + frontier streams AND HTTP requests all route over the relay; `relayDefault` flag + coordinator wiring |
| **B1 review fixes** | `9a7ace44` | 2 P0 + 2 P1 from the adversarial review (Mac-side reconnect seq reset; bridge re-open; malformed-frame drop; deinit cleanup) |
| **CB-P0b** reconnect epoch | `c0bd0dd3` + `9a7ace44` | iOS + Mac both reset the replay-seq epoch on a fresh handshake — DONE on both ends |
| **CB-P1g** secrets-out-of-JSON | `20056dea` | bearer tokens + derived key are Keychain-only; legacy-file migration |
| **B2** coverage gate | `a64e5b3d` | every daemon WS op classified relayed-or-exempt; CI fails on an unclassified new op |
| **B3 crypto** LAN auth | `f781cd33` | `RelayLanAuth` — Bonjour fingerprint + challenge-response + per-request MAC (role/path/body/nonce/ts bound) + fail-closed verifier (replay/stale/tamper). The security keystone (D3 + CB-P1f). |
| **B3/B4 policy cores** | `3ca14fb0` | `TransportResolver` (LAN-vs-relay-vs-tailscale; unverified-LAN never trusted) + `RelayAuthLockout` (CB-P2a per-source brute-force ban). |

### REMAINING — device / deploy / production-gated (NOT done; each needs verification the headless build can't provide)

- **B3 networking** — `BonjourAdvertiser` (Mac `NWListener` `_clawdmeter._tcp` + TXT fingerprint) + `BonjourBrowser` (iOS `NWBrowser`) feeding `TransportResolver`. **Gate:** needs 2 devices on a LAN to verify discovery + the challenge-response handshake end-to-end. The crypto (`RelayLanAuth`) AND the selection logic (`TransportResolver`) are DONE — only the `NWListener`/`NWBrowser` advertise/discover wiring remains.
- **B4** — wire `RelayLanAuthVerifier` + `RelayAuthLockout` into the daemon's LAN request path (fail-closed, MAC at dispatch); **then delete Tailscale** (`TailscaleHost`/`TailscaleWhois`, the IP allowlist, the QR/MagicDNS host plumbing). **Gate:** Tailscale removal is the irreversible cutover — only after B5 proves the relay. The verifier + lockout policy are DONE; the daemon LAN listener they guard is B3-networking.
- **CB-P0a** — relay worker (`infra/relay`, TypeScript): split the 15-min QR-bootstrap TTL from **long-lived paired-device credentials** with refresh/rotation/revocation (today `auth.ts` hard-expires at `ttlSeconds`). **Gate:** a new credential protocol across worker + DO + Swift pairing + QR; needs miniflare + device E2E, and a `wrangler deploy` to staging/prod. Must NOT ship unverified on a security-critical path.
- **B5 cutover** — flip `relayDefault` default → ON via a **staged % rollout** (5→25→100), after the **staging-DO live E2E** (pair → all 4 streams + requests → kill/resume socket → assert resync) + a **manual device drill** (background / lock / WiFi-switch). Remove the dead Tailscale paths only after 100% green. **Gate:** an irreversible, outward-facing production migration the plan (D6) explicitly gates on device verification.

**Net:** every part of Track B that can be built + unit-tested headlessly is DONE, committed, and pushed behind the OFF flag. What remains is inherently device/deploy/production-gated, and is precisely specified above for when a paired device pair + Cloudflare deploy access are available.

### 2026-06-05 CUTOVER TURN (user-authorized "turn it on now")

User cleared all gates (sole user, accepts the transition hump). Shipped the
proven path as the daily driver, sequencing only the irreversible Tailscale
deletion behind a first on-device proof.

- **B5a — relay is now the DEFAULT** (`76962d7c`): `RelayTransportFlag` returns
  true when unset; `AppRuntime` `relay.enabled` defaults true; iOS Settings →
  Connection toggle is the on-device off-switch.
- **CB-P0a — durable creds, no worker deploy needed** (`76962d7c`): the Worker
  already accepts any `ttlSeconds`, so durability was a client bump — Mac mints a
  30-day session (was 15 min), iOS `isValidTTL` cap → 31 days. Re-pair rotates
  keys (bounded blast radius). Continuous in-band rotation still deferred.
- **CRITICAL FIX — pairing-host allowlist** (`58c04b19`): the Mac minted
  `…continuumai.workers.dev` (the LIVE worker, verified 404-to-`/`) but the iOS
  scanner allowlisted the dead `…darshan-1ba.workers.dev`, so **every QR was
  rejected** — relay could never pair on device. Allowlist now matches the live
  host. Also fixed the 2 long-standing `RelayPairingHandshakeTests` failures.
- **3-platform build green**; shared suite 1373 tests, **0 failures**. Builds
  0.30.0 (198).
- **STILL DEFERRED (unchanged):** B3 Bonjour networking + LAN per-request-MAC
  wiring, B4 daemon LAN gate + **Tailscale deletion**, CB-P0a continuous
  rotation. Tailscale stays as the dormant fallback for THIS build; deletion
  lands once relay is confirmed working on the paired iPhone (the one check the
  headless build can't perform).
