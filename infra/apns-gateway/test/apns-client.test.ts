import { describe, it, expect } from "vitest";
import { buildApnsJwt, sendApnsPush } from "../src/apns-client.js";
import { base64Decode } from "../src/crypto-utils.js";
import { makeEnv } from "./helpers.js";

describe("buildApnsJwt", () => {
  it("produces a 3-part JWT (header.claims.signature) with ES256 header", async () => {
    const env = await makeEnv();
    const jwt = await buildApnsJwt({
      p8Pem: env.APNS_P8_KEY,
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
    });
    const parts = jwt.split(".");
    expect(parts.length).toBe(3);
    const headerJson = new TextDecoder().decode(base64Decode(parts[0]!));
    const header = JSON.parse(headerJson);
    expect(header.alg).toBe("ES256");
    expect(header.kid).toBe(env.APNS_KEY_ID);
    expect(header.typ).toBe("JWT");
  });

  it("includes iss + iat in the claims", async () => {
    const env = await makeEnv();
    const jwt = await buildApnsJwt({
      p8Pem: env.APNS_P8_KEY,
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
      nowSeconds: 1_700_000_000,
    });
    const claimsJson = new TextDecoder().decode(base64Decode(jwt.split(".")[1]!));
    const claims = JSON.parse(claimsJson);
    expect(claims.iss).toBe(env.APNS_TEAM_ID);
    expect(claims.iat).toBe(1_700_000_000);
  });

  it("signs uniquely per (header,claims) tuple", async () => {
    const env = await makeEnv();
    const a = await buildApnsJwt({
      p8Pem: env.APNS_P8_KEY,
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
      nowSeconds: 1000,
    });
    const b = await buildApnsJwt({
      p8Pem: env.APNS_P8_KEY,
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
      nowSeconds: 2000,
    });
    expect(a).not.toBe(b);
  });
});

describe("sendApnsPush", () => {
  function makeFetch(responses: Array<{ status: number; headers?: Record<string, string>; body?: string }>): typeof fetch {
    let i = 0;
    const captured: { url: string; init: RequestInit }[] = [];
    const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      captured.push({ url, init: init ?? {} });
      const r = responses[i++];
      if (!r) throw new Error("no response queued");
      return new Response(r.body ?? "", { status: r.status, headers: r.headers ?? {} });
    }) as typeof fetch;
    (fn as unknown as { captured: typeof captured }).captured = captured;
    return fn;
  }

  it("returns delivered on 200 + apns-id header", async () => {
    const fetchImpl = makeFetch([{ status: 200, headers: { "apns-id": "uuid-1" } }]);
    const result = await sendApnsPush({
      endpoint: "https://api.sandbox.push.apple.com",
      jwt: "j",
      deviceToken: "abc",
      topic: "com.clawdmeter.mac",
      encryptedPayload: "payload",
      fetchImpl,
    });
    expect(result.kind).toBe("delivered");
    if (result.kind === "delivered") expect(result.apnsId).toBe("uuid-1");
  });

  it("returns unregistered on 410 — used by index.ts to purge", async () => {
    const fetchImpl = makeFetch([{ status: 410 }]);
    const result = await sendApnsPush({
      endpoint: "https://api.sandbox.push.apple.com",
      jwt: "j",
      deviceToken: "abc",
      topic: "com.clawdmeter.mac",
      encryptedPayload: "payload",
      fetchImpl,
    });
    expect(result.kind).toBe("unregistered");
  });

  it("returns bad-token on 400/404", async () => {
    expect((await sendApnsPush({
      endpoint: "https://x", jwt: "j", deviceToken: "a", topic: "t",
      encryptedPayload: "p", fetchImpl: makeFetch([{ status: 400 }]),
    })).kind).toBe("bad-token");
    expect((await sendApnsPush({
      endpoint: "https://x", jwt: "j", deviceToken: "a", topic: "t",
      encryptedPayload: "p", fetchImpl: makeFetch([{ status: 404 }]),
    })).kind).toBe("bad-token");
  });

  it("returns rate-limited on 429", async () => {
    const result = await sendApnsPush({
      endpoint: "https://x", jwt: "j", deviceToken: "a", topic: "t",
      encryptedPayload: "p",
      fetchImpl: makeFetch([{ status: 429 }]),
    });
    expect(result.kind).toBe("rate-limited");
  });

  it("returns server-error on 5xx and surfaces the reason field", async () => {
    const result = await sendApnsPush({
      endpoint: "https://x", jwt: "j", deviceToken: "a", topic: "t",
      encryptedPayload: "p",
      fetchImpl: makeFetch([{
        status: 500,
        body: JSON.stringify({ reason: "InternalServerError" }),
      }]),
    });
    expect(result.kind).toBe("server-error");
    if (result.kind === "server-error") {
      expect(result.status).toBe(500);
      expect(result.reason).toBe("InternalServerError");
    }
  });

  it("returns transport-error when fetch throws", async () => {
    const fetchImpl = (async () => { throw new Error("ECONNRESET"); }) as typeof fetch;
    const result = await sendApnsPush({
      endpoint: "https://x", jwt: "j", deviceToken: "a", topic: "t",
      encryptedPayload: "p", fetchImpl,
    });
    expect(result.kind).toBe("transport-error");
    if (result.kind === "transport-error") expect(result.message).toContain("ECONNRESET");
  });

  it("sets apns-topic, apns-push-type, apns-priority headers correctly", async () => {
    const fetchImpl = makeFetch([{ status: 200, headers: { "apns-id": "u" } }]);
    await sendApnsPush({
      endpoint: "https://api.sandbox.push.apple.com",
      jwt: "JWT",
      deviceToken: "ab12",
      topic: "com.clawdmeter.mac",
      encryptedPayload: "payload",
      priority: 10,
      pushType: "alert",
      collapseId: "c-1",
      expiration: 12345,
      fetchImpl,
    });
    const captured = (fetchImpl as unknown as { captured: { url: string; init: RequestInit }[] }).captured;
    expect(captured[0]!.url).toContain("/3/device/ab12");
    const headers = captured[0]!.init.headers as Record<string, string>;
    expect(headers["authorization"]).toBe("bearer JWT");
    expect(headers["apns-topic"]).toBe("com.clawdmeter.mac");
    expect(headers["apns-push-type"]).toBe("alert");
    expect(headers["apns-priority"]).toBe("10");
    expect(headers["apns-collapse-id"]).toBe("c-1");
    expect(headers["apns-expiration"]).toBe("12345");
  });

  it("background push omits the alert dict", async () => {
    const fetchImpl = makeFetch([{ status: 200 }]);
    await sendApnsPush({
      endpoint: "https://x", jwt: "j", deviceToken: "a", topic: "t",
      encryptedPayload: "p",
      pushType: "background",
      fetchImpl,
    });
    const captured = (fetchImpl as unknown as { captured: { init: RequestInit }[] }).captured;
    const body = JSON.parse(captured[0]!.init.body as string);
    expect(body.aps["content-available"]).toBe(1);
    expect(body.aps.alert).toBeUndefined();
    expect(body.cmEncrypted).toBe("p");
  });
});
