import XCTest
@testable import ClawdmeterShared

/// Guards the `TransientToast.severity` addition made for the Code-tab feedback
/// layer. The field is decoded with `decodeIfPresent ?? .info` so toasts
/// persisted/encoded before severity existed still decode cleanly.
final class TransientToastTests: XCTestCase {

    func test_defaultSeverityIsInfo() {
        XCTAssertEqual(TransientToast(title: "Archived").severity, .info)
    }

    func test_severityRoundTrips() throws {
        let original = TransientToast(title: "Merge failed", detail: "boom", severity: .failure)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TransientToast.self, from: data)
        XCTAssertEqual(decoded.severity, .failure)
        XCTAssertEqual(decoded.title, "Merge failed")
        XCTAssertEqual(decoded.detail, "boom")
    }

    func test_legacyPayloadWithoutSeverity_decodesToInfo() throws {
        // A toast encoded before `severity` existed (key absent). Default date
        // strategy decodes `createdAt` from a raw Double (secs since 2001).
        let json = """
        {"id":"\(UUID().uuidString)","title":"Archived Foo","duration":5,"createdAt":12345.0,"isDestructiveRecovery":true}
        """
        let decoded = try JSONDecoder().decode(TransientToast.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.severity, .info)
        XCTAssertTrue(decoded.isDestructiveRecovery)
        XCTAssertEqual(decoded.title, "Archived Foo")
    }
}
