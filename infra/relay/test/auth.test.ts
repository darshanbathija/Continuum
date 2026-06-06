// Unit tests for the auth module. Pure functions; no Worker bindings needed.

import { describe, it, expect } from "vitest";
import {
  constantTimeEqual,
  extractBearerToken,
  hashToken,
  validateBearer,
  isValidAuthBundle,
  isValidSessionCreationGrantRequest,
  issueSessionCreationProof,
  issueSessionCreationSignature,
  deriveAPNSSessionSigningKey,
  validateSessionCreationProof,
  type SessionAuthBundle,
} from "../src/auth";
import { TEST_RELAY_OPERATOR_SIGNING_KEY } from "./helpers";

function wellShapedBundle(overrides: Partial<SessionAuthBundle> = {}): SessionAuthBundle {
  return {
    macTokenHash: "a".repeat(64),
    iosTokenHash: "b".repeat(64),
    ttlSeconds: 1700000000,
    creation: {
      issuedAtSeconds: 1700000000,
      nonce: "creation_nonce_123",
      signature: "signature-placeholder",
    },
    ...overrides,
  };
}

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
    const bundle = wellShapedBundle({
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 9999999999,
    });
    const result = await validateBearer(macTok, bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: true, role: "mac" });
  });
  it("accepts a matching iOS token", async () => {
    const macTok = "mac-secret";
    const iosTok = "ios-secret";
    const bundle = wellShapedBundle({
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 9999999999,
    });
    const result = await validateBearer(iosTok, bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: true, role: "ios" });
  });
  it("rejects a token that matches neither side (D22 peer isolation)", async () => {
    const macTok = "mac-secret";
    const iosTok = "ios-secret";
    const bundle = wellShapedBundle({
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 9999999999,
    });
    const result = await validateBearer("attacker-token", bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: false, reason: "token-mismatch" });
  });
  it("rejects when TTL has expired", async () => {
    const macTok = "mac-secret";
    const iosTok = "ios-secret";
    const bundle = wellShapedBundle({
      macTokenHash: await hashToken(macTok),
      iosTokenHash: await hashToken(iosTok),
      ttlSeconds: 1, // 1970-01-01
    });
    const result = await validateBearer(macTok, bundle, Math.floor(Date.now() / 1000));
    expect(result).toEqual({ ok: false, reason: "session-expired" });
  });
});

describe("isValidAuthBundle", () => {
  it("accepts a well-shaped bundle", () => {
    expect(isValidAuthBundle(wellShapedBundle())).toBe(true);
  });
  it("rejects when the two hashes are identical (would let one token auth both peers)", () => {
    expect(
      isValidAuthBundle(wellShapedBundle({
        macTokenHash: "c".repeat(64),
        iosTokenHash: "c".repeat(64),
      }))
    ).toBe(false);
  });
  it("rejects when ttlSeconds is missing or non-positive", () => {
    expect(isValidAuthBundle({ macTokenHash: "a".repeat(64), iosTokenHash: "b".repeat(64) })).toBe(false);
    expect(isValidAuthBundle(wellShapedBundle({ ttlSeconds: 0 }))).toBe(false);
  });
  it("rejects when a hash isn't 64 lowercase hex chars", () => {
    expect(
      isValidAuthBundle(wellShapedBundle({
        macTokenHash: "not-hex",
      }))
    ).toBe(false);
  });

  it("rejects when creation proof is missing or malformed", () => {
    const noCreation = {
      macTokenHash: "a".repeat(64),
      iosTokenHash: "b".repeat(64),
      ttlSeconds: 1700000000,
    };
    expect(isValidAuthBundle(noCreation)).toBe(false);
    expect(isValidAuthBundle(wellShapedBundle({
      creation: {
        issuedAtSeconds: 1700000000,
        nonce: "short",
        signature: "signature-placeholder",
      },
    }))).toBe(false);
  });
});

describe("validateSessionCreationProof", () => {
  it("accepts an operator-signed creation proof for the same sid and bundle", async () => {
    const bundle = wellShapedBundle();
    bundle.creation.signature = await issueSessionCreationSignature(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "session-creation-ok",
      bundle
    );
    const result = await validateSessionCreationProof(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "session-creation-ok",
      bundle,
      1700000030
    );
    expect(result).toEqual({ ok: true });
  });

  it("rejects replaying a signed bundle under a different sid", async () => {
    const bundle = wellShapedBundle();
    bundle.creation.signature = await issueSessionCreationSignature(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "original-session-id",
      bundle
    );
    const result = await validateSessionCreationProof(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "attacker-session-id",
      bundle,
      1700000030
    );
    expect(result.ok).toBe(false);
  });

  it("rejects an expired creation proof", async () => {
    const bundle = wellShapedBundle();
    bundle.creation.signature = await issueSessionCreationSignature(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "session-creation-old",
      bundle
    );
    const result = await validateSessionCreationProof(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "session-creation-old",
      bundle,
      1700001000
    );
    expect(result.ok).toBe(false);
  });
});

describe("session creation grants", () => {
  it("issues a proof that validates for the requested sid and hashes", async () => {
    const request = {
      macTokenHash: "a".repeat(64),
      iosTokenHash: "b".repeat(64),
      ttlSeconds: 1700003600,
    };
    const proof = await issueSessionCreationProof(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "session-grant-ok",
      request,
      1700000000
    );
    const bundle: SessionAuthBundle = {
      macTokenHash: request.macTokenHash,
      iosTokenHash: request.iosTokenHash,
      ttlSeconds: request.ttlSeconds,
      creation: proof,
    };
    expect(await validateSessionCreationProof(
      TEST_RELAY_OPERATOR_SIGNING_KEY,
      "session-grant-ok",
      bundle,
      1700000010
    )).toEqual({ ok: true });
  });

  it("rejects invalid grant requests and TTLs beyond the 31-day cap", () => {
    expect(isValidSessionCreationGrantRequest({
      macTokenHash: "a".repeat(64),
      iosTokenHash: "b".repeat(64),
      ttlSeconds: 1700000100,
    }, 1700000000)).toBe(true);
    expect(isValidSessionCreationGrantRequest({
      macTokenHash: "a".repeat(64),
      iosTokenHash: "a".repeat(64),
      ttlSeconds: 1700000100,
    }, 1700000000)).toBe(false);
    expect(isValidSessionCreationGrantRequest({
      macTokenHash: "a".repeat(64),
      iosTokenHash: "b".repeat(64),
      ttlSeconds: 1700000000 + 32 * 24 * 60 * 60,
    }, 1700000000)).toBe(false);
  });

  it("derives a stable APNS signing key scoped by sid and Mac fingerprint", async () => {
    const a = await deriveAPNSSessionSigningKey(TEST_RELAY_OPERATOR_SIGNING_KEY, "sid-a", "fingerprint-a");
    const b = await deriveAPNSSessionSigningKey(TEST_RELAY_OPERATOR_SIGNING_KEY, "sid-a", "fingerprint-a");
    const c = await deriveAPNSSessionSigningKey(TEST_RELAY_OPERATOR_SIGNING_KEY, "sid-a", "fingerprint-b");
    expect(a).toBe(b);
    expect(a).not.toBe(c);
  });
});
