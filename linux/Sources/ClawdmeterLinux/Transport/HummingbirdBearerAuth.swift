import Foundation
import ClawdmeterShared

/// Hummingbird middleware that enforces `Authorization: Bearer <token>`
/// against `BearerTokenStore.currentToken()`. Constant-time comparison to
/// avoid the timing-leak path that lets an attacker probe valid tokens
/// one byte at a time.
///
/// Phase 3 build-out: actual Hummingbird middleware shape + 401 response.
public struct HummingbirdBearerAuth: Sendable {

    public let store: BearerTokenStore

    public init(store: BearerTokenStore) {
        self.store = store
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        case missing       // no Authorization header → 401
        case malformed     // header present but wrong shape → 401
        case wrongToken    // header parseable but token doesn't match → 401
    }

    /// Check a request's Authorization header.
    /// Phase 3 calls this from middleware; tested directly via D7 security tests.
    public func decide(authorizationHeader: String?) -> Decision {
        guard let header = authorizationHeader else {
            return .missing
        }
        guard header.hasPrefix("Bearer ") else {
            return .malformed
        }
        let presented = String(header.dropFirst("Bearer ".count))
        let expected = store.currentToken()
        return constantTimeEquals(presented, expected) ? .allowed : .wrongToken
    }

    /// Constant-time string equality. Length-mismatched strings still take
    /// `min(a.len, b.len)` time so callers can't distinguish "wrong byte"
    /// from "wrong length".
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        // Compare up to max(len) but use the longer one to keep comparison time
        // independent of byte-by-byte mismatch positions. Distinct lengths fail.
        let maxLen = max(aBytes.count, bBytes.count)
        var diff: UInt8 = aBytes.count == bBytes.count ? 0 : 1
        for i in 0..<maxLen {
            let ab = i < aBytes.count ? aBytes[i] : 0
            let bb = i < bBytes.count ? bBytes[i] : 0
            diff |= ab ^ bb
        }
        return diff == 0
    }
}
