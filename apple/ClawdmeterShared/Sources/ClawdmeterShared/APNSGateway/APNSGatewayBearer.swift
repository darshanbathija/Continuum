// E6: per-peer bearer signer for the APNS gateway Worker.
//
// Mirrors the E5 Worker contract (`infra/apns-gateway/src/auth.ts`) and the
// E2 relay's per-peer auth pattern: every authenticated POST presents
//
//   Authorization: Bearer <token>
//
// where `<token>` is a versioned, one-use HMAC bearer:
//
//   token = "v1." + issuedAtSeconds + "." + nonce + "." +
//           base64( HMAC-SHA256(RELAY_BEARER_SIGNING_KEY,
//                               "apns:" + sessionId + ":" + macFingerprint
//                               + ":" + issuedAtSeconds + ":" + nonce) )
//
// The shared key is the SAME byte string the relay Worker uses. Only the
// `"apns:"` vs `"relay:"` prefix differs — that domain separation prevents
// a relay bearer from authorizing an APNS push (and vice versa) even if
// the same operator key is reused.
//
// We also expose the opt-out signature variant the E5 Worker accepts on
// the `DELETE /device-token` path (auth.ts line 350 in index.ts):
//
//   sig = base64( HMAC-SHA256(RELAY_BEARER_SIGNING_KEY,
//                             "optout:" + sessionId + ":" + deviceToken) )
//
// The Worker uses the Web Crypto API, while Apple clients use CryptoKit. The
// underlying HMAC-SHA256 + base64 primitives are the same, so cross-impl tests
// confirm byte parity.

import Foundation
import CryptoKit

/// Token issuer + opt-out signature helper. Stateless; the signing key is
/// passed in by the caller (held by Mac code in the pairing record).
public enum APNSGatewayBearer {

    /// Domain-separation prefix used to bind the bearer to the APNS gateway
    /// path. Mirrors `expectedTokenMessage` in `infra/apns-gateway/src/auth.ts`.
    public static let bearerMessagePrefix = "apns:"

    /// Domain-separation prefix used for opt-out signatures. Mirrors the
    /// `optout:` prefix in `infra/apns-gateway/src/index.ts:353`.
    public static let optOutMessagePrefix = "optout:"

    public static let bearerVersion = "v1"

    /// Issue a bearer for `(sessionId, senderMacFingerprint)`. The token is
    /// versioned and carries an issued-at timestamp plus nonce. The Worker
    /// verifies the signature, expiry, and nonce freshness after stripping the
    /// `Bearer ` prefix.
    ///
    /// `signingKey` is the operator's `RELAY_BEARER_SIGNING_KEY` raw bytes.
    /// The Mac obtains this at pairing time (it lives in the Worker secret
    /// store, and the Mac learns it via the relay during E3/E4); for E6
    /// it's threaded in by the caller so the test path can inject a known
    /// key for cross-impl assertions.
    public static func issueBearer(
        signingKey: Data,
        sessionId: String,
        senderMacFingerprint: String,
        issuedAtSeconds: UInt64 = UInt64(Date().timeIntervalSince1970),
        nonce: String? = nil
    ) -> String {
        let nonceValue = nonce ?? randomNonce()
        let message = bearerMessage(
            sessionId: sessionId,
            senderMacFingerprint: senderMacFingerprint,
            issuedAtSeconds: issuedAtSeconds,
            nonce: nonceValue
        )
        let signature = base64HMAC(signingKey: signingKey, message: message)
        return "\(bearerVersion).\(issuedAtSeconds).\(nonceValue).\(signature)"
    }

    /// Verify a token presented by some caller against `(sessionId, fingerprint)`.
    /// Returns true iff the recomputed token matches in constant time.
    ///
    /// This is the Mac-local mirror of the Worker's `verifyBearer`. Used by
    /// `APNSGatewayClientTests` to assert the token we emit is the token
    /// the Worker would accept.
    public static func verifyBearer(
        signingKey: Data,
        sessionId: String,
        senderMacFingerprint: String,
        presented: String,
        nowSeconds: UInt64 = UInt64(Date().timeIntervalSince1970),
        ttlSeconds: UInt64 = 300
    ) -> Bool {
        guard let parsed = parseBearer(presented) else { return false }
        if parsed.issuedAtSeconds > nowSeconds + 60 { return false }
        if nowSeconds > parsed.issuedAtSeconds + ttlSeconds { return false }
        let message = bearerMessage(
            sessionId: sessionId,
            senderMacFingerprint: senderMacFingerprint,
            issuedAtSeconds: parsed.issuedAtSeconds,
            nonce: parsed.nonce
        )
        let expected = base64HMAC(signingKey: signingKey, message: message)
        return constantTimeEquals(normalizeBase64(expected), normalizeBase64(parsed.signature))
    }

    /// Issue an opt-out signature for `DELETE /device-token`. The Worker
    /// accepts only signatures bound to the same `(sessionId, deviceToken)`
    /// tuple, which proves the caller knows the session-bound signing
    /// material without leaking the bearer used on the push path.
    public static func issueOptOutSignature(
        signingKey: Data,
        sessionId: String,
        deviceToken: String
    ) -> String {
        let message = optOutMessagePrefix + sessionId + ":" + deviceToken
        return base64HMAC(signingKey: signingKey, message: message)
    }

    // MARK: - HMAC + constant-time compare

    private struct ParsedBearer {
        let issuedAtSeconds: UInt64
        let nonce: String
        let signature: String
    }

    private static func bearerMessage(
        sessionId: String,
        senderMacFingerprint: String,
        issuedAtSeconds: UInt64,
        nonce: String
    ) -> String {
        bearerMessagePrefix + sessionId + ":" + senderMacFingerprint + ":\(issuedAtSeconds):" + nonce
    }

    private static func base64HMAC(signingKey: Data, message: String) -> String {
        let key = SymmetricKey(data: signingKey)
        let tag = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return Data(tag).base64EncodedString()
    }

    private static func randomNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func parseBearer(_ token: String) -> ParsedBearer? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, String(parts[0]) == bearerVersion else { return nil }
        guard let issuedAt = UInt64(parts[1]) else { return nil }
        let nonce = String(parts[2])
        let signature = String(parts[3])
        guard nonce.range(of: #"^[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil else {
            return nil
        }
        guard signature.range(of: #"^[A-Za-z0-9+/=_-]{16,}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return ParsedBearer(issuedAtSeconds: issuedAt, nonce: nonce, signature: signature)
    }

    private static func normalizeBase64(_ value: String) -> String {
        value
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Length-independent constant-time string compare. Mirrors the
    /// constant-time invariant required by §13 of the design doc threat
    /// model: token comparison MUST NOT branch on byte position.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        // For a real timing-side-channel guard we compare every byte even
        // when lengths differ. We XOR a length-tag in so mismatched lengths
        // still fail without an early-return.
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let len = max(aBytes.count, bBytes.count)
        var mismatch: UInt8 = aBytes.count == bBytes.count ? 0 : 1
        for i in 0..<len {
            let aByte = i < aBytes.count ? aBytes[i] : 0
            let bByte = i < bBytes.count ? bBytes[i] : 0
            mismatch |= aByte ^ bByte
        }
        return mismatch == 0
    }
}
