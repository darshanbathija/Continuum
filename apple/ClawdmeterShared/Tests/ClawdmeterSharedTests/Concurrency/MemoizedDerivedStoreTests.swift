import XCTest
@testable import ClawdmeterShared

/// Tests for the A4-pre `MemoizedDerivedStore` utility. Locks in the
/// cache-hit, cache-miss, cancellation, and detached-mode behavior that
/// A4 / C1 / F1 will depend on.
@MainActor
final class MemoizedDerivedStoreTests: XCTestCase {

    // MARK: - Cache key

    private struct Key: Equatable {
        let n: Int
        let label: String
    }

    // MARK: - Sync mode

    func test_sync_cacheHit_skipsCompute() {
        let computeCount = LockedCounter()
        let store = MemoizedDerivedStore<Key, Int>(mode: .sync) { input in
            computeCount.increment()
            return input.n * 2
        }
        store.update(input: Key(n: 5, label: "a"))
        XCTAssertEqual(store.output, 10)
        XCTAssertEqual(computeCount.value, 1)

        // Identical input → cache hit → no compute.
        store.update(input: Key(n: 5, label: "a"))
        XCTAssertEqual(store.output, 10)
        XCTAssertEqual(computeCount.value, 1, "Cache hit on identical input must not recompute")
    }

    func test_sync_cacheMiss_recomputes() {
        let computeCount = LockedCounter()
        let store = MemoizedDerivedStore<Key, Int>(mode: .sync) { input in
            computeCount.increment()
            return input.n * 2
        }
        store.update(input: Key(n: 5, label: "a"))
        store.update(input: Key(n: 7, label: "a"))
        XCTAssertEqual(store.output, 14)
        XCTAssertEqual(computeCount.value, 2)

        // Different label is still a cache miss (full Equatable comparison).
        store.update(input: Key(n: 7, label: "b"))
        XCTAssertEqual(computeCount.value, 3)
    }

    func test_sync_placeholder_isInitialOutput() {
        let store = MemoizedDerivedStore<Key, Int>(
            placeholder: -1,
            mode: .sync
        ) { input in
            input.n * 2
        }
        XCTAssertEqual(store.output, -1, "Placeholder surfaces before any update lands")
    }

    func test_invalidate_resetsToPlaceholder() {
        let store = MemoizedDerivedStore<Key, Int>(
            placeholder: -1,
            mode: .sync
        ) { input in
            input.n * 2
        }
        store.update(input: Key(n: 5, label: "a"))
        XCTAssertEqual(store.output, 10)
        store.invalidate()
        XCTAssertEqual(store.output, -1)

        // After invalidate, the next update should compute even if the
        // input matches a prior value.
        let computeCount = LockedCounter()
        let store2 = MemoizedDerivedStore<Key, Int>(
            placeholder: nil,
            mode: .sync
        ) { input in
            computeCount.increment()
            return input.n * 2
        }
        store2.update(input: Key(n: 5, label: "a"))
        store2.invalidate()
        store2.update(input: Key(n: 5, label: "a"))
        XCTAssertEqual(computeCount.value, 2, "Invalidate must drop the cache so the next identical input recomputes")
    }

    // MARK: - Detached mode

    func test_detached_surfacesPlaceholderWhileComputing() async throws {
        // Use a continuation we control so we can observe the placeholder
        // state mid-compute.
        let computeStarted = expectation(description: "compute started")
        let computeFinished = expectation(description: "compute finished")
        let store = MemoizedDerivedStore<Key, String>(
            placeholder: "loading…",
            mode: .detached(priority: .utility)
        ) { input in
            computeStarted.fulfill()
            // Slow sync work: 50ms is enough to verify placeholder is
            // observable without making the suite slow.
            Thread.sleep(forTimeInterval: 0.05)
            computeFinished.fulfill()
            return "value=\(input.n)"
        }
        XCTAssertEqual(store.output, "loading…")

        store.update(input: Key(n: 42, label: "x"))
        await fulfillment(of: [computeStarted], timeout: 1.0)
        // While the detached task is running, output is the placeholder.
        XCTAssertEqual(store.output, "loading…", "Detached mode shows placeholder during compute")

        await fulfillment(of: [computeFinished], timeout: 1.0)
        // Bridge back to main actor + observe.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.output, "value=42")
    }

    func test_update_cancelsInflightWork() async throws {
        // First update is slow; second update should cancel the first
        // before it can land. Compute closures are sync, so cancellation
        // is observed via the post-compute Task.isCancelled check that
        // gates the main-actor output write.
        let firstLanded = LockedFlag()
        let secondLanded = LockedFlag()
        let store = MemoizedDerivedStore<Key, Int>(
            mode: .detached(priority: .utility)
        ) { input in
            if input.n == 1 {
                Thread.sleep(forTimeInterval: 0.2)
                firstLanded.attemptSet()
                return -1
            } else {
                secondLanded.attemptSet()
                return input.n
            }
        }
        store.update(input: Key(n: 1, label: "slow"))
        try await Task.sleep(nanoseconds: 20_000_000)
        // Cancel the slow first update by issuing a different input.
        store.update(input: Key(n: 2, label: "fast"))
        // Wait long enough for the second to land + first to be cancelled.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(store.output, 2)
        // The first compute closure DID run (Thread.sleep completed before
        // we cancelled), but its main-actor write was skipped by the
        // Task.isCancelled gate, so it didn't clobber the second result.
        XCTAssertEqual(store.output, 2, "Cancelled first task must not overwrite second task's output")
        XCTAssertTrue(secondLanded.value)
    }

    // MARK: - Type behavior

    func test_genericOverArbitraryEquatableInput() {
        // Make sure the generic accepts a struct with multiple fields,
        // mirroring A4's `(snapshot.computedAt, window, providerFilter)`
        // composite key shape.
        struct Composite: Equatable {
            let computedAt: Date
            let window: Int
            let filter: String
        }
        let store = MemoizedDerivedStore<Composite, [Int]>(mode: .sync) { key in
            (0..<key.window).map { $0 + Int(key.computedAt.timeIntervalSince1970) }
        }
        let now = Date()
        store.update(input: Composite(computedAt: now, window: 3, filter: "claude"))
        XCTAssertEqual(store.output?.count, 3)
    }
}

// MARK: - Test helpers (thread-safe across Task boundaries)

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func attemptSet() {
        lock.lock(); defer { lock.unlock() }
        _value = true
    }
}
