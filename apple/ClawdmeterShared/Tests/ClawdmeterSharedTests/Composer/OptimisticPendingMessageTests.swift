import XCTest
@testable import ClawdmeterShared

/// A13 — optimistic composer UI value-type behaviour. Exercises the
/// state machine on `OptimisticPendingMessage`:
///   - injection defaults to `.sending`
///   - D24 rejection: `failing(error:)` preserves id + body + attachments
///     and surfaces the error description
///   - retry preserves identity (no flicker)
///   - offline transition is distinct from failed
///   - accessibility labels match the user-visible state
final class OptimisticPendingMessageTests: XCTestCase {

    func test_init_defaults_toSending_withNoError() {
        let pending = OptimisticPendingMessage(body: "hello world")
        XCTAssertEqual(pending.state, .sending)
        XCTAssertTrue(pending.isSending)
        XCTAssertFalse(pending.canRetry)
        XCTAssertNil(pending.errorDescription)
        XCTAssertTrue(pending.attachmentRefs.isEmpty)
    }

    /// D24 rejection acceptance: a daemon-rejected send transitions to
    /// `.failed` but preserves id/body/attachments/createdAt so the
    /// bubble doesn't flicker on the transition.
    func test_failing_preservesIdentity_andSurfacesError() {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_000_000)
        let original = OptimisticPendingMessage(
            id: id,
            body: "send rejection test",
            attachmentRefs: ["screenshot.png"],
            createdAt: created
        )

        let failed = original.failing(error: "HTTP 400 from daemon")

        XCTAssertEqual(failed.id, id, "id must survive the state transition (no flicker)")
        XCTAssertEqual(failed.body, "send rejection test")
        XCTAssertEqual(failed.attachmentRefs, ["screenshot.png"])
        XCTAssertEqual(failed.createdAt, created)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.errorDescription, "HTTP 400 from daemon")
        XCTAssertTrue(failed.canRetry, "D24: failed pendings must offer retry")
        XCTAssertFalse(failed.isSending)
    }

    func test_retrying_resetsToSending_clearsError_preservesId() {
        let original = OptimisticPendingMessage(body: "retry test")
        let failed = original.failing(error: "fail")
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNotNil(failed.errorDescription)

        let retrying = failed.retrying()

        XCTAssertEqual(retrying.id, original.id, "retry must reuse the same id — no flicker")
        XCTAssertEqual(retrying.state, .sending)
        XCTAssertNil(retrying.errorDescription)
        XCTAssertEqual(retrying.body, original.body)
    }

    /// Offline state is distinct from failed so the UI can show
    /// "will retry" copy rather than the explicit-error copy.
    func test_queuedOffline_isDistinctState_withOptionalErrorCopy() {
        let pending = OptimisticPendingMessage(body: "offline test")

        let queued = pending.queuedOffline(error: "Daemon offline")

        XCTAssertEqual(queued.state, .queuedOffline)
        XCTAssertEqual(queued.errorDescription, "Daemon offline")
        XCTAssertTrue(queued.canRetry, "offline messages must offer retry")
        XCTAssertNotEqual(queued.state, .failed,
                          "offline must be a distinct state from failed")
    }

    func test_accessibilityLabel_reflectsState() {
        let sending = OptimisticPendingMessage(body: "voice over")
        XCTAssertEqual(sending.accessibilityLabel, "Sending message: voice over")

        let failed = sending.failing(error: "boom")
        XCTAssertTrue(failed.accessibilityLabel.contains("Failed to send"))
        XCTAssertTrue(failed.accessibilityLabel.contains("voice over"))
        XCTAssertTrue(failed.accessibilityLabel.contains("boom"))

        let offline = sending.queuedOffline(error: "no network")
        XCTAssertTrue(offline.accessibilityLabel.contains("Queued offline"))
        XCTAssertTrue(offline.accessibilityLabel.contains("voice over"))
    }

    /// Equality respects identity so SwiftUI's `.animation(value:)`
    /// observer can detect state transitions without re-injecting.
    func test_equality_andHashable_byAllFields() {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 42)
        let a = OptimisticPendingMessage(
            id: id, body: "x", attachmentRefs: ["y"], createdAt: created
        )
        let b = OptimisticPendingMessage(
            id: id, body: "x", attachmentRefs: ["y"], createdAt: created
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)

        let c = a.failing(error: "different state")
        XCTAssertNotEqual(a, c)
    }

    /// Codable round-trip — composer needs to persist the offline
    /// queue across restarts so messages aren't lost when the user
    /// quits during a daemon outage.
    func test_codable_roundTrip() throws {
        let original = OptimisticPendingMessage(
            body: "roundtrip",
            attachmentRefs: ["foo.png", "bar.txt"],
            state: .queuedOffline,
            errorDescription: "offline"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OptimisticPendingMessage.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
