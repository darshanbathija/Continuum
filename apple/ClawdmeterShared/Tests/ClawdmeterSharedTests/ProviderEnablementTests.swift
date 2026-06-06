import XCTest
@testable import ClawdmeterShared

final class ProviderEnablementTests: XCTestCase {
    private let discoverParallelSessionsKey = "clawdmeter.code.discoverParallelSessions"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: discoverParallelSessionsKey)
        super.tearDown()
    }

    func testDiscoverParallelSessionsIgnoresPersistedOptIn() {
        UserDefaults.standard.set(true, forKey: discoverParallelSessionsKey)

        XCTAssertFalse(ProviderEnablement.discoverParallelSessions)
    }

    func testDiscoverParallelSessionsSetterCannotEnableExternalDiscovery() {
        ProviderEnablement.discoverParallelSessions = true

        XCTAssertFalse(ProviderEnablement.discoverParallelSessions)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: discoverParallelSessionsKey))
    }
}
