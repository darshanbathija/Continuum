import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class TranscriptMessageGutterTests: XCTestCase {
    func test_previewTextCollapsesWhitespaceAndTruncates() {
        let body = "  Go bigger and more prominent.\n\nMake the hero image fill the card.  "
        XCTAssertEqual(
            TranscriptGutterPreview.text(for: body),
            "Go bigger and more prominent. Make the hero image fill the card."
        )

        let long = String(repeating: "a", count: 120)
        XCTAssertEqual(TranscriptGutterPreview.text(for: long).count, 80)
        XCTAssertTrue(TranscriptGutterPreview.text(for: long).hasSuffix("…"))
    }

    func test_markersUseMeasuredPositionsWhenAvailable() {
        let turns = sampleTurns()
        let markers = TranscriptGutterPreview.markers(
            turns: turns,
            measuredPositions: ["u2": 400],
            contentHeight: 800
        )

        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].id, "u1")
        XCTAssertEqual(markers[1].id, "u2")
        XCTAssertEqual(markers[1].fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(markers[0].preview, "First prompt")
        XCTAssertEqual(markers[1].preview, "Second prompt with more detail")
    }

    func test_markersFallBackToEvenDistributionWithoutMeasurements() {
        let turns = sampleTurns()
        let markers = TranscriptGutterPreview.markers(
            turns: turns,
            measuredPositions: [:],
            contentHeight: 0
        )

        XCTAssertEqual(markers[0].fraction, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(markers[1].fraction, 2.0 / 3.0, accuracy: 0.001)
    }

    private func sampleTurns() -> [TranscriptTurn] {
        let projection = TranscriptTurnProjector.project(
            messages: [
                msg("u1", .userText, "First prompt", 0),
                msg("a1", .assistantText, "Done", 1),
                msg("u2", .userText, "Second prompt with more detail", 2),
                msg("a2", .assistantText, "Also done", 3),
            ],
            mode: .latestAnswerOnly
        )
        return projection.turns
    }

    private func msg(
        _ id: String,
        _ kind: ChatMessage.Kind,
        _ body: String,
        _ offset: TimeInterval
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            kind: kind,
            title: kind == .userText ? "You" : "Assistant",
            body: body,
            at: Date(timeIntervalSince1970: offset)
        )
    }
}
