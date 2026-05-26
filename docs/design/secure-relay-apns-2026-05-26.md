# Secure Relay + APNS Gateway — Design Doc + Threat Model

Status: **DRAFT** — initial spec for E1 (Phase 0). Requires security review before E2 (relay Worker) and E5 (APNS gateway) implementation begins.

Branch: `feat/e1-relay-apns-design-doc`
Plan: E1 / D18 / D21 / D22 from `.claude/plans/study-this-codebase-crystalline-shore.md`

---

## 1. Problem

Clawdmeter today depends on Tailscale or LAN reachability for Mac ↔ iPhone pairing. The GTM doc names this as **Gate 3 launch blocker**:

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
       iPhone (Clawdmeter iOS app)          │   relay Worker             │
        ├── RelayClient.swift               │   (apps/relay/)            │
        │                                   │                            │
        │  WSS / TLS 1.3                    │     Durable Object         │
        │  ciphertext frames ◄────────────► │     RelaySession           │
        │  ChaCha20-Poly1305 envelopes      │     (1 per pairing)        │
        │                                   │                            │
       Mac (Clawdmeter Mac app daemon)      │                            │
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
  bundleId:        string        // "com.clawdmeter.iphone" or "com.clawdmeter.watch"
  topic:           string        // APNS topic
  encryptedBody:   bytes         // ChaCha20-Poly1305 sealed { sessionId, kind, summary }
  nonce:           bytes24
  ts:              u64           // Unix seconds (for rate-limit + audit)
  senderMacFingerprint: bytes32  // SHA-256(Mac daemon's pairing pubkey) — for audit
}
```

Crucially, `encryptedBody` is sealed with the symmetric key from the existing relay-pairing ECDH (or a sibling key derived via HKDF info=`"clawdmeter.apns.v1"`). The gateway cannot decrypt it; only the paired iPhone can.

The iPhone receives the APNS push, decrypts `encryptedBody` using the same key it derived at pairing, and displays the notification.

## 5. Threat model — 10+ scenarios with mitigations

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

## 6. Sequencing + acceptance hooks

Per the plan's Phase 1 (E1 → E2/E5 → E3/E6 → E4 → E7 → E8) the order is:

1. **E1 (this doc)** — review + sign off
2. **E0** (codex #6 finding) — wrangler env + CI deploy pipeline + secret provisioning
3. **E2 (relay Worker) + E5 (APNS gateway)** — in parallel; each cites this doc's wire shapes
4. **E3 (Mac → relay) + E6 (Mac → APNS)** — in parallel; consume E2 + E5 staging deployments
5. **E4 (iOS → relay)** — adapter for the protocol defined here
6. **E7 (pairing UX)** — QR + ECDH handshake UI
7. **E8 (privacy + security docs)** — public-facing version of this doc

## 7. Open questions

1. **Should we add a server-pinned identity for the relay session (vs purely ephemeral)?** Today: no, ephemeral simplifies key rotation. Future: yes when we want "trusted device" UX where iPhone remembers it paired with this Mac.
2. **APNS sandbox vs production routing.** E5 acceptance per D21 needs explicit splits. Likely env-flag-gated; design TBD.
3. **Audit log retention.** Suggest 90 days in KV with auto-purge. Confirm during E5.
4. **Cost ceiling.** CF Workers free tier covers ~100k req/day per account. Single-operator at 10k users averaging 50 frames/day = 500k frames/day — hits paid tier. Budget acknowledged.
5. **Fallback discoverability.** When relay is unavailable and Tailscale isn't installed, what does the user see? E7 pairing UX must surface this clearly (probably: "Pairing requires Tailscale or Clawdmeter cloud. [Install Tailscale] [Use Clawdmeter cloud]").

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
