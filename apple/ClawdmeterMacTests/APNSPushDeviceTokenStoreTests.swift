// E6: device-token store tests.

import XCTest
@testable import Clawdmeter

final class APNSPushDeviceTokenStoreTests: XCTestCase {

    private func makeStore() -> (APNSPushDeviceTokenStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("e6-tokens-\(UUID()).json")
        return (APNSPushDeviceTokenStore(fileURL: tmp), tmp)
    }

    func testRegisterThenLookupBySession() {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let token = String(repeating: "ab", count: 32)
        store.register(sessionId: "sid-A", deviceToken: token, bundleId: "ai.continuum.ios")
        XCTAssertEqual(store.count, 1)
        let entry = store.entry(forSessionId: "sid-A")
        XCTAssertEqual(entry?.deviceToken, token)
        XCTAssertEqual(entry?.bundleId, "ai.continuum.ios")
    }

    func testRegisterIsIdempotent() {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let token = String(repeating: "cd", count: 32)
        store.register(sessionId: "sid-B", deviceToken: token, bundleId: "ai.continuum.ios")
        store.register(sessionId: "sid-B", deviceToken: token, bundleId: "ai.continuum.ios")
        XCTAssertEqual(store.count, 1, "Repeated register MUST be idempotent")
    }

    func testPurgeBySession() {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        store.register(sessionId: "sid-C", deviceToken: String(repeating: "ef", count: 32), bundleId: "x")
        XCTAssertEqual(store.count, 1)
        store.purge(sessionId: "sid-C")
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.entry(forSessionId: "sid-C"))
    }

    func testPurgeByDeviceTokenForFourTenCleanup() {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let token = String(repeating: "11", count: 32)
        store.register(sessionId: "sid-D", deviceToken: token, bundleId: "x")
        store.purgeByDeviceToken(token)
        XCTAssertEqual(store.count, 0)
    }

    /// Disk persistence — re-instantiating the store on the same file
    /// should restore the previously-registered entries.
    func testPersistsAcrossInstantiations() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("e6-tokens-persist-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeA = APNSPushDeviceTokenStore(fileURL: tmp)
        let token = String(repeating: "22", count: 32)
        storeA.register(sessionId: "sid-persist", deviceToken: token, bundleId: "ai.continuum.ios")

        let storeB = APNSPushDeviceTokenStore(fileURL: tmp)
        XCTAssertEqual(storeB.count, 1)
        XCTAssertEqual(storeB.entry(forSessionId: "sid-persist")?.deviceToken, token)
    }
}
