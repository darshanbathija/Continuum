# clawdmeter-apns-gateway — Rotation, Rollback, Canary, Owner Handoff

This is the on-call playbook for the operator. It covers:

1. [Routine `.p8` rotation (annual)](#routine-p8-rotation-annual)
2. [Emergency `.p8` rotation (suspected compromise)](#emergency-p8-rotation)
3. [Kill-switch](#kill-switch)
4. [Canary deploy](#canary-deploy)
5. [Rollback](#rollback)
6. [Owner handoff](#owner-handoff)
7. [Rotation drill CI job](#rotation-drill-ci-job)

The companion document `infra/SECRETS.md` enumerates the secrets each Worker needs. **This** doc is the runbook for changing them in anger.

---

## Routine `.p8` rotation (annual)

Target cadence: every 12 months. Apple does not auto-rotate `.p8` keys; this is the operator's call.

### Prerequisites

- Cloudflare account access with `Workers Scripts: Edit` scope
- Apple Developer account access to the operator's team
- `wrangler` installed locally (`npm i -g wrangler` or `bun add -g wrangler`)
- A second device on hand with a paired iPhone for the sanity-send

### Steps — production

```bash
# 1. Generate a new .p8 from the Apple Developer portal:
#    https://developer.apple.com/account/resources/authkeys/list
#    → "+" → name "clawdmeter-apns-<YYYYMM>" → Enable "Apple Push Notifications service (APNs)"
#    → Download the .p8 file (one-time download!)
#    → Note the 10-char Key ID Apple shows on the keys page

# 2. Stash the .p8 in your local password manager. NEVER commit it.

# 3. Push the new secrets to Cloudflare. wrangler reads PEM from stdin.
cd infra/apns-gateway
wrangler secret put APNS_P8_KEY --env production < ~/path/to/AuthKey_NEWKEYID.p8
wrangler secret put APNS_KEY_ID --env production
# wrangler prompts: paste "NEWKEYID" (10 chars)
wrangler secret put APNS_P8_ISSUED_AT --env production
# wrangler prompts: paste the current Unix-seconds. On macOS:
#   date -u +%s
# This timestamp drives the rotation-drill CI job (see below).

# 4. Deploy.
bun run deploy:production
# (or: wrangler deploy --env production)

# 5. Sanity send. From a paired Mac, trigger a plan-approval flow that
#    you expect to land on the paired iPhone. Verify the push arrives
#    on the lock screen in <2s.

# 6. Verify the rotation drill is happy.
curl https://apns-gateway.clawdmeter.dev/health | jq
# Expect: { "ok": true, "p8Stale": false, "p8AgeSeconds": <small> }

# 7. Revoke the OLD key in the Apple portal *only after* 24h with no rollback.
#    Apple immediately stops accepting JWTs signed with revoked keys.
```

### Steps — staging

Same flow, against the sandbox APNS endpoint:

```bash
wrangler secret put APNS_P8_KEY --env staging < ~/path/to/AuthKey_NEWKEYID_sandbox.p8
wrangler secret put APNS_KEY_ID --env staging
wrangler secret put APNS_P8_ISSUED_AT --env staging
bun run deploy:staging
curl https://apns-gateway-staging.clawdmeter.dev/health | jq
```

> **Two separate .p8 keys.** Production uses Apple's `api.push.apple.com`; staging uses `api.sandbox.push.apple.com`. The keys are not interchangeable; you'll get APNS 403s if you cross-wire them.

---

## Emergency `.p8` rotation

Trigger when there's any suspicion the `.p8` PEM has leaked (laptop stolen with the file, accidentally committed to git, Cloudflare account compromised).

Target SLO: kill-switch active within **5 minutes** of detection; new `.p8` deployed within **1 hour**.

```bash
# 0. STOP. Flip the kill-switch BEFORE anything else. This returns 503 to
#    every push attempt — including yours, including any push the attacker
#    is trying to forge.
cd infra/apns-gateway
wrangler secret put APNS_DISABLED --env production
# prompt: type "true"

# 1. Verify.
curl https://apns-gateway.clawdmeter.dev/health | jq
# Expect: { "ok": true, "killSwitch": true }
# Sanity-send a push from a paired Mac — should 503.

# 2. Tail the audit log for forensics. The audit log is the auth trail of
#    record — it has every push from the past 90 days with hashed token +
#    sender fingerprint + payload size + outcome.
wrangler tail --env production --format json | jq 'select(.kind=="audit")'
# Pipe to a file for incident review. Identify any "delivered" audit
# entries with sender-fingerprints you don't recognize.

# Optionally walk the KV-backed audit log for the past N days:
wrangler kv key list --binding=APNS_AUDIT_LOG --env production | \
  jq -r '.[].name' | head -1000 | \
  xargs -I {} wrangler kv key get {} --binding=APNS_AUDIT_LOG --env production

# 3. Generate a new .p8 per the routine playbook above (steps 1-4). This
#    REPLACES the compromised key.

# 4. UN-flip the kill-switch.
wrangler secret put APNS_DISABLED --env production
# prompt: type "false"

# 5. Sanity-send. Verify deliveries resume.

# 6. Revoke the OLD .p8 in the Apple portal IMMEDIATELY (not the 24h
#    grace from the routine rotation). Compromised key → no grace period.

# 7. Notify users. The relay Worker exposes an in-app banner endpoint
#    (see ../relay/README.md) — push an advisory describing what happened.
```

---

## Kill-switch

The kill-switch is a single env var the operator can flip at any time:

```bash
# On (returns 503 for every /push attempt):
wrangler secret put APNS_DISABLED --env production
# prompt: type "true"

# Off (resume normal operation):
wrangler secret put APNS_DISABLED --env production
# prompt: type "false"
```

Latency: secret writes propagate to all CF edges in <30s.

The kill-switch is plumbed through `src/env.ts#isKillSwitchOn` and accepts any truthy spelling (`true` / `1` / `on` / `yes`). It is checked **before** schema validation, auth, or rate-limit — so the operator can disable the gateway even if a buggy client is spamming malformed requests.

For non-emergency drills (e.g. a maintenance window), prefer the **non-secret** `APNS_DISABLED` var in `wrangler.toml` `[vars]`:

```toml
[env.production.vars]
APNS_DISABLED = "true"  # drill
```

…then `bun run deploy:production`. This is more visible in git history than `wrangler secret put`.

---

## Canary deploy

Codex #4 ops model: canary takes ~1% of traffic via a separate route. The wrangler config has a dedicated `[env.canary]` block; the load-balancer weighting is configured once via the Cloudflare dashboard.

### Deploying a canary

```bash
cd infra/apns-gateway
bun run deploy:canary
# (or: wrangler deploy --env canary)
```

This deploys to `apns-gateway-canary.clawdmeter.dev`. The route is registered as a custom domain; configure your Cloudflare Worker Routes (Dashboard → Workers Routes) so that 1% of `apns-gateway.clawdmeter.dev/*` traffic is routed to the canary script via a weighted rule.

### Promotion

After the canary has run clean for 24h (no 5xx, no audit anomalies):

```bash
bun run deploy:production
```

This deploys the same code to the production Worker. The canary route then drains naturally over the next eviction interval.

### Aborting a canary

```bash
# Easiest: flip the canary kill-switch only.
wrangler secret put APNS_DISABLED --env canary
# prompt: type "true"

# Or roll back the canary script:
wrangler rollback --env canary
```

---

## Rollback

```bash
cd infra/apns-gateway
wrangler rollback --env production
```

This reverts to the previous deployment. wrangler maintains the last ~10 deployments; verify with:

```bash
wrangler deployments list --env production
```

Pick a specific deployment id:

```bash
wrangler rollback <deployment-id> --env production
```

Rollback does NOT change `wrangler secret put` values — secrets persist across deploys. If a rotation is what triggered the breakage and you need to roll back to the **previous** `.p8`, you'll need to:

1. Roll back the script: `wrangler rollback --env production`
2. Restore the previous `APNS_P8_KEY` + `APNS_KEY_ID` + `APNS_P8_ISSUED_AT` from your password manager: `wrangler secret put APNS_P8_KEY --env production < ~/backup/old.p8` etc.

This is why step 7 of routine rotation says "revoke the old `.p8` only after 24h with no rollback".

---

## Owner handoff

When transferring operator ownership (project transfer, company sale, hand-off to a co-maintainer):

- [ ] Transfer the Cloudflare account ownership: Dashboard → My Profile → Members → Transfer
- [ ] Transfer the Apple Developer team ownership: developer.apple.com → People → Roles
- [ ] **Rotate ALL secrets** (treat the prior operator as compromised by default — even amicable handoffs):
  - `APNS_P8_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_P8_ISSUED_AT`
  - `APNS_TOPIC_PRODUCTION`, `APNS_TOPIC_SANDBOX` (if bundle IDs change)
  - `RELAY_BEARER_SIGNING_KEY` — coordinate with the relay Worker rotation
- [ ] Issue a fresh `.p8` under the NEW operator's Apple team
- [ ] Update Mac + iOS client builds with the new gateway URL if hosted under a different domain
- [ ] Update DNS for `apns-gateway.clawdmeter.dev` (operator-equivalent domain)
- [ ] Update GitHub repo secrets (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`)
- [ ] Update the GitHub Environments "staging" + "production" required-reviewer list
- [ ] Notify users via the in-app advisory banner (relay Worker `/notice` endpoint)
- [ ] Update `../SECRETS.md` "Account holder" line + this doc's escalation path
- [ ] Verify the rotation-drill CI job (next nightly) passes against the new `.p8`

---

## Rotation drill CI job

Codex #4 ops model requires a CI job that fails if the `.p8` is >90 days old. This is wired via:

1. `APNS_P8_ISSUED_AT` secret holds the Unix-seconds when the current `.p8` was provisioned (operator sets it during rotation).
2. `GET /health` compares it against `P8_MAX_AGE_SECONDS` (default 90 days). Returns 503 + `p8Stale: true` when stale.
3. A scheduled GitHub Action polls `/health` and fails the build if 503. Add to `.github/workflows/deploy-apns-gateway.yml` as a nightly job:

```yaml
rotation-drill:
  name: P8 freshness probe
  runs-on: ubuntu-24.04
  steps:
    - name: Probe production /health
      run: |
        resp=$(curl -sw '\n%{http_code}' https://apns-gateway.clawdmeter.dev/health)
        body=$(echo "$resp" | head -n -1)
        code=$(echo "$resp" | tail -n 1)
        echo "$body" | jq
        if [ "$code" != "200" ]; then
          echo "::error::APNS gateway /health returned $code — likely .p8 is stale"
          exit 1
        fi
```

(The deploy CI workflow scaffolded by E0 already wires the deploy + dry-run jobs; this nightly drill is a follow-up to add post-merge.)

When the drill fires, the operator runs the [routine rotation](#routine-p8-rotation-annual) playbook above.

---

## Plan reference

E5 + D21 mitigation suite + Codex #4 ops model — see `.claude/plans/study-this-codebase-crystalline-shore.md`.
