# APNS / Relay Cloud — Resume Checklist (2026-06)

Status as of this branch (`feat/apns-enablement`). The Cloudflare Worker
**code is done and green** — `apns-gateway` (70 tests) signs the ES256 APNS
JWT, seals payloads, enforces rate-limit + kill-switch + device-token egress;
`relay` (E2) carries E2E-encrypted envelopes over a Durable Object. CI for
staging deploys was wired in #187. What remains is **deployment + credential
wiring**, gated on two account-holder actions.

## Blockers (account-holder — only you can do these)

1. **Cloudflare auth on this machine.** wrangler is installed (4.98) but not
   logged in (no token, no `~/.wrangler` config). Do ONE of:
   - `! wrangler login` (browser, ~30s), or
   - authenticate the Cloudflare MCP via `/mcp` → "Cloudflare Developer Platform", or
   - export `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` (scoped: Workers Scripts Edit + KV Edit).

2. **Create the APNs Auth Key (.p8)** — this is the piece the Montauk dev
   account unblocks. Apple Developer → Certificates, IDs & Profiles → **Keys**
   → **+** → enable **"Apple Push Notifications service (APNs)"** → under the
   **Montauk Analytics Inc** team (`LRL8MRH6B4`). Download the `.p8`, note the
   10-char **Key ID**. NOTE: this is a *different* key from the App Store
   Connect API key (`AuthKey_PQT3B83PA3.p8`) — the ASC API cannot mint APNs keys.

## Then I can drive (once authed)

3. **KV namespaces** (replace the `REPLACE_WITH_*` placeholders in both
   `apns-gateway/wrangler.toml` and `relay/wrangler.toml`):
   ```
   cd infra/apns-gateway
   npx wrangler kv namespace create APNS_AUDIT_LOG      # + --preview ; repeat per env
   npx wrangler kv namespace create APNS_RATE_LIMIT
   npx wrangler kv namespace create APNS_DEVICE_TOKENS
   ```
4. **Secrets** (`wrangler secret put … --env staging|production`, values via
   stdin/prompt — never on argv):
   - `APNS_P8_KEY_SANDBOX` / `APNS_P8_KEY_PRODUCTION` = the new `.p8` PEM
   - `APNS_KEY_ID` = the 10-char Key ID
   - `APNS_TEAM_ID` = `LRL8MRH6B4`
   - `APNS_TOPIC_PRODUCTION` = `ai.continuum.ios`  (was com.clawdmeter.iphone)
   - `APNS_TOPIC_SANDBOX` = `ai.continuum.ios`
   - relay: `RELAY_OPERATOR_SIGNING_KEY` (32 random bytes b64)
   - the shared `RELAY_BEARER_SIGNING_KEY` that the Mac daemon uses to auth to the gateway
5. `npx wrangler deploy --env staging` (sandbox APNS) → smoke `/health` → then `--env production`.
6. Point the Mac/iOS build-time gateway URL at the deployed Worker host.

## Separate app-side work (the rest of `feat/apns-enablement`)

Even with the gateway live, the iOS/Watch app still needs:
- Enable **Push Notifications** capability on `ai.continuum.ios` + `…watchkitapp`
  App IDs; add `aps-environment` entitlement + `remote-notification` background mode.
- Wire `registerForRemoteNotifications` + forward the APNS device token to the
  gateway's device-token registry (today there is NO registration — only
  ActivityKit Live-Activity push tokens are observed).
- Flip the runtime off the **D15 local-notification fallback**
  (`iOSNotificationManager` + `BGAppRefreshTask`) onto the remote-push path.
- Re-provision the App Store profiles with the Push entitlement + re-archive.

## Today's actual notification behavior (so we don't regress it)

Local notifications via `UNUserNotificationCenter` + `BGAppRefreshTask` (D15),
plus in-process Live Activities. That keeps working until the APNS path is
switched on; the switch should be gated so a half-configured gateway never
silently drops notifications.
