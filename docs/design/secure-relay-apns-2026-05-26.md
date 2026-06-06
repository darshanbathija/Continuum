# Secure Relay + APNS Gateway — Design Doc + Threat Model

Status: **DRAFT** — initial spec for E1 (Phase 0). Requires security review before E2 (relay Worker) and E5 (APNS gateway) implementation begins.

Branch: `feat/e1-relay-apns-design-doc`
Plan: E1 / D18 / D21 / D22 from `.claude/plans/study-this-codebase-crystalline-shore.md`

---

## 1. Problem

Continuum today depends on Tailscale or LAN reachability for Mac ↔ iPhone pairing. The GTM doc names this as **Gate 3 launch blocker**:

> Tailscale/MagicDNS setup is documented or replaced by simpler transport.

Additionally, plan-approval push notifications today go through iOS Background App Refresh, which has a 15-30 minute lag. The GTM wedge ("walk away from Mac, approve from wrist") falls apart at that latency.

This design replaces both with:

1. **Secure cloud relay** — a Cloudflare Worker + Durable Object that brokers WebSocket frames between Mac daemon and iPhone client over end-to-end-encrypted envelopes. Removes the Tailscale dependency for the common case.
2. **APNS gateway** — a separate Cloudflare Worker that holds the operator's Apple Developer `.p8` key and forwards encrypted push payloads from Mac daemon to Apple APNS HTTP/2. Cuts plan-approval latency from minutes to ~2 seconds.

Both share a single E2E crypto invariant: the operator's Cloudflare account never sees plaintext content. The relay sees only opaque ciphertext frames; the APNS gateway sees only encrypted payload + device token + bundle ID.

## 2. Goals + non-goals

### Goals
- Zero-config onboarding for users with no Tailscale: pair via QR + relay in under 2 minutes (GTM Gate 3 target)
- Push delivery ≤2s end-to-end from Mac daemon → Apple APNS → iPhone lock screen (vs current 15-30 min BG refresh lag)
- E2E confidentiality + integrity: operator (us) cannot decrypt either pairing-session frames or APNS payload bodies
- Round-trip message SLO: p50 < 200ms / p99 < 500ms (per D28)
- Fail-safe fallback to legacy Tailscale LAN mode when relay is unavailable (per E3)
- Audit log + kill-switch for the APNS gateway (per D21)

### Non-goals
- Federation between Cloudflare and other clouds. Single-operator deployment.
- Multi-tenancy. Each operator runs their own relay + APNS gateway pair.
- Anonymous relay use. All connections require a relay session token issued at pairing time.
- Replacing the Tailscale path for users who explicitly want it. Tailscale stays as a fallback (E3 transport state machine).

## 3. Architecture overview

```
                                            CLOUDFLARE
                                            ┌────────────────────────────┐
       iPhone (Continuum iOS app)           │   relay Worker             │
        ├── RelayClient.swift               │   (apps/relay/)            │
        │                                   │                            │
        │  WSS / TLS 1.3                    │     Durable Object         │
        │  ciphertext frames ◄────────────► │     RelaySession           │
        │  ChaCha20-Poly1305 envelopes      │     (1 per pairing)        │
        │                                   │                            │
       Mac (Continuum Mac app daemon)       │                            │
        ├── RelayClient.swift               │                            │
        │  WSS / TLS 1.3                    │                            │
        │  ciphertext frames ◄────────────► │                            │
        │                                   │                            │
        ├── APNSGatewayClient.swift         │   apns-gateway Worker      │
        │  HTTPS POST                       │   (apps/apns-gateway/)     │
        │  { encrypted payload,             │                            │
        │    device token,                  │     holds operator .p8     │
        │    bundle id }                    │     signs JWT for APNS     │
        │                                   │     forwards via HTTP/2    │
        │                                   │             ▼              │
        │                                   │       Apple APNS HTTP/2    │
        │                                   │             │              │
        │                                   │             ▼              │
        │                                   │       iPhone lock screen   │
        │                                   │       (encrypted body,     │
        │                                   │        only iPhone can     │
        │                                   │        decrypt)            │
        │                                   │                            │
        └─── (legacy Tailscale LAN mode     │   audit-log KV namespace   │
              fallback when relay           │   (hashed device tokens +  │
              unavailable — E3)             │    send timestamps +       │
                                            │    sender Mac fingerprint) │
                                            └────────────────────────────┘
```

## 4. Wire protocol

### 4.1. Pairing handshake

The QR code at pairing time encodes a `PairingPayload` (CBOR-encoded, ~120 bytes):

```
PairingPayload = {
  v:       u8       // version, currently 1
  sid:     bytes32  // relay session ID (random, server-generated)
  macTok:  bytes32  // Mac peer's bearer token for the relay session
  iosTok:  bytes32  // iOS peer's bearer token for the relay session
  ecdhPub: bytes32  // Mac's X25519 public key (ephemeral, generated per pairing)
  ttl:     u32      // absolute Unix seconds; relay rejects connections after this
}
```

Per [D22](.claude/plans/study-this-codebase-crystalline-shore.md): **per-peer tokens** — `macTok` authorizes the WebSocket open from the Mac side only; `iosTok` authorizes the iOS side only. Leaking the QR compromises only that single pairing session (which has a 15-minute TTL).

**Server-side binding check (D22).** The relay Worker MUST verify on WebSocket open that the presented tuple `(sid, token, side)` matches a stored record: a `macTok` value is valid only when presented on the `?side=mac` connection for its own `sid`, and likewise for `iosTok` on `?side=ios`. Cross-side reuse (`iosTok` presented on the Mac side, or a `macTok` from session A presented against session B) MUST be rejected with 401 before any frame is forwarded. This binding is what makes "leaked QR compromises only this pairing" hold — without it, a single stolen token could be replayed against any open session.

### 4.2. ECDH key derivation

When both peers connect, they perform X25519 ECDH:
- Mac uses its ephemeral private key (kept in-memory only, never persisted)
- iOS uses an ephemeral key generated on QR scan
- Each peer sends its public key as the first frame (plaintext over WSS); the relay forwards
- Shared secret `s` = X25519(myPriv, theirPub)
- Symmetric key `K = HKDF-SHA256(salt=sid, info="clawdmeter.relay.v1", key_material=s, length=32)`

### 4.3. Encrypted frame format

Every payload frame after handshake is:

```
EncryptedFrame = {
  nonce:      bytes24    // ChaCha20-Poly1305 XChaCha20 nonce (random, never reused)
  ciphertext: bytes      // ChaCha20-Poly1305 sealed payload + 16-byte tag
}
```

Plaintext payload schema (CBOR):

```
Plaintext = {
  seq:  u64               // monotonically-increasing sequence number
  op:   string            // operation name — same shape as AgentControl wire (per Protocol.swift)
  data: any               // op-specific payload (mirrors existing WireXxxResponse types)
}
```

Replay protection: each peer keeps a "highest seq seen" counter; frames with `seq ≤ counter` are dropped + logged as `replay-rejected` in the local OSLog.

### 4.4. APNS gateway envelope

The APNS gateway sees:

```
APNSRequest = {
  deviceTokenHash: bytes32       // SHA-256(deviceToken) for audit log; raw token follows
  deviceToken:     bytes32       // raw APNS device token (gateway needs it for the HTTP/2 :path)
  bundleId:        string        // "ai.continuum.ios" or "ai.continuum.ios.watchkitapp"
  topic:           string        // APNS topic
  encryptedBody:   bytes         // ChaCha20-Poly1305 sealed { sessionId, kind, summary }
  nonce:           bytes24
  ts:              u64           // Unix seconds (for rate-limit + audit)
  senderMacFingerprint: bytes32  // SHA-256(Mac daemon's pairing pubkey) — for audit
}
```

Crucially, `encryptedBody` is sealed with the symmetric key from the existing relay-pairing ECDH (or a sibling key derived via HKDF info=`"clawdmeter.apns.v1"`). The gateway cannot decrypt it; only the paired iPhone can.

The iPhone receives the APNS push, decrypts `encryptedBody` using the same key it derived at pairing, and displays the notification.

## 5. Threat model — 14 scenarios with mitigations

| # | Scenario | Threat | Mitigation |
|---|---|---|---|
| 1 | Relay operator (us) is curious / compromised | Reads ciphertext frames | E2E encryption — operator sees only opaque frames. No plaintext logs from the Worker. Audit assertions in E2 acceptance criteria. |
| 2 | Operator's `.p8` is exfiltrated | Attacker sends arbitrary pushes to every paired iPhone | Per-device rate limit (100 pushes/hour); audit log with sender fingerprint + device-token hash; documented rotation playbook (rotate within 1h, replay audit log to identify affected devices); emergency kill-switch (single CF env flag = stop all pushes). |
| 3 | QR is screenshot / leaked before iPhone scans | Attacker connects to relay session and joins the pairing | Per-peer tokens (D22): leaked QR doesn't let attacker join — attacker would need BOTH `macTok` AND `iosTok` and at most ONE peer can connect per side. Short 15-min TTL ensures stale QRs expire fast. |
| 4 | Network-path MITM | Reads / modifies wire bytes | TLS 1.3 between every hop. E2E encryption layered on top means even a successful TLS MITM only sees ciphertext. |
| 5 | Replay attack (capture + resend a frame) | Repeat a "approve plan" message | Monotonic `seq` per direction; replayed frames dropped. Replay-rejection logged for audit. |
| 6 | Nonce reuse | ChaCha20-Poly1305 collapse to plaintext recovery | XChaCha20 24-byte nonces drawn from `SecRandomCopyBytes` (Mac) / `SecRandomCopyBytes` (iOS) / `crypto.getRandomValues` (Worker). At 2^96 nonces per key, collision probability is negligible. |
| 7 | Lost pairing key (iPhone wiped / Mac stolen) | Attacker holding the device decrypts in-flight messages | Pairing crypto is ephemeral — no long-lived identity keys. To re-pair after device loss, user runs the pairing wizard again, which generates fresh ephemeral keys. Old key material has nothing useful (the relay session expired). |
| 8 | Forged APNS payloads (attacker controls relay) | Push a fake "plan ready" to user | Encrypted body is sealed with the pairing key — only the real iPhone can decrypt + render. Forged APNS payloads decrypt to garbage and the iOS app silently drops them. |
| 9 | Relay Worker scaling exhaustion | DoS — open many WebSockets | Per-IP rate limit at relay edge; Durable Object cleanup cron evicts sessions idle >15 min; max-concurrent-sessions cap per operator. |
| 10 | Operator's Cloudflare account is compromised | Attacker can deploy new Worker code | This is the ultimate trust root and we accept it. Mitigation = 2FA on the Cloudflare account, separate deploy keys, code review on every Worker change, signed Worker bundles (CF supports this). |
| 11 | iOS background suspension drops the WS | iPhone misses a frame mid-session | APNS gateway path: even when WS is suspended, push delivers. iPhone foreground bring-up reconnects WS + drains backlog via the `seq` cursor — frames the relay buffered while iOS was offline replay in order. |
| 12 | TLS-MITM by the user's enterprise network proxy | Re-signs TLS to inject monitoring | Operator deploys with HSTS + certificate pinning where iOS allows (Network.framework `NWConnection.TLSOptions` + custom verifyBlock). Falls back to legacy Tailscale LAN if pinning fails. |
| 13 | Side-channel timing leak on the iOS / Mac decrypt path | Attacker observes wall-clock time of `aead_decrypt` or token-compare to learn key bits or token validity | Use CryptoKit / libsodium primitives that are documented constant-time (`ChaChaPoly.open`, `Curve25519.KeyAgreement.sharedSecretFromKeyAgreement`). All bearer-token comparisons (`macTok`/`iosTok` on the Worker) MUST use a constant-time compare (libsodium `sodium_memcmp` / `crypto.timingSafeEqual` on Workers). Reject with a uniform delay; do not branch on AEAD-tag-failed vs token-mismatch. Audit assertion in E2/E3 acceptance: no `==` comparisons on secret material in `apps/relay/` or `apple/.../RelayClient.swift`. |
| 14 | Protocol or transport downgrade | Attacker on path forces a v0 (plaintext) handshake, suppresses the relay so client falls back to a weaker LAN path, or rolls the wire-protocol `v` byte | Wire-protocol version `v` is bound into the HKDF `info` string (`"clawdmeter.relay.v1"`); a flipped `v` derives a different key and AEAD fails. Both peers MUST refuse `v < current` even if signaled in the QR. The relay/Tailscale fallback (E3) is **client-side opt-in only** — the Worker cannot signal "use Tailscale instead"; only the user toggles it. iOS pins TLS minimum to 1.3; HTTP/1.1 upgrade paths to `wss://` are rejected. |

## 5b. Key lifecycle + forward secrecy posture

This section is normative — implementations MUST conform.

- **Identity keys.** v1 ships with **no long-lived identity keys** on either peer. Every pairing generates fresh X25519 ephemeral keypairs on both sides; private keys live in process memory only and are zeroized on session close or 15-minute TTL expiry. Open Question 1 (server-pinned identity) defers identity keys to a future version.
- **Forward secrecy.** Because the per-session key is derived from ephemeral X25519 keys that never touch disk, **compromise of any device after a session ends cannot decrypt prior captured ciphertext** — there is nothing on disk to seize. Forward secrecy is by construction, not by rekey.
- **Post-compromise recovery.** If a device is presumed compromised mid-session, recovery is: user runs the pairing wizard again on the surviving device; this generates new ephemeral keys; old `sid` is rejected by the relay once TTL elapses (or immediately if the user hits "revoke" — see below). No transcript continuity across pairings.
- **Rekey policy.** A pairing session has a hard maximum lifetime equal to the QR `ttl` (default 15 min). Sessions are not re-keyed mid-flight in v1; if a session needs to outlive 15 min (open question for "trusted device" UX), a future spec MUST add an explicit ratchet — do not silently extend the existing key.
- **Revocation.** The relay Worker exposes a `DELETE /sessions/:sid` admin endpoint (operator-authenticated) that drops both bearers, closes any open WS, and tombstones `sid` for 24h to block re-use. User-initiated revoke flows route through this in E7.
- **APNS `.p8` rotation.** The operator's APNS signing key rotates every 90 days routinely, or immediately on any suspected compromise (per threat #2). Rotation playbook + audit-log replay procedure live in `docs/runbook/apns-key-rotation.md` (E5 deliverable).
- **Nonce lifetime.** XChaCha20 nonces are random per frame (line 114). Per-key nonce budget is 2^96 before collision probability becomes non-trivial; in practice a 15-min session never approaches this.

## 6. Sequencing + acceptance hooks

Per the plan's Phase 1 (E1 → E2/E5 → E3/E6 → E4 → E7 → E8) the order is:

1. **E1 (this doc)** — review + sign off
2. **E0** (codex #6 finding) — wrangler env + CI deploy pipeline + secret provisioning
3. **E2 (relay Worker) + E5 (APNS gateway)** — in parallel; each cites this doc's wire shapes
4. **E3 (Mac → relay) + E6 (Mac → APNS)** — in parallel; consume E2 + E5 staging deployments
5. **E4 (iOS → relay)** — adapter for the protocol defined here
6. **E7 (pairing UX)** — QR + ECDH handshake UI
7. **E8 (privacy + security docs)** — public-facing version of this doc

### 6.1 Per-PR acceptance gates

Each downstream PR must satisfy the following before merge. These are pulled from the wire shapes, threat-model mitigations, and key-lifecycle posture above.

**E2 (relay Worker, `apps/relay/`).**
- Worker accepts only WSS; rejects HTTP/1.1 upgrade attempts that haven't negotiated TLS 1.3.
- On WebSocket open, verifies `(sid, token, side)` tuple via constant-time compare (timing-side-channel mitigation, threat #13).
- Forwards opaque frames byte-for-byte; never logs payload bytes; emits only structured metadata logs (`sid`, `side`, `frame_count`, no plaintext).
- Durable Object cleanup cron evicts sessions idle >15 min (threat #9).
- Per-IP connection rate limit at edge.
- Admin `DELETE /sessions/:sid` endpoint behind operator auth (revocation, §5b).
- Test vectors in `apps/relay/test-vectors/` round-trip against §8 fixtures.

**E3 (Mac → relay, `apple/Clawdmeter/.../RelayClient.swift`).**
- Generates X25519 ephemeral keypair per pairing; private key never touches `Keychain` / disk.
- `SecRandomCopyBytes` for both ECDH private key and every XChaCha20 nonce.
- TLS minimum version pinned to 1.3 on `URLSessionConfiguration.tlsMinimumSupportedProtocolVersion`.
- Constant-time bearer-token equality (`Data.constantTimeEquals` or equivalent) on any server-supplied token echo.
- Falls back to legacy Tailscale path only on **explicit user toggle**, never on relay-signaled instruction (downgrade mitigation, threat #14).
- Replay counter (`seq` cursor) persisted only per-session; dropped on disconnect.

**E4 (iOS → relay, `apple/ClawdmeterShared/Sources/.../RelayClient.swift`).**
- Same crypto requirements as E3 (CryptoKit `Curve25519.KeyAgreement`, `ChaChaPoly.open`).
- Background-suspension drain path: on app foreground, reconnects WS and replays from local `seq` cursor (threat #11).
- Certificate pinning via `NWConnection.TLSOptions` custom verifyBlock; pinning failure surfaces to UI, does **not** silently fall back (threat #12).
- Decrypts APNS `encryptedBody` using the same per-pairing key derived in E3/E4 handshake.

**E5 (APNS gateway, `apps/apns-gateway/`).**
- `.p8` key stored only as a Cloudflare secret; never logged; never reachable from the relay Worker.
- Per-device rate limit (100 pushes/hour, threat #2) keyed by `deviceTokenHash`.
- Audit log entries written to KV with 90-day TTL: `{ts, deviceTokenHash, senderMacFingerprint, bundleId, topic, size}` — **never** the `encryptedBody`.
- Emergency kill-switch env flag (`APNS_KILL_SWITCH=1`) short-circuits all sends with a structured log.
- Explicit sandbox vs production routing (Open Q2) gated by env flag; staging always uses sandbox.
- `.p8` rotation runbook checked in at `docs/runbook/apns-key-rotation.md`.

**E6 (Mac → APNS, `apple/Clawdmeter/.../APNSGatewayClient.swift`).**
- Seals `encryptedBody` with the HKDF-derived key using `info="clawdmeter.apns.v1"` (sibling of relay key, §4.4).
- TLS pinning to the APNS gateway Worker hostname.
- Backoff + retry on 5xx without leaking plaintext into logs.

**E7 (pairing UX).**
- QR codepath: `PairingPayload` CBOR encode matches §4.1 byte layout; `ttl` defaults to 15 min.
- "Use Continuum cloud" vs "Use Tailscale" choice surfaced explicitly (Open Q5).
- Revoke-pairing button calls Worker admin `DELETE /sessions/:sid` (§5b).
- Clear error UX when TLS pinning fails (no silent downgrade).

**E8 (privacy + security docs).**
- Public-facing version of this doc with the threat-model table and key-lifecycle posture (§5b) verbatim or strengthened.
- Operator-account threat (#10) called out as known trust root.
- Audit-log retention, `.p8` rotation cadence, and revocation endpoint documented for users.

## 7. Open questions

1. **Should we add a server-pinned identity for the relay session (vs purely ephemeral)?** Today: no, ephemeral simplifies key rotation. Future: yes when we want "trusted device" UX where iPhone remembers it paired with this Mac.
2. **APNS sandbox vs production routing.** E5 acceptance per D21 needs explicit splits. Likely env-flag-gated; design TBD.
3. **Audit log retention.** Suggest 90 days in KV with auto-purge. Confirm during E5.
4. **Cost ceiling.** CF Workers free tier covers ~100k req/day per account. Single-operator at 10k users averaging 50 frames/day = 500k frames/day — hits paid tier. Budget acknowledged.
5. **Fallback discoverability.** When relay is unavailable and Tailscale isn't installed, what does the user see? E7 pairing UX must surface this clearly (probably: "Pairing requires Tailscale or Continuum cloud. [Install Tailscale] [Use Continuum cloud]").

## 8. Cross-implementation test vectors

For E2 (TypeScript / libsodium-wrappers) ↔ E3 (Swift / CryptoKit + Curve25519 + ChaCha20Poly1305) parity, the test suite must include:

- Fixed ECDH input keypair → expected shared secret
- Fixed shared secret + HKDF salt + info → expected symmetric key
- Fixed plaintext + key + nonce → expected ciphertext + tag (must roundtrip both ways)
- Fixed CBOR-encoded `Plaintext` → byte-for-byte stable encoding (CBOR canonicalization)

These vectors block E2/E3 sign-off and live in `apps/relay/test-vectors/` (TypeScript JSON fixtures) + `apple/ClawdmeterShared/Tests/.../RelayCryptoTests.swift` (Swift assertions reading the same JSON).

## 9. Out of scope

- **CRDT-style offline sync between two iPhones paired to the same Mac.** Group F (provider instance registry) covers multi-instance Claude, not multi-iPhone-per-Mac. Single-iPhone pairing only for v1.
- **iMessage-style read receipts on plan approvals.** Push goes one way; the approval roundtrip uses the existing iOS command outbox path.
- **End-to-end audit log signed by user's key.** Operator's audit log only. User-side auditing is future work.

## 10. References

- Plan: `.claude/plans/study-this-codebase-crystalline-shore.md`
- CEO plan: `~/.gstack/projects/darshanbathija-cc-watch/ceo-plans/2026-05-26-clawdmeter-vs-t3code-perf.md`
- Strategy docs: `docs/competitive_analysis.md`, `docs/go-to-market-strategy-mobile-first-ide.md`
- libsodium docs: https://libsodium.gitbook.io/doc/
- CF Durable Objects: https://developers.cloudflare.com/durable-objects/
- APNS HTTP/2 spec: https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server
