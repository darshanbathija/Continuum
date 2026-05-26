import XCTest
@testable import ClawdmeterShared

final class ParsedDiffCacheTests: XCTestCase {

    func testMissThenHit() {
        let cache = ParsedDiffCache(capacity: 4)
        let key = ParsedDiffCache.Key(inputHash: "abc", contextLines: 3)
        XCTAssertNil(cache.lookup(key))

        let parsed = UnifiedDiffParser.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        cache.set(parsed, for: key)
        XCTAssertEqual(cache.lookup(key)?.files.count, 1)
        XCTAssertEqual(cache.count, 1)
    }

    func testParsedConvenienceSharesResultsForRepeatInput() {
        let cache = ParsedDiffCache(capacity: 4)
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        let first = cache.parsed(input: diff)
        let second = cache.parsed(input: diff)
        XCTAssertEqual(first.inputHash, second.inputHash)
        XCTAssertEqual(cache.count, 1)
    }

    func testContextLinesIsPartOfKey() {
        let cache = ParsedDiffCache(capacity: 4)
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        _ = cache.parsed(input: diff, contextLines: 3)
        _ = cache.parsed(input: diff, contextLines: 7)
        XCTAssertEqual(cache.count, 2)
    }

    func testLRUEvictsOldestWhenCapacityExceeded() {
        let cache = ParsedDiffCache(capacity: 2)
        let k1 = ParsedDiffCache.Key(inputHash: "h1", contextLines: 3)
        let k2 = ParsedDiffCache.Key(inputHash: "h2", contextLines: 3)
        let k3 = ParsedDiffCache.Key(inputHash: "h3", contextLines: 3)
        let dummy = UnifiedDiffParser.parse("")
        cache.set(dummy, for: k1)
        cache.set(dummy, for: k2)
        // Touch k1 to make k2 the LRU.
        XCTAssertNotNil(cache.lookup(k1))
        cache.set(dummy, for: k3)
        // k2 was the LRU at insert time of k3, so it should be gone.
        XCTAssertNil(cache.lookup(k2))
        XCTAssertNotNil(cache.lookup(k1))
        XCTAssertNotNil(cache.lookup(k3))
        XCTAssertEqual(cache.count, 2)
    }

    func testClearDropsEverything() {
        let cache = ParsedDiffCache(capacity: 4)
        cache.set(UnifiedDiffParser.parse(""), for: ParsedDiffCache.Key(inputHash: "h1", contextLines: 3))
        cache.clear()
        XCTAssertEqual(cache.count, 0)
    }

    func testFileCacheBasic() {
        let cache = ParsedDiffFileCache(capacity: 4)
        let lines = [
            ParsedDiff.Line(fileIndex: 0, hunkIndex: 0, offset: 0, kind: .add, text: "+x")
        ]
        let key = ParsedDiffFileCache.Key(path: "foo.swift", hunksHash: "abc")
        XCTAssertNil(cache.lookup(key))
        cache.set(lines, for: key)
        XCTAssertEqual(cache.lookup(key)?.count, 1)
    }

    // MARK: - Threading

    func testCacheIsConcurrencySafe() {
        let cache = ParsedDiffCache(capacity: 8)
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        let expectation = expectation(description: "all writers finish")
        expectation.expectedFulfillmentCount = 16
        for _ in 0..<16 {
            DispatchQueue.global().async {
                _ = cache.parsed(input: diff)
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(cache.count, 1)
    }
}
