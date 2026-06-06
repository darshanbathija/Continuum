import Foundation

/// Per-device bearer token for the daemon HTTP/WS auth gate.
///
/// The Mac daemon requires every request to carry
/// `Authorization: Bearer <token>` matching whatever this store returns.
///
/// Implementations:
/// - **Mac**: `PairingTokenStore` in `apple/ClawdmeterMac/AgentControl/` —
///   stored in the local Keychain via `Security.framework`. Not iCloud-synced;
///   the token is host-specific.
/// 32 random bytes → base64url-encoded string (43 chars, no padding) on first
/// use. `regenerate()` mints a new token; iOS clients with the old one must
/// re-pair via QR.
public protocol BearerTokenStore: Sendable {
    /// Returns the current pairing token, generating one on first use.
    func currentToken() -> String

    /// Generate a fresh token, replacing the old one. Returns the new value.
    /// iPhone clients with the old token will start failing auth — they must
    /// re-pair via QR.
    @discardableResult
    func regenerate() -> String

    /// Remove the token entirely. Next call to `currentToken()` will mint a
    /// new one.
    func revoke()
}

/// Standard bearer-token generation used by every platform impl. 32 random
/// bytes via `SystemRandomNumberGenerator`, base64url-encoded (43 chars).
public enum BearerTokenGenerator {
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: .min ... .max, using: &rng))
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    /// base64url (no padding) — daemon wire format for QR / Bearer header.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
