// Unit tests for the envelope wire format.

import { describe, it, expect } from "vitest";
import {
  parseEnvelopeHeader,
  serializeEnvelopeHeader,
  validateEnvelope,
  MAX_ENVELOPE_BODY_BYTES,
} from "../src/envelope";

describe("parseEnvelopeHeader", () => {
  it("parses a well-shaped header", () => {
    const text = JSON.stringify({ v: 1, from: "mac", type: "ciphertext" });
    expect(parseEnvelopeHeader(text)).toEqual({ v: 1, from: "mac", type: "ciphertext" });
  });
  it("rejects unknown wire version", () => {
    const text = JSON.stringify({ v: 2, from: "mac", type: "ciphertext" });
    expect(parseEnvelopeHeader(text)).toBeNull();
  });
  it("rejects unknown role", () => {
    const text = JSON.stringify({ v: 1, from: "alien", type: "ciphertext" });
    expect(parseEnvelopeHeader(text)).toBeNull();
  });
  it("rejects unknown type", () => {
    const text = JSON.stringify({ v: 1, from: "mac", type: "unknown" });
    expect(parseEnvelopeHeader(text)).toBeNull();
  });
  it("returns null on malformed JSON", () => {
    expect(parseEnvelopeHeader("not json")).toBeNull();
  });
});

describe("serializeEnvelopeHeader", () => {
  it("emits stable key ordering for cross-impl test vectors", () => {
    const h = { v: 1 as const, from: "ios" as const, type: "handshake" as const };
    expect(serializeEnvelopeHeader(h)).toBe('{"v":1,"from":"ios","type":"handshake"}');
  });
});

describe("validateEnvelope", () => {
  it("accepts a normal ciphertext envelope", () => {
    expect(
      validateEnvelope({
        header: { v: 1, from: "mac", type: "ciphertext" },
        body: new Uint8Array([1, 2, 3]),
      })
    ).toBeNull();
  });
  it("rejects a control envelope with a non-empty body", () => {
    expect(
      validateEnvelope({
        header: { v: 1, from: "mac", type: "control" },
        body: new Uint8Array([1]),
      })
    ).toMatch(/empty body/);
  });
  it("rejects a body that exceeds the cap", () => {
    expect(
      validateEnvelope({
        header: { v: 1, from: "mac", type: "ciphertext" },
        body: new Uint8Array(MAX_ENVELOPE_BODY_BYTES + 1),
      })
    ).toMatch(/exceeds/);
  });
});
