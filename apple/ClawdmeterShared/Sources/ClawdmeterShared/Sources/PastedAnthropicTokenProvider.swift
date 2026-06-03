#if os(iOS) || os(watchOS) || os(macOS)
import Foundation
import LocalAuthentication
import Security
#if canImport(OSLog)
import OSLog
#endif

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
    public static let sharedAccessGroup = "LRL8MRH6B4.com.continuum"

    private let serviceName: String
    private let accessGroup: String?
    private let synchronizable: Bool
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "PastedAnthropicTokenProvider")
    private let lock = NSLock()
    private var cached: String?
    /// Set to `true` after we observe `errSecMissingEntitlement (-34018)`
    /// from any SecItem call against the configured shared access group.
    /// That happens when the host process is signed without the matching
    /// `keychain-access-groups` entitlement — most commonly an ad-hoc /
    /// Debug build of the Mac app, or a developer signed under a team
    /// that isn't the one baked into `sharedAccessGroup`. We fall back
    /// to a local-only Keychain entry (no access group, not
    /// synchronizable) so Continuum still works locally; the only
    /// feature lost is cross-Apple-device iCloud Keychain sync, which is
    /// gated by the access group anyway.
    private var fellBackToLocalKeychain: Bool = false

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

    /// F3-wire (Codex eng-review #10): per-instance Keychain partition.
    /// Returns a fresh provider scoped to the instance's
    /// `keychainAccessGroupOverride`, so credentials for instance A's
    /// Keychain partition are invisible to instance B (the underlying
    /// `SecItem*` API treats access group as part of the lookup primary
    /// key — a query with one group's value cannot read the other
    /// group's entries).
    ///
    /// For the back-compat primary instance (no override), returns the
    /// shared singleton (same identity as `shared()`). Non-primary
    /// instances get a fresh provider — they don't share the cache
    /// with the primary, which is the entire point of partitioning.
    ///
    /// Per-instance service name disambiguation: when the access-group
    /// override is set, the service name is also suffixed with the
    /// instance's wireId. This double-bind (group + service) means a
    /// dev who copies the wrong entitlement (forgetting to add the
    /// per-instance access group) still can't accidentally read the
    /// other instance's entries — the service name mismatches as well.
    public static func forInstance(_ instance: ProviderInstanceId) -> PastedAnthropicTokenProvider {
        if instance.isPrimary, instance.keychainAccessGroupOverride == nil {
            return _shared
        }
        let group = instance.keychainAccessGroupOverride ?? sharedAccessGroup
        let service = "\(defaultService).\(instance.wireId)"
        return PastedAnthropicTokenProvider(
            serviceName: service,
            accessGroup: group,
            // iCloud sync stays on for the primary; per-instance
            // partitions default to device-local so credential rotation
            // doesn't fan out to sibling devices that may not yet have
            // the matching access-group entitlement.
            synchronizable: false
        )
    }

    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let value = readFromKeychain() {
            cached = value
            return value
        }
        return nil
    }

    public var hasToken: Bool {
        lock.lock(); defer { lock.unlock() }
        if cached != nil { return true }
        return keychainItemExists()
    }

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
    ///
    /// Codex follow-up to P1-Shared-2: clear `cached` UNCONDITIONALLY
    /// on the empty-token path. Before this change, deleteFromKeychain()
    /// only nilled `cached` when the Keychain call returned
    /// errSecSuccess or errSecItemNotFound — any other status (e.g.,
    /// Keychain locked, item present but undeletable) left the cached
    /// token in memory. With the new singleton, every caller shared
    /// that stale token, so "Sign out" could appear successful while
    /// the daemon kept using the old token until process restart.
    @discardableResult
    public func setToken(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let deleted = deleteFromKeychain()
            // Even if Keychain refused the delete, drop the in-memory
            // copy. The persistent store may still hold the token
            // (caller can retry), but the singleton must not keep
            // serving it.
            cached = nil
            return deleted
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
        // Effective synchronizable + accessGroup honor the runtime
        // fallback set by `recordMissingEntitlementFallback`. Once we
        // hit -34018 against the shared access group, every subsequent
        // query goes local-only so reads and writes keep landing on the
        // same Keychain entry.
        let effectiveSyncable = synchronizable && !fellBackToLocalKeychain
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            // Explicit protection class. AfterFirstUnlock is the most
            // restrictive that is still iCloud-sync-compatible; we drop
            // the ThisDeviceOnly variant on the synchronizable instance
            // because iCloud Keychain rejects ThisDeviceOnly entries.
            kSecAttrAccessible as String: effectiveSyncable
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if !fellBackToLocalKeychain, let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        if effectiveSyncable {
            q[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return q
    }

    /// Called from a SecItem call site whenever the OS returns
    /// `errSecMissingEntitlement (-34018)`. Returns `true` the first time
    /// it's called against a configured access group (caller should
    /// retry); `false` thereafter (so we don't infinite-loop). Caller
    /// must already hold `lock`.
    private func recordMissingEntitlementFallback() -> Bool {
        guard accessGroup != nil, !fellBackToLocalKeychain else { return false }
        fellBackToLocalKeychain = true
        logger.notice("Keychain access group entitlement missing (errSecMissingEntitlement). Falling back to local-only Keychain entry. Cross-device iCloud Keychain sync will not work in this build; install a properly-signed release to re-enable.")
        return true
    }

    private func readFromKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        PassiveKeychainAccess.apply(to: &query)
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        // Missing-entitlement fall-through: retry against the local-only
        // Keychain (no accessGroup, no synchronizable) so a Debug / ad-hoc
        // host can still read its own stored token.
        if status == -34018, recordMissingEntitlementFallback() {
            var retry = baseQuery()
            retry[kSecReturnData as String] = true
            retry[kSecMatchLimit as String] = kSecMatchLimitOne
            PassiveKeychainAccess.apply(to: &retry)
            status = SecItemCopyMatching(retry as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    private func keychainItemExists() -> Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        PassiveKeychainAccess.apply(to: &query)
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == -34018, recordMissingEntitlementFallback() {
            var retry = baseQuery()
            retry[kSecReturnAttributes as String] = true
            retry[kSecMatchLimit as String] = kSecMatchLimitOne
            PassiveKeychainAccess.apply(to: &retry)
            status = SecItemCopyMatching(retry as CFDictionary, &item)
        }
        return status == errSecSuccess
    }

    @discardableResult
    private func writeToKeychain(value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data]

        // First try with the configured (possibly shared-group) query.
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == -34018, recordMissingEntitlementFallback() {
            // Re-enter with the local-only baseQuery now in effect.
            return writeToKeychain(value: value)
        }
        if updateStatus != errSecItemNotFound {
            logger.error("PastedAnthropicTokenProvider update failed: \(updateStatus, privacy: .public) group=\(self.accessGroup ?? "nil", privacy: .public) sync=\(self.synchronizable, privacy: .public) localFallback=\(self.fellBackToLocalKeychain, privacy: .public)")
        }
        // Doesn't exist yet — add a fresh entry.
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == -34018, recordMissingEntitlementFallback() {
            return writeToKeychain(value: value)
        }
        // errSecDuplicateItem (-25299): a Keychain item with the same
        // service name exists in a DIFFERENT access group (typically
        // left over from a prior Debug/non-sandboxed build that wrote
        // the item without an accessGroup). The sandboxed app can't
        // see/update that orphan via the access-group-filtered query,
        // but the Keychain Services subsystem still treats it as a
        // collision against the new add. Fall back to local-only
        // (drop accessGroup + synchronizable) so the add lands in the
        // namespace that CAN see the orphan, and have it overwrite.
        if addStatus == errSecDuplicateItem, recordMissingEntitlementFallback() {
            logger.notice("PastedAnthropicTokenProvider hit errSecDuplicateItem; falling back to local-only Keychain to overwrite the orphan entry")
            return writeToKeychain(value: value)
        }
        if addStatus != errSecSuccess {
            logger.error("PastedAnthropicTokenProvider add failed: \(addStatus, privacy: .public) group=\(self.accessGroup ?? "nil", privacy: .public) sync=\(self.synchronizable, privacy: .public) localFallback=\(self.fellBackToLocalKeychain, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    private func deleteFromKeychain() -> Bool {
        var status = SecItemDelete(baseQuery() as CFDictionary)
        if status == -34018, recordMissingEntitlementFallback() {
            status = SecItemDelete(baseQuery() as CFDictionary)
        }
        // ALWAYS clear the in-memory cache, even when the Keychain delete
        // fails — sign-out must invalidate the local copy regardless. If
        // we only cleared on errSecSuccess/errSecItemNotFound, a locked
        // Keychain (errSecInteractionNotAllowed) or auth-failure path
        // would leave the singleton serving the stale token to every
        // caller until process restart, defeating sign-out entirely.
        cached = nil
        if status == errSecSuccess || status == errSecItemNotFound {
            return true
        }
        logger.error("PastedAnthropicTokenProvider delete failed: \(status, privacy: .public) (cache cleared anyway)")
        return false
    }
}
#endif
