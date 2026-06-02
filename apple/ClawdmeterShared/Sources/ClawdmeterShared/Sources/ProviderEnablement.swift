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

    /// Whether `id` (e.g. "claude", "cursor") is enabled. An env override
    /// `CLAWDMETER_PROVIDER_<ID>_ENABLED` wins (CI / power users); otherwise the
    /// persisted flag, defaulting to **false** (opt-in). Mirrors the existing
    /// `cursorStartupPollingEnabled` reader in AppRuntime.
    public static func isEnabled(_ id: String) -> Bool {
        let env = "CLAWDMETER_PROVIDER_\(id.uppercased())_ENABLED"
        if let raw = ProcessInfo.processInfo.environment[env] {
            let v = raw.lowercased()
            return v == "1" || v == "true" || v == "yes"
        }
        return UserDefaults.standard.object(forKey: key(for: id)) as? Bool ?? false
    }

    public static func setEnabled(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key(for: id))
        NotificationCenter.default.post(
            name: changedNotification,
            object: nil,
            userInfo: [changedProviderIdUserInfoKey: id]
        )
    }

    public static func isEnabled(_ provider: AgentKind) -> Bool {
        isEnabled(provider.rawValue)
    }

    public static func isEnabled(_ vendor: ChatVendor) -> Bool {
        isEnabled(vendor.backingProvider)
    }

    public static func enabledChatVendors(
        in order: [ChatVendor] = [.chatgpt, .claude, .antigravity, .cursor, .openrouter, .grok]
    ) -> [ChatVendor] {
        order.filter { isEnabled($0) }
    }

    /// Analytics (Usage tab) reads other apps' data (~/.codex, ~/.gemini,
    /// opencode db), which triggers the macOS "access data from other apps"
    /// prompt — so it's gated behind an explicit tap.
    public static var usageDataAccessGranted: Bool {
        get { UserDefaults.standard.bool(forKey: "clawdmeter.usage.dataAccessGranted") }
        set { UserDefaults.standard.set(newValue, forKey: "clawdmeter.usage.dataAccessGranted") }
    }

    /// Code sidebar discovery. When false (default), the sidebar shows only
    /// managed (explicitly-added) repos and does NO filesystem session
    /// discovery — no ~/.claude / ~/.codex read, no folder scan, so opening
    /// Code triggers no folder/cross-app prompt. The "Discover parallel
    /// sessions" button opts in to full discovery (the prior behavior).
    public static var discoverParallelSessions: Bool {
        get { UserDefaults.standard.bool(forKey: "clawdmeter.code.discoverParallelSessions") }
        set { UserDefaults.standard.set(newValue, forKey: "clawdmeter.code.discoverParallelSessions") }
    }

    /// First-run welcome sheet gate.
    public static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "clawdmeter.hasOnboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "clawdmeter.hasOnboarded") }
    }

    /// Providers surfaced in onboarding + Settings toggles, in display order.
    public static let allProviderIds: [String] = ["claude", "codex", "gemini", "cursor", "opencode"]
}
