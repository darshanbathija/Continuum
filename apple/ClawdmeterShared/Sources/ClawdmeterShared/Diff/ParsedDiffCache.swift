import Foundation

// A12 — diff workbench virtual rendering: cache layer.
//
// In-memory LRU keyed on `(rawInputHash, contextLines)` so re-opening
// the same diff (Cmd-tab into the workbench, toggling display modes,
// "Mark all viewed" round-trips) is an O(1) lookup. Without this,
// a 50k-line diff re-parses every time the pane re-mounts.
//
// Design notes:
//   - Class with `NSLock` mirroring `Pricing` (B3) and `FirstPromptCache`
//     — battle-tested pattern across the codebase, gives us thread
//     safety without forcing every caller into actor isolation.
//   - LRU eviction via a simple `recencyOrder` array. Diff opens are
//     interactive (≤ few per minute), so an O(N) eviction is fine
//     for N ≤ 32. We keep `defaultCapacity` small (16) because
//     ParsedDiff for a 50k-line diff is ~few MB; 16 caps the worst
//     case around 80 MB.
//   - `contextLines` is part of the key because git's `--unified=N`
//     affects the output materially (changing N from 3 → 7 re-parses).
//     Storing it in the key avoids a stale cache hit when a future
//     "show more context" toggle ships.

public final class ParsedDiffCache: @unchecked Sendable {

    public struct Key: Hashable, Sendable {
        public let inputHash: String
        public let contextLines: Int

        public init(inputHash: String, contextLines: Int = 3) {
            self.inputHash = inputHash
            self.contextLines = contextLines
        }
    }

    public static let shared = ParsedDiffCache()

    private let lock = NSLock()
    private var storage: [Key: ParsedDiff] = [:]
    /// MRU-last ordering. `removeFirst()` evicts the LRU entry; new /
    /// touched entries get appended.
    private var recencyOrder: [Key] = []
    private let capacity: Int

    public init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    // MARK: - Lookup / store

    /// Fast non-mutating lookup. Returns nil on miss; caller is
    /// expected to call `set(_:for:)` after running the parser.
    public func lookup(_ key: Key) -> ParsedDiff? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = storage[key] else { return nil }
        // Promote to MRU on hit.
        if let existing = recencyOrder.firstIndex(of: key) {
            recencyOrder.remove(at: existing)
        }
        recencyOrder.append(key)
        return cached
    }

    public func set(_ diff: ParsedDiff, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if storage[key] != nil {
            // Overwrite path: drop the old MRU entry, append fresh.
            if let existing = recencyOrder.firstIndex(of: key) {
                recencyOrder.remove(at: existing)
            }
        }
        storage[key] = diff
        recencyOrder.append(key)
        // Evict LRU entries to honor capacity. Loop because callers
        // could in principle insert multiple before the next eviction
        // check, but in practice we evict at most one per `set`.
        while storage.count > capacity, let oldest = recencyOrder.first {
            recencyOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    /// Convenience: lookup, and on miss parse + store atomically. The
    /// parse itself runs OUTSIDE the lock so a slow 50k-line parse
    /// doesn't block other cache readers. Two concurrent misses for
    /// the same key will both parse — acceptable: the parse is
    /// deterministic, the result of the second `set` is byte-identical
    /// to the first, and we waste at most one redundant parse rather
    /// than holding a lock across multi-millisecond work.
    public func parsed(
        input: String,
        contextLines: Int = 3
    ) -> ParsedDiff {
        let key = Key(
            inputHash: UnifiedDiffParser.sha256Hex(input),
            contextLines: contextLines
        )
        if let hit = lookup(key) {
            return hit
        }
        let parsed = UnifiedDiffParser.parse(input)
        set(parsed, for: key)
        return parsed
    }

    // MARK: - Test / settings hooks

    /// Drop everything. Tests and a hypothetical user-facing "reset"
    /// button.
    public func clear() {
        lock.lock()
        storage.removeAll()
        recencyOrder.removeAll()
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }
}

// MARK: - Per-file / per-hunk cache (composability hook)

/// Secondary cache keyed on a single file's `(filePath, hunksHash,
/// lineRange)` slice — A12 acceptance asks for "repeat opens of the
/// same diff are O(1) lookups", and a diff workbench that supports
/// per-file viewing benefits when the OUTER diff snapshot changes (a
/// fresh `git diff` adds an unrelated file at the top) but a given
/// file's hunk set is byte-identical to a prior parse.
///
/// We expose this as a separate cache so the primary `ParsedDiffCache`
/// stays simple and the per-file cache can be wired in incrementally.
public final class ParsedDiffFileCache: @unchecked Sendable {

    public struct Key: Hashable, Sendable {
        public let path: String
        public let hunksHash: String
        public let lineRangeStart: Int
        public let lineRangeEnd: Int

        public init(path: String, hunksHash: String, lineRangeStart: Int = 0, lineRangeEnd: Int = .max) {
            self.path = path
            self.hunksHash = hunksHash
            self.lineRangeStart = lineRangeStart
            self.lineRangeEnd = lineRangeEnd
        }
    }

    public static let shared = ParsedDiffFileCache()

    private let lock = NSLock()
    private var storage: [Key: [ParsedDiff.Line]] = [:]
    private var recencyOrder: [Key] = []
    private let capacity: Int

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    public func lookup(_ key: Key) -> [ParsedDiff.Line]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = storage[key] else { return nil }
        if let existing = recencyOrder.firstIndex(of: key) {
            recencyOrder.remove(at: existing)
        }
        recencyOrder.append(key)
        return cached
    }

    public func set(_ lines: [ParsedDiff.Line], for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if storage[key] != nil, let existing = recencyOrder.firstIndex(of: key) {
            recencyOrder.remove(at: existing)
        }
        storage[key] = lines
        recencyOrder.append(key)
        while storage.count > capacity, let oldest = recencyOrder.first {
            recencyOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        recencyOrder.removeAll()
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }
}
