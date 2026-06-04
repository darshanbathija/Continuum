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

---

## 2026-06 UPDATE — cloud is LIVE

All 4 Workers deployed + healthy on `continuumai.workers.dev` (account `1bad887b…`):
- gateway: `clawdmeter-apns-gateway-staging` (sandbox) + `clawdmeter-apns-gateway` (prod, api.push.apple.com). APNs key `SZ9FYQ7BG5`, team `LRL8MRH6B4`, topic `ai.continuum.ios`. `/health` green, `.p8` loaded.
- relay: `clawdmeter-relay-staging` + `clawdmeter-relay` (Durable Object + KV + operator key).

App now points at these (APNSGatewayEnvironment + RelayEnvironment defaults → workers.dev). iOS has `aps-environment=production` + `remote-notification` background mode.

### Remaining last mile (to a real push)
1. **iOS device-token registration** (not yet wired): add a `UIApplicationDelegate` (via `@UIApplicationDelegateAdaptor`), call `registerForRemoteNotifications()` after notif-auth, implement `didRegisterForRemoteNotificationsWithDeviceToken` → forward the hex token to the **Mac daemon** over the relay/pairing channel. The Mac stores it (`APNSPushDeviceTokenStore`) and includes `deviceToken` in each gateway push request (the gateway registers it on first push — no separate endpoint).
2. **Enable Push on the App IDs**: `ai.continuum.ios` (+ `…watchkitapp`) → Capabilities → Push Notifications, then regenerate the App Store provisioning profiles so they carry the entitlement.
3. **Flip the path**: emit a real APNS push from the daemon's SessionEventWiring (plan-approval / done events) via `APNSGatewayClient`, keeping the D15 local path as the fallback when no device token is registered.
4. **Re-archive build 192** (manual signing, profiles with Push) → TestFlight; verify a lock-screen push end-to-end against the **production** gateway (TestFlight = production APNS).

---

## 2026-06 — precise remainder (Mac pipeline is DONE; iOS + pairing-key are the gap)

**Verified already built on the Mac (no work needed):**
- `MacAPNSPusher` emits pushes (called from `AppRuntime.swift:814`).
- `APNSGatewayClient` seals the payload (`APNSPayloadSealer`), signs the per-peer
  bearer (`APNSGatewayBearer.issueBearer`), POSTs `<gateway>/push`.
- `APNSPushDeviceTokenStore` + daemon endpoint **`POST /devices/apns-token`**
  (body `{deviceToken:64hex, bundleId, sessionId}`) — receives the iPhone token.
- `APNSGatewaySettings` toggles (pushEnabled, notifyOnPlanApproval/SessionDone/…).

**Gap 1 — iOS device-token registration (only missing app code):**
- Add `@UIApplicationDelegateAdaptor` to `ClawdmeteriOSApp`; in
  `didRegisterForRemoteNotificationsWithDeviceToken`, hex-encode the token and
  call a new `AgentControlClient.registerAPNSDeviceToken(hexToken:bundleId:sessionId:)`
  that POSTs to `/devices/apns-token` (mirror `ackNotifications`, line ~2759).
- Call `UIApplication.shared.registerForRemoteNotifications()` right after
  `notifManager.requestAuthorizationIfNeeded()` (`ContentView.swift:46`).
- `bundleId = "ai.continuum.ios"`, `sessionId = the pairing session id`.

**Gap 2 — bearer-key coordination (CRITICAL, or the gateway 401s the Mac):**
- The Mac's `RELAY_BEARER_SIGNING_KEY` is **learned over the relay at pairing
  (E3)** via `APNSGatewaySigningKeyProvider` (dev override:
  `CLAWDMETER_RELAY_BEARER_SIGNING_KEY` env). The gateway Worker's
  `RELAY_BEARER_SIGNING_KEY` secret (currently a RANDOM value I set) must equal
  what the relay hands the Mac. Verify the relay's pairing handshake distributes
  the gateway's key (read `infra/relay/src` + `RelayPairingService.swift`); for a
  quick dev test, set the SAME base64 on the Mac (`CLAWDMETER_RELAY_BEARER_SIGNING_KEY`)
  and the gateway secret.

**Gap 3 — Apple:** enable Push on `ai.continuum.ios` (+ watch) App IDs, regen
the App Store profiles, re-archive build 192 (manual signing) → TestFlight.

**Gap 4 — verify on device:** pair iPhone → background app → trigger a
plan-approval/done event on the Mac → confirm lock-screen push (TestFlight =
PRODUCTION gateway). Watch `wrangler tail --env production` for the send.

---

## 2026-06-05 — ALL 4 DONE (push live; device-verify is the only remainder)

1. **Bearer key** ✅ one 32-byte base64url key set on gateway Worker secret
   `RELAY_BEARER_SIGNING_KEY` (staging+prod) + operator Mac
   `launchctl setenv CLAWDMETER_RELAY_BEARER_SIGNING_KEY` (relaunch Mac app to
   apply; not reboot-durable → LaunchAgent for permanence later).
2. **iOS registration** ✅ iOSAppDelegate + APNSDeviceTokenHolder →
   POST /devices/apns-token (pairing sid). iOS+shared build green. Watch n/a.
3. **Push capability** ✅ enabled PUSH_NOTIFICATIONS on ai.continuum.ios
   (`259XLR2PR8`) via ASC API (was missing — the root cause). Profile regen
   folded into the archive (Automatic signing + -allowProvisioningUpdates).
4. **Archive→TestFlight** ✅ build 192 archived/exported/uploaded
   (Delivery UUID 39e18db2-…; app signed with aps-environment). Processing.

**User-only remaining:** relaunch Mac app → install TF build 192 on the paired
iPhone → grant notif perms + pair → background → trigger a plan-approval/done
on the Mac → confirm the lock-screen push. `wrangler tail --env production`
on clawdmeter-apns-gateway shows the send.
