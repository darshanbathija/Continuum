// clawdmeter-apns-gateway — Apple Push Notification gateway Worker (E5)
//
// Responsibilities:
//  - POST /push: validate, auth, rate-limit, audit, sign+forward to APNS
//  - DELETE /device-token: opt-out endpoint (codex #5)
//  - GET /health: liveness + .p8-age probe for the rotation-drill CI job
//
// All security invariants live in their respective modules and are exercised
// by the integration tests under test/. See README + ROTATION.md for ops.

import { sendApnsPush, buildApnsJwt } from "./apns-client.js";
import { writeAudit, makeAuditEntry } from "./audit-log.js";
import { verifyBearer } from "./auth.js";
import { isKillSwitchOn, p8MaxAgeSeconds } from "./env.js";
import type { Env } from "./env.js";
import {
  bindDeviceToken,
  hashDeviceToken,
  purgeDeviceToken,
} from "./device-tokens.js";
import { checkRateLimit } from "./rate-limit.js";
import {
  validateOptOutRequest,
  validatePushRequest,
} from "./schema.js";
import {
  base64UrlEncode,
  verifyHmacSha256Base64,
} from "./crypto-utils.js";

interface HandlerContext {
  readonly env: Env;
  readonly ctx: ExecutionContext;
  readonly requestId: string;
  readonly nowSeconds: number;
}

function newRequestId(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

function jsonResponse(status: number, body: unknown, requestId: string): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "x-request-id": requestId,
      // Tight CORS: only the Mac daemon POSTs here, but allow operator
      // tooling from any origin to GET /health.
      "access-control-allow-origin": "*",
    },
  });
}

/* ============================================================
 * POST /push
 * ============================================================ */
async function handlePush(req: Request, hc: HandlerContext): Promise<Response> {
  const { env, requestId, nowSeconds } = hc;

  // D21 mitigation suite — kill switch short-circuits everything.
  if (isKillSwitchOn(env)) {
    await writeAudit(
      env,
      makeAuditEntry(env, { outcome: "rejected-kill-switch", requestId }),
    );
    return jsonResponse(
      503,
      { error: "service-unavailable", reason: "kill-switch active" },
      requestId,
    );
  }

  // Parse body.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    await writeAudit(
      env,
      makeAuditEntry(env, { outcome: "rejected-schema", requestId }),
    );
    return jsonResponse(400, { error: "bad-request", reason: "invalid JSON" }, requestId);
  }

  // Schema validation (D21 mitigation suite).
  const validation = validatePushRequest(body, env);
  if (!validation.ok) {
    await writeAudit(
      env,
      makeAuditEntry(env, { outcome: "rejected-schema", requestId, reason: validation.error }),
    );
    return jsonResponse(
      400,
      { error: "bad-request", reason: validation.error, field: validation.field },
      requestId,
    );
  }
  const push = validation.value;

  // Bearer auth (codex #5 abuse prevention; matches E2 relay).
  const auth = await verifyBearer(env, req.headers.get("authorization"), {
    sessionId: push.sessionId,
    senderMacFingerprint: push.senderMacFingerprint,
  });
  if (!auth.ok) {
    await writeAudit(
      env,
      makeAuditEntry(env, {
        outcome: "rejected-auth",
        requestId,
        sessionId: push.sessionId,
        senderMacFingerprint: push.senderMacFingerprint,
        reason: auth.reason,
      }),
    );
    return jsonResponse(401, { error: "unauthorized", reason: auth.reason }, requestId);
  }

  // Hash the device token before ANY persistence (codex #5 storage rule).
  const deviceTokenHash = await hashDeviceToken(push.deviceToken);

  // Tenant binding (codex #5). First push registers the token under the
  // session; subsequent pushes must come from the same session.
  const binding = await bindDeviceToken(
    env,
    deviceTokenHash,
    push.sessionId,
    push.senderMacFingerprint,
    nowSeconds,
  );
  if (binding.kind === "cross-tenant") {
    await writeAudit(
      env,
      makeAuditEntry(env, {
        outcome: "rejected-cross-tenant",
        requestId,
        deviceTokenHash,
        senderMacFingerprint: push.senderMacFingerprint,
        sessionId: push.sessionId,
        reason: `token bound to session ${binding.existing.sessionId.slice(0, 8)}…`,
      }),
    );
    return jsonResponse(
      403,
      { error: "forbidden", reason: "device token bound to a different pairing session" },
      requestId,
    );
  }

  // Rate limit (D21 mitigation suite — 60/h/device).
  const decision = await checkRateLimit(env, deviceTokenHash, nowSeconds);
  if (!decision.allowed) {
    await writeAudit(
      env,
      makeAuditEntry(env, {
        outcome: "rejected-rate-limit",
        requestId,
        deviceTokenHash,
        senderMacFingerprint: push.senderMacFingerprint,
        sessionId: push.sessionId,
        reason: `used ${decision.used}/${decision.limit} in current hour`,
      }),
    );
    return new Response(
      JSON.stringify({
        error: "rate-limited",
        reason: `device exceeded ${decision.limit}/hour`,
        retry_after_seconds: decision.resetSeconds,
      }),
      {
        status: 429,
        headers: {
          "content-type": "application/json; charset=utf-8",
          "x-request-id": requestId,
          "retry-after": String(decision.resetSeconds),
          "x-ratelimit-limit": String(decision.limit),
          "x-ratelimit-remaining": String(Math.max(0, decision.limit - decision.used)),
          "x-ratelimit-reset": String(nowSeconds + decision.resetSeconds),
        },
      },
    );
  }

  // Sign JWT + forward to APNS.
  let jwt: string;
  try {
    jwt = await buildApnsJwt({
      p8Pem: env.APNS_P8_KEY,
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
      nowSeconds,
    });
  } catch (e) {
    await writeAudit(
      env,
      makeAuditEntry(env, {
        outcome: "apns-server-error",
        requestId,
        deviceTokenHash,
        senderMacFingerprint: push.senderMacFingerprint,
        sessionId: push.sessionId,
        reason: `jwt-sign-failed: ${e instanceof Error ? e.message : String(e)}`,
      }),
    );
    return jsonResponse(
      500,
      { error: "internal-error", reason: "could not sign APNS JWT" },
      requestId,
    );
  }

  const result = await sendApnsPush({
    endpoint: env.APNS_ENDPOINT,
    jwt,
    deviceToken: push.deviceToken,
    topic: push.topic,
    encryptedPayload: push.encryptedPayload,
    priority: push.priority,
    pushType: push.pushType,
    collapseId: push.collapseId,
    expiration: push.expiration,
  });

  const auditBase = {
    requestId,
    deviceTokenHash,
    senderMacFingerprint: push.senderMacFingerprint,
    sessionId: push.sessionId,
    payloadSize: push.encryptedPayload.length,
  };

  switch (result.kind) {
    case "delivered": {
      await writeAudit(
        env,
        makeAuditEntry(env, {
          ...auditBase,
          outcome: "delivered",
          apnsId: result.apnsId,
          apnsStatus: 200,
        }),
      );
      return jsonResponse(
        200,
        { ok: true, apnsId: result.apnsId },
        requestId,
      );
    }
    case "unregistered": {
      // Codex #5 stale-token cleanup — purge the row.
      await purgeDeviceToken(env, deviceTokenHash);
      await writeAudit(
        env,
        makeAuditEntry(env, {
          ...auditBase,
          outcome: "apns-unregistered",
          apnsStatus: 410,
          reason: "purged hashed token from registry",
        }),
      );
      return jsonResponse(
        410,
        { error: "unregistered", reason: "device token purged" },
        requestId,
      );
    }
    case "bad-token": {
      await writeAudit(
        env,
        makeAuditEntry(env, {
          ...auditBase,
          outcome: "apns-bad-token",
          apnsStatus: 400,
        }),
      );
      return jsonResponse(400, { error: "bad-token" }, requestId);
    }
    case "rate-limited": {
      await writeAudit(
        env,
        makeAuditEntry(env, {
          ...auditBase,
          outcome: "apns-rate-limited",
          apnsStatus: 429,
        }),
      );
      return jsonResponse(429, { error: "apns-rate-limited" }, requestId);
    }
    case "server-error": {
      await writeAudit(
        env,
        makeAuditEntry(env, {
          ...auditBase,
          outcome: "apns-server-error",
          apnsStatus: result.status,
          reason: result.reason ?? null,
        }),
      );
      return jsonResponse(
        502,
        { error: "apns-server-error", status: result.status, reason: result.reason },
        requestId,
      );
    }
    case "transport-error": {
      await writeAudit(
        env,
        makeAuditEntry(env, {
          ...auditBase,
          outcome: "transport-error",
          reason: result.message,
        }),
      );
      return jsonResponse(
        502,
        { error: "transport-error", reason: result.message },
        requestId,
      );
    }
  }
}

/* ============================================================
 * DELETE /device-token
 * ============================================================ */
async function handleOptOut(req: Request, hc: HandlerContext): Promise<Response> {
  const { env, requestId, nowSeconds } = hc;

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { error: "bad-request", reason: "invalid JSON" }, requestId);
  }

  const validation = validateOptOutRequest(body);
  if (!validation.ok) {
    return jsonResponse(
      400,
      { error: "bad-request", reason: validation.error, field: validation.field },
      requestId,
    );
  }
  const { deviceToken, signature, sessionId } = validation.value;

  // Opt-out signature: HMAC-SHA256(RELAY_BEARER_SIGNING_KEY,
  //                                "optout:" + sessionId + ":" + deviceToken).
  // Proves the caller is bound to the pairing without leaking the bearer
  // we use on the push path.
  const message = `optout:${sessionId}:${deviceToken}`;
  const sigValid = await verifyHmacSha256Base64(
    env.RELAY_BEARER_SIGNING_KEY,
    message,
    signature,
  );
  if (!sigValid) {
    await writeAudit(
      env,
      makeAuditEntry(env, {
        outcome: "rejected-auth",
        requestId,
        sessionId,
        reason: "opt-out signature mismatch",
      }),
    );
    return jsonResponse(401, { error: "unauthorized" }, requestId);
  }

  const deviceTokenHash = await hashDeviceToken(deviceToken);
  await purgeDeviceToken(env, deviceTokenHash);

  await writeAudit(
    env,
    makeAuditEntry(env, {
      ts: nowSeconds,
      outcome: "opt-out",
      requestId,
      deviceTokenHash,
      sessionId,
    }),
  );

  return jsonResponse(200, { ok: true, purged: true }, requestId);
}

/* ============================================================
 * GET /health  (also exposes .p8 age for the rotation-drill CI job)
 * ============================================================ */
async function handleHealth(hc: HandlerContext): Promise<Response> {
  const { env, requestId, nowSeconds } = hc;

  const issuedAtRaw = env.APNS_P8_ISSUED_AT ?? "";
  const issuedAt = Number.parseInt(issuedAtRaw, 10);
  const p8AgeSeconds = Number.isFinite(issuedAt) && issuedAt > 0 ? nowSeconds - issuedAt : null;
  const maxAge = p8MaxAgeSeconds(env);
  const p8Stale = p8AgeSeconds !== null && p8AgeSeconds > maxAge;

  return jsonResponse(
    p8Stale ? 503 : 200,
    {
      ok: !p8Stale,
      env: env.ENVIRONMENT,
      killSwitch: isKillSwitchOn(env),
      apnsEndpoint: env.APNS_ENDPOINT,
      topicEnv: env.TOPIC_ENV,
      p8AgeSeconds,
      p8MaxAgeSeconds: maxAge,
      p8Stale,
    },
    requestId,
  );
}

/* ============================================================
 * Router
 * ============================================================ */
const worker: ExportedHandler<Env> = {
  async fetch(req, env, ctx): Promise<Response> {
    const requestId = req.headers.get("x-request-id") ?? newRequestId();
    const url = new URL(req.url);
    const hc: HandlerContext = {
      env,
      ctx,
      requestId,
      nowSeconds: Math.floor(Date.now() / 1000),
    };

    // Preflight for the opt-out endpoint (iOS settings panel may call this
    // from a webview).
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "POST,DELETE,GET,OPTIONS",
          "access-control-allow-headers": "authorization,content-type,x-request-id",
          "access-control-max-age": "86400",
        },
      });
    }

    if (req.method === "POST" && url.pathname === "/push") {
      return await handlePush(req, hc);
    }
    if (req.method === "DELETE" && url.pathname === "/device-token") {
      return await handleOptOut(req, hc);
    }
    if (req.method === "GET" && url.pathname === "/health") {
      return await handleHealth(hc);
    }

    return jsonResponse(404, { error: "not-found" }, requestId);
  },
};

export default worker;
