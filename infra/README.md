# Continuum Cloud Infra

Cloudflare Workers + Durable Objects supporting the **Mac ↔ iPhone secure pairing relay** (Group E from `.claude/plans/study-this-codebase-crystalline-shore.md`) plus the **APNS push gateway** that cuts plan-approval latency from minutes to ~2s.

Design doc: [`docs/design/secure-relay-apns-2026-05-26.md`](../docs/design/secure-relay-apns-2026-05-26.md).

## Subdirectories

| Path | Worker | Purpose |
|---|---|---|
| `relay/` | `clawdmeter-relay` | WebSocket relay over E2E-encrypted envelopes. One Durable Object per pairing session. Lands in **E2**. |
| `apns-gateway/` | `clawdmeter-apns-gateway` | Holds operator Apple `.p8`; signs APNS JWT; forwards encrypted push payloads to Apple APNS HTTP/2. Lands in **E5**. |

Each Worker has its own `wrangler.toml`, dependency manifest, `src/`, and `test/` directories.

## E0 — what this PR ships

This is the **infra scaffold** (codex eng-review finding #6, folded into E0). Lands before E2 + E5 so the Workers ship into a known-good environment with:

- Per-env (`development` / `staging` / `production`) `wrangler.toml` for both Workers
- CI deploy gates in `.github/workflows/deploy-relay.yml` + `deploy-apns-gateway.yml`:
  - PR check: `wrangler deploy --dry-run`
  - Merge to main: deploy to `staging`, run smoke test, then prompt-gate the `production` deploy via GitHub Actions environment protection
- Secret provisioning playbook in [`infra/SECRETS.md`](SECRETS.md) — what secrets each Worker needs, how to rotate, who holds the keys
- Observability hooks: `wrangler tail` instructions, Worker Analytics dashboard targets
- Cost guardrails: per-Worker `[limits]` block in `wrangler.toml` (e.g. CPU ms cap)
- Custom domain plan (deferred to E2/E5 deploys but documented here)

## E0 is not

- The Worker source code. That lives in `src/index.ts` under each subdir, landing in E2 + E5.
- The cross-impl test vectors. Those land alongside the Worker code in `relay/test-vectors/`.
- The Mac/iOS client wiring (E3/E4/E6).

## Local dev

```bash
# Install once
bun install

# Spin up the relay locally on http://localhost:8787
cd infra/relay
bun run dev   # wrangler dev under the hood

# Spin up the APNS gateway locally
cd infra/apns-gateway
bun run dev
```

Both Workers default to the `development` env (in-memory Durable Object;
no APNS production credentials needed for the relay; the APNS gateway uses
the Apple **sandbox** APNS endpoint in development).

## Staging + production deploy

CI handles deploys after PR merge to main. Manual deploy works via:

```bash
cd infra/relay
bun run deploy:staging      # wrangler deploy --env staging
bun run deploy:production   # wrangler deploy --env production
```

## Owner handoff

Operator: see [`SECRETS.md`](SECRETS.md). Single-operator deployment for v1 (no federation). Each operator runs their own pair of Workers; the Mac + iOS clients hard-code the operator's relay URL via build-time env var (defaults to the official Continuum cloud).
