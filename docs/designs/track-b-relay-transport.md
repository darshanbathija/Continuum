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
  LAN-direct stays plain HTTP gated by the pairing token).
- Deleting `DirectHTTPTransport` (kept for LAN-direct).

## What already exists (reused, not rebuilt)
- `RelayFrameCodec` (E2E seal), `RelayClient` (Mac outbound + inbound dispatch),
  `RelayRequestDispatcher` (HTTP tunnel — extended for streams), the Cloudflare DO + Hibernation,
  the pairing-token store + relay bearer auth, the 4 existing `WSChannel`s (reused unchanged via
  the loopback-WS bridge), the chat-subscribe reconnect/backoff ladder (mirror for RelayTransport).
