import { describe, it, expect } from "vitest";
import { validateOptOutRequest, validatePushRequest } from "../src/schema.js";
import { makeEnv, makePushBody } from "./helpers.js";

describe("validatePushRequest", () => {
  it("accepts a well-formed body", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(makePushBody(), env);
    expect(r.ok).toBe(true);
  });

  it("rejects non-object bodies", async () => {
    const env = await makeEnv();
    expect(validatePushRequest(null, env).ok).toBe(false);
    expect(validatePushRequest("nope", env).ok).toBe(false);
    expect(validatePushRequest([], env).ok).toBe(false);
  });

  it("rejects missing deviceToken", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(makePushBody({ deviceToken: "" }), env);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("deviceToken");
  });

  it("rejects deviceToken with wrong length", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(makePushBody({ deviceToken: "abcd" }), env);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("deviceToken");
  });

  it("rejects deviceToken with non-hex characters", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({ deviceToken: "g".repeat(64) }),
      env,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("deviceToken");
  });

  it("rejects oversized encryptedPayload", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({ encryptedPayload: "A".repeat(4000) }),
      env,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("encryptedPayload");
  });

  it("rejects topic that doesn't match the operator-configured sandbox topic", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({ topic: "com.evil.bundle" }),
      env,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("topic");
  });

  it("rejects sessionId with invalid characters", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({ sessionId: "with spaces!" }),
      env,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("sessionId");
  });

  it("rejects senderMacFingerprint that isn't 64 hex chars", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({ senderMacFingerprint: "deadbeef" }),
      env,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("senderMacFingerprint");
  });

  it("rejects priority other than 5 or 10", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({ priority: 7 as unknown as 5 }),
      env,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("priority");
  });

  it("rejects unknown pushType", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({ pushType: "evil" as unknown as "alert" }),
      env,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.field).toBe("pushType");
  });

  it("rejects expiration that is negative or NaN", async () => {
    const env = await makeEnv();
    const r1 = validatePushRequest(makePushBody({ expiration: -1 }), env);
    expect(r1.ok).toBe(false);
    const r2 = validatePushRequest(
      makePushBody({ expiration: Number.NaN as unknown as number }),
      env,
    );
    expect(r2.ok).toBe(false);
  });

  it("preserves optional fields when present", async () => {
    const env = await makeEnv();
    const r = validatePushRequest(
      makePushBody({
        priority: 10,
        pushType: "alert",
        collapseId: "plan-123",
        expiration: 0,
      }),
      env,
    );
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.value.priority).toBe(10);
      expect(r.value.pushType).toBe("alert");
      expect(r.value.collapseId).toBe("plan-123");
      expect(r.value.expiration).toBe(0);
    }
  });

  it("accepts the production topic when TOPIC_ENV is production", async () => {
    const env = await makeEnv({ topicEnv: "production" });
    const r = validatePushRequest(
      makePushBody({ topic: "com.clawdmeter.iphone" }),
      env,
    );
    expect(r.ok).toBe(true);
  });
});

describe("validateOptOutRequest", () => {
  it("accepts a well-formed body", () => {
    const r = validateOptOutRequest({
      deviceToken: "a".repeat(64),
      sessionId: "sess_abc_0123456789",
      signature: "AAECAwQFBgcICQoLDA0ODw",
    });
    expect(r.ok).toBe(true);
  });

  it("rejects bad device token", () => {
    const r = validateOptOutRequest({
      deviceToken: "tooshort",
      sessionId: "sess_abc_0123456789",
      signature: "AAECAwQFBgcICQoLDA0ODw",
    });
    expect(r.ok).toBe(false);
  });

  it("rejects missing signature", () => {
    const r = validateOptOutRequest({
      deviceToken: "a".repeat(64),
      sessionId: "sess_abc_0123456789",
    });
    expect(r.ok).toBe(false);
  });
});
