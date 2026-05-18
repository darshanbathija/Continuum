#if os(macOS) || os(iOS)
import Foundation
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

    private let lock = NSLock()
    private var cached: TokenBundle?

    public init(
        serviceName: String = "Claude Code-credentials",
        synchronizable: Bool = false
    ) {
        self.serviceName = serviceName
        self.synchronizable = synchronizable
    }

    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        // v0.4.11 root-cause fix: always re-read Keychain. Caching the
        // first read meant that when Claude Code rotated its OAuth
        // token (it does this every few hours), the Mac app kept its
        // stale copy and started getting 403s. Anthropic returns 403
        // (not 401) for rotated tokens, so UsagePoller's 401-only
        // refresh path never fired — backoff grew, dashboard stuck
        // on "Connecting…" forever. Keychain reads are sub-ms;
        // re-reading on every 60s poll is free.
        do {
            let bundle = try loadFromKeychain()
            cached = bundle
            return bundle.claudeAiOauth.accessToken
        } catch {
            return nil
        }
    }

    public var hasToken: Bool {
        currentAccessToken != nil
    }

    /// Returns true if a refresh was performed; false if no refresh was needed.
    /// Throws `AISourceError.authExpired` if the refresh token itself is missing
    /// or expired. V1 keeps the Claude-Code-issued token in sync rather than
    /// driving the refresh ourselves: re-reading Keychain may pick up a freshly
    /// rotated token that Claude Code wrote.
    public func refreshIfNeeded() async throws -> Bool {
        lock.lock(); defer { lock.unlock() }

        // V1 strategy: drop cache and re-read Keychain. Claude Code itself rotates
        // the token periodically; we just want the freshest copy.
        let previous = cached?.claudeAiOauth.accessToken
        cached = nil
        let fresh: TokenBundle
        do {
            fresh = try loadFromKeychain()
        } catch {
            throw AISourceError.authExpired
        }
        cached = fresh

        // NOTE: Claude Code stores an `expiresAt` field but tokens remain valid
        // beyond it in practice (Anthropic rotates them server-side). Trust the
        // network result, not the local field — if the token actually fails,
        // `AnthropicSource.poll()` will return 401 and we'll re-read Keychain.

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

    public enum KeychainError: Error {
        case itemNotFound(status: OSStatus)
        case decodeFailed(underlying: Error)
    }
}

#endif
