import Foundation
import Security
import OSLog

private let pairingLogger = Logger(subsystem: "com.clawdmeter.mac", category: "PairingToken")

/// Per-device bearer token for daemon HTTP/WS auth.
///
/// Generated on first launch, stored in the Mac's local Keychain (NOT
/// iCloud-synced — the token is host-specific). iOS Sessions clients
/// receive it via QR pairing (D17 / E3) and present it as
/// `Authorization: Bearer <token>` on every request.
///
/// Codex eng-round reviewer concern #6: there must be a regenerate/revoke
/// path so a lost-phone story is recoverable. Both are exposed here as
/// `regenerate()` and `revoke()`; the AgentControlServer rejects every
/// connection whose token doesn't match.
public final class PairingTokenStore: @unchecked Sendable {

    /// Single instance — Keychain is process-global anyway.
    public static let shared = PairingTokenStore()

    private let service = "com.clawdmeter.mac.pairing"
    private let account = "daemon-bearer-token"

    private let lock = NSLock()
    private var cachedToken: String?

    public init() {}

    // MARK: - Read / generate

    /// Returns the current pairing token, generating one on first use.
    /// 32 random bytes → base64url-encoded string (43 chars, no padding).
    public func currentToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedToken { return cached }
        if let stored = readFromKeychain() {
            cachedToken = stored
            return stored
        }
        let fresh = Self.generateToken()
        writeToKeychain(fresh)
        cachedToken = fresh
        pairingLogger.info("Generated new pairing token (first launch)")
        return fresh
    }

    /// Generate a fresh token, replacing the old one. Returns the new value.
    /// iPhone clients with the old token will start failing auth — they
    /// must re-pair via QR.
    @discardableResult
    public func regenerate() -> String {
        lock.lock()
        defer { lock.unlock() }
        let fresh = Self.generateToken()
        writeToKeychain(fresh)
        cachedToken = fresh
        pairingLogger.warning("Pairing token regenerated; iOS clients must re-pair")
        return fresh
    }

    /// Remove the token entirely. The next `currentToken()` call generates
    /// a fresh one. Useful for "log out all devices" UX.
    public func revoke() {
        lock.lock()
        defer { lock.unlock() }
        deleteFromKeychain()
        cachedToken = nil
        pairingLogger.warning("Pairing token revoked; daemon will not accept any token until next launch generates one")
    }

    // MARK: - Constant-time compare for auth path

    /// Validate a presented token against the stored one in constant time.
    /// Avoids timing-side-channel leaks from `String == String` short-circuits.
    public func validate(_ presented: String) -> Bool {
        let expected = currentToken()
        guard presented.utf8.count == expected.utf8.count else { return false }
        var mismatch: UInt8 = 0
        for (a, b) in zip(presented.utf8, expected.utf8) {
            mismatch |= a ^ b
        }
        return mismatch == 0
    }

    // MARK: - Token generation

    /// 32 random bytes from `SecRandomCopyBytes`, encoded as base64url
    /// (RFC 4648 §5: `+` → `-`, `/` → `_`, no padding). Produces a
    /// 43-character URL-safe string.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed: \(result)")
        return base64URLEncode(Data(bytes))
    }

    /// Base64URL encode without padding.
    private static func base64URLEncode(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain plumbing

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // NOT synchronized to iCloud — token is per-Mac.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func readFromKeychain() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                pairingLogger.error("Keychain read failed: status=\(status)")
            }
            return nil
        }
        return token
    }

    private func writeToKeychain(_ token: String) {
        // Delete-then-add. SecItemUpdate fails when the entry doesn't exist
        // yet; delete-then-add is the idempotent pattern.
        deleteFromKeychain()
        var query = keychainQuery()
        query[kSecValueData as String] = Data(token.utf8)
        // Persist across reboots and Mac sleep; not accessible while locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            pairingLogger.error("Keychain write failed: status=\(status)")
        }
    }

    private func deleteFromKeychain() {
        let status = SecItemDelete(keychainQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            pairingLogger.error("Keychain delete failed: status=\(status)")
        }
    }
}
