import { describe, it, expect } from "vitest";
import { checkRateLimit, peekRateLimit } from "../src/rate-limit.js";
import { makeEnv } from "./helpers.js";

describe("checkRateLimit", () => {
  it("allows the first request and increments to 1", async () => {
    const env = await makeEnv({ ratePerHour: 5 });
    const r = await checkRateLimit(env, "hash-a", 1000);
    expect(r.allowed).toBe(true);
    expect(r.used).toBe(1);
    expect(r.limit).toBe(5);
  });

  it("blocks at exactly the configured limit", async () => {
    const env = await makeEnv({ ratePerHour: 3 });
    for (let i = 0; i < 3; i++) {
      const r = await checkRateLimit(env, "hash-b", 1000);
      expect(r.allowed).toBe(true);
    }
    const blocked = await checkRateLimit(env, "hash-b", 1000);
    expect(blocked.allowed).toBe(false);
    expect(blocked.used).toBe(3);
  });

  it("uses separate buckets per hash", async () => {
    const env = await makeEnv({ ratePerHour: 2 });
    await checkRateLimit(env, "hash-c", 1000);
    await checkRateLimit(env, "hash-c", 1000);
    const c = await checkRateLimit(env, "hash-c", 1000);
    expect(c.allowed).toBe(false);
    const d = await checkRateLimit(env, "hash-d", 1000);
    expect(d.allowed).toBe(true);
  });

  it("rolls over at the hour boundary", async () => {
    const env = await makeEnv({ ratePerHour: 1 });
    await checkRateLimit(env, "hash-e", 1000); // bucket 0
    const blocked = await checkRateLimit(env, "hash-e", 1000); // still bucket 0
    expect(blocked.allowed).toBe(false);
    // 3600 seconds later we're in bucket 1.
    const allowedAgain = await checkRateLimit(env, "hash-e", 1000 + 3600);
    expect(allowedAgain.allowed).toBe(true);
    expect(allowedAgain.used).toBe(1);
  });

  it("peek does not mutate", async () => {
    const env = await makeEnv({ ratePerHour: 5 });
    const p1 = await peekRateLimit(env, "hash-f", 1000);
    expect(p1.used).toBe(0);
    const p2 = await peekRateLimit(env, "hash-f", 1000);
    expect(p2.used).toBe(0);
  });

  it("60/h is the default plan-spec limit", async () => {
    const env = await makeEnv(); // omit ratePerHour
    const r = await checkRateLimit(env, "hash-default", 1000);
    expect(r.limit).toBe(60);
  });
});
