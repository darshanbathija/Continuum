import { describe, it, expect } from "vitest";
import { deriveAPNSSessionSigningKey, issueBearerToken, verifyBearer } from "../src/auth.js";
import { makeEnv } from "./helpers.js";

describe("verifyBearer", () => {
  it("accepts a token issued for the same (sessionId, fingerprint) pair", async () => {
    const env = await makeEnv();
    const claim = { sessionId: "s-1", senderMacFingerprint: "f-1" };
    const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, claim);
    const r = await verifyBearer(env, `Bearer ${token}`, claim);
    expect(r.ok).toBe(true);
  });

  it("accepts a token issued with the pairing-derived session signing key", async () => {
    const env = await makeEnv();
    const claim = { sessionId: "s-1", senderMacFingerprint: "f-1" };
    const sessionSigningKey = await deriveAPNSSessionSigningKey(env.RELAY_BEARER_SIGNING_KEY, claim);
    const token = await issueBearerToken(sessionSigningKey, claim);
    const r = await verifyBearer(env, `Bearer ${token}`, claim);
    expect(r.ok).toBe(true);
  });

  it("rejects when header is missing", async () => {
    const env = await makeEnv();
    const r = await verifyBearer(env, null, { sessionId: "s", senderMacFingerprint: "f" });
    expect(r.ok).toBe(false);
  });

  it("rejects non-Bearer schemes", async () => {
    const env = await makeEnv();
    const r = await verifyBearer(env, "Basic abc", { sessionId: "s", senderMacFingerprint: "f" });
    expect(r.ok).toBe(false);
  });

  it("rejects an empty bearer", async () => {
    const env = await makeEnv();
    const r = await verifyBearer(env, "Bearer ", { sessionId: "s", senderMacFingerprint: "f" });
    expect(r.ok).toBe(false);
  });

  it("rejects a token issued for a different session", async () => {
    const env = await makeEnv();
    const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, {
      sessionId: "real-session",
      senderMacFingerprint: "f",
    });
    const r = await verifyBearer(env, `Bearer ${token}`, {
      sessionId: "attacker-session",
      senderMacFingerprint: "f",
    });
    expect(r.ok).toBe(false);
  });

  it("rejects a token issued for a different fingerprint", async () => {
    const env = await makeEnv();
    const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, {
      sessionId: "s",
      senderMacFingerprint: "real-mac",
    });
    const r = await verifyBearer(env, `Bearer ${token}`, {
      sessionId: "s",
      senderMacFingerprint: "attacker-mac",
    });
    expect(r.ok).toBe(false);
  });

  it("rejects a garbage token", async () => {
    const env = await makeEnv();
    const r = await verifyBearer(env, "Bearer aaaaaaaaaaaaaaaaaaaaaaaa", {
      sessionId: "s",
      senderMacFingerprint: "f",
    });
    expect(r.ok).toBe(false);
  });

  it("is case-insensitive on the Bearer prefix", async () => {
    const env = await makeEnv();
    const claim = { sessionId: "s", senderMacFingerprint: "f" };
    const lowerToken = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, claim);
    const upperToken = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, claim);
    expect((await verifyBearer(env, `bearer ${lowerToken}`, claim)).ok).toBe(true);
    expect((await verifyBearer(env, `BEARER ${upperToken}`, claim)).ok).toBe(true);
  });

  it("rejects an expired bearer", async () => {
    const env = await makeEnv({ bearerTtlSeconds: 300 });
    const claim = { sessionId: "s", senderMacFingerprint: "f" };
    const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, claim, {
      issuedAtSeconds: 1000,
      nonce: "expired_nonce_123",
    });
    const r = await verifyBearer(env, `Bearer ${token}`, claim, 1401);
    expect(r.ok).toBe(false);
  });

  it("rejects replay of the same nonce-bearing token", async () => {
    const env = await makeEnv();
    const claim = { sessionId: "s", senderMacFingerprint: "f" };
    const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, claim, {
      issuedAtSeconds: 1700000000,
      nonce: "replay_nonce_123",
    });
    expect((await verifyBearer(env, `Bearer ${token}`, claim, 1700000010)).ok).toBe(true);
    const replay = await verifyBearer(env, `Bearer ${token}`, claim, 1700000011);
    expect(replay).toEqual({ ok: false, reason: "bearer nonce replay" });
  });
});
