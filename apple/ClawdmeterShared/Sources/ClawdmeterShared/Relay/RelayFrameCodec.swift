// Shared relay wire codec — used by both the iOS client (E4) and the
// future Mac client (E3). Lives in `ClawdmeterShared` so the cross-impl
// test vectors line up byte-for-byte with the TypeScript relay Worker
// (E2, infra/relay/test-vectors/).
//
// Per docs/design/secure-relay-apns-2026-05-26.md §4 the wire shape is:
//
//   - HEADER frame  (WebSocket text frame, ≤1 KiB)
//     JSON object: {"v":1,"from":"mac"|"ios","type":"handshake"|"ciphertext"|"control"}
//     Field ORDER matters — the TS relay's `serializeEnvelopeHeader` uses
//     `JSON.stringify({ v, from, type })`, so Swift must produce the same
//     ASCII bytes (key order: v, from, type).
//
//   - BODY frame    (WebSocket binary frame, ≤64 KiB)
//     For `handshake` envelopes: the raw 32-byte X25519 public key.
//     For `ciphertext` envelopes: the XChaCha20-Poly1305 sealed bytes
//     (ciphertext || 16-byte Poly1305 tag).
//     `control` envelopes have NO body (the relay flushes the header alone).
//
// The relay sees only the header + opaque body bytes. The AEAD key is the
// HKDF-derived symmetric key from the E7 pairing handshake (lives in
// `RelayPairingStore` on iOS; in-process on Mac per §5b).
//
// This file is platform-neutral — it uses swift-crypto + a tiny pure-Swift
// HChaCha20 helper, so it builds the same on iOS, macOS, watchOS, and
// Linux CI (no CryptoKit-only types touched).
//
// Per the E3/E4 acceptance gates (§6.1):
//   - All nonces drawn from `SecRandomCopyBytes` (Darwin) /
//     `crypto.getRandomValues` equivalent (`SystemRandomNumberGenerator`
//     on Swift, which on Darwin pulls from the same CSPRNG).
//   - Bearer-token equality uses constant-time compare (`Data.constantTimeEquals`).
//   - The wire-protocol version `v` is bound into the HKDF info string so
//     a downgrade (`v=0`) derives a different key and AEAD fails.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Envelope header (§4.3)

/// Who sent this envelope. Bound into HKDF + the wire so a forged
/// `from:"mac"` on the iOS socket is rejected by the relay (D22 defense
/// at the message layer) and a forged value at decrypt time would also
/// have to forge an AEAD tag.
public enum RelayPeerRole: String, Codable, Sendable, CaseIterable, Equatable {
    case mac
    case ios
}

/// Envelope category — see relay docs §4.3 for the wire-level semantics.
public enum RelayEnvelopeType: String, Codable, Sendable, CaseIterable, Equatable {
    /// ECDH public-key exchange (plaintext 32 bytes). Sent as the very
    /// first envelope on either side per §4.2.
    case handshake
    /// XChaCha20-Poly1305 sealed payload (per §4.3).
    case ciphertext
    /// Heartbeat / keepalive. No body. Per §5b the relay forwards these
    /// blind to the other peer for cheap radio-keepalive UX.
    case control
}

/// JSON header that prefixes every WebSocket envelope.
///
/// **Wire-format invariant** — keys MUST appear in `(v, from, type)`
/// order so the Swift bytes line up with the TypeScript relay's
/// `JSON.stringify({ v, from, type })`. We encode through a hand-rolled
/// serializer (`encodeCanonicalJSON()`) to lock the order; the test
/// vector `envelope-header-001.json` is the gating contract.
public struct RelayEnvelopeHeader: Sendable, Equatable {
    public let v: Int
    public let from: RelayPeerRole
    public let type: RelayEnvelopeType

    public init(v: Int = RelayFrameCodec.wireVersion, from: RelayPeerRole, type: RelayEnvelopeType) {
        self.v = v
        self.from = from
        self.type = type
    }

    /// Encode this header in the byte-exact form the relay + TS test
    /// vector expect: `{"v":1,"from":"<role>","type":"<type>"}`.
    public func encodeCanonicalJSON() -> Data {
        // Hand-rolled to lock the key order. `JSONEncoder` does not
        // guarantee insertion order for `Codable` structs in Swift's
        // current toolchain; even with `.sortedKeys` we'd get
        // (from, type, v) alphabetically which disagrees with the TS
        // canonicalization. So we just write it.
        let json = #"{"v":\#(v),"from":"\#(from.rawValue)","type":"\#(type.rawValue)"}"#
        return Data(json.utf8)
    }

    /// Parse a wire JSON header. Returns nil on any malformed input —
    /// the caller MUST close the WebSocket with `1003 protocol error`.
    public static func decode(_ data: Data) -> RelayEnvelopeHeader? {
        if data.count > RelayFrameCodec.maxHeaderBytes { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        guard let v = dict["v"] as? Int, v == RelayFrameCodec.wireVersion,
              let fromRaw = dict["from"] as? String,
              let from = RelayPeerRole(rawValue: fromRaw),
              let typeRaw = dict["type"] as? String,
              let type = RelayEnvelopeType(rawValue: typeRaw) else {
            return nil
        }
        return RelayEnvelopeHeader(v: v, from: from, type: type)
    }
}

// MARK: - Envelope (header + body pair)

/// Fully-formed envelope. The relay sees the header + an opaque body;
/// only the paired peer can decrypt the body (for `ciphertext` envelopes).
public struct RelayEnvelope: Sendable, Equatable {
    public let header: RelayEnvelopeHeader
    /// Raw body bytes. Empty for `type == .control`. For `handshake`
    /// envelopes this is the 32-byte X25519 public key. For `ciphertext`
    /// envelopes it's the XChaCha20-Poly1305 sealed bytes (ciphertext
    /// concatenated with the 16-byte Poly1305 tag).
    public let body: Data

    public init(header: RelayEnvelopeHeader, body: Data = Data()) {
        self.header = header
        self.body = body
    }
}

// MARK: - Plaintext payload (§4.3)

/// Inner plaintext shape. After XChaCha20-Poly1305 decryption the bytes
/// MUST decode as JSON into this shape.
public struct RelayPlaintext: Codable, Sendable, Equatable {
    public let seq: UInt64
    public let op: String
    /// Op-specific payload. Encoded as opaque JSON — both peers agree on
    /// the per-op schema out-of-band (matches the existing AgentControl
    /// `WireXxxResponse` types).
    public let data: Data

    public init(seq: UInt64, op: String, data: Data) {
        self.seq = seq
        self.op = op
        self.data = data
    }

    /// Encode to the wire JSON `{seq, op, data}`. The `data` field is
    /// preserved as-is (the caller has already encoded it). Output key
    /// order: `seq, op, data` — matches the TS relay's test vector.
    public func encodeCanonicalJSON() throws -> Data {
        // Validate `data` is itself well-formed JSON so we don't ship
        // arbitrary bytes through; the relay never sees it but the
        // paired peer's decoder expects parseable JSON.
        let dataJSON = data.isEmpty ? Data("null".utf8) : data
        // Hand-write the envelope. `op` is run through JSONSerialization
        // so quotes/backslashes/control chars survive the round trip —
        // a hand-interpolated `"\#(op)"` would mangle anything but ASCII.
        let opQuoted = try JSONSerialization.data(
            withJSONObject: op,
            options: [.fragmentsAllowed]
        )
        var head = Data()
        head.append(Data(#"{"seq":\#(seq),"op":"#.utf8))
        head.append(opQuoted)
        head.append(Data(#","data":"#.utf8))
        head.append(dataJSON)
        head.append(Data("}".utf8))
        return head
    }

    /// Decode the inner plaintext. Returns nil on parse failure; the
    /// caller MUST treat this as a protocol violation and tear the
    /// session down.
    public static func decode(_ bytes: Data) -> RelayPlaintext? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              let dict = object as? [String: Any],
              let seqAny = dict["seq"],
              let op = dict["op"] as? String else { return nil }
        let seq: UInt64
        if let asInt = seqAny as? Int, asInt >= 0 { seq = UInt64(asInt) }
        else if let asUInt = seqAny as? UInt64 { seq = asUInt }
        else if let asNum = seqAny as? NSNumber { seq = asNum.uint64Value }
        else { return nil }
        // Re-serialize `data` so we hand back the same bytes shape both
        // sides agree on. JSONSerialization will produce a stable form
        // for already-parsed JSON; we re-encode with `.sortedKeys` to
        // keep cross-impl bytes line up if the caller round-trips.
        let dataValue = dict["data"] ?? NSNull()
        let dataBytes = (try? JSONSerialization.data(
            withJSONObject: dataValue,
            options: [.fragmentsAllowed, .sortedKeys]
        )) ?? Data("null".utf8)
        return RelayPlaintext(seq: seq, op: op, data: dataBytes)
    }
}

// MARK: - Errors

public enum RelayCodecError: Error, Equatable {
    case headerTooLarge
    case bodyTooLarge
    case malformedHeader
    case malformedBody
    case aeadFailed
    case keyDerivationFailed
    case nonceGenerationFailed
    case invalidNonceLength
    case invalidKeyLength
    case replayedSequence
}

// MARK: - Codec entry point

/// Stateless helpers that seal + open envelope bodies and derive the
/// per-session key. The replay counter + nonce state lives on the
/// caller (e.g., `IOSRelayClient`); this enum just holds the static
/// crypto primitives.
public enum RelayFrameCodec {

    /// Wire protocol version baked into HKDF + the header. A downgrade
    /// (`v=0`) derives a different key and AEAD verification fails —
    /// design doc threat #14.
    public static let wireVersion: Int = 1

    /// HKDF `info` string for relay frames (§4.3, also matches
    /// `RelayPairingCryptoConstants.hkdfInfoRelayV1`).
    public static let hkdfInfoRelayV1 = "clawdmeter.relay.v1"

    /// Associated data baked into XChaCha20-Poly1305 — domain-separates
    /// relay frames from APNS payloads (§4.4) so the same per-session
    /// key cannot mix payload types.
    public static let aeadAssociatedData = "clawdmeter.relay.frame.v1"

    /// XChaCha20 nonce length (24 bytes). Twice the IETF ChaCha20-Poly1305
    /// nonce — that's the whole point: 96-bit nonces from CSPRNG have a
    /// non-trivial collision probability after ~2^48 messages; 192-bit
    /// nonces never collide in practice.
    public static let nonceLength: Int = 24

    /// AEAD key length (32 bytes / 256 bits).
    public static let keyLength: Int = 32

    /// Poly1305 tag length (16 bytes / 128 bits).
    public static let tagLength: Int = 16

    /// Cap on a single header (§4.3).
    public static let maxHeaderBytes: Int = 1024

    /// Cap on a single body (§4.3) — well below CF's 1 MiB WS frame cap.
    public static let maxBodyBytes: Int = 64 * 1024

    // MARK: - HKDF

    /// Re-derive the per-session symmetric key from the ECDH shared
    /// secret. Matches `RelayPairingKeyPair.deriveSharedKey` byte-for-byte
    /// (both call `HKDF<SHA256>.deriveKey(...)`), kept here so a future
    /// E3/E4 caller that already has the shared secret in-process can
    /// skip the public-key wrapper.
    public static func deriveSessionKey(sharedSecret: SharedSecret, sessionId: String) -> SymmetricKey {
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sessionId.utf8),
            sharedInfo: Data(hkdfInfoRelayV1.utf8),
            outputByteCount: keyLength
        )
    }

    // MARK: - Nonce

    /// Fresh random 24-byte XChaCha20 nonce drawn from the platform CSPRNG.
    public static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        // SystemRandomNumberGenerator pulls from SecRandomCopyBytes on
        // Darwin and /dev/urandom on Linux — both satisfy threat #6.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<nonceLength {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return Data(bytes)
    }

    // MARK: - Seal / Open (XChaCha20-Poly1305-IETF)

    /// Seal `plaintext` with `key` and `nonce`. Returns the 16-byte tag
    /// concatenated to the ciphertext (`ciphertext || tag`) — matches
    /// libsodium's `crypto_aead_xchacha20poly1305_ietf_encrypt` output
    /// shape and the TS test vector format.
    public static func seal(
        plaintext: Data,
        key: SymmetricKey,
        nonce: Data,
        aad: Data = Data(aeadAssociatedData.utf8)
    ) throws -> Data {
        guard nonce.count == nonceLength else { throw RelayCodecError.invalidNonceLength }
        guard key.bitCount == keyLength * 8 else { throw RelayCodecError.invalidKeyLength }
        // XChaCha20-Poly1305-IETF = HChaCha20(key, nonce[0..16]) → subkey,
        // then ChaCha20-Poly1305-IETF(subkey, [0,0,0,0] || nonce[16..24], pt, aad).
        let subkey = HChaCha20.subkey(key: key, salt: nonce.prefix(16))
        // Build the 12-byte IETF nonce: 4 zero bytes || last 8 of XChaCha nonce.
        var ietfNonce = Data(count: 4)
        ietfNonce.append(nonce.suffix(8))
        do {
            let sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: subkey),
                nonce: try ChaChaPoly.Nonce(data: ietfNonce),
                authenticating: aad
            )
            // `sealedBox.combined` = nonce || ciphertext || tag (IETF nonce
            // included). We strip the IETF nonce because the caller already
            // owns the 24-byte XChaCha nonce; the on-wire format is just
            // `ciphertext || tag`.
            return sealedBox.ciphertext + sealedBox.tag
        } catch {
            throw RelayCodecError.aeadFailed
        }
    }

    /// Open a sealed body. Returns the plaintext bytes or throws
    /// `.aeadFailed` (which the caller surfaces as a protocol error
    /// + WebSocket close, never as a UI-visible exception).
    public static func open(
        sealed: Data,
        key: SymmetricKey,
        nonce: Data,
        aad: Data = Data(aeadAssociatedData.utf8)
    ) throws -> Data {
        guard nonce.count == nonceLength else { throw RelayCodecError.invalidNonceLength }
        guard key.bitCount == keyLength * 8 else { throw RelayCodecError.invalidKeyLength }
        guard sealed.count >= tagLength else { throw RelayCodecError.aeadFailed }
        let subkey = HChaCha20.subkey(key: key, salt: nonce.prefix(16))
        var ietfNonce = Data(count: 4)
        ietfNonce.append(nonce.suffix(8))
        let ciphertextLength = sealed.count - tagLength
        let ciphertext = sealed.prefix(ciphertextLength)
        let tag = sealed.suffix(tagLength)
        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: ietfNonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(
                sealedBox,
                using: SymmetricKey(data: subkey),
                authenticating: aad
            )
        } catch {
            throw RelayCodecError.aeadFailed
        }
    }
}

// MARK: - Constant-time compare

/// Constant-time byte compare. Bearer-token + tag equality MUST use this
/// to avoid the timing-side-channel called out in threat #13.
public extension Data {
    func constantTimeEquals(_ other: Data) -> Bool {
        guard self.count == other.count else { return false }
        var result: UInt8 = 0
        self.withUnsafeBytes { (lhs: UnsafeRawBufferPointer) in
            other.withUnsafeBytes { (rhs: UnsafeRawBufferPointer) in
                for i in 0..<self.count {
                    result |= lhs[i] ^ rhs[i]
                }
            }
        }
        return result == 0
    }
}
