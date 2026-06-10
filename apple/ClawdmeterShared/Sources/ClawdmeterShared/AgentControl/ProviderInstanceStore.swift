import Foundation

/// One persisted non-primary provider account ("instance"). The primary
/// instance for every kind is synthesized by `ProviderInstanceRegistry`'s
/// constructor and is intentionally NEVER persisted — a corrupted or
/// deleted store can therefore never take the user's default account away.
///
/// **No secrets live here.** Claude tokens live in the per-instance
/// Keychain partition (`PastedAnthropicTokenProvider.forInstance`);
/// Codex auth lives at `<configRoot>/auth.json`, written by the Codex
/// CLI itself during `codex login`.
///
/// `keychainAccessGroupOverride` is intentionally NOT persisted —
/// multi-account v1 never sets it (partitioning rides on the service-
/// name suffix within the shared access group). A feature that starts
/// setting it must add it here or lose the partition on boot replay.
public struct ProviderInstanceRecord: Codable, Sendable, Equatable {
    public let kind: AgentKind
    public let name: String
    /// Instance config root — the directory the provider CLI treats as
    /// its config home (`CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME`
    /// for Codex). See `ProviderInstanceId.homePathOverride`.
    public let configRoot: String
    public let createdAt: Date

    public init(kind: AgentKind, name: String, configRoot: String, createdAt: Date = Date()) {
        self.kind = kind
        self.name = name
        self.configRoot = configRoot
        self.createdAt = createdAt
    }

    public init(instance: ProviderInstanceId, createdAt: Date = Date()) {
        self.init(
            kind: instance.kind,
            name: instance.name,
            configRoot: instance.homePathOverride ?? "",
            createdAt: createdAt
        )
    }

    /// The runtime identity this record reconstitutes on boot replay.
    public var instanceId: ProviderInstanceId {
        ProviderInstanceId(
            kind: kind,
            name: name,
            homePathOverride: configRoot.isEmpty ? nil : configRoot
        )
    }
}

/// Disk persistence for non-primary provider instances —
/// `provider-instances.json` next to `sessions.json` / `workspaces.json`
/// in the app-support container. Atomic writes; tolerant reads (corrupt
/// or missing file ⇒ empty list, the registry's seeded primaries keep
/// every provider usable).
public final class ProviderInstanceStore: @unchecked Sendable {

    /// Envelope versioning mirrors the sessions.json pattern: bump when
    /// the record shape changes incompatibly; unknown versions load as
    /// empty rather than crashing or half-decoding.
    private struct Envelope: Codable {
        var version: Int
        var instances: [ProviderInstanceRecord]
    }

    public static let currentVersion = 1

    public let storeURL: URL
    private let lock = NSLock()

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    /// Deterministic per-instance config root:
    /// `<baseDir>/Instances/<kind>/<name>/`. `name` has already passed
    /// `ProviderInstanceId.isValidName` (non-empty; no `/`, `\`, NUL, or
    /// whitespace; no leading `.` — which rejects the `..` relative-path
    /// escape) so the path cannot resolve outside the base.
    public static func configRoot(baseDir: URL, kind: AgentKind, name: String) -> URL {
        baseDir
            .appendingPathComponent("Instances", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// All persisted records. Missing file, unreadable bytes, decode
    /// failures, and future-version envelopes all return `[]`.
    public func load() -> [ProviderInstanceRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Replace the persisted set. Primary-named records are dropped —
    /// the registry constructor owns primaries and persisting one could
    /// shadow it on a future load.
    public func save(_ records: [ProviderInstanceRecord]) {
        lock.lock(); defer { lock.unlock() }
        saveLocked(records)
    }

    /// Insert-or-replace by (kind, name).
    public func upsert(_ record: ProviderInstanceRecord) {
        lock.lock(); defer { lock.unlock() }
        var records = loadLocked()
        records.removeAll { $0.kind == record.kind && $0.name == record.name }
        records.append(record)
        saveLocked(records)
    }

    /// Remove by (kind, name). No-op when absent.
    public func remove(kind: AgentKind, name: String) {
        lock.lock(); defer { lock.unlock() }
        let records = loadLocked().filter { !($0.kind == kind && $0.name == name) }
        saveLocked(records)
    }

    // MARK: - Locked primitives

    private func loadLocked() -> [ProviderInstanceRecord] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version <= Self.currentVersion else {
            return []
        }
        return envelope.instances.filter { $0.name != ProviderInstanceId.primaryName }
    }

    private func saveLocked(_ records: [ProviderInstanceRecord]) {
        let persistable = records.filter { $0.name != ProviderInstanceId.primaryName }
        let envelope = Envelope(version: Self.currentVersion, instances: persistable)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}
