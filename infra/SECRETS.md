# Clawdmeter Cloud — Secret Provisioning + Rotation Playbook

E0 (Phase 0) — infra prep that gates E2 (relay) and E5 (APNS gateway). The Worker source code lands in those PRs; this doc defines what secrets each Worker needs, how to rotate them, and who holds the keys.

## Cloudflare account setup

**Account holder:** operator (one Cloudflare account per Clawdmeter deployment; the official Clawdmeter cloud + any self-hosted operator each own their own).

**Required Cloudflare features:**
- Workers (Paid plan recommended — Free covers dev but D1 + Durable Object + KV combined will hit Free-tier caps at ~10k users)
- Durable Objects (relay session state)
- Workers KV (APNS audit log + relay-session metadata; cheap, eventually consistent)
- Workers Logs (built-in observability)
- 2FA on the account itself (table-stakes per the threat model)
- Separate API tokens scoped to single-Worker deploys (no account-wide tokens for CI)

## Per-Worker secrets

### `clawdmeter-relay` Worker

Set via `wrangler secret put <NAME> --env <env>`:

| Secret | Purpose | Rotation cadence | Notes |
|---|---|---|---|
| `RELAY_OPERATOR_SIGNING_KEY` | HKDF salt for derived rate-limit keys + audit signatures | Annual | 32 random bytes (base64) |

Per-env Cloudflare KV namespaces (created via `wrangler kv namespace create`):

| Binding | Purpose | TTL strategy |
|---|---|---|
| `RELAY_AUDIT_LOG` | Audit trail of relay-session creations (per-peer Mac fingerprints, timestamps, region) | 90 days auto-purge |
| `RELAY_RATE_LIMIT` | Per-IP + per-Mac-fingerprint connection throttling | 1 hour rolling window |

Durable Object: `RelaySession` (one per pairing session; auto-evicts at 15-min idle).

### `clawdmeter-apns-gateway` Worker

Set via `wrangler secret put <NAME> --env <env>`:

| Secret | Purpose | Rotation cadence | Notes |
|---|---|---|---|
| `APNS_P8_KEY_PRODUCTION` | Apple `.p8` private key (PEM) for production APNS | Annual (Apple-recommended) | Issued from Apple Developer portal under operator's team |
| `APNS_P8_KEY_SANDBOX` | Apple `.p8` private key for sandbox APNS | Annual | Use sandbox for development + staging envs |
| `APNS_KEY_ID` | 10-char Apple key identifier paired with the `.p8` | When the `.p8` rotates | Stamped into APNS JWT `kid` claim |
| `APNS_TEAM_ID` | 10-char Apple Team ID | Rare (only if operator's Apple team changes) | Stamped into APNS JWT `iss` claim |
| `APNS_TOPIC_PRODUCTION` | Bundle ID for production iOS + Watch (e.g. `com.clawdmeter.iphone`) | Never (bundle ID is structural) | |
| `APNS_TOPIC_SANDBOX` | Bundle ID for sandbox builds | Never | |
| `APNS_KILL_SWITCH` | Single flag (string: `"on"` or `"off"`). When `"on"`, gateway returns 503 to every send. | Set in emergencies | Lets us stop all pushes in <30s if the `.p8` is suspected compromised. |

Per-env Cloudflare KV namespaces:

| Binding | Purpose | TTL strategy |
|---|---|---|
| `APNS_AUDIT_LOG` | Every send: `(timestamp, deviceTokenHash, senderMacFingerprint, bundleId, deliveryStatus)` | 90 days auto-purge |
| `APNS_RATE_LIMIT` | Per-device-token send counter (cap 100/hour per D21) | 1 hour rolling window |

## Rotation playbook

### Routine `.p8` rotation (annual)

1. Generate a new `.p8` from the [Apple Developer portal → Keys](https://developer.apple.com/account/resources/authkeys/list) under the operator's Apple team
2. Get the new `kid` (Apple displays it on the keys page)
3. `wrangler secret put APNS_P8_KEY_PRODUCTION --env production` — paste the new PEM
4. `wrangler secret put APNS_KEY_ID --env production` — set to the new `kid`
5. `wrangler deploy --env production`
6. Sanity-send: trigger a test push from a paired Mac → verify lock-screen delivery within 2s
7. Revoke the OLD `kid` in the Apple Developer portal **only after** 24h with no rollback
8. Repeat for `--env staging` against the sandbox endpoint

### Emergency `.p8` rotation (suspected compromise)

Per D21 mitigation suite — target: rotation within 1h of detection.

1. `wrangler secret put APNS_KILL_SWITCH --env production --value on` — immediate; gateway returns 503 for every send
2. `wrangler tail --env production` — observe the rejection rate; confirm killswitch is active
3. Replay the `APNS_AUDIT_LOG` from the past 30 days to identify any forged sends since suspected compromise window:
   ```bash
   wrangler kv key list --binding=APNS_AUDIT_LOG --env production | \
     jq -r '.[].name' | xargs -I {} wrangler kv key get {} --binding=APNS_AUDIT_LOG --env production
   ```
4. Issue a fresh `.p8` via the Apple portal; set `APNS_P8_KEY_PRODUCTION` + `APNS_KEY_ID` per the routine playbook
5. `wrangler secret put APNS_KILL_SWITCH --env production --value off`
6. Notify affected users via in-app banner (Clawdmeter daemon polls a Worker `/notice` endpoint to surface operator-side advisories)

## CI deploy gates

CI uses a scoped API token (Workers Scripts: Edit + KV: Edit, scoped to the two Worker names). Provisioned by:

1. Cloudflare Dashboard → My Profile → API Tokens → Create Token → "Edit Cloudflare Workers" template
2. Restrict scope to **specific account + specific scripts** (`clawdmeter-relay` + `clawdmeter-apns-gateway`)
3. Store in GitHub Actions secrets:
   - `CLOUDFLARE_API_TOKEN` (repo-scoped)
   - `CLOUDFLARE_ACCOUNT_ID` (repo-scoped)

The CI workflows in `.github/workflows/deploy-relay.yml` + `deploy-apns-gateway.yml` consume these.

Production deploys are gated by a GitHub Environment named `production` with required reviewer approval (the operator). Staging deploys auto-fire on every merge to main.

## Owner handoff checklist

When transferring operator ownership (e.g. company sale, project transfer):

- [ ] Transfer Cloudflare account ownership (Account → Members → Transfer)
- [ ] Rotate ALL secrets above (treat the prior operator as compromised by default)
- [ ] Rotate `.p8` (issue new from new operator's Apple Developer team)
- [ ] Update Mac + iOS client builds with new relay/gateway URLs if they're hosted under a different domain
- [ ] Update DNS for `relay.clawdmeter.dev` + `apns-gateway.clawdmeter.dev` (or operator equivalents)
- [ ] Notify users in-app of the operator change (Clawdmeter daemon poll endpoint described above)
