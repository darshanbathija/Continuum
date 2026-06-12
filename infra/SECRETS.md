# Continuum Cloud — Secret Provisioning + Rotation Playbook

E0 (Phase 0) — infra prep that gates E2 (relay) and E5 (APNS gateway). The Worker source code lands in those PRs; this doc defines what secrets each Worker needs, how to rotate them, and who holds the keys.

## Cloudflare account setup

**Account holder:** operator (one Cloudflare account per Continuum deployment; the official Continuum cloud + any self-hosted operator each own their own).

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
| `RELAY_OPERATOR_SIGNING_KEY` | Signs first-peer relay session creation bundles so clients cannot create arbitrary DO sessions | Annual | 32 random bytes (base64). Keep this Worker-side except for local operator fallback via `CLAWDMETER_RELAY_OPERATOR_SIGNING_KEY`. |
| `RELAY_CREATION_GRANT_TOKEN` | Authorizes `/creation-grant` callers before the relay signs a first-connect proof | Quarterly / incident-driven | 32+ random bytes. Provision approved Macs with the same value via `CLAWDMETER_RELAY_CREATION_GRANT_TOKEN`; never embed it in the shipped app bundle. |
| `RELAY_CLIENT_PROVISIONING_KEY` | Lets shipped Mac apps auto-provision per-install grant tokens via `POST /v1/relay/provision/grant-token` | Annual / incident-driven | 32 random bytes (base64). Must match the client key baked into Mac release builds (or `CLAWDMETER_RELAY_CLIENT_PROVISIONING_KEY` for dev). Rate-limited per install id; not interchangeable with `RELAY_CREATION_GRANT_TOKEN`. |

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
| `APNS_P8_KEY` | Apple `.p8` private key (PEM) for the selected APNS endpoint | Annual (Apple-recommended) | Issued from Apple Developer portal under operator's team |
| `APNS_P8_ISSUED_AT` | Unix-seconds timestamp for the active `.p8` key | When `.p8` rotates | `/health` returns 503 when this is missing, invalid, future-dated, or stale. |
| `APNS_KEY_ID` | 10-char Apple key identifier paired with the `.p8` | When the `.p8` rotates | Stamped into APNS JWT `kid` claim |
| `APNS_TEAM_ID` | 10-char Apple Team ID | Rare (only if operator's Apple team changes) | Stamped into APNS JWT `iss` claim |
| `APNS_TOPIC_PRODUCTION` | Bundle ID for production iOS + Watch (e.g. `ai.continuum.ios`) | Never (bundle ID is structural) | |
| `APNS_TOPIC_SANDBOX` | Bundle ID for sandbox builds | Never | |
| `APNS_DISABLED` | Single flag (truthy string). When true, gateway returns 503 to every send. | Set in emergencies | Lets us stop all pushes in <30s if the `.p8` is suspected compromised. |
| `RELAY_BEARER_SIGNING_KEY` | Signs short-lived APNS gateway bearer tokens and opt-out requests | Annual / incident-driven | 32 random bytes (base64). Must match the operator Mac's APNS gateway signing key. |

Per-env Cloudflare KV namespaces:

| Binding | Purpose | TTL strategy |
|---|---|---|
| `APNS_AUDIT_LOG` | Every send: `(timestamp, deviceTokenHash, senderMacFingerprint, bundleId, deliveryStatus)` | 90 days auto-purge |
| `APNS_RATE_LIMIT` | Per verified sender identity send counter plus one-use APNS bearer nonce registry | 1 hour rolling window for counters; bearer TTL + skew for nonce keys |

## Rotation playbook

### Routine `.p8` rotation (annual)

1. Generate a new `.p8` from the [Apple Developer portal → Keys](https://developer.apple.com/account/resources/authkeys/list) under the operator's Apple team
2. Get the new `kid` (Apple displays it on the keys page)
3. `wrangler secret put APNS_P8_KEY --env production` — paste the new PEM
4. `wrangler secret put APNS_KEY_ID --env production` — set to the new `kid`
5. `wrangler secret put APNS_P8_ISSUED_AT --env production` — set to the Unix seconds when the key was issued/imported
6. `wrangler deploy --env production`
7. Sanity-send: trigger a test push from a paired Mac → verify lock-screen delivery within 2s
8. Revoke the OLD `kid` in the Apple Developer portal **only after** 24h with no rollback
9. Repeat for `--env staging` against the sandbox endpoint

### Emergency `.p8` rotation (suspected compromise)

Per D21 mitigation suite — target: rotation within 1h of detection.

> **Never** put secret values on the command line (e.g. `--value <secret>`).
> Wrangler's `secret put` does not accept `--value`; the supported flows
> are the interactive prompt or piping via stdin. Anything on argv lands
> in shell history and the process table.

1. Flip the killswitch — pipe the value via stdin to keep it out of shell
   history:
   ```bash
   printf 'true' | wrangler secret put APNS_DISABLED --env production
   ```
   Gateway then returns 503 for every send.
2. `wrangler tail --env production` — observe the rejection rate; confirm killswitch is active
3. Replay the `APNS_AUDIT_LOG` from the past 30 days to identify any forged sends since suspected compromise window:
   ```bash
   wrangler kv key list --binding=APNS_AUDIT_LOG --env production | \
     jq -r '.[].name' | xargs -I {} wrangler kv key get {} --binding=APNS_AUDIT_LOG --env production
   ```
4. Issue a fresh `.p8` via the Apple portal; set `APNS_P8_KEY` + `APNS_KEY_ID` + `APNS_P8_ISSUED_AT` per the routine playbook (paste PEM at the interactive prompt — do NOT echo it on the command line)
5. Disable the killswitch (same stdin-pipe pattern):
   ```bash
   printf 'false' | wrangler secret put APNS_DISABLED --env production
   ```
6. Notify affected users via in-app banner (Continuum daemon polls a Worker `/notice` endpoint to surface operator-side advisories)

## CI deploy gates

CI uses Wrangler OAuth credentials from a machine where `wrangler login` has been run. Provisioned by:

```bash
./tools/setup-cloudflare-github-secrets.sh
```

That script reads `wrangler auth token` + the refresh token from `~/.wrangler/config/default.toml`, verifies with `wrangler deploy --dry-run`, and stores:

- `CLOUDFLARE_API_TOKEN` — current OAuth access token (optional bootstrap; CI refreshes it)
- `CLOUDFLARE_OAUTH_REFRESH_TOKEN` — long-lived refresh token (primary CI credential)
- `CLOUDFLARE_ACCOUNT_ID` — from `wrangler whoami` (`1bad887b43fb6dbb2e08757324d7afe1`)

Deploy workflows source `tools/cloudflare-ci-auth.sh` to exchange the refresh token for a fresh access token before each `wrangler deploy`.

Manual override (Account API token from the dashboard) still works:

```bash
CLOUDFLARE_API_TOKEN='<paste token>' ./tools/setup-cloudflare-github-secrets.sh
```

The CI workflows in `.github/workflows/deploy-relay.yml` + `deploy-apns-gateway.yml` consume these.

Production deploys are gated by a GitHub Environment named `production` with required reviewer approval (the operator). Staging deploys auto-fire on every merge to main.

## Owner handoff checklist

When transferring operator ownership (e.g. company sale, project transfer):

- [ ] Transfer Cloudflare account ownership (Account → Members → Transfer)
- [ ] Rotate ALL secrets above (treat the prior operator as compromised by default)
- [ ] Rotate `.p8` (issue new from new operator's Apple Developer team)
- [ ] Update Mac + iOS client builds with new relay/gateway URLs if they're hosted under a different domain
- [ ] Update DNS for `relay.clawdmeter.dev` + `apns-gateway.clawdmeter.dev` (or operator equivalents)
- [ ] Notify users in-app of the operator change (Continuum daemon poll endpoint described above)
