import XCTest
@testable import Clawdmeter

final class MacComposerSenderTests: XCTestCase {
    func testHTTPErrorDescriptionIncludesDaemonDetail() {
        let error = MacComposerSender.Error.http(
            status: 503,
            retryAfter: nil,
            detail: "acp_start_failed: codex thread/start failed"
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Daemon HTTP 503: acp_start_failed: codex thread/start failed"
        )
    }
}
