#if os(macOS)
import XCTest
@testable import ClawdmeterShared

final class CursorAuthProbeTests: XCTestCase {

    func test_isStatusOutputAuthenticated_rejectsCommonLoggedOutPhrases() {
        XCTAssertFalse(CursorAuthProbe.isStatusOutputAuthenticated("Not logged in"))
        XCTAssertFalse(CursorAuthProbe.isStatusOutputAuthenticated("not authenticated"))
        XCTAssertFalse(CursorAuthProbe.isStatusOutputAuthenticated("You are not signed in"))
        XCTAssertTrue(CursorAuthProbe.isStatusOutputAuthenticated("Logged in as user@example.com"))
    }
}
#endif
