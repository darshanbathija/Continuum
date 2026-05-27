// E3: relay frame codec — XChaCha20-Poly1305 envelope encode/decode shared
// by the Mac daemon (this PR) and iOS client (E4).
//
// Why hand-rolled XChaCha20? The E2 relay's cross-impl test vectors
// (infra/relay/test-vectors/xchacha20-poly1305-001.json) use
// XChaCha20-Poly1305 with a 24-byte nonce. Swift's CryptoKit/swift-crypto
// `ChaChaPoly` is RFC 8439 with a 12-byte nonce — cannot decrypt the
// relay's frames as-is. libsodium-swift would solve it but introduces a
// binary-xcframework dependency that risks watchOS build breakage (the
// E3 STOP condition explicitly anticipates this).
//
// Instead we hand-roll the standard libsodium-style XChaCha20 construction:
//
//   subkey = HChaCha20(K, nonce[0..15])               // 32 bytes
//   ct, tag = ChaCha20-Poly1305(subkey,
//                               (0,0,0,0)||nonce[16..23],
//                               plaintext,
//                               AAD)
//
// HChaCha20 is just the ChaCha20 block function applied to (K, nonce[0..15])
// with the matrix-output-as-key derivation (extracts state[0..3] + state[12..15]).
// ChaCha20-Poly1305 with the synthesized 12-byte nonce is what
// CryptoKit/swift-crypto's `ChaChaPoly.seal` already provides.
//
// Cross-impl invariant: the byte-exact ciphertext from this code must
// match libsodium's `crypto_aead_xchacha20poly1305_ietf_encrypt` output
// for the same inputs. Asserted by `RelayFrameCodecTests` against the
// fixtures in `infra/relay/test-vectors/`.
//
// Per E3 acceptance:
//   - Frame format: 24-byte nonce || ChaCha20-Poly1305 ciphertext (incl. tag)
//   - AAD: "clawdmeter.relay.frame.v1" (24 bytes ASCII)
//   - Inner plaintext shape (after decrypt):
//        { "seq": <u64>, "op": <string>, "data": <any> }
//   - Replay protection: monotonic `seq` counter per direction.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Public types

/// Wire-format constants shared with the E2 relay (TypeScript) impl.
public enum RelayFrameConstants {
    /// AEAD associated-data string per `infra/relay/test-vectors/xchacha20-poly1305-001.json`.
    /// Bound into the encrypt/decrypt so a stripped/tampered AAD fails Poly1305 verification.
    public static let frameAAD = "clawdmeter.relay.frame.v1"

    /// XChaCha20 nonce length (bytes). Larger than RFC 8439's 12 — that's the
    /// whole point of using XChaCha over plain ChaCha: random nonces are safe
    /// without collision risk over a single key's lifetime.
    public static let nonceLength = 24

    /// Poly1305 tag length (bytes). Same as ChaCha20-Poly1305.
    public static let tagLength = 16

    /// Maximum inner-plaintext bytes a single frame may carry. Mirrors E2's
    /// `MAX_ENVELOPE_BODY_BYTES = 64 KiB`. Picked so the encoded frame stays
    /// under CF Workers' 1 MiB WebSocket message cap with comfortable
    /// headroom for the nonce + tag overhead.
    public static let maxPlaintextBytes = 64 * 1024
}

/// Inner plaintext shape — the structure that's encrypted and decrypted by
/// each peer. The relay only ever sees the encrypted bytes; the relay never
/// sees `op` / `data`.
///
/// Per the design doc §4.3:
///   - `seq` is monotonically increasing per direction (Mac → iOS and iOS → Mac
///     each maintain independent counters)
///   - Frames with `seq <= lastSeenSeq` are dropped + logged as replay-rejected
public struct RelayInnerFrame: Codable, Equatable, Sendable {
    public let seq: UInt64
    public let op: String
    /// Op-specific payload. Stored as raw JSON bytes so the codec doesn't
    /// have to know about every possible op's schema — the AgentControl
    /// handlers parse `data` themselves.
    public let data: Data

    public init(seq: UInt64, op: String, data: Data) {
        self.seq = seq
        self.op = op
        self.data = data
    }

    /// Encode this inner frame as deterministic JSON for encryption.
    /// Key order is `seq, op, data` (matching the design doc's CBOR-ish
    /// order). `JSONEncoder.outputFormatting = .sortedKeys` would give
    /// alphabetical order which doesn't match the doc — we emit manually
    /// to keep the wire-format spec authoritative.
    public func encodeForEncryption() throws -> Data {
        // We hand-build the JSON so we control key ordering precisely.
        // Each peer's encoder produces the same byte string for the same
        // input, which keeps tampering detection unambiguous.
        var out = Data()
        out.append(Data(#"{"seq":"#.utf8))
        out.append(Data(String(seq).utf8))
        out.append(Data(#","op":"#.utf8))
        // Encode op as a JSON string with proper escaping. JSONEncoder is
        // fine here — single-value encoding is deterministic.
        let opData = try JSONEncoder().encode(op)
        out.append(opData)
        out.append(Data(#","data":"#.utf8))
        // `data` is already a JSON-encoded value (object/array/string/number).
        // Caller is responsible for ensuring it's valid JSON. We don't double-
        // encode — that would wrap an array as a string and break the wire.
        if data.isEmpty {
            out.append(Data(#"null"#.utf8))
        } else {
            out.append(data)
        }
        out.append(Data(#"}"#.utf8))
        return out
    }

    /// Decode an inner-frame plaintext back into Swift form. Returns nil if
    /// the bytes aren't valid JSON or are missing required fields.
    public static func decode(_ plaintext: Data) -> RelayInnerFrame? {
        guard let json = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            return nil
        }
        guard let seq = json["seq"] as? UInt64 ?? (json["seq"] as? Int).map({ UInt64($0) }) else {
            return nil
        }
        guard let op = json["op"] as? String else { return nil }
        // Re-encode the `data` field's raw JSON so the caller has the same
        // bytes it could've sent through op-specific dispatch logic.
        let dataValue = json["data"] as Any?
        let dataBytes: Data
        if dataValue == nil || dataValue is NSNull {
            dataBytes = Data()
        } else {
            do {
                dataBytes = try JSONSerialization.data(
                    withJSONObject: dataValue as Any,
                    options: [.fragmentsAllowed, .sortedKeys]
                )
            } catch {
                return nil
            }
        }
        return RelayInnerFrame(seq: seq, op: op, data: dataBytes)
    }
}

/// Errors thrown by the codec. Distinguish encrypt-time (input validation)
/// from decrypt-time (auth failure or corrupt input).
public enum RelayFrameCodecError: Error, Equatable {
    /// Symmetric key was not 32 bytes.
    case invalidKeyLength
    /// Nonce was not 24 bytes (only thrown when callers supply their own).
    case invalidNonceLength
    /// Plaintext exceeded `maxPlaintextBytes`.
    case plaintextTooLarge
    /// Ciphertext input was shorter than the minimum (24 nonce + 16 tag).
    case ciphertextTooShort
    /// Ciphertext didn't decrypt cleanly — either wrong key, tampered bytes,
    /// or wrong AAD. The single error case is deliberate: we don't want to
    /// leak distinguishing signal to an attacker.
    case authenticationFailed
    /// Seq counter must be strictly greater than the last-seen seq. This is
    /// the replay-protection check.
    case replayedSequence
}

// MARK: - Outer envelope (matches E2 relay wire)

/// The outer envelope the E2 relay routes between peers. Mirrors the relay's
/// `EnvelopeHeader` shape from `infra/relay/src/envelope.ts` byte-exactly —
/// key order `(v, from, type)` is asserted by
/// `infra/relay/test-vectors/envelope-header-001.json`.
public struct RelayEnvelopeHeader: Equatable, Sendable {
    public let v: Int
    public let from: String  // "mac" | "ios"
    public let type: String  // "handshake" | "ciphertext" | "control"

    public init(v: Int = 1, from: String, type: String) {
        self.v = v
        self.from = from
        self.type = type
    }

    /// Serialize to canonical JSON. Key order MUST be (v, from, type) to
    /// match E2's `serializeEnvelopeHeader`. Generic `JSONEncoder` doesn't
    /// guarantee insertion-order keys, so we hand-build.
    public func encodeJSON() -> String {
        // Hand-build to guarantee key order — matches
        // infra/relay/src/envelope.ts `serializeEnvelopeHeader`
        // which uses object-literal key order.
        // JSON escaping: from/type are constrained to ASCII identifiers, so
        // no escape edge cases.
        return #"{"v":\#(v),"from":"\#(from)","type":"\#(type)"}"#
    }

    /// Parse a JSON envelope header. Returns nil for malformed input.
    public static func decode(_ text: String) -> RelayEnvelopeHeader? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let v = obj["v"] as? Int, v == 1 else { return nil }
        guard let from = obj["from"] as? String,
              (from == "mac" || from == "ios") else { return nil }
        guard let type = obj["type"] as? String,
              (type == "handshake" || type == "ciphertext" || type == "control") else { return nil }
        return RelayEnvelopeHeader(v: v, from: from, type: type)
    }
}

// MARK: - XChaCha20-Poly1305 (hand-rolled HChaCha20 + ChaCha20-Poly1305)

/// XChaCha20-Poly1305 AEAD. Pure-Swift HChaCha20 subkey derivation + swift-crypto's
/// ChaCha20-Poly1305 for the actual encryption/auth.
///
/// Cross-impl assertion: for fixed (key, nonce, plaintext, aad) this MUST
/// produce the same ciphertext bytes as libsodium's `crypto_aead_xchacha20poly1305_ietf_encrypt`
/// (used by E2's `infra/relay/src/durable-object.ts` test-vector generation
/// pathway). Asserted in `RelayFrameCodecTests` against
/// `infra/relay/test-vectors/xchacha20-poly1305-001.json` and friends.
public enum XChaCha20Poly1305 {

    /// Encrypt with XChaCha20-Poly1305. Returns ciphertext + 16-byte
    /// Poly1305 tag (concatenated; libsodium-compatible layout).
    public static func seal(
        plaintext: Data,
        key: SymmetricKey,
        nonce: Data,
        aad: Data
    ) throws -> Data {
        // Key length is enforced by SymmetricKey; we just verify nonce here.
        guard nonce.count == RelayFrameConstants.nonceLength else {
            throw RelayFrameCodecError.invalidNonceLength
        }
        guard plaintext.count <= RelayFrameConstants.maxPlaintextBytes else {
            throw RelayFrameCodecError.plaintextTooLarge
        }
        // 1) Derive 32-byte subkey via HChaCha20.
        let subkey = try hchacha20(key: key, nonce: nonce.prefix(16))
        // 2) Build the 12-byte inner ChaCha20-Poly1305 nonce:
        //    4 zero bytes || last 8 bytes of the 24-byte XChaCha nonce.
        //    Per RFC draft-irtf-cfrg-xchacha §2.3.
        var innerNonce = Data(count: 4)
        innerNonce.append(nonce.suffix(8))
        precondition(innerNonce.count == 12, "inner ChaCha20 nonce must be 12 bytes")
        // 3) Encrypt + auth using swift-crypto's ChaChaPoly.
        let cpNonce = try ChaChaPoly.Nonce(data: innerNonce)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: subkey),
            nonce: cpNonce,
            authenticating: aad
        )
        // 4) Concatenate ciphertext + tag — drops the inner 12-byte nonce
        //    from the SealedBox's `combined` field (we never transmit the
        //    inner nonce since the outer 24-byte XChaCha nonce alongside
        //    suffices to reproduce it).
        var out = Data()
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Decrypt + authenticate. Returns plaintext if the tag verifies,
    /// throws `.authenticationFailed` otherwise.
    public static func open(
        ciphertextWithTag: Data,
        key: SymmetricKey,
        nonce: Data,
        aad: Data
    ) throws -> Data {
        guard nonce.count == RelayFrameConstants.nonceLength else {
            throw RelayFrameCodecError.invalidNonceLength
        }
        guard ciphertextWithTag.count >= RelayFrameConstants.tagLength else {
            throw RelayFrameCodecError.ciphertextTooShort
        }
        // Split into ciphertext + tag.
        let ctLen = ciphertextWithTag.count - RelayFrameConstants.tagLength
        let ciphertext = ciphertextWithTag.prefix(ctLen)
        let tag = ciphertextWithTag.suffix(RelayFrameConstants.tagLength)

        let subkey = try hchacha20(key: key, nonce: nonce.prefix(16))
        var innerNonce = Data(count: 4)
        innerNonce.append(nonce.suffix(8))
        let cpNonce = try ChaChaPoly.Nonce(data: innerNonce)
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.SealedBox(nonce: cpNonce, ciphertext: ciphertext, tag: tag)
        } catch {
            // Tag size mismatch etc. — surface as auth failure.
            throw RelayFrameCodecError.authenticationFailed
        }
        do {
            return try ChaChaPoly.open(
                sealedBox,
                using: SymmetricKey(data: subkey),
                authenticating: aad
            )
        } catch {
            throw RelayFrameCodecError.authenticationFailed
        }
    }

    // MARK: - HChaCha20

    /// HChaCha20: applies the standard ChaCha20 block function to (K, nonce16)
    /// and emits a 32-byte subkey by extracting state[0..3] + state[12..15]
    /// per `draft-irtf-cfrg-xchacha §2.2`.
    ///
    /// Implemented in pure Swift so we don't need a libsodium binary
    /// xcframework — keeps the cross-platform build matrix simple.
    ///
    /// Internal (not public) — only `XChaCha20Poly1305.seal/open` and the
    /// cross-impl tests should call this directly. Exposed at module scope
    /// (not fileprivate) so `@testable import` can reach it.
    internal static func hchacha20(key: SymmetricKey, nonce: Data) throws -> Data {
        let keyBytes = key.withUnsafeBytes { Data($0) }
        guard keyBytes.count == 32 else {
            throw RelayFrameCodecError.invalidKeyLength
        }
        guard nonce.count == 16 else {
            throw RelayFrameCodecError.invalidNonceLength
        }

        // ChaCha20 initial state (per RFC 7539 §2.3):
        //   "expand 32-byte k" constants (4 words)
        //   key (8 words)
        //   nonce (4 words) — for HChaCha20, this is the FULL 16 nonce bytes
        var state: [UInt32] = Array(repeating: 0, count: 16)
        // Sigma constants: "expand 32-byte k"
        state[0] = 0x6170_7865  // "expa"
        state[1] = 0x3320_646e  // "nd 3"
        state[2] = 0x7962_2d32  // "2-by"
        state[3] = 0x6b20_6574  // "te k"
        // Key (8 words, little-endian)
        for i in 0..<8 {
            state[4 + i] = readU32LE(keyBytes, offset: i * 4)
        }
        // Nonce (4 words, little-endian) — note this is 16 bytes vs ChaCha20's 12
        for i in 0..<4 {
            state[12 + i] = readU32LE(nonce, offset: i * 4)
        }

        // 20 rounds (10 double rounds) of the ChaCha20 quarter round, in-place.
        // HChaCha20 SKIPS the post-mix addition of the initial state — that's
        // what makes it a one-way KDF rather than a stream cipher block.
        for _ in 0..<10 {
            // Column round
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            // Diagonal round
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        // HChaCha20 output: state[0..3] || state[12..15], little-endian.
        // (Per `draft-irtf-cfrg-xchacha §2.2.1`.)
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { ptr in
            for i in 0..<4 {
                writeU32LE(state[i], to: ptr, offset: i * 4)
            }
            for i in 0..<4 {
                writeU32LE(state[12 + i], to: ptr, offset: 16 + i * 4)
            }
        }
        return out
    }

    @inline(__always)
    fileprivate static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl32(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl32(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl32(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl32(s[b], 7)
    }

    @inline(__always)
    fileprivate static func rotl32(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }

    @inline(__always)
    fileprivate static func readU32LE(_ data: Data, offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    @inline(__always)
    fileprivate static func writeU32LE(_ value: UInt32, to ptr: UnsafeMutableRawBufferPointer, offset: Int) {
        ptr[offset] = UInt8(value & 0xff)
        ptr[offset + 1] = UInt8((value >> 8) & 0xff)
        ptr[offset + 2] = UInt8((value >> 16) & 0xff)
        ptr[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}

// MARK: - RelayFrameCodec — sequencer + envelope assembler

/// Stateful per-direction codec. Owns:
///   - the symmetric key K derived at pairing time (E7 / `RelayPairingCrypto`)
///   - the outgoing `seq` counter
///   - the highest incoming `seq` we've accepted (replay protection)
///
/// Two instances per peer in production: one Mac→iOS, one iOS→Mac. The
/// codec is value-equal for snapshot/debug but mutable for the counters.
public final class RelayFrameCodec: @unchecked Sendable {

    public let key: SymmetricKey
    public let from: String      // "mac" | "ios"
    public let aad: Data

    private let lock = NSLock()
    private var outgoingSeq: UInt64 = 0
    private var lastIncomingSeq: UInt64 = 0

    public init(key: SymmetricKey, from: String) {
        self.key = key
        self.from = from
        self.aad = Data(RelayFrameConstants.frameAAD.utf8)
    }

    /// Encrypt + assemble an outbound frame. Returns the binary body the
    /// caller sends as the WebSocket binary message immediately after the
    /// text header `{"v":1,"from":...,"type":"ciphertext"}`.
    ///
    /// Layout: 24-byte XChaCha nonce || (ciphertext || 16-byte tag)
    ///
    /// Picks a fresh random nonce on every call — XChaCha's 192-bit space
    /// makes random nonces collision-free without sequence numbering.
    public func encrypt(op: String, data: Data) throws -> (header: RelayEnvelopeHeader, body: Data) {
        // Bump the outgoing sequence counter.
        let seq: UInt64
        lock.lock()
        outgoingSeq &+= 1
        seq = outgoingSeq
        lock.unlock()

        let inner = RelayInnerFrame(seq: seq, op: op, data: data)
        let plaintext = try inner.encodeForEncryption()
        guard plaintext.count <= RelayFrameConstants.maxPlaintextBytes else {
            throw RelayFrameCodecError.plaintextTooLarge
        }
        let nonce = Self.randomNonce()
        let ct = try XChaCha20Poly1305.seal(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            aad: aad
        )
        var body = Data(capacity: nonce.count + ct.count)
        body.append(nonce)
        body.append(ct)
        let header = RelayEnvelopeHeader(from: from, type: "ciphertext")
        return (header, body)
    }

    /// Decrypt an inbound binary body. Validates the outgoing-direction
    /// `seq` counter rejects replays.
    public func decrypt(body: Data) throws -> RelayInnerFrame {
        guard body.count >= RelayFrameConstants.nonceLength + RelayFrameConstants.tagLength else {
            throw RelayFrameCodecError.ciphertextTooShort
        }
        let nonce = body.prefix(RelayFrameConstants.nonceLength)
        let ct = body.suffix(from: body.startIndex + RelayFrameConstants.nonceLength)
        let plaintext = try XChaCha20Poly1305.open(
            ciphertextWithTag: Data(ct),
            key: key,
            nonce: Data(nonce),
            aad: aad
        )
        guard let inner = RelayInnerFrame.decode(plaintext) else {
            throw RelayFrameCodecError.authenticationFailed
        }
        // Replay-protection. The seq counter must be strictly greater than
        // the last-accepted seq. We hold the lock across the comparison + the
        // increment so two messages arriving concurrently don't race the
        // counter back into a window where a stale frame would pass.
        lock.lock()
        defer { lock.unlock() }
        if inner.seq <= lastIncomingSeq {
            throw RelayFrameCodecError.replayedSequence
        }
        lastIncomingSeq = inner.seq
        return inner
    }

    /// For tests / diagnostics: read the current outgoing seq (last value
    /// the codec assigned). Don't use this to drive logic outside tests.
    public var outgoingSequenceForTesting: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return outgoingSeq
    }

    /// For tests: read the highest accepted incoming seq.
    public var lastIncomingSequenceForTesting: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastIncomingSeq
    }

    // MARK: - Helpers

    /// Generate a 24-byte cryptographically-random XChaCha nonce. CryptoKit
    /// pulls from `SecRandomCopyBytes` on Darwin and `/dev/urandom` on Linux
    /// (via swift-crypto's compat shim) — both satisfy threat #6 in the E1
    /// threat model.
    static func randomNonce() -> Data {
        // SymmetricKey(size:) is a convenient CSPRNG-backed byte vendor —
        // we just discard the "key" wrapper and use the raw bytes.
        // 192 bits = 24 bytes.
        let key = SymmetricKey(size: .init(bitCount: RelayFrameConstants.nonceLength * 8))
        return key.withUnsafeBytes { Data($0) }
    }
}
