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
    /// P1-Mac-17: persisted "revoked" sentinel. While present, `validate()`
    /// fails closed for every input — `revoke()` previously deleted the
    /// Keychain row but the next `currentToken()` call silently generated
    /// a new one, contradicting the settings UI's "daemon refuses every
    /// connection until relaunch" copy. The sentinel is cleared by
    /// `regenerate()` (deliberate user action), not by an implicit
    /// regenerate on the read path.
    private let revokedKey = "clawdmeter.pairing.revoked"

    private let lock = NSLock()
    private var cachedToken: String?

    public init() {}

    // MARK: - Read / generate

    /// Returns the current pairing token, generating one on first use.
    /// 32 random bytes → base64url-encoded string (43 chars, no padding).
    ///
    /// Note: while `isRevoked` is true, the returned value is display-only —
    /// `validate()` fails closed for every input regardless of what this
    /// returns. Pairing-UI callers should branch on `isRevoked` and show a
    /// "Generate new token" affordance instead of the QR.
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

    /// True when the token is in the revoked/disabled state. While true,
    /// `validate()` returns false for every input.
    public var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRevokedLocked
    }

    /// Generate a fresh token, replacing the old one and clearing any
    /// revoked sentinel. iPhone clients with the old token will start
    /// failing auth — they must re-pair via QR.
    @discardableResult
    public func regenerate() -> String {
        lock.lock()
        defer { lock.unlock() }
        clearRevokedLocked()
        let fresh = Self.generateToken()
        writeToKeychain(fresh)
        cachedToken = fresh
        pairingLogger.warning("Pairing token regenerated; iOS clients must re-pair")
        return fresh
    }

    /// Move the daemon into a revoked state: drop the Keychain row AND
    /// persist a `revoked` sentinel so subsequent `currentToken()` calls
    /// don't silently regenerate, and `validate()` rejects every input.
    /// The user must explicitly call `regenerate()` (via the
    /// pairing-settings "Generate new token" button) to re-enable pairing.
    public func revoke() {
        lock.lock()
        defer { lock.unlock() }
        deleteFromKeychain()
        cachedToken = nil
        markRevokedLocked()
        pairingLogger.warning("Pairing token revoked; daemon will reject every connection until a new token is generated")
    }

    // MARK: - Constant-time compare for auth path

    /// Validate a presented token against the stored one in constant time.
    /// Avoids timing-side-channel leaks from `String == String` short-circuits.
    /// Fails closed when the token has been revoked, regardless of what
    /// `currentToken()` returns.
    public func validate(_ presented: String) -> Bool {
        if isRevoked { return false }
        let expected = currentToken()
        guard presented.utf8.count == expected.utf8.count else { return false }
        var mismatch: UInt8 = 0
        for (a, b) in zip(presented.utf8, expected.utf8) {
            mismatch |= a ^ b
        }
        return mismatch == 0
    }

    /// True when a pairing token has been issued and not revoked.
    /// This is credential availability, not proof that an iPhone has
    /// paired or is currently connected. UI must not label this state as
    /// a paired-device label without a real device/WS lifecycle signal.
    public var hasAnyPaired: Bool {
        !isRevoked && !currentToken().isEmpty
    }

    // MARK: - Revoke sentinel

    /// Caller MUST hold `lock`.
    private var isRevokedLocked: Bool {
        UserDefaults.standard.bool(forKey: revokedKey)
    }

    private func markRevokedLocked() {
        UserDefaults.standard.set(true, forKey: revokedKey)
    }

    private func clearRevokedLocked() {
        UserDefaults.standard.removeObject(forKey: revokedKey)
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
