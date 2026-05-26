import Foundation

/// Single-slot, synchronous, main-thread-only memoization cache for
/// expensive view projections.
///
/// Keeps one cached `(key, output)` pair. Calling `value(for:)`:
///   - returns the cached output without invoking `compute` when the new
///     key equals the cached key (cache hit)
///   - otherwise invokes `compute`, stores the result, and returns it
///     (cache miss)
///
/// The cache is reference-typed so SwiftUI views can carry one across body
/// re-evaluations via `@StateObject`/`@State` without the cached value
/// being rebuilt on every body pass. It does NOT publish on its own —
/// SwiftUI re-renders are driven by the upstream `@Published` sources
/// (registry, repos, search query, filters); this cache merely keeps the
/// projection step from re-doing work when none of those upstream sources
/// actually changed the inputs the projection depends on.
///
/// Why "single-slot": the only consumer that needs a window of cached
/// values is the chat store, which has its own LRU. Sidebar projections
/// have one current key — when it changes, the prior projection is dead
/// and there is no benefit to keeping it around for a future bounce-back.
///
/// **Concurrency contract:** main-thread only. The cache is not
/// `Sendable`; passing it across actors will be rejected by the compiler
/// once views adopt strict concurrency. We deliberately do not lock —
/// the SwiftUI body that owns this cache always runs on the main actor,
/// so locking would just add overhead.
///
/// **Why not `MemoizedDerivedStore` (A4-pre):** that store is observable
/// (`@Published var output`), targeted at off-main `Task.detached`
/// recomputes, and surfaces a placeholder while computing. The sidebar
/// projection is fast (microseconds — sorts + bucketing over hundreds of
/// sessions, not seconds), runs on-main, and has no placeholder concept;
/// the lighter primitive is a better fit and avoids `@Published`'s
/// objectWillChange traffic on every cache miss.
///
/// Plan: A11 (Phase 2) — see .claude/plans/study-this-codebase-crystalline-shore.md
public final class SingleSlotProjectionCache<Key: Equatable, Output> {

    private var cachedKey: Key?
    private var cachedOutput: Output?
    /// Number of times `value(for:)` was called with a key matching the
    /// stored one (no `compute` invocation). Exposed for tests + perf
    /// debugging; not used by production view code.
    public private(set) var hitCount: Int = 0
    /// Number of times `value(for:)` was called with a new key, triggering
    /// `compute`. Exposed for tests + perf debugging.
    public private(set) var missCount: Int = 0

    public init() {}

    /// Look up the cached output for `key`, or compute + store it.
    ///
    /// The `compute` closure is only invoked on cache miss. Callers can
    /// pass a heavy projection step here without worrying about whether
    /// SwiftUI re-evaluated the body for unrelated reasons.
    public func value(for key: Key, compute: () -> Output) -> Output {
        if let cachedKey, cachedKey == key, let cachedOutput {
            hitCount &+= 1
            return cachedOutput
        }
        let fresh = compute()
        cachedKey = key
        cachedOutput = fresh
        missCount &+= 1
        return fresh
    }

    /// Drop the cached pair so the next `value(for:)` call always
    /// recomputes. Useful when an upstream source mutates in a way the
    /// cache key doesn't capture (e.g. a soft refresh that should
    /// force-bust the cache).
    public func invalidate() {
        cachedKey = nil
        cachedOutput = nil
    }
}
