#if os(macOS)
import Foundation
import Security
#if canImport(OSLog)
import OSLog
#endif

/// Reads the Cursor Agent CLI's OAuth bundle from the macOS Keychain.
///
/// `cursor-agent login` stores two generic-password items in the user's
/// login keychain via Node's `keytar`:
///
///   - service `cursor-access-token` → JWT (HS256, ~424B, ~7 day exp,
///     `sub: "google-oauth2|user_<id>"`). Bearer-attached on every
///     authenticated call against `https://api2.cursor.sh/aiserver.v1.*`.
///   - service `cursor-refresh-token` → refresh JWT, used by cursor-agent
///     itself to silently rotate the access token. We only read it; we
///     never call `/refresh` — instead, when the access token 401s we
///     re-read both items, trusting that the user (or a background
///     cursor-agent invocation) has already refreshed the on-disk copy.
///
/// **Sandbox notes**: `cursor-agent` is a CLI that has no keychain-access-
/// group entitlement, so its items live in the user's login keychain with
/// a permissive ACL that allows any user-mode process to read after a
/// one-time confirmation prompt. From sandboxed Clawdmeter, the first
/// `SecItemCopyMatching` call may surface a "Clawdmeter wants to use
/// confidential information stored in the keychain" dialog — the user
/// clicks Always Allow once and subsequent reads are silent.
///
/// **iOS / watchOS**: Cursor doesn't ship on those platforms, and the
/// keychain items are macOS-local anyway. The whole type is wrapped in
/// `#if os(macOS)`; iOS sources that observe `CursorSource` should never
/// reach this provider on those platforms.
public final class CursorTokenProvider: TokenProvider, @unchecked Sendable {

    private static let accessTokenService = "cursor-access-token"
    private static let refreshTokenService = "cursor-refresh-token"

    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "CursorTokenProvider")

    private let lock = NSLock()
    private var cachedAccessToken: String?
    private var cachedAt: Date?
    /// Re-read the keychain at most this often even when nothing fails —
    /// catches background-rotated tokens without battering the keychain
    /// daemon. 5 min matches the cursor-agent's own refresh cadence.
    private static let cacheTTL: TimeInterval = 300

    public init() {}

    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        if let cachedAccessToken, let cachedAt,
           Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cachedAccessToken
        }
        let fresh = Self.readKeychainPassword(service: Self.accessTokenService)
        cachedAccessToken = fresh
        cachedAt = Date()
        if fresh == nil {
            logger.info("CursorTokenProvider: no cursor-access-token in keychain (user not logged in?)")
        }
        return fresh
    }

    /// Surfaces the refresh token to callers that want to mint a fresh
    /// access token by calling cursor-agent's refresh endpoint themselves.
    /// We don't currently use this — see refreshIfNeeded() comment.
    public var currentRefreshToken: String? {
        lock.lock(); defer { lock.unlock() }
        return Self.readKeychainPassword(service: Self.refreshTokenService)
    }

    public var hasToken: Bool { currentAccessToken != nil }

    @discardableResult
    public func refreshIfNeeded() async throws -> Bool {
        // We don't call Cursor's refresh endpoint here — cursor-agent's
        // own background loop rotates the on-disk keychain entry every
        // ~hour. Our refresh path just drops the in-memory cache and
        // re-reads from keychain; if cursor-agent rotated it, we pick up
        // the new token. If it didn't, we return false and the poller
        // bails per its E7 retry budget.
        lock.lock()
        let previous = cachedAccessToken
        cachedAccessToken = nil
        cachedAt = nil
        lock.unlock()
        let fresh = currentAccessToken
        guard fresh != nil else {
            throw AISourceError.authExpired
        }
        return fresh != previous
    }

    // MARK: - Keychain read

    /// Reads a generic-password item by `kSecAttrService`. Returns the
    /// password string (UTF-8 decoded), or nil for any failure path
    /// (item missing, ACL denial, keychain locked, decode failure).
    ///
    /// Internal so the v0.28.0 fixture test can exercise the keychain-
    /// missing path without touching the real keychain.
    static func readKeychainPassword(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            // matchLimit one is the default but make it explicit so future
            // schema migrations that introduce multiple items per service
            // don't silently flap between which one we return.
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
#endif // os(macOS)
