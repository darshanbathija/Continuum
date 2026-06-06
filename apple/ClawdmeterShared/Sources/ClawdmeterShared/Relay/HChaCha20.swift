// HChaCha20 — sub-key derivation for XChaCha20-Poly1305.
//
// XChaCha20-Poly1305-IETF (the AEAD libsodium calls
// `crypto_aead_xchacha20poly1305_ietf_encrypt`) is defined as:
//
//   subkey = HChaCha20(key, nonce[0..16])
//   ciphertext, tag = ChaCha20-Poly1305-IETF(
//       subkey,
//       0x00000000 || nonce[16..24],
//       plaintext,
//       associated_data
//   )
//
// CryptoKit exposes `ChaChaPoly` (the IETF variant with 12-byte nonces) but
// NOT the raw ChaCha20 quarter-round building block,
// which is what HChaCha20 boils down to: a single 20-round permutation
// on the ChaCha20 state matrix where the output is the first 128 bits +
// last 128 bits (skipping the intermediate state).
//
// This file is the only pure-Swift crypto in the project. It's tiny —
// ~80 LOC — and gated by the cross-impl test vectors in
// `apple/ClawdmeterShared/Tests/.../RelayCodecCryptoTests.swift`
// which round-trip against the libsodium-generated vectors from
// `infra/relay/test-vectors/`. A regression here is caught loudly.
//
// Reference: RFC draft-irtf-cfrg-xchacha-03 §2.2.

import Foundation

enum HChaCha20 {

    /// ChaCha20 magic constants — ASCII "expand 32-byte k".
    private static let sigma: [UInt32] = [
        0x61707865, // "expa"
        0x3320646e, // "nd 3"
        0x79622d32, // "2-by"
        0x6b206574, // "te k"
    ]

    /// Derive the 32-byte XChaCha20 sub-key from `(key, salt)`.
    ///
    /// - Parameters:
    ///   - key: 32-byte ChaCha20 key (the AEAD master key).
    ///   - salt: First 16 bytes of the XChaCha20 nonce.
    /// - Returns: 32 raw sub-key bytes. The caller wraps these in a
    ///   `SymmetricKey` before passing to `ChaChaPoly.seal/open`.
    static func subkey(key: SymmetricKey, salt: some DataProtocol) -> Data {
        precondition(salt.count == 16, "HChaCha20 salt must be 16 bytes")
        var keyBytes = [UInt8](repeating: 0, count: 32)
        key.withUnsafeBytes { src in
            precondition(src.count == 32, "HChaCha20 key must be 32 bytes")
            for i in 0..<32 { keyBytes[i] = src[i] }
        }
        let saltBytes = Array(salt)
        let keyWords = words(from: keyBytes)
        let saltWords = words(from: saltBytes)

        // Initial state: sigma || key (8 words) || salt (4 words).
        var state: [UInt32] = [
            sigma[0], sigma[1], sigma[2], sigma[3],
            keyWords[0], keyWords[1], keyWords[2], keyWords[3],
            keyWords[4], keyWords[5], keyWords[6], keyWords[7],
            saltWords[0], saltWords[1], saltWords[2], saltWords[3],
        ]

        // 20 rounds = 10 column rounds + 10 diagonal rounds (interleaved).
        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        // HChaCha20 output = state[0..4] || state[12..16] (the constants
        // + nonce rows of the post-permutation matrix). Critically, no
        // initial-state addback — that's the difference vs ChaCha20.
        var out = [UInt8](repeating: 0, count: 32)
        write(state[0], to: &out, offset: 0)
        write(state[1], to: &out, offset: 4)
        write(state[2], to: &out, offset: 8)
        write(state[3], to: &out, offset: 12)
        write(state[12], to: &out, offset: 16)
        write(state[13], to: &out, offset: 20)
        write(state[14], to: &out, offset: 24)
        write(state[15], to: &out, offset: 28)
        return Data(out)
    }

    // MARK: - Helpers

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }

    /// Little-endian load of 4 bytes → UInt32.
    private static func words(from bytes: [UInt8]) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(bytes.count / 4)
        var i = 0
        while i + 4 <= bytes.count {
            let w = UInt32(bytes[i])
                | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16)
                | (UInt32(bytes[i + 3]) << 24)
            out.append(w)
            i += 4
        }
        return out
    }

    /// Little-endian store of UInt32 → 4 bytes.
    private static func write(_ value: UInt32, to bytes: inout [UInt8], offset: Int) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8((value >> 16) & 0xff)
        bytes[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}

import CryptoKit
