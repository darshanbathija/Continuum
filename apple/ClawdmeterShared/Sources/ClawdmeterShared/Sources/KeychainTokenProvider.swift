#if os(macOS) || os(iOS)
import Foundation
import LocalAuthentication
import Security

/// Reads the Claude Code OAuth token from the system Keychain.
///
/// Service name `Claude Code-credentials` matches the empirically-observed Keychain
/// entry on macOS . On iOS the same
/// service name is used; cross-device share via iCloud Keychain controlled by
/// `synchronizable` (defaults to false in V1 per plan; flip per E12 once the
/// iOS app's Apple ID and entitlements are settled).
public final class KeychainTokenProvider: TokenProvider, @unchecked Sendable {

    /// Stored shape (observed on macOS):
    /// ```json
    /// { "claudeAiOauth": { "accessToken": "sk-ant-oat01-…",
    ///                      "refreshToken": "…",
    ///                      "expiresAt": <epoch_ms> } }
    /// ```
    public struct TokenBundle: Codable, Sendable {
        public struct ClaudeAIOauth: Codable, Sendable {
            public let accessToken: String
            public let refreshToken: String?
            public let expiresAt: Int64?  // epoch milliseconds
        }
        public let claudeAiOauth: ClaudeAIOauth
    }

    public let serviceName: String
    public let synchronizable: Bool
    public let allowsUserInteraction: Bool

    private let lock = NSLock()
    private var cached: TokenBundle?

    public init(
        serviceName: String = "Claude Code-credentials",
        synchronizable: Bool = false,
        allowsUserInteraction: Bool = false
    ) {
        self.serviceName = serviceName
        self.synchronizable = synchronizable
        self.allowsUserInteraction = allowsUserInteraction
    }

    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        // This provider reads Claude Code's third-party Keychain item and
        // is now used only by explicit import/refresh actions. Do not cache
        // here: a manual refresh should pick up Claude Code's latest rotated
        // token before we copy it into Continuum's own Keychain entry.
        do {
            let bundle = try loadFromKeychain()
            cached = bundle
            return bundle.claudeAiOauth.accessToken
        } catch {
            return nil
        }
    }

    public var hasToken: Bool {
        lock.lock(); defer { lock.unlock() }
        return keychainItemExists()
    }

    /// Returns true if the imported token changed since the previous read.
    /// This exists for `TokenProvider` conformance, but normal app polling
    /// should use `PastedAnthropicTokenProvider` after the explicit import.
    public func refreshIfNeeded() async throws -> Bool {
        lock.lock(); defer { lock.unlock() }

        // Drop the comparison cache and re-read Claude Code's item so an
        // explicit refresh can pick up a rotated token.
        let previous = cached?.claudeAiOauth.accessToken
        cached = nil
        let fresh: TokenBundle
        do {
            fresh = try loadFromKeychain()
        } catch {
            throw AISourceError.authExpired
        }
        cached = fresh

        // NOTE: Claude Code stores an `expiresAt` field, but the importer
        // trusts the actual network failure path. If the copied token is stale,
        // the app asks the user to click Refresh auth and import again.

        return fresh.claudeAiOauth.accessToken != previous
    }

    // MARK: - Keychain

    private func loadFromKeychain() throws -> TokenBundle {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        if !allowsUserInteraction {
            PassiveKeychainAccess.apply(to: &query)
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.itemNotFound(status: status)
        }

        do {
            return try JSONDecoder().decode(TokenBundle.self, from: data)
        } catch {
            throw KeychainError.decodeFailed(underlying: error)
        }
    }

    private func keychainItemExists() -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        if !allowsUserInteraction {
            PassiveKeychainAccess.apply(to: &query)
        }

        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    public enum KeychainError: Error {
        case itemNotFound(status: OSStatus)
        case decodeFailed(underlying: Error)
    }
}

#endif
