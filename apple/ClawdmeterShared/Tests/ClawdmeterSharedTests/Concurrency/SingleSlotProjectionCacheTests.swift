import XCTest
@testable import ClawdmeterShared

final class SingleSlotProjectionCacheTests: XCTestCase {

    func test_firstCall_isCacheMiss_andInvokesCompute() {
        let cache = SingleSlotProjectionCache<Int, String>()
        var calls = 0
        let result = cache.value(for: 1) {
            calls += 1
            return "one"
        }
        XCTAssertEqual(result, "one")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 0)
    }

    func test_secondCallWithSameKey_isCacheHit_andSkipsCompute() {
        let cache = SingleSlotProjectionCache<Int, String>()
        var calls = 0
        _ = cache.value(for: 1) { calls += 1; return "one" }
        let result = cache.value(for: 1) {
            calls += 1
            return "one-again"  // would be returned only if compute ran
        }
        XCTAssertEqual(result, "one")        // cached value wins
        XCTAssertEqual(calls, 1)             // compute ran only once
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 1)
    }

    func test_keyChange_invalidatesCache() {
        let cache = SingleSlotProjectionCache<Int, String>()
        var calls = 0
        _ = cache.value(for: 1) { calls += 1; return "one" }
        let result = cache.value(for: 2) {
            calls += 1
            return "two"
        }
        XCTAssertEqual(result, "two")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cache.missCount, 2)
        XCTAssertEqual(cache.hitCount, 0)
    }

    func test_returningToPreviousKey_isStillMissBecauseCacheIsSingleSlot() {
        let cache = SingleSlotProjectionCache<Int, String>()
        var calls = 0
        _ = cache.value(for: 1) { calls += 1; return "one" }
        _ = cache.value(for: 2) { calls += 1; return "two" }
        let result = cache.value(for: 1) {
            calls += 1
            return "one-again"
        }
        XCTAssertEqual(result, "one-again")  // single-slot — old slot evicted
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(cache.missCount, 3)
    }

    func test_invalidate_forcesNextCallToRecompute() {
        let cache = SingleSlotProjectionCache<Int, String>()
        var calls = 0
        _ = cache.value(for: 1) { calls += 1; return "one" }
        cache.invalidate()
        let result = cache.value(for: 1) {
            calls += 1
            return "one-refreshed"
        }
        XCTAssertEqual(result, "one-refreshed")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cache.missCount, 2)
    }

    func test_hitCount_overManyIdenticalKeys() {
        let cache = SingleSlotProjectionCache<String, Int>()
        var calls = 0
        for _ in 0..<100 {
            _ = cache.value(for: "static") { calls += 1; return 42 }
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.hitCount, 99)
        XCTAssertEqual(cache.missCount, 1)
    }

    func test_compositeKey_typedAsStructEquatable() {
        struct K: Equatable {
            let a: Int
            let b: String
            let c: [UInt8]
        }
        let cache = SingleSlotProjectionCache<K, String>()
        var calls = 0
        let k1 = K(a: 1, b: "x", c: [1, 2, 3])
        let k1again = K(a: 1, b: "x", c: [1, 2, 3])
        let k2 = K(a: 1, b: "x", c: [1, 2, 4])  // differs by one byte
        _ = cache.value(for: k1) { calls += 1; return "first" }
        _ = cache.value(for: k1again) { calls += 1; return "should-not-run" }
        _ = cache.value(for: k2) { calls += 1; return "second" }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cache.missCount, 2)
        XCTAssertEqual(cache.hitCount, 1)
    }
}
