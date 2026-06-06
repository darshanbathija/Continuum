// Regenerate cross-impl test vectors. Run with:
//   node test/test-vectors.gen.cjs
//
// This file is NOT part of the vitest run. It produces the fixtures in
// ../test-vectors/. CJS to dodge libsodium-wrappers-sumo's ESM packaging
// bug.

const sodium = require("libsodium-wrappers-sumo");
const crypto = require("node:crypto");
const { writeFileSync } = require("node:fs");
const { join } = require("node:path");

(async () => {
  await sodium.ready;

  const outDir = join(__dirname, "..", "test-vectors");

  function hex(b) {
    return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  }

  // X25519 ECDH
  const macPriv = new Uint8Array(32).fill(0x01);
  const iosPriv = new Uint8Array(32).fill(0x02);
  const macPub = sodium.crypto_scalarmult_base(macPriv);
  const iosPub = sodium.crypto_scalarmult_base(iosPriv);
  const sharedSecret = sodium.crypto_scalarmult(macPriv, iosPub);
  const sharedSecretCheck = sodium.crypto_scalarmult(iosPriv, macPub);
  if (hex(sharedSecret) !== hex(sharedSecretCheck)) {
    throw new Error("X25519 ECDH did not commute");
  }

  writeFileSync(
    join(outDir, "x25519-ecdh-001.json"),
    JSON.stringify(
      {
        name: "x25519-ecdh-001",
        kind: "x25519-ecdh",
        description:
          "X25519 ECDH: Mac priv = 0x01*32, iOS priv = 0x02*32. Shared secret must match in both directions.",
        mac_priv_hex: hex(macPriv),
        mac_pub_hex: hex(macPub),
        ios_priv_hex: hex(iosPriv),
        ios_pub_hex: hex(iosPub),
        expected_shared_secret_hex: hex(sharedSecret),
      },
      null,
      2
    ) + "\n"
  );

  // HKDF-SHA256 — use extract + expand manually for cross-impl clarity.
  const sid = new TextEncoder().encode("0123456789abcdef0123456789abcdef");
  const info = new TextEncoder().encode("clawdmeter.relay.v1");
  const prk = sodium.crypto_auth_hmacsha256(sharedSecret, sid);
  const tIn = new Uint8Array(info.length + 1);
  tIn.set(info, 0);
  tIn[info.length] = 0x01;
  const derivedKey = sodium.crypto_auth_hmacsha256(tIn, prk).slice(0, 32);

  writeFileSync(
    join(outDir, "hkdf-sha256-001.json"),
    JSON.stringify(
      {
        name: "hkdf-sha256-001",
        kind: "hkdf-sha256",
        description:
          "HKDF-SHA256: extract(salt=session-id-ascii, ikm=X25519 shared secret) then expand(info='clawdmeter.relay.v1', L=32). Output = symmetric key for XChaCha20-Poly1305.",
        shared_secret_hex: hex(sharedSecret),
        salt_ascii: "0123456789abcdef0123456789abcdef",
        salt_hex: hex(sid),
        info_ascii: "clawdmeter.relay.v1",
        info_hex: hex(info),
        prk_hex: hex(prk),
        output_len: 32,
        expected_key_hex: hex(derivedKey),
      },
      null,
      2
    ) + "\n"
  );

  // XChaCha20-Poly1305 AEAD encrypt
  const aeadKey = derivedKey;
  const aeadNonce = new Uint8Array(24);
  for (let i = 0; i < 24; i++) aeadNonce[i] = i + 1;
  const aeadPlaintext = new TextEncoder().encode(
    JSON.stringify({ seq: 1, op: "approve_plan", data: { ok: true } })
  );
  const aeadAad = new TextEncoder().encode("clawdmeter.relay.frame.v1");
  const aeadCiphertext = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
    aeadPlaintext,
    aeadAad,
    null,
    aeadNonce,
    aeadKey
  );

  writeFileSync(
    join(outDir, "xchacha20-poly1305-001.json"),
    JSON.stringify(
      {
        name: "xchacha20-poly1305-001",
        kind: "xchacha20-poly1305-encrypt",
        description:
          "XChaCha20-Poly1305 AEAD encryption: deterministic key + nonce + plaintext, AAD = 'clawdmeter.relay.frame.v1'. Swift CryptoKit ChaChaPoly.seal MUST produce the same ciphertext + tag.",
        key_hex: hex(aeadKey),
        nonce_hex: hex(aeadNonce),
        aad_ascii: "clawdmeter.relay.frame.v1",
        aad_hex: hex(aeadAad),
        plaintext_ascii: Buffer.from(aeadPlaintext).toString("utf-8"),
        plaintext_hex: hex(aeadPlaintext),
        expected_ciphertext_hex: hex(aeadCiphertext),
        expected_ciphertext_len: aeadCiphertext.byteLength,
        expected_tag_hex: hex(aeadCiphertext.slice(-16)),
      },
      null,
      2
    ) + "\n"
  );

  // Decryption direction.
  const decrypted = sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
    null,
    aeadCiphertext,
    aeadAad,
    aeadNonce,
    aeadKey
  );
  if (hex(decrypted) !== hex(aeadPlaintext)) {
    throw new Error("AEAD did not roundtrip");
  }
  writeFileSync(
    join(outDir, "xchacha20-poly1305-roundtrip-001.json"),
    JSON.stringify(
      {
        name: "xchacha20-poly1305-roundtrip-001",
        kind: "xchacha20-poly1305-decrypt",
        description:
          "XChaCha20-Poly1305 AEAD decryption: ciphertext from xchacha20-poly1305-001 MUST decrypt to the original plaintext.",
        key_hex: hex(aeadKey),
        nonce_hex: hex(aeadNonce),
        aad_ascii: "clawdmeter.relay.frame.v1",
        ciphertext_hex: hex(aeadCiphertext),
        expected_plaintext_hex: hex(aeadPlaintext),
      },
      null,
      2
    ) + "\n"
  );

  // Tamper detection
  const tampered = new Uint8Array(aeadCiphertext);
  tampered[5] ^= 0x80;
  let tamperDetected = false;
  try {
    sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
      null,
      tampered,
      aeadAad,
      aeadNonce,
      aeadKey
    );
  } catch {
    tamperDetected = true;
  }
  if (!tamperDetected) {
    throw new Error("AEAD failed to detect tamper");
  }
  writeFileSync(
    join(outDir, "tampered-ciphertext-001.json"),
    JSON.stringify(
      {
        name: "tampered-ciphertext-001",
        kind: "xchacha20-poly1305-tamper",
        description:
          "Negative test: flipping byte 5 of ciphertext (XOR 0x80) MUST cause AEAD verification to fail (Poly1305 integrity).",
        key_hex: hex(aeadKey),
        nonce_hex: hex(aeadNonce),
        aad_ascii: "clawdmeter.relay.frame.v1",
        original_ciphertext_hex: hex(aeadCiphertext),
        tampered_ciphertext_hex: hex(tampered),
        tamper_byte_index: 5,
        tamper_xor_mask: "0x80",
        expected_decrypt_throws: true,
      },
      null,
      2
    ) + "\n"
  );

  // Envelope header canonical encoding.
  const envelopeHeader = { v: 1, from: "mac", type: "ciphertext" };
  const envelopeHeaderText = JSON.stringify(envelopeHeader);
  const envelopeHeaderBytes = new TextEncoder().encode(envelopeHeaderText);

  writeFileSync(
    join(outDir, "envelope-header-001.json"),
    JSON.stringify(
      {
        name: "envelope-header-001",
        kind: "envelope-header",
        description:
          "Canonical envelope header: keys MUST appear in (v, from, type) order. Swift Codable + JSONEncoder MUST produce identical bytes.",
        header_object: envelopeHeader,
        expected_serialized_ascii: envelopeHeaderText,
        expected_serialized_hex: hex(envelopeHeaderBytes),
      },
      null,
      2
    ) + "\n"
  );

  // Session bundle base64-JSON
  const sessionId = "session-bundle-001";
  const bundleIssuedAtSeconds = 1735689300;
  const bundleNonce = "creation_nonce_001";
  const macTokenHash = hex(sodium.crypto_hash_sha256(new TextEncoder().encode("mac-token-001")));
  const iosTokenHash = hex(sodium.crypto_hash_sha256(new TextEncoder().encode("ios-token-001")));
  const bundleTTLSeconds = 1735689600;
  const operatorSigningKey = Buffer.from("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=", "base64");
  const creationMessage = [
    "relay-create",
    sessionId,
    macTokenHash,
    iosTokenHash,
    String(bundleTTLSeconds),
    String(bundleIssuedAtSeconds),
    bundleNonce,
  ].join(":");
  const creationSignature = crypto
    .createHmac("sha256", operatorSigningKey)
    .update(creationMessage)
    .digest("base64")
    .replace(/=+$/, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  const bundle = {
    creation: {
      issuedAtSeconds: bundleIssuedAtSeconds,
      nonce: bundleNonce,
      signature: creationSignature,
    },
    iosTokenHash,
    macTokenHash,
    ttlSeconds: bundleTTLSeconds,
  };
  const bundleJson = JSON.stringify(bundle);
  const bundleBase64 = Buffer.from(bundleJson, "utf-8").toString("base64");

  writeFileSync(
    join(outDir, "session-bundle-001.json"),
    JSON.stringify(
      {
        name: "session-bundle-001",
        kind: "session-bundle",
        description:
          "Operator-signed auth bundle the first peer presents on ?bundle=<base64-json>. Swift encodes identical fields.",
        session_id: sessionId,
        raw_mac_token_ascii: "mac-token-001",
        raw_ios_token_ascii: "ios-token-001",
        creation_message: creationMessage,
        bundle_object: bundle,
        expected_bundle_json: bundleJson,
        expected_bundle_base64: bundleBase64,
      },
      null,
      2
    ) + "\n"
  );

  console.log("Wrote 7 test vectors to", outDir);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
