import { describe, it, expect } from "vitest";
import {
  bindDeviceToken,
  hashDeviceToken,
  lookupDeviceToken,
  purgeDeviceToken,
} from "../src/device-tokens.js";
import { makeDeviceToken, makeEnv, makeFingerprint, makeSessionId } from "./helpers.js";

describe("device-tokens", () => {
  it("hashes the raw token via SHA-256", async () => {
    const token = makeDeviceToken();
    const hash = await hashDeviceToken(token);
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
    expect(hash).not.toBe(token);
  });

  it("binds a fresh token to the first session it sees", async () => {
    const env = await makeEnv();
    const hash = await hashDeviceToken(makeDeviceToken(1));
    const sid = makeSessionId("a");
    const r = await bindDeviceToken(env, hash, sid, makeFingerprint(), 1000);
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.firstRegistration).toBe(true);
      expect(r.binding.sessionId).toBe(sid);
    }
    const stored = await lookupDeviceToken(env, hash);
    expect(stored?.sessionId).toBe(sid);
  });

  it("refreshes lastSeenAt on subsequent same-session pushes", async () => {
    const env = await makeEnv();
    const hash = await hashDeviceToken(makeDeviceToken(2));
    const sid = makeSessionId("b");
    await bindDeviceToken(env, hash, sid, makeFingerprint(), 1000);
    const r = await bindDeviceToken(env, hash, sid, makeFingerprint(), 2000);
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.firstRegistration).toBe(false);
      expect(r.binding.lastSeenAt).toBe(2000);
      expect(r.binding.createdAt).toBe(1000);
    }
  });

  it("rejects a cross-tenant push (different session id)", async () => {
    const env = await makeEnv();
    const hash = await hashDeviceToken(makeDeviceToken(3));
    await bindDeviceToken(env, hash, makeSessionId("first"), makeFingerprint(), 1000);
    const r = await bindDeviceToken(env, hash, makeSessionId("attacker"), makeFingerprint(), 2000);
    expect(r.kind).toBe("cross-tenant");
    if (r.kind === "cross-tenant") {
      expect(r.existing.sessionId).toContain("first");
      expect(r.attemptedSessionId).toContain("attacker");
    }
  });

  it("purgeDeviceToken removes the row", async () => {
    const env = await makeEnv();
    const hash = await hashDeviceToken(makeDeviceToken(4));
    await bindDeviceToken(env, hash, makeSessionId("c"), makeFingerprint(), 1000);
    expect(await lookupDeviceToken(env, hash)).not.toBeNull();
    await purgeDeviceToken(env, hash);
    expect(await lookupDeviceToken(env, hash)).toBeNull();
  });

  it("re-binds after a purge (simulating APNS 410 → re-register)", async () => {
    const env = await makeEnv();
    const hash = await hashDeviceToken(makeDeviceToken(5));
    await bindDeviceToken(env, hash, makeSessionId("old"), makeFingerprint(), 1000);
    await purgeDeviceToken(env, hash);
    const r = await bindDeviceToken(env, hash, makeSessionId("new"), makeFingerprint(), 2000);
    expect(r.kind).toBe("ok");
    if (r.kind === "ok") {
      expect(r.firstRegistration).toBe(true);
      expect(r.binding.sessionId).toContain("new");
    }
  });

  it("does NOT store the raw device token in KV", async () => {
    const env = await makeEnv();
    const raw = makeDeviceToken(6);
    const hash = await hashDeviceToken(raw);
    await bindDeviceToken(env, hash, makeSessionId("d"), makeFingerprint(), 1000);
    // Walk every entry in the KV stub and verify the raw hex never appears.
    const kv = env.APNS_DEVICE_TOKENS as unknown as {
      rawEntries(): Map<string, { value: string }>;
    };
    for (const [k, v] of kv.rawEntries()) {
      expect(k).not.toContain(raw);
      expect(v.value).not.toContain(raw);
    }
  });
});
