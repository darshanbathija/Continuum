# Continuum — Security

This doc is the public-facing version of the secure-relay + APNS design.
It describes what Continuum trusts, what it doesn't, and what the
operator's Cloudflare account can and cannot see. The full normative
design lives at [`docs/design/secure-relay-apns-2026-05-26.md`](design/secure-relay-apns-2026-05-26.md);
this doc is the contract with users.

> Status note. Group E (the secure relay + APNS gateway) is partially
> shipped at the time of writing. The Cloudflare Workers (E2 — relay,
> [PR #151](https://github.com/darshanbathija/Clawdmeter/pull/151); E5 —
> APNS gateway, [PR #147](https://github.com/darshanbathija/Clawdmeter/pull/147))
> are in main. The Mac/iOS clients that connect to them (E3, E4, E6)
> are not. See [`docs/known-limitations.md`](known-limitations.md) for
> exactly what's live vs. designed.

---

## 1. Trust model

Continuum has six trust tiers:

| Tier | Component | Trust | Notes |
| --- | --- | --- | --- |
| 1 | Local Mac daemon | **Trusted root** | Holds the user's Keychain entries, spawns provider CLIs, owns the in-process HTTP/WebSocket listener (`AgentControlServer`). |
| 2 | Paired iPhone / Apple Watch | **Trusted peer** | Pairing is QR + bearer-token + (for the secure-cloud path) per-pairing ECDH. iPhone derives the same symmetric key as the Mac and can decrypt every relay frame and every APNS body. |
| 3 | Cloudflare relay Worker (E2) | **Untrusted** | Sees opaque XChaCha20-Poly1305 envelopes only. Never holds the session key. Audit log records sender role + envelope type + byte length — never body content. |
| 4 | Cloudflare APNS gateway Worker (E5) | **Untrusted for payload** / trusted for `.p8` | Holds the operator's APNS signing key. Forwards sealed payloads to Apple. Cannot decrypt the body; only the paired iPhone can. |
| 5 | Third-party provider CLIs (claude, codex, opencode, cursor, antigravity/gemini) | **Sandboxed children** | Spawned by the Mac daemon as child processes. Each owns its own telemetry, its own auth state, and its own network egress. Continuum does not proxy or inspect their traffic. F3 [PR #142](https://github.com/darshanbathija/Clawdmeter/pull/142) carries the type-level seam for HOME isolation across instances (e.g. `claude_personal` vs. `claude_work`); the wire-up that actually enforces env scrub on spawn is F3-wire and not in main yet. |
| 6 | Sparkle appcast + GitHub release assets | **Authenticated release channel** | The appcast is served from GitHub Pages, while DMGs are hosted on GitHub Releases. Sparkle verifies EdDSA update signatures; the release script gates Developer ID signing, notarization, stapling, asset byte length, and appcast output before publishing. |

The trust root is the local Mac daemon. Compromising the daemon
compromises everything; compromising any single other tier does not.

Mac update compromise is bounded by Sparkle and Apple platform checks:
the appcast item must carry a valid Sparkle signature for the configured
public key, the DMG must be signed by the expected Developer ID
Application identity, and the release path staples a successful Apple
notarization ticket before the appcast is published.

## 2. Cryptographic primitives

Per the design doc:

- **Key exchange.** X25519 ECDH between Mac and iPhone. Each pairing
  generates fresh ephemeral keypairs on both sides; private keys live
  in process memory only.
- **Key derivation.** HKDF-SHA256 with `salt = sessionId` and
  `info = "clawdmeter.relay.v1"` (relay channel) or
  `info = "clawdmeter.apns.v1"` (APNS payload channel). Different info
  strings derive sibling keys from the same ECDH secret so a leak in
  one channel doesn't compromise the other.
- **Authenticated encryption.** XChaCha20-Poly1305 AEAD with random
  24-byte nonces. Per-key nonce budget is 2^96 — a 15-minute pairing
  session never approaches collision.
- **Integrity.** Replay protection via monotonically increasing `seq`
  counters per direction; the wire-protocol version byte is bound into
  the HKDF `info` string so a flipped `v` derives a different key and
  AEAD fails closed.

Test vectors live at
[`infra/relay/test-vectors/`](../infra/relay/test-vectors/) as
deterministic JSON fixtures. Both the TypeScript Worker
(`libsodium-wrappers-sumo`) and the Swift clients (CryptoKit, when E3/E4
land) MUST produce byte-identical outputs for the same inputs.

## 3. Key lifecycle

### 3.1 Generation

Both peers generate X25519 keypairs on demand at pairing time. Private
keys are produced from `SecRandomCopyBytes` (Mac/iOS) or
`crypto.getRandomValues` (Worker). The relay Worker never sees private
keys; it only sees public keys when they appear in the first opaque
handshake frame.

### 3.2 Storage

There are no long-lived identity keys in v1. Per-pairing ephemeral
private keys live in process memory only and are zeroized on session
close or 15-minute TTL expiry. Forward secrecy follows by construction —
nothing on disk can be seized after the fact to decrypt prior captured
ciphertext.

Per-instance Keychain access groups (the
`keychainAccessGroupOverride` field on `ProviderInstanceId`) are typed
into the model in [PR #142](https://github.com/darshanbathija/Clawdmeter/pull/142)
but enforcement of partition boundaries is the daemon's job in F3-wire,
which is not yet in main.

### 3.3 Rotation cadence

- **Pairing session keys.** Hard maximum lifetime equal to the QR
  `ttl` (default 15 min). Sessions are not re-keyed mid-flight in v1;
  a session that needs to outlive 15 minutes triggers a fresh pairing.
- **APNS `.p8` signing key.** Operator rotates every 12 months by
  default. The Worker exposes `GET /health` with a `p8Stale` flag that
  the CI rotation-drill job in
  [`infra/apns-gateway/ROTATION.md`](../infra/apns-gateway/ROTATION.md)
  reads; the build fails when `.p8` is older than 90 days, giving the
  operator three months of slack on annual rotation.

### 3.4 Revocation

The relay Worker exposes an admin `DELETE /v1/relay/sessions/:sid`
endpoint behind operator auth. Calling it drops both per-peer bearer
hashes, closes any open WebSocket with close code 4000, and tombstones
the `sid` for 24 hours so it cannot be re-used. User-initiated
revoke flows route through this endpoint when E7 (pairing UX rewrite)
ships.

### 3.5 Post-compromise recovery

If a device is presumed compromised mid-session, recovery is:

1. The surviving device runs the pairing wizard again.
2. The wizard generates fresh ephemeral X25519 keys and a new
   `sessionId`.
3. The old `sid` is rejected by the relay once TTL elapses, or
   immediately if the user hits "Revoke pairing" (which calls the admin
   `DELETE` endpoint).
4. There is no transcript continuity across pairings. The new pairing
   starts with no prior history.

The APNS `.p8` rotation playbook in
[`infra/apns-gateway/ROTATION.md`](../infra/apns-gateway/ROTATION.md)
covers the operator-side recovery path when the signing key itself is
suspected compromised: kill-switch within 5 minutes, new `.p8`
deployed within 1 hour, old key revoked at Apple immediately (no grace
period for compromised keys).

## 4. Per-peer bearer auth (D22)

The relay Worker authenticates each connecting peer with its own
256-bit bearer token. The QR code at pairing time issues TWO bearers:
`macTok` for the Mac side, `iosTok` for the iOS side. The Worker stores
only the SHA-256 hashes — even an operator with full Durable Object
storage read access cannot recover the raw bearers.

On every WebSocket open, the Worker:

1. Hashes the presented bearer.
2. Constant-time-compares the hash against `macTokenHash` AND
   `iosTokenHash`.
3. Whichever matches becomes the peer's assigned role (`mac` or `ios`).
4. Rejects with 403 if neither matches.

Bearer tokens are bound to the `(sessionId, peerRole, fingerprint)`
triple. Cross-side reuse — presenting `iosTok` on the Mac side, or
replaying a token from session A against session B — is rejected with
401 before any frame is forwarded. The role check repeats on every
envelope: if `header.from` doesn't match the role assigned at connect
time, the socket is closed with code 1008.

Constant-time comparison is required by the design doc threat #13
(timing side-channel). The Worker uses
`crypto.timingSafeEqual`-equivalent comparison; no `==` on secret
material in `infra/relay/src/`.

This is what makes "leaked QR compromises only this pairing" hold. An
attacker who screenshots the QR but doesn't get to scan it before the
real iPhone gets at most one of the two bearers, which authorizes only
one role, and at most one peer can connect per side. The 15-minute QR
TTL ensures stale codes expire fast.

Source: relay Worker [PR #151](https://github.com/darshanbathija/Clawdmeter/pull/151).

## 5. APNS device-token egress controls

When the Mac daemon sends an encrypted push payload through the APNS
gateway Worker, the device token is the unavoidable plaintext —
Apple's HTTP/2 endpoint addresses pushes by device token in the URL
path. The gateway treats the device token as PII and implements the
following controls per Codex #5 (audit findings folded into E5
acceptance):

- **Hash before persistence.** Every device token is SHA-256 hashed
  before any KV write or log line. The raw token reaches the
  Worker on the inbound request and the outbound Apple HTTP/2 request
  only; it never lands in KV, never lands in audit log entries, never
  lands in Workers Logs. Asserted by
  `test/index.test.ts → "never logs the raw device token"` and
  `test/device-tokens.test.ts → "does NOT store the raw device token in KV"`.
- **Tenant binding.** The `APNS_DEVICE_TOKENS` KV binding records
  `hashedToken → sessionId`. A push attempt for a device token that
  doesn't belong to the requesting session is rejected with 403 and
  an audit entry of outcome `rejected-cross-tenant`.
- **Stale-token cleanup on APNS 410.** When Apple returns
  `410 Unregistered` (the user removed the app, the token rotated,
  etc.), the gateway purges the hashed row from KV. No
  send-to-zombie-token forever.
- **Opt-out endpoint.** `DELETE /device-token` with an HMAC-signed
  proof of ownership purges the row immediately. Users who uninstall
  the iPhone app and want their token forgotten without waiting for
  the 410 cycle have an authenticated path.

Source: APNS gateway Worker [PR #147](https://github.com/darshanbathija/Clawdmeter/pull/147).

## 6. F3 HOME isolation

The provider-instance registry ships in source-only form in
[PR #142](https://github.com/darshanbathija/Clawdmeter/pull/142). The
type carries two security-relevant fields:

- `homePathOverride: String?` — when set, the daemon spawns the
  child process with `HOME=<override>` so provider configs
  (`~/.claude/`, `~/.codex/`, etc.) stay isolated per instance.
- `keychainAccessGroupOverride: String?` — when set, each instance's
  credential entries live under a distinct Keychain partition.

The shape these guarantee, when the daemon wire-up lands in F3-wire:

- **Keychain partitioning.** Each `ProviderInstanceId` with an
  override is given its own access group; Keychain queries from one
  instance cannot see another instance's items.
- **Env scrubbing on child spawn.** The daemon strips all `CLAUDE_*`,
  `CODEX_*`, provider-namespaced env vars from the parent environment
  before re-applying only the instance's own env. An attacker who
  somehow injects an env var into the parent shell cannot bleed it
  into a child provider process.
- **Per-instance log redaction.** Log lines prefix the instance's
  user-visible name (`claude_work:...`) but NEVER the raw
  `homePathOverride` value, since the override may contain user
  identifiers or directory names the user considers sensitive.
- **Credential bleed integration tests.** Required by F3-wire
  acceptance; an integration test seeds a leaked-key scenario in
  instance A and asserts instance B's credentials remain unreachable.

The shape is wired into the type today (input validation rejects empty
names and slash-containing names, and the registry refuses to overwrite
a seeded primary instance — see the PR #142 review-fix commit). The
runtime enforcement lands when F3-wire ships.

## 7. Audit log

### 7.1 What is logged

The APNS gateway Worker writes one audit entry per push attempt to the
`APNS_AUDIT_LOG` KV namespace and (redundantly) to Workers Logs. Each
entry records:

| Field | Value |
| --- | --- |
| `ts` | Unix seconds when the request landed at the gateway. |
| `env` | `staging` / `production` / `canary`. |
| `outcome` | One of: `delivered`, `rejected-schema`, `rejected-auth`, `rejected-rate-limit`, `rejected-kill-switch`, `rejected-cross-tenant`, `rejected-disabled`, `apns-bad-token`, `apns-unregistered`, `apns-rate-limited`, `apns-server-error`, `transport-error`, `opt-out`. |
| `deviceTokenHash` | SHA-256 hex of the device token. **Never the raw token.** |
| `senderMacFingerprint` | SHA-256 of the Mac daemon's pairing public key. |
| `sessionId` | The pairing session this push belongs to (used for cross-tenant detection). |
| `payloadSize` | Bytes of the encrypted payload. **Never the payload itself.** |
| `apnsId` | The APNS response `apns-id` UUID for cross-referencing with Apple. |
| `apnsStatus` | The APNS HTTP status (when the request reached Apple). |
| `reason` | Optional reason string from APNS or the gateway. |
| `requestId` | Local request id surfaced in the response header for correlation. |

The relay Worker emits a parallel structured log for every WebSocket
open / close / envelope, recording `sid`, `side`, `frame_count`, and
byte length. **Never plaintext, never body bytes.**

### 7.2 What is never logged

The following values are NEVER written to any log, any KV namespace,
any audit entry, or any tail stream:

- Raw bearer tokens (`macTok`, `iosTok`). Only their SHA-256 hashes
  hit storage.
- Raw APNS device tokens. Only their SHA-256 hash hits storage.
- Raw `homePathOverride` values from `ProviderInstanceId`. Per-instance
  logs use the user-visible instance name, not the override path.
- Encrypted payload bodies. The gateway records the byte length but
  never the bytes themselves; the relay never inspects the body at all.
- Provider CLI prompts, model responses, code diffs, or repo paths.
  These never leave the local Mac.

### 7.3 Retention

The audit log is held in KV with a 90-day TTL (`auditLogTtlSeconds`
default). Workers Logs follow Cloudflare's platform retention. The
operator can drop the retention window or purge selectively via
`wrangler kv` per the runbook in
[`infra/apns-gateway/ROTATION.md`](../infra/apns-gateway/ROTATION.md).

> Inferred value flagged for review. The plan does not specify an
> audit-log retention period. The 90-day TTL comes from the E5 ROTATION
> runbook's audit-log section and the gateway's KV TTL default.
> Confirm during the security-review pass before user-facing copy.

## 8. Kill-switch + rate limit

Per the D21 mitigation suite shipped in E5
[PR #147](https://github.com/darshanbathija/Clawdmeter/pull/147):

### 8.1 Per-device rate limit

The gateway enforces a per-device hourly cap (default 60 pushes /
device / hour) keyed by `deviceTokenHash` and bucketed by
`floor(nowSeconds / 3600)`. A burst at the minute-59 boundary gets a
fresh budget at minute-00 — conservative for the abuse scenario
(stolen `.p8` → push spam).

The limit is tunable via the `RATE_LIMIT_PER_HOUR` Worker var; the
operator can dial it down during an incident without redeploying code.

### 8.2 Kill-switch

A single Worker env var, `APNS_DISABLED`, short-circuits every push
attempt with a 503 status and an audit entry of outcome
`rejected-kill-switch`. The check runs **before** schema validation,
auth, or rate-limit — so the operator can disable the gateway even if
a buggy client is spamming malformed requests, and even if the auth
key itself is suspected compromised.

Latency from `wrangler secret put APNS_DISABLED true` to all Cloudflare
edges seeing the change: under 30 seconds in practice. The emergency
playbook in
[`infra/apns-gateway/ROTATION.md`](../infra/apns-gateway/ROTATION.md)
sequences the kill-switch first, forensics second, key rotation third
— the kill-switch buys time without requiring any other change.

### 8.3 What rate limit and kill-switch defend against

These controls defend against operator-side compromise scenarios:

- An attacker exfiltrates the operator's `.p8` and tries to send
  arbitrary pushes to every paired iPhone. The audit log captures the
  sender fingerprint of every forged push; the kill-switch stops
  delivery within 30 seconds of detection; rotation deploys a new key
  within an hour.
- An abusive client (compromised Mac daemon, malicious test harness,
  etc.) tries to flood the gateway. The per-device rate limit caps
  damage; the audit log identifies the offending sender fingerprint.

They do NOT defend against the operator themselves going rogue — that
is the trust root (see threat #10 below).

## 9. Threat model

The normative threat model is the 14-scenario table in
[`docs/design/secure-relay-apns-2026-05-26.md` §5](design/secure-relay-apns-2026-05-26.md#5-threat-model--14-scenarios-with-mitigations).
The mitigations summarized in this doc all trace back to a row in that
table. Briefly, the scenarios covered are:

1. Relay operator curious / compromised
2. Operator `.p8` exfiltrated
3. QR screenshot / leaked before iPhone scans
4. Network-path MITM
5. Replay attack
6. Nonce reuse
7. Lost pairing key (device wiped / stolen)
8. Forged APNS payloads (attacker controls relay)
9. Relay Worker scaling exhaustion (DoS)
10. Operator's Cloudflare account is compromised — **accepted trust root**
11. iOS background suspension drops the WS
12. TLS-MITM by enterprise proxy
13. Side-channel timing leak on decrypt path
14. Protocol or transport downgrade

Threat #10 (operator Cloudflare account compromise) is the irreducible
trust root and explicitly accepted. The mitigations are
account-hygiene: 2FA on the Cloudflare account, separate deploy keys,
code review on every Worker change, signed Worker bundles. There is no
in-product defense; the user trusts that the operator runs their
Cloudflare account responsibly.

## 10. Cross-impl crypto parity

Test vectors at
[`infra/relay/test-vectors/`](../infra/relay/test-vectors/) are the
byte-exact contract between the TypeScript Worker side and the Swift
client side. The TypeScript side passes via
`libsodium-wrappers-sumo`; the Swift side will verify against CryptoKit
when E3 lands.

There is a known cross-impl gap with Swift CryptoKit's XChaCha20
nonce size (24 bytes vs. CryptoKit's ChaChaPoly default 12 bytes).
Bridging requires either `libsodium-swift` or a custom XChaCha20
prelude. See [`docs/known-limitations.md`](known-limitations.md) for
the current state and the verifier finding that surfaced this.

## 11. Agent fs/terminal trust boundary (RepoTrustGate)

When Continuum drives an agent over ACP as a full harness (Grok, Cursor),
the agent can ask the client (us) to **read or write files** on its behalf
(`fs/read_text_file` / `fs/write_text_file`). We do not obey blindly.

- **Capability is off by default.** The ACP `initialize` handshake advertises
  `fs.readTextFile` / `fs.writeTextFile` ONLY when the session's repo is on the
  per-repo **autopilot trust list** (`AutopilotState.isRepoTrusted`). Untrusted
  repos advertise no fs capability and every fs request is refused
  (`methodNotFound`). `terminal/*` is not advertised in this release.
- **Every request is validated through `RepoTrustGate`** (bound to the repo
  root + the session's worktree cwd) before any disk I/O:
  - the path is canonicalized — `..` collapsed AND symlinks resolved via
    `realpath` (for writes, the deepest existing ancestor is resolved and the
    new-file remainder appended) — and the **canonical** result must sit at/under
    the repo root. This defeats traversal (`../../etc/passwd`), absolute-path
    escape, and symlink escape (a `link → /etc` placed inside the repo);
  - it is **TOCTOU-aware**: the gate returns the resolved canonical path and the
    handler operates on THAT path (resolve-then-use), never re-resolving the
    attacker-supplied string;
  - reads/outputs are **byte-capped** (anti-DoS);
  - terminal command policy default-denies privilege escalation (`sudo`/`su`/…)
    and catastrophic patterns (`rm -rf /`, pipe-to-shell, raw-device writes).
- **Audited:** each fs op is logged hash-only (op + allow/deny + a hash of the
  path — never the path or content).

`RepoTrustGate` is pure + exhaustively unit-tested (traversal, symlink-escape on
read and write-through-symlinked-parent, sibling-root-prefix confusion, command
denylist) so the boundary is verifiable without the daemon. `PathAllowList`
(scoped to iOS workspace onboarding) is NOT this boundary and is insufficient for
agent-driven fs.

## 12. Reporting a vulnerability

If you find a security issue, email the maintainers directly rather
than opening a public GitHub issue. The repo's `CONTRIBUTING.md` and
the operator's `infra/apns-gateway/ROTATION.md` "Owner handoff" section
list current escalation contacts.
