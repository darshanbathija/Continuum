// E6: bearer-issuer parity tests.
//
// The Mac signs:
//   token = "v1." + issuedAt + "." + nonce + "." +
//           base64( HMAC-SHA256(KEY, "apns:" + sid + ":" + fingerprint + ":" + issuedAt + ":" + nonce) )
// The E5 Worker `verifyBearer` accepts that exact string. These tests
// pin the byte format with a deterministic key + claim tuple so any
// future refactor that drifts from the Worker contract fails loud.

import XCTest
@testable import ClawdmeterShared
import CryptoKit

final class APNSGatewayBearerTests: XCTestCase {

    // MARK: - Cross-impl byte parity

    /// Pinned vector. Signing key is 32 deterministic bytes; the resulting
    /// token must match the same shape the Worker would derive. This is
    /// the load-bearing invariant — if it drifts, every Mac push starts
    /// getting 401 unauthorized.
    func testBearerByteParityWithFixedVector() {
        let key = Data((0..<32).map { UInt8($0 + 1) })  // 0x01..0x20
        let sid = "test-session-1234567890ab"
        let fingerprint = String(repeating: "ab", count: 32)  // 64 hex chars

        let issuedAt: UInt64 = 1_700_000_000
        let nonce = "nonce_nonce_1234"
        let token = APNSGatewayBearer.issueBearer(
            signingKey: key,
            sessionId: sid,
            senderMacFingerprint: fingerprint,
            issuedAtSeconds: issuedAt,
            nonce: nonce
        )

        // Manually compute the expected token to pin the algorithm. If this
        // test fails, either the algorithm or the message format drifted.
        let message = "apns:\(sid):\(fingerprint):\(issuedAt):\(nonce)"
        let symKey = SymmetricKey(data: key)
        let tag = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: symKey
        )
        let expected = "v1.\(issuedAt).\(nonce).\(Data(tag).base64EncodedString())"

        XCTAssertEqual(token, expected)
    }

    /// Symmetric — the verifier must accept what the issuer just produced.
    func testIssueAndVerifyRoundtrip() {
        let key = Data(repeating: 0xAB, count: 32)
        let sid = "session-001"
        let fingerprint = String(repeating: "cd", count: 32)
        let token = APNSGatewayBearer.issueBearer(
            signingKey: key,
            sessionId: sid,
            senderMacFingerprint: fingerprint,
            issuedAtSeconds: 1_700_000_000,
            nonce: "roundtrip_nonce_1"
        )
        XCTAssertTrue(APNSGatewayBearer.verifyBearer(
            signingKey: key,
            sessionId: sid,
            senderMacFingerprint: fingerprint,
            presented: token,
            nowSeconds: 1_700_000_010
        ))
    }

    /// Different sids MUST produce different tokens (domain separation
    /// inside the prefix).
    func testDifferentSidsProduceDifferentTokens() {
        let key = Data(repeating: 0x11, count: 32)
        let fingerprint = String(repeating: "ef", count: 32)
        let tA = APNSGatewayBearer.issueBearer(
            signingKey: key, sessionId: "sidA", senderMacFingerprint: fingerprint,
            issuedAtSeconds: 1_700_000_000, nonce: "sid_nonce_123456"
        )
        let tB = APNSGatewayBearer.issueBearer(
            signingKey: key, sessionId: "sidB", senderMacFingerprint: fingerprint,
            issuedAtSeconds: 1_700_000_000, nonce: "sid_nonce_123456"
        )
        XCTAssertNotEqual(tA, tB)
    }

    /// Different fingerprints MUST produce different tokens — a stolen
    /// bearer can't be replayed against a different Mac on the same
    /// pairing.
    func testDifferentFingerprintsProduceDifferentTokens() {
        let key = Data(repeating: 0x22, count: 32)
        let sid = "session-002"
        let tA = APNSGatewayBearer.issueBearer(
            signingKey: key,
            sessionId: sid,
            senderMacFingerprint: String(repeating: "aa", count: 32),
            issuedAtSeconds: 1_700_000_000,
            nonce: "fingerprint_nonce"
        )
        let tB = APNSGatewayBearer.issueBearer(
            signingKey: key,
            sessionId: sid,
            senderMacFingerprint: String(repeating: "bb", count: 32),
            issuedAtSeconds: 1_700_000_000,
            nonce: "fingerprint_nonce"
        )
        XCTAssertNotEqual(tA, tB)
    }

    /// Different signing keys MUST produce different tokens — even with
    /// every other input identical.
    func testDifferentSigningKeysProduceDifferentTokens() {
        let sid = "session-003"
        let fingerprint = String(repeating: "11", count: 32)
        let tA = APNSGatewayBearer.issueBearer(
            signingKey: Data(repeating: 0x01, count: 32),
            sessionId: sid,
            senderMacFingerprint: fingerprint,
            issuedAtSeconds: 1_700_000_000,
            nonce: "key_nonce_123456"
        )
        let tB = APNSGatewayBearer.issueBearer(
            signingKey: Data(repeating: 0x02, count: 32),
            sessionId: sid,
            senderMacFingerprint: fingerprint,
            issuedAtSeconds: 1_700_000_000,
            nonce: "key_nonce_123456"
        )
        XCTAssertNotEqual(tA, tB)
    }

    func testExpiredBearerFailsVerification() {
        let key = Data(repeating: 0x44, count: 32)
        let token = APNSGatewayBearer.issueBearer(
            signingKey: key,
            sessionId: "session-expired",
            senderMacFingerprint: String(repeating: "44", count: 32),
            issuedAtSeconds: 1_700_000_000,
            nonce: "expired_nonce_12"
        )
        XCTAssertFalse(APNSGatewayBearer.verifyBearer(
            signingKey: key,
            sessionId: "session-expired",
            senderMacFingerprint: String(repeating: "44", count: 32),
            presented: token,
            nowSeconds: 1_700_000_301,
            ttlSeconds: 300
        ))
    }

    // MARK: - Constant-time compare

    /// Constant-time equality returns true on a match, false otherwise,
    /// and (load-bearingly) does NOT branch on length. We assert behavior
    /// only — timing-side-channel resistance is asserted by code review.
    func testConstantTimeEqualsBehavior() {
        XCTAssertTrue(APNSGatewayBearer.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(APNSGatewayBearer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(APNSGatewayBearer.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(APNSGatewayBearer.constantTimeEquals("", "x"))
        XCTAssertTrue(APNSGatewayBearer.constantTimeEquals("", ""))
    }

    // MARK: - Opt-out signature

    /// Opt-out signature uses the `optout:` prefix — must differ from the
    /// push bearer for the same tuple.
    func testOptOutSignatureDiffersFromBearer() {
        let key = Data(repeating: 0x33, count: 32)
        let sid = "session-optout"
        let deviceToken = String(repeating: "dd", count: 32)

        let bearer = APNSGatewayBearer.issueBearer(
            signingKey: key,
            sessionId: sid,
            senderMacFingerprint: deviceToken  // misleading var; just verify domain sep
        )
        let optOut = APNSGatewayBearer.issueOptOutSignature(
            signingKey: key,
            sessionId: sid,
            deviceToken: deviceToken
        )
        XCTAssertNotEqual(bearer, optOut, "Different domain prefix must yield different signature")
    }
}
