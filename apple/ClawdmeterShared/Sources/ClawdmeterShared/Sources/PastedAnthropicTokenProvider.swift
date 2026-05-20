#if os(iOS) || os(watchOS) || os(macOS)
import Foundation
import Security
import OSLog

/// Anthropic OAuth token stored in Clawdmeter's own Keychain entry.
///
/// `KeychainTokenProvider` reads Claude Code's existing Keychain entry — that
/// works on macOS where Claude Code is installed, but breaks down on iOS and
/// watchOS where the user has to provide their token directly.
///
/// On iOS we ask the user to paste their token in Settings. We store it
/// here under our own service name so it survives reinstall (Keychain) and
/// stays out of `UserDefaults` (where it would be backed up unencrypted and
/// could appear in `defaults read`).
public final class PastedAnthropicTokenProvider: TokenProvider, @unchecked Sendable {

    public static let defaultService = "com.clawdmeter.anthropic.token"

    /// Shared Keychain access group, matching `keychain-access-groups`
    /// entitlements on both the Mac and iOS apps. Team-prefixed because
    /// that's what `AppIdentifierPrefix` resolves to at runtime.
    public static let sharedAccessGroup = "76S62SDSD3.com.clawdmeter"

    private let serviceName: String
    private let accessGroup: String?
    private let synchronizable: Bool
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "PastedAnthropicTokenProvider")
    private let lock = NSLock()
    private var cached: String?

    public init(
        serviceName: String = defaultService,
        accessGroup: String? = nil,
        synchronizable: Bool = false
    ) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    /// iCloud-Keychain-synced shared instance. Use this when you want the
    /// same token visible across the user's Apple devices (e.g., Mac mirrors
    /// the Claude Code token into here, iPhone/Watch read from here).
    ///
    /// P1-Shared-2: a `static func` body was returning a fresh instance on
    /// every call. Each instance kept its own `cached` field, so a
    /// `clear()` / `setToken(...)` on one call site never invalidated the
    /// cached token held by an instance some other call site grabbed
    /// earlier — logouts and token rotations leaked stale values
    /// indefinitely. Back it with a `static let` so all callers share a
    /// single live cache.
    public static func shared() -> PastedAnthropicTokenProvider {
        _shared
    }

    private static let _shared = PastedAnthropicTokenProvider(
        serviceName: defaultService,
        accessGroup: sharedAccessGroup,
        synchronizable: true
    )

    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let value = readFromKeychain() {
            cached = value
            return value
        }
        return nil
    }

    public var hasToken: Bool { currentAccessToken != nil }

    @discardableResult
    public func refreshIfNeeded() async throws -> Bool {
        // The user-pasted token doesn't have a refresh token (those are
        // Anthropic-internal). We just re-read the Keychain entry in case
        // the user updated it. If it's missing/empty after a re-read, we
        // surface `.authExpired` so the UI prompts a re-paste.
        lock.lock(); defer { lock.unlock() }
        let previous = cached
        cached = readFromKeychain()
        guard cached != nil else {
            throw AISourceError.authExpired
        }
        return cached != previous
    }

    // MARK: - Public mutators (called from Settings UI)

    /// Persist the token and update the in-memory cache. Pass an empty string
    /// to clear ("Sign out").
    @discardableResult
    public func setToken(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return deleteFromKeychain()
        }
        let ok = writeToKeychain(value: trimmed)
        if ok { cached = trimmed }
        return ok
    }

    public func clear() {
        _ = setToken("")
    }

    // MARK: - Keychain

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        if synchronizable {
            q[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return q
    }

    private func readFromKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    @discardableResult
    private func writeToKeychain(value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query = baseQuery()
        let attrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            logger.error("PastedAnthropicTokenProvider update failed: \(updateStatus, privacy: .public) group=\(self.accessGroup ?? "nil", privacy: .public) sync=\(self.synchronizable, privacy: .public)")
        }
        // Doesn't exist yet — add a fresh entry.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            logger.error("PastedAnthropicTokenProvider add failed: \(addStatus, privacy: .public) group=\(self.accessGroup ?? "nil", privacy: .public) sync=\(self.synchronizable, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    private func deleteFromKeychain() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            cached = nil
            return true
        }
        logger.error("PastedAnthropicTokenProvider delete failed: \(status)")
        return false
    }
}
#endif
