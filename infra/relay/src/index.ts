// index.ts — clawdmeter-relay Worker entry point.
//
// Routes:
//   GET  /healthz                            → 200 ok (CF health probe + smoke test)
//   GET  /v1/relay/sessions/:sid/connect     → WebSocket upgrade; forwards to DO :sid
//   GET  /v1/relay/sessions/:sid/stats       → JSON aggregate counts (no body content)
//
// Cold start budget (Codex #2): <50ms p99. Keep this module's top-level work
// to essentially zero — no top-level awaits, no global JSON parsing. The DO
// module is the only "heavy" import, and it's tree-shaken to just type info
// at module load (the actual class instantiation happens per-request inside
// the workerd isolate).
//
// All HTTP responses include `cache-control: no-store` because the WS upgrade
// path is auth-stateful and any cache layer (browser, CF cache) would be
// catastrophic.

import { RelaySession, type RelayEnv } from "./durable-object";
import {
  deriveAPNSSessionSigningKey,
  isValidSessionCreationGrantRequest,
  issueSessionCreationProof,
  validateCreationGrantAuthorization,
  type SessionCreationGrantResponse,
} from "./auth";
import {
  checkProvisionRateLimit,
  isValidGrantProvisionRequest,
  issueDeviceGrantToken,
  validateDeviceGrantToken,
  validateGrantProvisionAuthorization,
} from "./provision";

export { RelaySession };

const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;

export default {
  async fetch(request: Request, env: RelayEnv, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // ----- /healthz -----
    if (url.pathname === "/healthz" && request.method === "GET") {
      return jsonResponse({ ok: true, env: env.ENVIRONMENT }, 200);
    }

    if (url.pathname === "/v1/relay/provision/grant-token") {
      return handleGrantProvision(request, env);
    }

    // ----- /v1/relay/sessions/:sid/connect | /stats | /creation-grant -----
    const match = /^\/v1\/relay\/sessions\/([^/]+)\/(connect|stats|creation-grant)$/.exec(url.pathname);
    if (match) {
      const sid = match[1];
      const action = match[2];

      if (!SESSION_ID_PATTERN.test(sid)) {
        return textResponse("invalid session id", 400);
      }

      if (action === "creation-grant") {
        return handleCreationGrant(request, env, sid);
      }

      // CRITICAL: `idFromName(sid)` ensures BOTH peers land on the SAME DO,
      // and pins the DO to the colo of the first peer to request it.
      // (CF picks the colo closest to the first request.)
      const doId = env.RELAY_SESSIONS.idFromName(sid);
      const stub = env.RELAY_SESSIONS.get(doId);

      // Rewrite the URL so the DO sees a stable shape (`/connect` or
      // `/admin/stats`). Preserve the query string for `?bundle=...`.
      const innerPath = action === "connect" ? "/connect" : "/admin/stats";
      const innerUrl = `https://do.invalid${innerPath}${url.search}`;
      const innerRequest = new Request(innerUrl, request);
      innerRequest.headers.set("x-relay-session-id", sid);

      return stub.fetch(innerRequest);
    }

    return textResponse("not found", 404);
  },
};

async function handleCreationGrant(request: Request, env: RelayEnv, sid: string): Promise<Response> {
  if (request.method !== "POST") {
    return textResponse("method not allowed", 405);
  }
  const grantAuth = await validateCreationGrantAuthorization(
    env.RELAY_CREATION_GRANT_TOKEN,
    request.headers.get("authorization"),
    {
      provisioningKeyBase64: env.RELAY_CLIENT_PROVISIONING_KEY,
      validateDeviceGrantToken,
    }
  );
  if (!grantAuth.ok) {
    return textResponse(grantAuth.reason, grantAuth.status);
  }
  if (!env.RELAY_OPERATOR_SIGNING_KEY) {
    return textResponse("relay operator signing key is not configured", 500);
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return textResponse("invalid json body", 400);
  }
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (!isValidSessionCreationGrantRequest(body, nowSeconds)) {
    return textResponse("invalid creation grant request", 400);
  }
  const creation = await issueSessionCreationProof(
    env.RELAY_OPERATOR_SIGNING_KEY,
    sid,
    body,
    nowSeconds
  );
  const response: SessionCreationGrantResponse = { creation };
  if (env.RELAY_BEARER_SIGNING_KEY && body.senderMacFingerprint) {
    response.apnsSigningKey = await deriveAPNSSessionSigningKey(
      env.RELAY_BEARER_SIGNING_KEY,
      sid,
      body.senderMacFingerprint
    );
  }
  return jsonResponse(response, 201);
}

async function handleGrantProvision(request: Request, env: RelayEnv): Promise<Response> {
  if (request.method !== "POST") {
    return textResponse("method not allowed", 405);
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return textResponse("invalid json body", 400);
  }
  if (!isValidGrantProvisionRequest(body)) {
    return textResponse("invalid grant provision request", 400);
  }
  const nowSeconds = Math.floor(Date.now() / 1000);
  const auth = await validateGrantProvisionAuthorization(
    env.RELAY_CLIENT_PROVISIONING_KEY,
    request.headers.get("authorization"),
    body,
    nowSeconds
  );
  if (!auth.ok) {
    return textResponse(auth.reason, auth.status);
  }
  const rate = await checkProvisionRateLimit(env.RELAY_RATE_LIMIT, body.installId, nowSeconds);
  if (!rate.ok) {
    return textResponse(rate.reason, rate.status);
  }
  const grantToken = await issueDeviceGrantToken(env.RELAY_CLIENT_PROVISIONING_KEY!, body.installId);
  return jsonResponse({ grantToken }, 201);
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
  });
}

function textResponse(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain", "cache-control": "no-store" },
  });
}
