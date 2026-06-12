import Foundation

/// Opt-in permission gates (v0.29.32).
///
/// The app defaults every provider OFF and analytics access OFF so a fresh
/// launch performs **no** keychain reads, **no** cross-app data access, and
/// **no** user-folder scans. Sensitive access is requested on-demand:
///   - a provider's poller + credential (keychain) reads start only when the
///     user enables it (first-run welcome sheet or Settings → Providers),
///   - analytics (which reads other apps' data) loads only after the Usage
///     tab's "Get access from your Mac" tap,
///   - user folders are touched only when adding a repo in Code.
///
/// This enum is the single home for all those flags so the gate is consistent
/// across the Mac target and the shared analytics store.
public enum ProviderEnablement {

    public static let changedNotification = Notification.Name("clawdmeter.providerEnablement.changed")
    public static let changedProviderIdUserInfoKey = "providerId"

    /// UserDefaults key gating a provider's poller + credential reads.
    public static func key(for id: String) -> String { "clawdmeter.provider.\(id).enabled" }

    private static var sharedDefaults: UserDefaults? {
        for group in UsageStore.appGroups {
            if let defaults = UserDefaults(suiteName: group) {
                return defaults
            }
        }
        return nil
    }

    private static func storedBool(forKey key: String) -> Bool? {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool { return value }
        return sharedDefaults?.object(forKey: key) as? Bool
    }

    private static func setStoredBool(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        sharedDefaults?.set(value, forKey: key)
    }

    /// Whether `id` (e.g. "claude", "cursor") is enabled. An env override
    /// `CLAWDMETER_PROVIDER_<ID>_ENABLED` wins (CI / power users); otherwise the
    /// persisted flag, defaulting to **false** (opt-in).
    public static func isEnabled(_ id: String) -> Bool {
        let rootID = ProviderRegistry.rootProviderID(for: id)
        let env = "CLAWDMETER_PROVIDER_\(rootID.uppercased())_ENABLED"
        if let raw = ProcessInfo.processInfo.environment[env] {
            let v = raw.lowercased()
            return v == "1" || v == "true" || v == "yes"
        }
        return storedBool(forKey: key(for: rootID)) ?? false
    }

    public static func setEnabled(_ id: String, _ on: Bool) {
        let rootID = ProviderRegistry.rootProviderID(for: id)
        setStoredBool(on, forKey: key(for: rootID))
        NotificationCenter.default.post(
            name: changedNotification,
            object: nil,
            userInfo: [changedProviderIdUserInfoKey: rootID]
        )
    }

    public static func isEnabled(_ provider: AgentKind) -> Bool {
        isEnabled(provider.rawValue)
    }

    public static func isEnabled(_ vendor: ChatVendor) -> Bool {
        isEnabled(vendor.backingProvider)
    }

    public static func enabledChatVendors(
        in order: [ChatVendor] = [.chatgpt, .claude, .antigravity, .cursor, .opencode, .openrouter, .grok]
    ) -> [ChatVendor] {
        order.filter { ProviderRegistry.isEnabled(chatVendor: $0) }
    }

    public static func enabledProviderIDs(
        for capability: ProviderCapability? = nil
    ) -> [String] {
        ProviderRegistry.descriptors
            .filter { descriptor in
                if let capability, !descriptor.capabilities.contains(capability) { return false }
                return isEnabled(descriptor.id)
            }
            .map(\.id)
    }

    /// Analytics (Usage tab) reads other apps' data (~/.codex, ~/.gemini,
    /// opencode db), which triggers the macOS "access data from other apps"
    /// prompt — so it's gated behind an explicit tap.
    public static var usageDataAccessGranted: Bool {
        get { UserDefaults.standard.bool(forKey: "clawdmeter.usage.dataAccessGranted") }
        set { UserDefaults.standard.set(newValue, forKey: "clawdmeter.usage.dataAccessGranted") }
    }

    /// First-run welcome sheet gate.
    public static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "clawdmeter.hasOnboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "clawdmeter.hasOnboarded") }
    }

    /// Providers surfaced in onboarding + Settings toggles, in display order.
    public static let allProviderIds: [String] = ProviderRegistry.allProviderIDs
}
