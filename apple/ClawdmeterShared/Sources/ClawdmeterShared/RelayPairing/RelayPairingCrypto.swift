// E7: relay pairing crypto — X25519 ECDH + HKDF-SHA256 key derivation.
//
// Per docs/design/secure-relay-apns-2026-05-26.md §4.2:
//   - both peers generate ephemeral X25519 keypairs at pairing time
//   - each peer sends its public key as the first frame (plaintext) over
//     the relay WSS — the relay sees the public keys but cannot derive
//     the shared secret without one of the private keys
//   - shared secret `s = X25519(myPriv, theirPub)`
//   - symmetric key `K = HKDF-SHA256(salt=sid, info="clawdmeter.relay.v1",
//     key_material=s, length=32)`
//
// We use CryptoKit on Darwin and swift-crypto everywhere else; both
// expose the identical `Curve25519.KeyAgreement` + `HKDF` APIs.
//
// E7 stops at "derive K and persist it locally". E3 (Mac) / E4 (iOS)
// will pick this up and seal frames with ChaCha20-Poly1305.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Thin wrapper around CryptoKit's `Curve25519.KeyAgreement` so callers
/// in either iOS or Mac can use the same identifier names. The private
/// key is held in process memory only — never written to Keychain, disk,
/// or App Group storage (§5b "forward secrecy by construction").
public struct RelayPairingKeyPair: Sendable {

    /// Ephemeral X25519 private key. Held in-memory, zeroized when this
    /// struct goes out of scope (CryptoKit owns the underlying buffer).
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    /// Matching public key (32 bytes raw).
    public let publicKey: Curve25519.KeyAgreement.PublicKey

    /// Generate a fresh keypair from the system CSPRNG. CryptoKit's
    /// initializer pulls bytes from `SecRandomCopyBytes` on Darwin and
    /// `/dev/urandom` (via libcrypto) on Linux — both satisfy threat #6
    /// (nonce/secret randomness) and #13 (constant-time primitives).
    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
    }

    /// Base64url-no-padding encoding of the 32-byte raw public key.
    /// This is what gets stuffed into the QR's `ecdhPub` field on the
    /// Mac side and what the iPhone sends as its first frame in E4.
    public var publicKeyBase64URL: String {
        RelayPairingBase64URL.encode(publicKey.rawRepresentation)
    }

    /// Derive the per-session symmetric key from `theirPublicKey` plus
    /// `sid` (used as HKDF salt). Returns 32 raw key bytes; in E3/E4 the
    /// caller wraps these in `SymmetricKey(data:)` before passing to
    /// `ChaChaPoly.seal`.
    ///
    /// Per §5b the salt MUST be the session id — binding the key to the
    /// session makes a stolen key useless against a different `sid`.
    public func deriveSharedKey(
        theirPublicKeyBase64URL: String,
        sessionId: String
    ) throws -> Data {
        guard let raw = RelayPairingBase64URL.decode(theirPublicKeyBase64URL) else {
            throw RelayPairingCryptoError.invalidPublicKey
        }
        guard raw.count == 32 else {
            throw RelayPairingCryptoError.invalidPublicKey
        }
        let theirPub: Curve25519.KeyAgreement.PublicKey
        do {
            theirPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        } catch {
            throw RelayPairingCryptoError.invalidPublicKey
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: theirPub)
        // HKDF: salt = sid bytes (per design doc), info = "clawdmeter.relay.v1".
        // The v1 string is bound into HKDF info so a future v2 derives a
        // different key from the same shared secret — defense against
        // threat #14 (protocol downgrade).
        let saltBytes = Data(sessionId.utf8)
        let infoBytes = Data(RelayPairingCryptoConstants.hkdfInfoRelayV1.utf8)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltBytes,
            sharedInfo: infoBytes,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

/// Constants used by both Mac + iOS code paths. Mirror the design doc
/// §4.2 strings byte-for-byte so cross-impl test vectors line up with
/// the future E2 TypeScript relay test fixtures.
public enum RelayPairingCryptoConstants {
    /// HKDF info string for the relay symmetric key (§4.2).
    public static let hkdfInfoRelayV1 = "clawdmeter.relay.v1"
    /// HKDF info string for the APNS symmetric key (§4.4). Not used in
    /// E7 — included for E6 parity.
    public static let hkdfInfoApnsV1 = "clawdmeter.apns.v1"
}

public enum RelayPairingCryptoError: Error, Equatable {
    case invalidPublicKey
}

// MARK: - Token + session-id minting helpers

/// E7 helpers that generate the bearer tokens + session ID for a new
/// pairing. The Mac uses these at QR time; the iPhone reads the values
/// out of the scanned bundle and never mints new ones.
public enum RelayPairingMint {

    /// 32 random bytes → base64url (43 chars). Used for `sid`, `macTok`,
    /// `iosTok`. CryptoKit's `SymmetricKey(size: .bits256)` pulls from
    /// the platform CSPRNG.
    public static func randomBase64URLToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        return RelayPairingBase64URL.encode(bytes)
    }
}
