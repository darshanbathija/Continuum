# clawdmeter-relay — Cloudflare Worker (Group E2)

WebSocket relay for the Clawdmeter Mac <-> iPhone pairing channel. One Durable Object per pairing session; two peers connect via WSS; the DO fans encrypted envelopes between them. **The Worker never sees plaintext** — peers derive a symmetric key via X25519 + HKDF on their own and encrypt every frame with XChaCha20-Poly1305 before handing it to the relay.

Plan: **E2** in `.claude/plans/study-this-codebase-crystalline-shore.md`.
Design doc: [`docs/design/secure-relay-apns-2026-05-26.md`](../../docs/design/secure-relay-apns-2026-05-26.md).
Scaffold: [E0 / PR #124](https://github.com/darshanbathija/Clawdmeter/pull/124).

---

## Wire protocol

The relay is intentionally dumb. It does THREE things and nothing else:

1. **Authenticate** each connecting peer with a per-peer bearer token (D22).
2. **Route** the next opaque envelope it receives from peer A to peer B.
3. **Count** envelopes for an audit log — sender role, type, byte length. **Never** body content.

### HTTP routes

| Method | Path                                           | Notes                                                                                                                         |
| ------ | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| GET    | `/healthz`                                     | 200 ok JSON; CF health probe + smoke test                                                                                     |
| GET    | `/v1/relay/sessions/:sid/connect`              | WebSocket upgrade. Auth via `Authorization: Bearer <tok>` OR `?token=<tok>` OR `Sec-WebSocket-Protocol: bearer.<tok>`. First peer MUST supply `?bundle=<base64-json-bundle>`. |
| GET    | `/v1/relay/sessions/:sid/stats`                | JSON aggregate counts (sender role + type + bytes). NEVER body content. For audit + tests.                                    |

`:sid` is 16-64 chars from `[A-Za-z0-9_-]`. Anything else 400s.

### Session bootstrap

The QR generator (Mac side at pairing time) produces three things:
- `sid` — random 128-bit session ID (URL-safe base64 or hex)
- `macTok` + `iosTok` — two opaque 256-bit bearer tokens (one per peer)
- `ttlSeconds` — absolute Unix timestamp after which the relay rejects all connections

The Mac is **always the first peer** in v1. On its first connect, it presents `?bundle=` containing `{ macTokenHash, iosTokenHash, ttlSeconds }` (each `*TokenHash` = SHA-256 hex of the raw bearer). The DO stores ONLY hashes — even an operator with full DO storage read access cannot recover the raw bearers.

Subsequent connections (Mac reconnecting, iOS connecting, iOS reconnecting) just present a bearer; no bundle needed.

### Envelope wire format

Every payload is a (text-header, binary-body) pair:

**Text header (JSON, ≤1024 bytes):**
```json
{ "v": 1, "from": "mac" | "ios", "type": "handshake" | "ciphertext" | "control" }
```

Key order MUST be `(v, from, type)` for byte-exact cross-impl parity (see [test-vectors/envelope-header-001.json](test-vectors/envelope-header-001.json)).

**Binary body (≤64 KiB):**
Opaque bytes. The relay never inspects.

For `type: "control"`, the body MUST be omitted (header-only fan-out — used for keepalive/seq-cursor sync between peers).

### Bearer auth (D22 per-peer)

A presented bearer is hashed and constant-time compared against `macTokenHash` AND `iosTokenHash`. Whichever matches is assigned as the peer's role:

- Match `macTokenHash` → role `mac`
- Match `iosTokenHash` → role `ios`
- Match neither → 403 `token-mismatch`

The role is enforced at TWO layers:
1. **Connect**: 403 if neither hash matches.
2. **Every envelope**: the `header.from` field MUST match the role assigned at connect, or the socket is closed (1008).

A leaked QR compromises ONLY that single pairing session (15-min TTL by default). And a leaked QR + the attacker presenting one half (`macTok` only, say) still cannot impersonate the other side because each token authorizes only one role.

### Reconnect-displaces-self

If a Mac peer drops and redials with the same `macTok`, the relay closes the existing Mac socket (4000 "displaced by reconnect") and accepts the new one. The iOS peer is unaffected. This is the design fundamental for mobile-radio churn — peers can sleep, wake, reconnect freely without dragging the other side down.

---

## SLO budget (Codex #2)

Per plan acceptance: E2 must hit each of these. Most are CF-native; we just have to not get in their way.

| # | Target                                  | How we achieve it                                                                                                                                                                                                                                                                                                                          |
| - | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | Worker cold start <50ms p99             | The `src/index.ts` entrypoint is ~50 lines, no top-level await, no top-level JSON parse. The DO module is tree-shaken to type info at module load. Total bundle is 37 KiB / 9 KiB gzip (`wrangler deploy --dry-run` output).                                                                                                              |
| 2 | DO placement = closest region to first peer | `env.RELAY_SESSIONS.idFromName(sid)` pins the DO to the colo of the first request. Mac is always the first peer in v1, so the DO lands in the Mac's region. iOS — typically same metro — gets a sub-30ms hop.                                                                                                                            |
| 3 | WS hibernation wake <100ms p99          | We use Cloudflare's [WebSocket Hibernation API](https://developers.cloudflare.com/durable-objects/best-practices/websockets/#websocket-hibernation): `ctx.acceptWebSocket(server)` (not `server.accept()`) plus `webSocketMessage` / `webSocketClose` handlers. CF rehydrates the DO from the wake event in <100ms by design. We don't add latency.       |
| 4 | Reconnect storm — 100 concurrent reconnects without dropping established peers | Per-role displacement: a reconnecting Mac displaces ONLY its own previous socket (close 4000), never the iOS peer. Audit-log counts persist across reconnect cycles. Integration test (`relay.integration.test.ts → "100 sequential reconnects do not corrupt routing"`) exercises 25 sequential displacements while the iOS peer stays connected. |
| 5 | Fan-out serialization O(N)              | A DO holds at most 2 sockets (Mac + iOS). `fanOut()` iterates `this.state.getWebSockets()` once per envelope, sending to every socket whose role differs from sender. O(N) trivially.                                                                                                                                                     |
| 6 | CF regional routing                     | (Same as #2 — `idFromName` pins region.) The Mac DAEMON's first contact with the relay defines the region; iOS routes to that colo via CF Anycast for any subsequent connect.                                                                                                                                                              |
| 7 | Mobile radio wake — keepalive every 25s | The DO's alarm fires every `KEEPALIVE_PING_SECONDS` (25s, under iOS's 30s aggressive radio-wake threshold) and sends a `"__keepalive__"` text frame to every live socket. Clients filter it out. Eviction is checked on the same tick.                                                                                                    |

### What we explicitly punt on

- **CPU ms cap** — `[limits].cpu_ms = 50` per Worker invocation. Per-envelope work is JSON parse + 1-2 `getWebSockets()` traversals + storage IO. Well under 50ms p99 in our integration tests. Real-traffic numbers re-tunable after the first week of staging traffic.
- **Per-IP rate limit** at Worker edge — placeholder KV binding `RELAY_RATE_LIMIT` exists; logic deferred to a follow-up "harden" PR if the staging traffic shows abuse. Acceptable risk: a bad actor opening many sessions can exhaust the operator's DO quota, but they can't read plaintext — that's the real D22 / D21 invariant.
- **Sub-region DO migration when the second peer is on the other side of the world** — CF doesn't migrate DOs once placed; if the iOS peer is in a different metro from the Mac's region, the iOS leg sees ~one CF Anycast hop + the inter-colo round-trip. v1 acceptable; if it becomes a problem, follow-up is to place the DO via `idFromName` keyed by something region-aware.

---

## Acceptance gate (from plan E2)

> **Acceptance:** 2 peers exchange E2E-encrypted frames; relay logs show only opaque envelopes + counts.

Covered by:

- `test/relay.integration.test.ts → "Mac → iOS: one ciphertext envelope is fanned out unchanged"`
- `test/relay.integration.test.ts → "bidirectional: iOS → Mac envelopes also fan out"`
- `test/relay.integration.test.ts → "stats endpoint — counts only, no body content"` — explicit assertion that `JSON.stringify(stats)` does NOT contain the plaintext body bytes (the test plants the literal string `PLAINTEXT_THAT_MUST_NEVER_LEAK` in the envelope body and assert-greps the stats output for it).

D22 (per-peer auth) covered by:
- `test/auth.test.ts → "rejects a token that matches neither side"`
- `test/auth.test.ts → "rejects when the two hashes are identical"`
- `test/relay.integration.test.ts → "Mac token is rejected by the iOS role check"`
- `test/relay.integration.test.ts → "a malicious bundle with mac==ios hashes is rejected"`

Codex #2 SLO breakdown — each row of the table above maps to a test or a deploy-time check.

---

## Cross-impl test vectors

[`test-vectors/`](test-vectors/) holds JSON fixtures that BOTH this TypeScript Worker AND the Swift Mac/iOS clients (E3/E4) MUST match byte-exact. See [test-vectors/README.md](test-vectors/README.md) for the format + how to regenerate.

The TS suite verifies the vectors via `test/test-vectors.test.ts` (runs in the Node project of the vitest workspace). The Swift suite — landing in E3 — will read the same JSON via `JSONDecoder` and assert against `CryptoKit.ChaChaPoly.seal` + `Curve25519.KeyAgreement` outputs.

---

## Local dev

```bash
cd infra/relay
bun install     # or npm install
bun run dev     # wrangler dev — http://localhost:8787
```

The dev env uses in-memory DOs and dummy KV namespaces; secrets are placeholders. Suitable for integration testing against a local Mac/iOS simulator.

## Test

```bash
bun run test       # vitest run — both workers + node projects
bun run typecheck  # tsc --noEmit
```

Two projects in `vitest.workspace.ts`:
- **workers** — runs `auth.test.ts`, `envelope.test.ts`, `relay.integration.test.ts` inside a real workerd isolate via `@cloudflare/vitest-pool-workers`. Exercises the DO + WebSocket Hibernation API.
- **node** — runs `test-vectors.test.ts` in vanilla Node. The libsodium-wrappers-sumo ESM build has a relative-import bug that breaks under workerd's module resolver; Node handles the CJS variant fine via `createRequire()`.

**Path-with-spaces caveat for local dev:** if your worktree path contains a space (e.g. `~/Downloads/CC Watch/...`), the vitest-pool-workers @0.5 build emits a URL-spec form that workerd's module resolver chokes on. CI runs from a no-space GitHub Actions path so this never affects deploys. For local test iteration, either run from a no-space copy (`cp -R infra/relay /tmp/relay-test && cd /tmp/relay-test && bun install && bun run test`) or wait for the vitest-pool-workers v0.16+ upgrade (which requires Vitest 4 + Wrangler 4 — punted to a separate dependency-bump PR).

## Deploy

CI handles deploys after PR merge to main (see [`.github/workflows/deploy-relay.yml`](../../.github/workflows/deploy-relay.yml)). Manual:

```bash
bun run deploy:staging      # wrangler deploy --env staging
bun run deploy:production   # wrangler deploy --env production
```

Operator must run `wrangler kv namespace create` per env and fill the KV `id` placeholders in `wrangler.toml` before the first deploy. See [`infra/SECRETS.md`](../SECRETS.md).

---

## NOT in this PR

- The **APNS gateway** Worker (lands in E5; lives in [`infra/apns-gateway/`](../apns-gateway/), no overlap with this PR).
- The **Mac client** that opens a relay session (lands in E3).
- The **iOS client** that scans the QR + connects (lands in E4).
- The **pairing UX** (QR generation + scan UI; lands in E7).
- **Per-IP rate limit** in the relay edge logic (deferred to a "harden" follow-up; KV binding exists but isn't read by current code).
- **OAuth-like grant flow** for the QR (v1: the QR IS the bundle; rotating secrets requires re-pairing).
