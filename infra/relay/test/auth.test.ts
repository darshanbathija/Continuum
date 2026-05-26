// Unit tests for the auth module. Pure functions; no Worker bindings needed.

import { describe, it, expect } from "vitest";
import {
  constantTimeEqual,
  extractBearerToken,
  hashToken,
  validateBearer,
  isValidAuthBundle,
} from "../src/auth";

describe("constantTimeEqual", () => {
  it("returns true for identical strings", () => {
    expect(constantTimeEqual("abc123", "abc123")).toBe(true);
  });
  it("returns false for different strings of equal length", () => {
    expect(constantTimeEqual("abc123", "abc124")).toBe(false);
  });
  it("returns false for different lengths", () => {
    expect(constantTimeEqual("abc", "abcd")).toBe(false);
  });
});

describe("extractBearerToken", () => {
  it("reads Authorization: Bearer <token>", () => {
    const req = new Request("https://x/y", {
      headers: { authorization: "Bearer abc.123" },
    });
    expect(extractBearerToken(req)).toBe("abc.123");
  });
  it("reads ?token=<token> query string", () => {
    const req = new Request("https://x/y?token=qparam");
    expect(extractBearerToken(req)).toBe("qparam");
  });
  it("reads sec-websocket-protocol: bearer.<token>", () => {
    const req = new Request("https://x/y", {
      headers: { "sec-websocket-protocol": "bearer.ws_token" },
    });
    expect(extractBearerToken(req)).toBe("ws_token");
  });
  it("returns null when no token present", () => {
    expect(extractBearerToken(new Request("https://x/y"))).toBeNull();
  });
});

describe("validateBearer", () => {
  it("accepts a matching Mac token (constant-time hash compare)", async () => {
    const macTok = "mac-secret";
    const iosTok = "ios-secret";
    const bundle = {
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 9999999999,
    };
    const result = await validateBearer(macTok, bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: true, role: "mac" });
  });
  it("accepts a matching iOS token", async () => {
    const macTok = "mac-secret";
    const iosTok = "ios-secret";
    const bundle = {
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 9999999999,
    };
    const result = await validateBearer(iosTok, bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: true, role: "ios" });
  });
  it("rejects a token that matches neither side (D22 peer isolation)", async () => {
    const macTok = "mac-secret";
    const iosTok = "ios-secret";
    const bundle = {
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 9999999999,
    };
    const result = await validateBearer("attacker-token", bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: false, reason: "token-mismatch" });
  });
  it("rejects when TTL has expired", async () => {
    const macTok = "mac-secret";
    const iosTok = "ios-secret";
    const bundle = {
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 1, // 1970-01-01
    };
    const result = await validateBearer(macTok, bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: false, reason: "session-expired" });
  });
});

describe("isValidAuthBundle", () => {
  it("accepts a well-shaped bundle", () => {
    expect(
      isValidAuthBundle({
        macTokenHash: "a".repeat(64),
        iosTokenHash: "b".repeat(64),
        ttlSeconds: 1700000000,
      })
    ).toBe(true);
  });
  it("rejects when the two hashes are identical (would let one token auth both peers)", () => {
    expect(
      isValidAuthBundle({
        macTokenHash: "c".repeat(64),
        iosTokenHash: "c".repeat(64),
        ttlSeconds: 1700000000,
      })
    ).toBe(false);
  });
  it("rejects when ttlSeconds is missing or non-positive", () => {
    expect(isValidAuthBundle({ macTokenHash: "a".repeat(64), iosTokenHash: "b".repeat(64) })).toBe(false);
    expect(isValidAuthBundle({ macTokenHash: "a".repeat(64), iosTokenHash: "b".repeat(64), ttlSeconds: 0 })).toBe(false);
  });
  it("rejects when a hash isn't 64 lowercase hex chars", () => {
    expect(
      isValidAuthBundle({
        macTokenHash: "not-hex",
        iosTokenHash: "b".repeat(64),
        ttlSeconds: 1700000000,
      })
    ).toBe(false);
  });
});
