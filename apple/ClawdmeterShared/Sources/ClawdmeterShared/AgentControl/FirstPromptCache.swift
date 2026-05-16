import Foundation
import OSLog

// Now lives in ClawdmeterShared so the unit tests can exercise it
// (XCTest hits the Shared package; the Mac target is closed to it).
// The subsystem stays Mac-flavored because the only caller today is on
// Mac (`RepoIndex.cachedFirstUserPrompt`); if/when iOS pulls it in,
// switch to `com.clawdmeter` for cross-platform attribution.
private let cacheLogger = Logger(subsystem: "com.clawdmeter.shared", category: "FirstPromptCache")

/// T12 (codex A1' override): on-disk + in-memory cache for the first
/// user prompt extracted from a JSONL. Keyed by `(path, mtime, size)`.
///
/// Without this cache, `RepoIndex.refresh()` (every 60s) re-reads up to
/// 256 KB from every recent JSONL — 50 per repo × N repos × every minute
/// = hundreds of MB of disk I/O. With it, JSONLs whose mtime+size
/// haven't moved skip the disk entirely.
///
/// Codex argued (correctly) that NSCache is the wrong fit for 1,451
/// stable entries: a plain dictionary is enumerable for the dead-file
/// sweep, deterministic for tests, and lighter on memory than the
/// class-wrapper NSCache requires for value types.
///
/// Sidecar lives at `~/Library/Application Support/Clawdmeter/first-prompt-cache.json`.
/// Schema v1: `{ schemaVersion: 1, entries: { path: { mtime, size, prompt } } }`.
public final class FirstPromptCache: @unchecked Sendable {

    public struct Entry: Codable, Equatable, Hashable, Sendable {
        public let mtime: TimeInterval  // seconds since 1970
        public let size: Int64
        public let prompt: String?

        public init(mtime: TimeInterval, size: Int64, prompt: String?) {
            self.mtime = mtime
            self.size = size
            self.prompt = prompt
        }
    }

    private struct StoreFile: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }
    private static let currentSchemaVersion = 1

    public static let shared = FirstPromptCache()

    /// In-memory mirror of the sidecar JSON. Mutations buffer here and
    /// flush via `save()` (called from `RepoIndex.buildSnapshot` after a
    /// refresh completes — at most once per minute).
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let storeURL: URL
    /// Set when `load()` finds a sidecar with a schemaVersion GREATER
    /// than `currentSchemaVersion` — protects future-format files from
    /// being overwritten with our older format on the next save. The
    /// classic broken case: user installs vNext (writes schema v2),
    /// downgrades to this binary (expects v1), and the downgrade silently
    /// wipes their accumulated cache. With this flag, downgrades leave
    /// the on-disk file untouched and rebuild from in-memory state.
    private var refuseToOverwriteSidecar: Bool = false

    public init(storeURL: URL = FirstPromptCache.defaultStoreURL()) {
        self.storeURL = storeURL
        load()
    }

    public nonisolated static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("first-prompt-cache.json")
    }

    /// Lookup. Returns `Entry?`. Caller checks whether mtime+size match
    /// the current filesystem state — if not, the entry is stale and the
    /// caller should re-read the JSONL.
    public func lookup(path: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    /// Store an entry. Caller should pass the prompt they just extracted
    /// along with the mtime + size they observed at extraction time so
    /// future lookups can detect when the file has rotated.
    public func set(path: String, entry: Entry) {
        lock.lock()
        entries[path] = entry
        lock.unlock()
    }

    /// Drop entries for paths that no longer exist on disk. Run periodically
    /// during snapshot build to keep the cache from growing unbounded.
    /// Returns the number of entries pruned.
    @discardableResult
    public func pruneDeadFiles() -> Int {
        lock.lock()
        let allPaths = Array(entries.keys)
        lock.unlock()
        var pruned = 0
        for path in allPaths {
            if !FileManager.default.fileExists(atPath: path) {
                lock.lock()
                entries.removeValue(forKey: path)
                lock.unlock()
                pruned += 1
            }
        }
        return pruned
    }

    /// Number of entries currently in memory. For tests and signposts.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Persist the in-memory dict to the sidecar JSON. Atomic write via
    /// `Data.write(options: .atomic)`. Idempotent — caller can invoke
    /// after each refresh without worrying about contention.
    public func save() {
        lock.lock()
        let snapshot = entries
        let skip = refuseToOverwriteSidecar
        lock.unlock()
        guard !skip else {
            cacheLogger.info("first-prompt-cache skipping save — on-disk sidecar is from a newer schema version")
            return
        }
        let file = StoreFile(schemaVersion: Self.currentSchemaVersion, entries: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        do {
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            cacheLogger.error("Failed to save first-prompt cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wipe both the in-memory dict and the sidecar file. Used by tests
    /// and a hypothetical user-facing "reset cache" Settings button.
    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            let file = try decoder.decode(StoreFile.self, from: data)
            if file.schemaVersion > Self.currentSchemaVersion {
                // Newer-than-ours on disk (probably a future Clawdmeter
                // build wrote v2). Don't load AND don't overwrite — the
                // user might be downgrading. We rebuild from scratch in
                // memory but leave the sidecar alone.
                cacheLogger.warning("first-prompt-cache schema v\(file.schemaVersion) is newer than v\(Self.currentSchemaVersion); leaving sidecar untouched")
                lock.lock()
                refuseToOverwriteSidecar = true
                lock.unlock()
                return
            }
            if file.schemaVersion < Self.currentSchemaVersion {
                cacheLogger.warning("first-prompt-cache schema v\(file.schemaVersion) (we expect v\(Self.currentSchemaVersion)); discarding")
                return
            }
            lock.lock()
            entries = file.entries
            lock.unlock()
            cacheLogger.info("Loaded \(file.entries.count) first-prompt cache entries from \(self.storeURL.path, privacy: .public)")
        } catch {
            cacheLogger.warning("Failed to load first-prompt cache: \(error.localizedDescription, privacy: .public); starting fresh")
        }
    }
}
