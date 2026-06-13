import XCTest
@testable import Clawdmeter

@MainActor
final class DictationHistoryStoreTests: XCTestCase {
    func testAppendPrependsNewestEntry() {
        let directory = temporaryAppSupportDirectory()
        let store = DictationHistoryStore(appSupportDirectory: directory)
        store.append("first")
        store.append("second")
        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])
    }

    func testAppendTruncatesToMaximumEntries() {
        let directory = temporaryAppSupportDirectory()
        let store = DictationHistoryStore(appSupportDirectory: directory)
        for index in 0..<25 {
            store.append("entry \(index)")
        }
        XCTAssertEqual(store.entries.count, DictationHistoryStore.maximumEntries)
        XCTAssertEqual(store.entries.first?.text, "entry 24")
        XCTAssertEqual(store.entries.last?.text, "entry 5")
    }

    func testAppendIgnoresEmptyText() {
        let directory = temporaryAppSupportDirectory()
        let store = DictationHistoryStore(appSupportDirectory: directory)
        store.append("   ")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testClearRemovesAllEntries() {
        let directory = temporaryAppSupportDirectory()
        let store = DictationHistoryStore(appSupportDirectory: directory)
        store.append("hello")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPersistsAcrossReload() {
        let directory = temporaryAppSupportDirectory()
        let firstStore = DictationHistoryStore(appSupportDirectory: directory)
        firstStore.append("persisted")

        let reloadedStore = DictationHistoryStore(appSupportDirectory: directory)
        XCTAssertEqual(reloadedStore.entries.map(\.text), ["persisted"])
    }

    private func temporaryAppSupportDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuumHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
