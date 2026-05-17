import Foundation
import ClawdmeterShared

/// XDG-backed file store for `UsageData` — replaces the App Group
/// `UserDefaults` path used by iOS / watchOS widgets (which the
/// shared `UsageStore.swift:182` branch defaults to for non-macOS).
///
/// **Why this exists** (Codex C3): Linux had no usage cache/write path.
/// Without one, the Linux dashboard couldn't read what the daemon had
/// most recently observed. This is the equivalent of iOS's shared App
/// Group cache, just file-backed at `$XDG_DATA_HOME/clawdmeter/usage-store.json`.
///
/// Shape: same `[providerID: UsageData]` map the iOS path stores in
/// `UserDefaults.suiteName: group`. Atomic-write via temp + rename.
///
/// Used by: TrayPollLoop (poll → write → notify dashboard observers),
/// DashboardWindow (read at present), the daemon's /usage HTTP endpoint
/// (read to serve iOS clients).
public actor LinuxUsageStore {
    public static let shared = LinuxUsageStore()

    /// Cached in-memory copy; backing file is the durable store.
    private var providers: [String: UsageData] = [:]
    private var loaded = false

    public init() {}

    /// Load on first access — kept lazy because the JSON parse is small but
    /// not worth doing at process start if no one calls.
    private func loadIfNeeded() throws {
        guard !loaded else { return }
        let url = LinuxConfigPaths.usageStoreFile
        try LinuxConfigPaths.ensureDirectory(LinuxConfigPaths.dataHome)
        guard FileManager.default.fileExists(atPath: url.path) else {
            providers = [:]
            loaded = true
            return
        }
        let data = try Data(contentsOf: url)
        let dict = try JSONDecoder().decode([String: UsageData].self, from: data)
        providers = dict
        loaded = true
    }

    /// Atomic write: temp file + rename(2). Guards against torn JSON on
    /// daemon crash mid-write.
    private func persist() throws {
        let url = LinuxConfigPaths.usageStoreFile
        let temp = url.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(providers)
        try data.write(to: temp, options: .atomic)
        // rename(2) is atomic on POSIX filesystems for files on the same FS.
        try FileManager.default.replaceItem(
            at: url, withItemAt: temp,
            backupItemName: nil,
            options: [],
            resultingItemURL: nil
        )
    }

    // MARK: - Public API (mirrors UsageStore's shape)

    public func snapshot(for providerID: String) throws -> UsageData? {
        try loadIfNeeded()
        return providers[providerID]
    }

    public func writeSnapshot(_ usage: UsageData, for providerID: String) throws {
        try loadIfNeeded()
        providers[providerID] = usage
        try persist()
    }

    public func allProviderIDs() throws -> [String] {
        try loadIfNeeded()
        return Array(providers.keys).sorted()
    }
}
