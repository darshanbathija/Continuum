// Verify the cross-impl test vectors in ../test-vectors/ are still byte-exact
// with libsodium-wrappers-sumo's current implementation. If this test ever
// fails, a libsodium upgrade silently changed the wire bytes and BOTH the
// Mac/iOS Swift client and the TS relay would silently diverge.
//
// Runs in the "node" vitest project (see vitest.config.ts). libsodium-
// wrappers-sumo's ESM build has a broken relative import to its sister
// libsodium-sumo package, so we load it through createRequire (CJS) which
// works fine.

import { describe, it, expect, beforeAll } from "vitest";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
// eslint-disable-next-line @typescript-eslint/no-require-imports
const sodium = require("libsodium-wrappers-sumo") as typeof import("libsodium-wrappers-sumo");

// Static imports of the JSON fixtures.
import x25519Vec from "../test-vectors/x25519-ecdh-001.json";
import hkdfVec from "../test-vectors/hkdf-sha256-001.json";
import aeadEncVec from "../test-vectors/xchacha20-poly1305-001.json";
import aeadDecVec from "../test-vectors/xchacha20-poly1305-roundtrip-001.json";
import tamperVec from "../test-vectors/tampered-ciphertext-001.json";
import headerVec from "../test-vectors/envelope-header-001.json";
import bundleVec from "../test-vectors/session-bundle-001.json";

function fromHex(s: string): Uint8Array {
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substring(i * 2, i * 2 + 2), 16);
  return out;
}
function toHex(b: Uint8Array): string {
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

beforeAll(async () => {
  await sodium.ready;
});

describe("cross-impl test vectors", () => {
  it("x25519-ecdh-001: shared secret matches", () => {
    const macPriv = fromHex(x25519Vec.mac_priv_hex);
    const iosPub = fromHex(x25519Vec.ios_pub_hex);
    const got = sodium.crypto_scalarmult(macPriv, iosPub);
    expect(toHex(got)).toBe(x25519Vec.expected_shared_secret_hex);
  });

  it("hkdf-sha256-001: derived key matches", () => {
    const sharedSecret = fromHex(hkdfVec.shared_secret_hex);
    const salt = fromHex(hkdfVec.salt_hex);
    const info = fromHex(hkdfVec.info_hex);
    const prk = sodium.crypto_auth_hmacsha256(sharedSecret, salt);
    const tIn = new Uint8Array(info.length + 1);
    tIn.set(info, 0);
    tIn[info.length] = 0x01;
    const got = sodium.crypto_auth_hmacsha256(tIn, prk).slice(0, hkdfVec.output_len);
    expect(toHex(got)).toBe(hkdfVec.expected_key_hex);
  });

  it("xchacha20-poly1305-001: ciphertext + tag match", () => {
    const key = fromHex(aeadEncVec.key_hex);
    const nonce = fromHex(aeadEncVec.nonce_hex);
    const aad = fromHex(aeadEncVec.aad_hex);
    const plaintext = fromHex(aeadEncVec.plaintext_hex);
    const got = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, aad, null, nonce, key);
    expect(toHex(got)).toBe(aeadEncVec.expected_ciphertext_hex);
  });

  it("xchacha20-poly1305-roundtrip-001: decrypts to plaintext", () => {
    const key = fromHex(aeadDecVec.key_hex);
    const nonce = fromHex(aeadDecVec.nonce_hex);
    const aad = new TextEncoder().encode(aeadDecVec.aad_ascii);
    const ciphertext = fromHex(aeadDecVec.ciphertext_hex);
    const got = sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(null, ciphertext, aad, nonce, key);
    expect(toHex(got)).toBe(aeadDecVec.expected_plaintext_hex);
  });

  it("tampered-ciphertext-001: decryption throws on byte flip", () => {
    const key = fromHex(tamperVec.key_hex);
    const nonce = fromHex(tamperVec.nonce_hex);
    const aad = new TextEncoder().encode(tamperVec.aad_ascii);
    const tampered = fromHex(tamperVec.tampered_ciphertext_hex);
    expect(() =>
      sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(null, tampered, aad, nonce, key)
    ).toThrow();
  });

  it("envelope-header-001: serialization is byte-exact", () => {
    const header = headerVec.header_object as { v: number; from: string; type: string };
    // Must serialize with v→from→type key order (the source emits this).
    const got = JSON.stringify({ v: header.v, from: header.from, type: header.type });
    expect(got).toBe(headerVec.expected_serialized_ascii);
    expect(toHex(new TextEncoder().encode(got))).toBe(headerVec.expected_serialized_hex);
  });

  it("session-bundle-001: bundle base64 encoding is byte-exact", () => {
    // We don't have Buffer in workerd, but btoa over UTF-8 ASCII matches.
    const json = bundleVec.expected_bundle_json;
    const got = btoa(json);
    expect(got).toBe(bundleVec.expected_bundle_base64);
  });
});
