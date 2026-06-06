# clawdmeter-apns-gateway

Cloudflare Worker that signs APNS JWTs and forwards **opaque encrypted push payloads** from the Mac daemon to Apple's APNS HTTP/2 endpoint. Plan row **E5** of the Continuum perf/relay/backend plan.

The gateway is the only component that holds the operator's `.p8`. The Mac never sees it; the iPhone never sees it; Apple validates it on every push.

> **Crypto invariant:** the Worker never decrypts the payload body. Only the paired iPhone has the symmetric key (derived at pairing time via X25519 ECDH between Mac + iPhone). The gateway sees: device token, topic, opaque ciphertext, audit metadata. That's it.

For the higher-level design + threat model, see [`../../docs/design/secure-relay-apns-2026-05-26.md`](../../docs/design/secure-relay-apns-2026-05-26.md). For routine + emergency `.p8` rotation, owner handoff, canary deploy, see [`ROTATION.md`](ROTATION.md).

## Endpoints

| Method   | Path             | Purpose |
|---------|------------------|---------|
| `POST`  | `/push`          | Validate + auth + rate-limit + audit + sign + forward to APNS |
| `DELETE`| `/device-token`  | Opt-out (codex #5) — purge a hashed device token row given a signed proof |
| `GET`   | `/health`        | Liveness + `.p8`-age probe (used by the rotation-drill CI job) |
| `OPTIONS` | (any)          | CORS preflight |

### `POST /push` request shape

```json
{
  "deviceToken": "<64-hex-char APNS token>",
  "encryptedPayload": "<base64/base64url opaque ciphertext, max 3500 chars>",
  "topic": "ai.continuum.ios",
  "sessionId": "<pairing-session-id, [A-Za-z0-9_-]{8,128}>",
  "senderMacFingerprint": "<64-hex SHA-256 of Mac pairing pubkey>",
  "priority": 10,
  "pushType": "alert",
  "collapseId": "plan-123",
  "expiration": 0
}
```

Headers required:

- `authorization: Bearer <token>` — see "Auth model" below
- `content-type: application/json`

Responses:

| Status | Body | Why |
|---|---|---|
| 200 | `{ ok, apnsId }` | Apple accepted the push |
| 400 | `{ error: "bad-request", reason, field? }` | Schema validation failed |
| 401 | `{ error: "unauthorized", reason }` | Bearer missing/invalid |
| 403 | `{ error: "forbidden" }` | Cross-tenant attempt — token bound to a different session |
| 410 | `{ error: "unregistered" }` | APNS says the token is dead; we purged it |
| 429 | `{ error: "rate-limited", retry_after_seconds }` | Per-device limit (60/h) tripped |
| 502 | `{ error: "apns-server-error" \| "transport-error" }` | Upstream failure |
| 503 | `{ error: "service-unavailable" }` | Kill-switch active |

### `DELETE /device-token` request shape

```json
{
  "deviceToken": "<64-hex>",
  "sessionId": "<pairing-session-id>",
  "signature": "<base64url HMAC-SHA256(SIGNING_KEY, 'optout:' + sessionId + ':' + deviceToken)>"
}
```

Returns `200 { ok: true, purged: true }` on success, `401` if the signature doesn't verify.

### `GET /health`

```json
{
  "ok": true,
  "env": "production",
  "killSwitch": false,
  "apnsEndpoint": "https://api.push.apple.com",
  "topicEnv": "production",
  "p8IssuedAtValid": true,
  "p8AgeSeconds": 1234567,
  "p8MaxAgeSeconds": 7776000,
  "p8Stale": false
}
```

Returns `503` instead of `200` when `APNS_P8_ISSUED_AT` is missing/invalid/future or when `p8Stale === true`. The rotation-drill CI job at `.github/workflows/deploy-apns-gateway.yml` polls this and fails the build to nag the operator.

## Auth model (matches E2 relay)

Bearer token = versioned HMAC-SHA256, with the message bound to the pairing session id, Mac fingerprint, issue time, and one-use nonce:

```
token = "v1." + issuedAtSeconds + "." + nonce + "." +
        base64url( HMAC-SHA256( RELAY_BEARER_SIGNING_KEY,
                                "apns:" + sessionId + ":" + senderMacFingerprint + ":" +
                                issuedAtSeconds + ":" + nonce ) )
```

`RELAY_BEARER_SIGNING_KEY` is shared between the relay Worker and this gateway, so the per-peer token issued to the Mac at pairing time (see design doc §4.1) authorizes BOTH the relay WebSocket open AND the APNS gateway POST. The Mac client derives a fresh short-lived bearer per request; the gateway rejects expired tokens and consumes each nonce once to prevent replay.

The shape of `expectedTokenMessage` is exported from `src/auth.ts#expectedTokenMessage` for cross-impl parity tests with the Mac/iOS Swift client.

## Security invariants enforced

| # | Invariant | Where |
|---|---|---|
| D21.1 | Per verified sender identity rate limit (60/h, configurable) | `src/rate-limit.ts` + `RATE_LIMIT_PER_HOUR` var |
| D21.2 | Audit log — `(ts, deviceTokenHash, sender-fingerprint, payload-size)`, **no plaintext** | `src/audit-log.ts` + `APNS_AUDIT_LOG` KV |
| D21.3 | Schema validation rejects malformed POSTs | `src/schema.ts` |
| D21.4 | Rotation playbook | [ROTATION.md](ROTATION.md) |
| D21.5 | Kill-switch (`APNS_DISABLED=true`) returns 503 | `src/index.ts` + `isKillSwitchOn` |
| C#4.1 | Sandbox vs production routing (`TOPIC_ENV` + `APNS_ENDPOINT`) | `wrangler.toml` envs |
| C#4.2 | Team/key/topic separation (3 distinct secrets) | `wrangler.toml` + `ROTATION.md` |
| C#4.3 | Canary deploy (`wrangler deploy --env canary`) | `wrangler.toml [env.canary]` |
| C#4.4 | Rotation drill — CI fails if `.p8` >90 days old | `GET /health` + workflow |
| C#4.5 | Rollback documented | [ROTATION.md](ROTATION.md#rollback) |
| C#4.6 | Owner handoff documented | [ROTATION.md](ROTATION.md#owner-handoff) |
| C#5.1 | Hashed-only storage (SHA-256 device tokens) | `src/device-tokens.ts` |
| C#5.2 | Tenant binding (token → sessionId) | `src/device-tokens.ts` + `APNS_DEVICE_TOKENS` KV |
| C#5.3 | Stale-token cleanup on APNS 410 | `src/index.ts` push handler |
| C#5.4 | Opt-out endpoint | `DELETE /device-token` |
| C#5.5 | Bearer auth (abuse prevention) | `src/auth.ts` |

## Local development

```bash
cd infra/apns-gateway
bun install
bun run typecheck   # tsc --noEmit
bun run test        # vitest run
bun run dev         # wrangler dev — uses sandbox APNS endpoint by default
```

For `wrangler dev` to forward to Apple's APNS sandbox you'll need real secrets. Create `.dev.vars`:

```
APNS_P8_KEY="-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEG..."
APNS_P8_ISSUED_AT="1700000000"
APNS_KEY_ID="ABCD123456"
APNS_TEAM_ID="WXYZ987654"
APNS_TOPIC_PRODUCTION="ai.continuum.ios"
APNS_TOPIC_SANDBOX="ai.continuum.ios"
RELAY_BEARER_SIGNING_KEY="<32-byte base64>"
APNS_BEARER_TTL_SECONDS="300"
```

`.dev.vars` is in `.gitignore`. Never commit secrets.

## Deploy

```bash
# Per-env (uses wrangler.toml's [env.<name>] block)
bun run deploy:staging
bun run deploy:production
bun run deploy:canary
```

CI gates: PRs touching `infra/apns-gateway/**` get a `wrangler deploy --dry-run` against staging; merges to `main` auto-deploy staging; production needs a `workflow_dispatch` with the GitHub Environment "production" reviewer (operator) approval. See `.github/workflows/deploy-apns-gateway.yml`.

## Files

- `src/index.ts` — router + push/opt-out/health handlers
- `src/apns-client.ts` — ES256 JWT signing + HTTP/2 send to Apple
- `src/auth.ts` — bearer issuance + verification (HMAC, matches E2 relay)
- `src/audit-log.ts` — D21 audit entry shape + KV/Logs writer
- `src/crypto-utils.ts` — Web Crypto helpers (no Node.js APIs)
- `src/device-tokens.ts` — codex #5 hashed-token registry + tenant binding
- `src/env.ts` — env binding types + accessors (kill-switch, rate-limit, TTLs)
- `src/rate-limit.ts` — D21 per verified sender identity hourly counter
- `src/schema.ts` — hand-rolled request validators (no zod — zero deps in bundle)
- `test/` — vitest suite covering every invariant above
- `wrangler.toml` — Worker config (4 envs: dev / staging / production / canary)
- `ROTATION.md` — `.p8` rotation drill (routine + emergency) + rollback + owner handoff

## Owner + escalation

Operator owns the Apple Developer account, the Cloudflare account, and all `wrangler secret`s. See [`../SECRETS.md`](../SECRETS.md) for the secret provisioning playbook and [`ROTATION.md`](ROTATION.md#owner-handoff) for the transfer checklist when ownership changes.

Escalation path for emergencies (suspected `.p8` compromise, APNS outage propagation):

1. Operator: flip kill-switch via `wrangler secret put APNS_DISABLED --value true --env production`
2. Operator: tail Workers Logs (`wrangler tail --env production --format json | jq 'select(.kind=="audit")'`) and replay the last 24h of audit entries
3. Operator: issue a fresh `.p8` per [ROTATION.md](ROTATION.md#emergency-p8-rotation)
4. Operator: notify users via the in-app banner endpoint (see relay Worker E2)

## Plan reference

E5 (Phase 2) + D21 mitigation suite + Codex #4 ops model + Codex #5 device-token egress — see `.claude/plans/study-this-codebase-crystalline-shore.md`.
