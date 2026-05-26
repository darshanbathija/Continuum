// Integration tests against the Worker's exported fetch handler. Cover the
// D21 + codex #4 + codex #5 invariants end-to-end.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import workerImport from "../src/index.js";
import type { Env } from "../src/env.js";
import {
  authHeaderFor,
  makeCtx,
  makeDeviceToken,
  makeEnv,
  makePushBody,
  makeSessionId,
  optOutSignatureFor,
  withMockedApnsFetch,
} from "./helpers.js";
import { hashDeviceToken, lookupDeviceToken } from "../src/device-tokens.js";

// Cast away IncomingRequestCfProperties — tests use the DOM Request shape.
const worker = workerImport as unknown as {
  fetch: (req: Request, env: Env, ctx: ExecutionContext) => Promise<Response>;
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let logSpy: any;

beforeEach(() => {
  // Audit lines spam stdout; quiet them but keep them spy-able.
  logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  logSpy.mockRestore();
});

function makePushRequest(body: unknown, authHeader?: string): Request {
  return new Request("https://apns-gateway.test/push", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(authHeader ? { authorization: authHeader } : {}),
    },
    body: JSON.stringify(body),
  });
}

function getLoggedAuditOutcomes(): string[] {
  const outcomes: string[] = [];
  for (const call of logSpy.mock.calls) {
    try {
      const parsed = JSON.parse(call[0] as string);
      if (parsed.kind === "audit") outcomes.push(parsed.outcome);
    } catch {
      // ignore non-JSON
    }
  }
  return outcomes;
}

describe("POST /push happy path", () => {
  it("delivers, returns 200, audits 'delivered', and writes hashed token to KV", async () => {
    const env = await makeEnv();
    const body = makePushBody();
    const auth = await authHeaderFor(env, body);

    let resp: Response | undefined;
    await withMockedApnsFetch(
      [{ status: 200, headers: { "apns-id": "apns-uuid-1" } }],
      async () => {
        resp = await worker.fetch(makePushRequest(body, auth), env, makeCtx());
      },
    );
    expect(resp!.status).toBe(200);
    const json = (await resp!.json()) as { ok: boolean; apnsId: string | null };
    expect(json.ok).toBe(true);
    expect(json.apnsId).toBe("apns-uuid-1");
    expect(getLoggedAuditOutcomes()).toContain("delivered");

    // Token row exists, hashed only — raw token never appears.
    const hash = await hashDeviceToken(body.deviceToken);
    const stored = await lookupDeviceToken(env, hash);
    expect(stored).not.toBeNull();
    expect(stored?.sessionId).toBe(body.sessionId);
  });

  it("never logs the raw device token", async () => {
    const env = await makeEnv();
    const body = makePushBody();
    const auth = await authHeaderFor(env, body);
    await withMockedApnsFetch([{ status: 200 }], async () => {
      await worker.fetch(makePushRequest(body, auth), env, makeCtx());
    });
    // Inspect every JSON log line for the raw device token.
    for (const call of logSpy.mock.calls) {
      const text = call[0] as string;
      expect(text).not.toContain(body.deviceToken);
    }
  });
});

describe("D21 invariants", () => {
  it("kill-switch returns 503 and audits 'rejected-kill-switch'", async () => {
    const env = await makeEnv({ killSwitch: true });
    const body = makePushBody();
    const auth = await authHeaderFor(env, body);
    const resp = await worker.fetch(makePushRequest(body, auth), env, makeCtx());
    expect(resp.status).toBe(503);
    expect(getLoggedAuditOutcomes()).toContain("rejected-kill-switch");
  });

  it("schema validation rejects a malformed POST with 400", async () => {
    const env = await makeEnv();
    const resp = await worker.fetch(
      new Request("https://apns-gateway.test/push", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer x" },
        body: JSON.stringify({ not: "valid" }),
      }),
      env,
      makeCtx(),
    );
    expect(resp.status).toBe(400);
    expect(getLoggedAuditOutcomes()).toContain("rejected-schema");
  });

  it("schema validation rejects non-JSON body", async () => {
    const env = await makeEnv();
    const resp = await worker.fetch(
      new Request("https://apns-gateway.test/push", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer x" },
        body: "not-json",
      }),
      env,
      makeCtx(),
    );
    expect(resp.status).toBe(400);
  });

  it("rate limit triggers at the configured threshold (60 default — using 3 for speed)", async () => {
    const env = await makeEnv({ ratePerHour: 3 });
    const body = makePushBody({ deviceToken: makeDeviceToken(99) });
    const auth = await authHeaderFor(env, body);

    await withMockedApnsFetch(
      Array.from({ length: 3 }, () => ({ status: 200 })),
      async () => {
        for (let i = 0; i < 3; i++) {
          const resp = await worker.fetch(makePushRequest(body, auth), env, makeCtx());
          expect(resp.status).toBe(200);
        }
      },
    );

    // 4th call should be 429 — no APNS fetch needed.
    const blocked = await worker.fetch(makePushRequest(body, auth), env, makeCtx());
    expect(blocked.status).toBe(429);
    expect(blocked.headers.get("retry-after")).toBeTruthy();
    expect(getLoggedAuditOutcomes()).toContain("rejected-rate-limit");
  });
});

describe("Auth invariants", () => {
  it("rejects requests with no Authorization header (401)", async () => {
    const env = await makeEnv();
    const body = makePushBody();
    const resp = await worker.fetch(makePushRequest(body), env, makeCtx());
    expect(resp.status).toBe(401);
    expect(getLoggedAuditOutcomes()).toContain("rejected-auth");
  });

  it("rejects a token issued for a different session id", async () => {
    const env = await makeEnv();
    const realBody = makePushBody({ sessionId: makeSessionId("real") });
    const realAuth = await authHeaderFor(env, realBody);
    // Use the token for a different session.
    const attackerBody = makePushBody({ sessionId: makeSessionId("attacker") });
    const resp = await worker.fetch(makePushRequest(attackerBody, realAuth), env, makeCtx());
    expect(resp.status).toBe(401);
  });
});

describe("Codex #5 device-token egress", () => {
  it("rejects cross-tenant push (same token under a different sessionId)", async () => {
    const env = await makeEnv();
    const sharedToken = makeDeviceToken(7);
    const ownerBody = makePushBody({ deviceToken: sharedToken, sessionId: makeSessionId("owner") });
    const ownerAuth = await authHeaderFor(env, ownerBody);

    await withMockedApnsFetch([{ status: 200 }], async () => {
      const ok = await worker.fetch(makePushRequest(ownerBody, ownerAuth), env, makeCtx());
      expect(ok.status).toBe(200);
    });

    const attackerBody = makePushBody({
      deviceToken: sharedToken,
      sessionId: makeSessionId("attacker"),
    });
    const attackerAuth = await authHeaderFor(env, attackerBody);
    const blocked = await worker.fetch(makePushRequest(attackerBody, attackerAuth), env, makeCtx());
    expect(blocked.status).toBe(403);
    expect(getLoggedAuditOutcomes()).toContain("rejected-cross-tenant");
  });

  it("APNS 410 'Unregistered' purges the hashed token from KV", async () => {
    const env = await makeEnv();
    const body = makePushBody({ deviceToken: makeDeviceToken(12) });
    const auth = await authHeaderFor(env, body);

    // First push succeeds → token row created.
    await withMockedApnsFetch([{ status: 200 }], async () => {
      const ok = await worker.fetch(makePushRequest(body, auth), env, makeCtx());
      expect(ok.status).toBe(200);
    });
    const hash = await hashDeviceToken(body.deviceToken);
    expect(await lookupDeviceToken(env, hash)).not.toBeNull();

    // Second push returns 410 → token row purged.
    // Need a fresh body so rate-limit doesn't trip; reuse same deviceToken.
    const body2 = makePushBody({ deviceToken: body.deviceToken, sessionId: body.sessionId, senderMacFingerprint: body.senderMacFingerprint });
    const auth2 = await authHeaderFor(env, body2);
    await withMockedApnsFetch([{ status: 410 }], async () => {
      const gone = await worker.fetch(makePushRequest(body2, auth2), env, makeCtx());
      expect(gone.status).toBe(410);
    });
    expect(await lookupDeviceToken(env, hash)).toBeNull();
    expect(getLoggedAuditOutcomes()).toContain("apns-unregistered");
  });

  it("DELETE /device-token opt-out endpoint purges with valid signature", async () => {
    const env = await makeEnv();
    const body = makePushBody({ deviceToken: makeDeviceToken(33) });
    const auth = await authHeaderFor(env, body);
    await withMockedApnsFetch([{ status: 200 }], async () => {
      await worker.fetch(makePushRequest(body, auth), env, makeCtx());
    });
    const hash = await hashDeviceToken(body.deviceToken);
    expect(await lookupDeviceToken(env, hash)).not.toBeNull();

    const signature = await optOutSignatureFor(env, body.deviceToken, body.sessionId);
    const optoutResp = await worker.fetch(
      new Request("https://apns-gateway.test/device-token", {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          deviceToken: body.deviceToken,
          sessionId: body.sessionId,
          signature,
        }),
      }),
      env,
      makeCtx(),
    );
    expect(optoutResp.status).toBe(200);
    expect(await lookupDeviceToken(env, hash)).toBeNull();
    expect(getLoggedAuditOutcomes()).toContain("opt-out");
  });

  it("DELETE /device-token rejects a bad signature with 401", async () => {
    const env = await makeEnv();
    const resp = await worker.fetch(
      new Request("https://apns-gateway.test/device-token", {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          deviceToken: makeDeviceToken(),
          sessionId: makeSessionId(),
          signature: "AAAAAAAAAAAAAAAAAAAA",
        }),
      }),
      env,
      makeCtx(),
    );
    expect(resp.status).toBe(401);
  });
});

describe("Codex #4 ops + topic separation", () => {
  it("rejects a push whose topic doesn't match the operator's TOPIC_ENV", async () => {
    const env = await makeEnv({ topicEnv: "production" });
    const body = makePushBody({ topic: "com.attacker.bundle" });
    const auth = await authHeaderFor(env, body);
    const resp = await worker.fetch(makePushRequest(body, auth), env, makeCtx());
    expect(resp.status).toBe(400);
    expect(getLoggedAuditOutcomes()).toContain("rejected-schema");
  });
});

describe("Audit log shape", () => {
  it("audit entries include payloadSize but never the encrypted payload", async () => {
    const env = await makeEnv();
    const body = makePushBody({ encryptedPayload: "U28gcGxhaW4gYW5kIGNyaXNw" });
    const auth = await authHeaderFor(env, body);
    await withMockedApnsFetch([{ status: 200 }], async () => {
      await worker.fetch(makePushRequest(body, auth), env, makeCtx());
    });
    let foundDelivered = false;
    for (const call of logSpy.mock.calls) {
      try {
        const parsed = JSON.parse(call[0] as string);
        if (parsed.kind === "audit" && parsed.outcome === "delivered") {
          foundDelivered = true;
          expect(parsed.payloadSize).toBe(body.encryptedPayload.length);
          expect(parsed.encryptedPayload).toBeUndefined();
          expect(parsed.payload).toBeUndefined();
          expect(parsed.deviceTokenHash).toMatch(/^[0-9a-f]{64}$/);
          expect(parsed.requestId).toBeDefined();
        }
      } catch {
        // ignore
      }
    }
    expect(foundDelivered).toBe(true);
  });
});

describe("Routing", () => {
  it("GET /health returns 200 with ops summary when .p8 is fresh", async () => {
    const env = await makeEnv();
    const resp = await worker.fetch(
      new Request("https://apns-gateway.test/health"),
      env,
      makeCtx(),
    );
    expect(resp.status).toBe(200);
    const json = (await resp.json()) as {
      ok: boolean;
      env: string;
      killSwitch: boolean;
      p8Stale: boolean;
    };
    expect(json.ok).toBe(true);
    expect(json.killSwitch).toBe(false);
    expect(json.p8Stale).toBe(false);
  });

  it("GET /health returns 503 when .p8 exceeds P8_MAX_AGE_SECONDS", async () => {
    // Issued 200 days ago — exceeds default 90-day max.
    const env = await makeEnv({
      p8IssuedAt: Math.floor(Date.now() / 1000) - 200 * 86400,
    });
    const resp = await worker.fetch(
      new Request("https://apns-gateway.test/health"),
      env,
      makeCtx(),
    );
    expect(resp.status).toBe(503);
    const json = (await resp.json()) as { p8Stale: boolean };
    expect(json.p8Stale).toBe(true);
  });

  it("unknown route returns 404", async () => {
    const env = await makeEnv();
    const resp = await worker.fetch(
      new Request("https://apns-gateway.test/nope"),
      env,
      makeCtx(),
    );
    expect(resp.status).toBe(404);
  });

  it("OPTIONS preflight returns 204 with CORS headers", async () => {
    const env = await makeEnv();
    const resp = await worker.fetch(
      new Request("https://apns-gateway.test/push", { method: "OPTIONS" }),
      env,
      makeCtx(),
    );
    expect(resp.status).toBe(204);
    expect(resp.headers.get("access-control-allow-methods")).toContain("POST");
  });
});
