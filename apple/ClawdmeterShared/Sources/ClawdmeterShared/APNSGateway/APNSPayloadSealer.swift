// E6: ChaCha20-Poly1305 payload sealing for the APNS gateway push path.
//
// Per docs/design/secure-relay-apns-2026-05-26.md §4.4 the APNS gateway
// Worker forwards an opaque ciphertext blob to Apple — the Worker never
// decrypts. Only the paired iPhone, which holds the same HKDF-derived
// symmetric key, can recover the plaintext.
//
// The design doc names "ChaCha20-Poly1305 XChaCha20" with 24-byte nonces.
// CryptoKit on macOS/iOS only ships the IETF ChaCha20-Poly1305 construction
// (RFC 8439) with 12-byte nonces via `ChaChaPoly`. Since both Mac and
// iPhone use CryptoKit (no libsodium dep on either platform), we ship the
// 12-byte-nonce variant — which still gives a 2^96 nonce space, more than
// enough for the 15-minute pairing-session lifetime. The Worker doesn't
// care: it accepts any base64-encoded opaque blob.
//
// Sealed wire format:
//   sealed_bytes = nonce (12 bytes) || ciphertext || tag (16 bytes)
//   wire         = base64(sealed_bytes)
//
// CryptoKit's `ChaChaPoly.SealedBox.combined` produces exactly this layout,
// which we wrap in standard base64 (NOT base64url — the Worker accepts
// both via `B64_ANY`, but matching the relay envelope's standard base64
// keeps tooling uniform).

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Stateless seal + open for the APNS gateway path. The caller threads in
/// the symmetric key — it must be the 32 bytes that came out of
/// `RelayPairingKeyPair.deriveSharedKey(...)` with HKDF `info` set to
/// `RelayPairingCryptoConstants.hkdfInfoApnsV1`.
public enum APNSPayloadSealer {

    /// Maximum cleartext size we'll seal. APNS hard-caps the final encrypted
    /// payload at 4096 bytes; the Worker validates the base64 form at 3500
    /// chars. We hard-stop in `seal(...)` at 2KB cleartext (≈2.7KB base64
    /// after the 28-byte AEAD overhead) so a future schema bloat doesn't
    /// silently get rejected at the edge.
    public static let maxCleartextBytes = 2048

    /// Seal `plaintext` under `keyBytes`. Returns the wire-encoded base64
    /// string the Mac POSTs in the `encryptedPayload` field.
    ///
    /// `nonceOverride` is for cross-impl test vectors only — production
    /// callers omit it and CryptoKit generates a random 12-byte nonce per
    /// call.
    public static func seal(
        plaintext: Data,
        keyBytes: Data,
        nonceOverride: Data? = nil
    ) throws -> String {
        guard plaintext.count <= maxCleartextBytes else {
            throw APNSPayloadSealError.plaintextTooLarge(size: plaintext.count, limit: maxCleartextBytes)
        }
        guard keyBytes.count == 32 else {
            throw APNSPayloadSealError.invalidKeyLength
        }
        let key = SymmetricKey(data: keyBytes)
        let nonce: ChaChaPoly.Nonce
        if let nonceOverride {
            guard nonceOverride.count == 12 else {
                throw APNSPayloadSealError.invalidNonceLength
            }
            nonce = try ChaChaPoly.Nonce(data: nonceOverride)
        } else {
            nonce = ChaChaPoly.Nonce()
        }
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        return sealed.combined.base64EncodedString()
    }

    /// Inverse of `seal`. Used by the iPhone (E4) and by Mac tests that
    /// verify the round-trip. Returns plaintext or throws if decryption
    /// fails (tampered ciphertext, wrong key, etc.).
    public static func open(
        wire: String,
        keyBytes: Data
    ) throws -> Data {
        guard let combined = Data(base64Encoded: wire) else {
            throw APNSPayloadSealError.invalidBase64
        }
        guard keyBytes.count == 32 else {
            throw APNSPayloadSealError.invalidKeyLength
        }
        let key = SymmetricKey(data: keyBytes)
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(box, using: key)
    }

    /// Convenience that JSON-encodes `body` then seals. Used by the
    /// `APNSGatewayClient` push-trigger code paths.
    public static func sealJSON<T: Encodable>(
        body: T,
        keyBytes: Data,
        encoder: JSONEncoder = APNSPayloadSealer.canonicalEncoder
    ) throws -> String {
        let cleartext = try encoder.encode(body)
        return try seal(plaintext: cleartext, keyBytes: keyBytes)
    }

    /// Inverse of `sealJSON`.
    public static func openJSON<T: Decodable>(
        as type: T.Type,
        wire: String,
        keyBytes: Data,
        decoder: JSONDecoder = APNSPayloadSealer.canonicalDecoder
    ) throws -> T {
        let plaintext = try open(wire: wire, keyBytes: keyBytes)
        return try decoder.decode(T.self, from: plaintext)
    }

    /// Sorted-keys encoder so test vectors and cross-impl assertions are
    /// byte-stable. Production code can pass its own encoder if it has
    /// different formatting needs.
    public static var canonicalEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    /// Pair to `canonicalEncoder`.
    public static var canonicalDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

public enum APNSPayloadSealError: Error, Equatable {
    case plaintextTooLarge(size: Int, limit: Int)
    case invalidKeyLength
    case invalidNonceLength
    case invalidBase64
}

// MARK: - Push body shape

/// Cleartext shape the Mac seals into `encryptedPayload`. Only the paired
/// iPhone — which holds the same HKDF-derived key — can decode this.
///
/// Field names are short to stay under the 4KB APNS limit even with the
/// 28-byte AEAD overhead and the base64 expansion. Don't add UI strings
/// here that the daemon already exposes via the WebSocket — the iPhone
/// can fetch full bodies from the daemon on wake.
public struct APNSPushBody: Codable, Sendable, Equatable {
    /// Stable kind identifier the iPhone branches on to choose the local
    /// notification surface (planning card vs done-toast vs permission UI).
    public let kind: String

    /// Session UUID the push refers to.
    public let sessionId: String

    /// Short human title — what the iOS notification banner renders.
    public let title: String

    /// Short human body — what the iOS notification banner subtext renders.
    /// MUST stay under ~140 bytes to leave room for the AEAD overhead +
    /// base64 expansion inside the 3500-char Worker cap.
    public let body: String

    /// Mac monotonic timestamp (epoch seconds) at trigger time. Used by the
    /// SLO assertion: iPhone subtracts this from receipt time to confirm
    /// ≤2s end-to-end.
    public let triggerAt: UInt64

    public init(
        kind: String,
        sessionId: String,
        title: String,
        body: String,
        triggerAt: UInt64
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.triggerAt = triggerAt
    }
}

// MARK: - APNS-key derivation

/// Cross-platform helper that derives the APNS sibling key from the
/// relay-derived symmetric key. Used by both the Mac (sealing) and the
/// iPhone (opening). The two sides MUST produce byte-identical keys.
///
/// Inputs:
///   - `relaySymmetricKey`: the 32-byte key derived from
///     `RelayPairingKeyPair.deriveSharedKey(...)` with HKDF info=
///     `clawdmeter.relay.v1`.
///   - `sessionId`: the pairing session id (used as HKDF salt).
///
/// Returns the 32-byte APNS payload key, or nil on bad input.
public enum APNSGatewayKey {

    public static func derivePayloadKey(
        relaySymmetricKey: Data,
        sessionId: String
    ) -> Data? {
        guard relaySymmetricKey.count == 32 else { return nil }
        let symKey = SymmetricKey(data: relaySymmetricKey)
        let salt = Data(sessionId.utf8)
        let info = Data(RelayPairingCryptoConstants.hkdfInfoApnsV1.utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: symKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Sender fingerprint

/// SHA-256 hex fingerprint of the Mac's pairing public key. The Worker
/// audit-logs this so a leaked `.p8` key can be traced to which Mac was
/// abusing it. We compute it client-side and ship as the
/// `senderMacFingerprint` field (must be exactly 64 hex chars per E5
/// schema.ts:139).
public enum APNSSenderFingerprint {

    /// Compute SHA-256(macPublicKeyRawBytes) → 64 hex chars.
    /// `macPublicKeyBase64URL` is the Mac's ECDH pubkey from the pairing
    /// bundle (`RelayPairingBundle.ecdhPub`).
    public static func compute(macPublicKeyBase64URL: String) -> String? {
        guard let raw = RelayPairingBase64URL.decode(macPublicKeyBase64URL) else {
            return nil
        }
        return computeFromRaw(macPublicKeyRawBytes: raw)
    }

    public static func computeFromRaw(macPublicKeyRawBytes: Data) -> String {
        let digest = SHA256.hash(data: macPublicKeyRawBytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
