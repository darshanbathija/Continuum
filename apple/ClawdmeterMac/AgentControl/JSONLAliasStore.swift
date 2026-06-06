import Foundation
import OSLog

private let aliasLogger = Logger(subsystem: "com.clawdmeter.mac", category: "JSONLAliasStore")

/// Legacy persisted custom-name aliases for external JSONL rows. The current
/// Code sidebar no longer surfaces those rows; the store remains only so
/// older alias files and compatibility routes can be decoded safely.
///
/// Thread-safe via internal `NSLock` so any context (actors, HTTP handlers,
/// SwiftUI views) can read/write without isolation hops.
public final class JSONLAliasStore: @unchecked Sendable {
    public static let shared = JSONLAliasStore()

    private let lock = NSLock()
    private var aliases: [String: String] = [:]
    private let storeURL: URL

    public init(storeURL: URL = JSONLAliasStore.defaultStoreURL()) {
        self.storeURL = storeURL
        load()
    }

    public static func defaultStoreURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jsonl-aliases.json", isDirectory: false)
    }

    public func alias(for path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return aliases[path]
    }

    /// Snapshot of all aliases. Cheap copy for compatibility/debug tooling.
    public func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return aliases
    }

    public func setAlias(path: String, name: String?) {
        lock.lock()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            aliases[path] = trimmed
        } else {
            aliases.removeValue(forKey: path)
        }
        lock.unlock()
        save()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return aliases.count
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            aliasLogger.warning("Failed to decode JSONL aliases at \(self.storeURL.path, privacy: .public)")
            return
        }
        lock.lock()
        aliases = decoded
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let snapshot = aliases
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let tmp = storeURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmp)
        } catch {
            aliasLogger.error("Failed to persist JSONL aliases: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
