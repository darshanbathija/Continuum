import { describe, it, expect } from "vitest";
import { issueBearerToken, verifyBearer } from "../src/auth.js";
import { makeEnv } from "./helpers.js";

describe("verifyBearer", () => {
  it("accepts a token issued for the same (sessionId, fingerprint) pair", async () => {
    const env = await makeEnv();
    const claim = { sessionId: "s-1", senderMacFingerprint: "f-1" };
    const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, claim);
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
    const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, claim);
    expect((await verifyBearer(env, `bearer ${token}`, claim)).ok).toBe(true);
    expect((await verifyBearer(env, `BEARER ${token}`, claim)).ok).toBe(true);
  });
});
