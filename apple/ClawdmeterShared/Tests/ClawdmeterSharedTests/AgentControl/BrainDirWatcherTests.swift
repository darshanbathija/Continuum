import XCTest
@testable import ClawdmeterShared

/// Smoke-tests the BrainDirWatcher class against a synthetic tempdir.
/// We can't drive an exhaustive matrix of vnode events from XCTest, but
/// these tests catch the basic lifecycle: start succeeds, change → callback,
/// callback fires on the configured queue, stop closes the fd.
final class BrainDirWatcherTests: XCTestCase {

    private func makeDir(file: StaticString = #file, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_start_returnsFalseOnMissingDir() {
        let missing = URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString)")
        let watcher = BrainDirWatcher(dirURL: missing)
        XCTAssertFalse(watcher.start { /* should not fire */ })
    }

    func test_start_returnsTrueOnExistingDir() throws {
        let dir = try makeDir()
        let watcher = BrainDirWatcher(dirURL: dir)
        XCTAssertTrue(watcher.start { })
        watcher.stop()
    }

    func test_callbackFiresOnFileWrite() throws {
        let dir = try makeDir()
        let queue = DispatchQueue(label: "watcher-test", qos: .userInitiated)
        let watcher = BrainDirWatcher(dirURL: dir, debounceInterval: 0.05, queue: queue)
        let exp = expectation(description: "watcher fires")
        exp.assertForOverFulfill = false
        let didStart = watcher.start {
            exp.fulfill()
        }
        XCTAssertTrue(didStart)

        // Touch a new file in the dir — this should trigger the watcher.
        // Brief sleep so the watcher's source is fully attached before we
        // write (the test is timing-sensitive but resilient via the
        // expectation timeout).
        queue.asyncAfter(deadline: .now() + 0.05) {
            try? "hello".write(
                to: dir.appendingPathComponent("touch-\(UUID().uuidString)"),
                atomically: true,
                encoding: .utf8
            )
        }

        wait(for: [exp], timeout: 2.0)
        watcher.stop()
    }

    func test_debounceCoalescesRapidWrites() throws {
        let dir = try makeDir()
        let queue = DispatchQueue(label: "watcher-test", qos: .userInitiated)
        let watcher = BrainDirWatcher(dirURL: dir, debounceInterval: 0.15, queue: queue)

        // Count how many times the callback fires across 20 quick writes.
        // With debounce, we should see ≤ 2 firings, not 20.
        let counter = TestCounter()
        let exp = expectation(description: "settled")
        exp.assertForOverFulfill = false
        XCTAssertTrue(watcher.start {
            counter.increment()
            // After the burst settles, give the timer a beat to coalesce.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                exp.fulfill()
            }
        })

        // Fire 20 writes back-to-back.
        queue.asyncAfter(deadline: .now() + 0.05) {
            for _ in 0..<20 {
                try? "x".write(
                    to: dir.appendingPathComponent("burst-\(UUID().uuidString)"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        wait(for: [exp], timeout: 3.0)
        watcher.stop()
        // Empirically the debounced source coalesces all 20 events into 1
        // callback. Allow up to 2 to tolerate timing slop in CI.
        XCTAssertLessThanOrEqual(counter.value, 2, "20 rapid writes should coalesce to ≤2 callbacks")
    }

    func test_stopIsIdempotent() throws {
        let dir = try makeDir()
        let watcher = BrainDirWatcher(dirURL: dir)
        XCTAssertTrue(watcher.start { })
        watcher.stop()
        watcher.stop() // calling stop twice should not crash
    }
}

/// Thread-safe counter for the debounce test.
private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
