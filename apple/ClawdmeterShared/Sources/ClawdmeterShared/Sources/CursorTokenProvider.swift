#if os(macOS)
import Foundation
import LocalAuthentication
import Security
import SQLite3
#if canImport(OSLog)
import OSLog
#endif

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Reads Cursor's local OAuth access token.
///
/// Preferred source: Cursor.app's local VS Code storage database:
///
///   `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
///   key `cursorAuth/accessToken`
///
/// Fallback source: `cursor-agent login` stores two generic-password items in
/// the user's login keychain via Node's `keytar`:
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
/// **Why app DB first:** the Cursor dashboard and editor are keyed off the
/// Cursor.app session. The CLI keychain can point at a different account, which
/// gives the wrong monthly Total / Auto / API breakdown. Keychain remains a
/// fallback for headless `cursor-agent`-only setups.
///
/// **Sandbox notes**: Cursor.app storage and `cursor-agent` keychain items are
/// both outside this app's container in Release builds; failures are swallowed
/// and reported as unauthenticated. Keychain reads are non-interactive so
/// switching tabs or opening Settings never surfaces a macOS SecurityAgent
/// prompt; explicit login still happens through Cursor or `cursor-agent login`.
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
        let fresh = Self.readCursorAppAccessToken() ?? Self.readKeychainPassword(service: Self.accessTokenService)
        cachedAccessToken = fresh
        cachedAt = Date()
        if fresh == nil {
            logger.info("CursorTokenProvider: no Cursor app access token or cursor-access-token in keychain (user not logged in?)")
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

    public var hasToken: Bool {
        Self.readCursorAppAccessToken() != nil || Self.keychainItemExists(service: Self.accessTokenService)
    }

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

    static func defaultCursorStateDatabaseURL() -> URL {
        ClawdmeterRealHome.url()
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Reads Cursor.app's signed-in access token from VS Code state storage.
    /// Internal so tests can seed a temp SQLite DB without touching the user's
    /// real Cursor profile.
    static func readCursorAppAccessToken(databaseURL: URL = defaultCursorStateDatabaseURL()) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 100)

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "cursorAuth/accessToken", -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        let token = String(cString: cString)
        guard token.split(separator: ".").count >= 2 else {
            return nil
        }
        return token
    }

    /// Reads a generic-password item by `kSecAttrService`. Returns the
    /// password string (UTF-8 decoded), or nil for any failure path
    /// (item missing, ACL denial, keychain locked, decode failure).
    ///
    /// Internal so the v0.28.0 fixture test can exercise the keychain-
    /// missing path without touching the real keychain.
    static func readKeychainPassword(service: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            // matchLimit one is the default but make it explicit so future
            // schema migrations that introduce multiple items per service
            // don't silently flap between which one we return.
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        PassiveKeychainAccess.apply(to: &query)
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

    private static func keychainItemExists(service: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        PassiveKeychainAccess.apply(to: &query)
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}
#endif // os(macOS)
