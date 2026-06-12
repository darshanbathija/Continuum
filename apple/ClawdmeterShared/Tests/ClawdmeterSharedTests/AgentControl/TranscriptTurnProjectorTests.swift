import XCTest
@testable import ClawdmeterShared

final class TranscriptTurnProjectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testCompletedTurnShowsPromptAndFinalAnswerOnlyByDefault() {
        let messages = [
            msg("u1", .userText, "You", "Build the page", 0),
            msg("a1", .assistantText, "Codex", "I will inspect first.", 5),
            msg("call:t1", .toolCall, "exec_command", "rg page", 10),
            msg("result:t1", .toolResult, "exec_command", "found files", 12),
            msg("a2", .assistantText, "Codex", "Done. Open .context/site.html", 30),
        ]

        let projection = TranscriptTurnProjector.project(messages: messages, now: t0.addingTimeInterval(30))

        XCTAssertEqual(projection.turns.count, 1)
        let turn = try! XCTUnwrap(projection.turns.first)
        XCTAssertEqual(turn.visibleItems.map(\.id), ["u1", "a2"])
        XCTAssertEqual(turn.hiddenItems.count, 2)
        XCTAssertEqual(turn.summary.hiddenMessageCount, 3)
        XCTAssertEqual(turn.summary.toolCallCount, 1)
        XCTAssertEqual(turn.outputArtifacts.map(\.path), [".context/site.html"])
        XCTAssertEqual(turn.outputArtifacts.map(\.kind), [.html])
    }

    func testStreamingTurnWithoutFinalAnswerStillKeepsPromptVisible() {
        let messages = [
            msg("u1", .userText, "You", "Run tests", 0),
            msg("call:t1", .toolCall, "exec_command", "swift test", 5),
        ]

        let projection = TranscriptTurnProjector.project(messages: messages, now: t0.addingTimeInterval(8))
        let turn = try! XCTUnwrap(projection.turns.first)

        XCTAssertEqual(turn.visibleItems.map(\.id), ["u1", "run:t1"])
        XCTAssertEqual(turn.hiddenItems.map(\.id), [])
        XCTAssertEqual(turn.summary.toolCallCount, 1)
    }

    func testSyntheticUserTextAfterToolResultDoesNotSplitTurn() {
        let messages = [
            msg("u1", .userText, "You", "Implement feature", 0),
            msg("call:t1", .toolCall, "Task", "spawn helper", 1),
            msg("result:t1", .toolResult, "Task", "helper done", 2),
            msg("synthetic", .userText, "You", "Request interrupted", 2),
            msg("a1", .assistantText, "Codex", "Feature done", 4),
            msg("u2", .userText, "You", "Now test it", 8),
        ]

        let projection = TranscriptTurnProjector.project(messages: messages)

        XCTAssertEqual(projection.turns.count, 2)
        XCTAssertEqual(projection.turns[0].prompt?.id, "u1")
        XCTAssertTrue(projection.turns[0].hiddenItems.flatMap(Self.flatten).contains { $0.id == "synthetic" })
        XCTAssertEqual(projection.turns[1].prompt?.id, "u2")
    }

    func testPaginatedOrphanToolResultIsPreservedLosslessly() {
        let messages = [
            msg("result:t1", .toolResult, "exec_command", "old page result", 0),
            msg("u1", .userText, "You", "Continue", 3),
            msg("a1", .assistantText, "Codex", "Continuing.", 5),
        ]

        let projection = TranscriptTurnProjector.project(messages: messages)

        XCTAssertEqual(projection.turns.count, 2)
        XCTAssertEqual(projection.turns[0].expandedItems.map(\.id), ["result:t1"])
        if case .message(let preserved)? = projection.turns[0].expandedItems.first {
            XCTAssertEqual(preserved.kind, .toolResult)
        } else {
            XCTFail("Expected orphan tool result to remain a visible message row")
        }
    }

    func testAnchorsMapHiddenToolResultToPairAnchor() {
        let messages = [
            msg("u1", .userText, "You", "Search", 0),
            msg("call:t1", .toolCall, "exec_command", "rg needle", 1),
            msg("result:t1", .toolResult, "exec_command", "needle appears here", 2),
            msg("a1", .assistantText, "Codex", "Found it.", 3),
        ]

        let projection = TranscriptTurnProjector.project(messages: messages)
        let anchor = projection.anchorByMessageId["result:t1"]

        XCTAssertEqual(anchor?.turnId, "turn:u1")
        XCTAssertEqual(anchor?.itemId, "pair:t1")
        XCTAssertEqual(anchor?.pairId, "t1")
        XCTAssertEqual(anchor?.isHidden, true)
    }

    func testOutputClassifierDetectsHtmlMarkdownImagesAndArchives() {
        let text = "Open /tmp/site.html, docs/report.MDOWN, ./shot.png, and build/archive.zip"

        let candidates = TranscriptArtifactClassifier.pathCandidates(in: text)

        XCTAssertEqual(candidates, ["/tmp/site.html", "docs/report.MDOWN", "./shot.png", "build/archive.zip"])
        XCTAssertEqual(TranscriptArtifactClassifier.kind(forPath: "/tmp/site.html"), .html)
        XCTAssertEqual(TranscriptArtifactClassifier.kind(forPath: "docs/report.MDOWN"), .markdown)
        XCTAssertEqual(TranscriptArtifactClassifier.kind(forPath: "./shot.png"), .image)
        XCTAssertEqual(TranscriptArtifactClassifier.kind(forPath: "build/archive.zip"), .archive)
        XCTAssertTrue(GeneratedArtifactDetector.isMarkdownPath("docs/report.MDOWN"))
    }

    func testEditedFileChipStripOverflowSummaryAggregatesHiddenFiles() {
        let files = (0..<14).map {
            TranscriptEditedFile(
                filePath: "Sources/File\($0).swift",
                additions: $0 == 0 ? 52 : 1,
                deletions: $0 == 0 ? 5 : 1
            )
        }

        XCTAssertNil(TranscriptEditedFileChipStripModel.overflowSummary(for: Array(files.prefix(4))))

        let overflow = TranscriptEditedFileChipStripModel.overflowSummary(for: files)
        XCTAssertEqual(overflow?.hiddenCount, 10)
        XCTAssertEqual(overflow?.additions, 10)
        XCTAssertEqual(overflow?.deletions, 10)
    }

    func testEditFileDetailsAttachDiffPayloadFromExpandedItems() {
        let editStatsMessage = msg(
            "call:edit",
            .toolCall,
            "Edit",
            "Sources/App.swift",
            0,
            editStats: EditStats(kind: .edit, filePath: "Sources/App.swift", additions: 2, deletions: 1),
            editDiff: EditDiff(kind: .edit, filePath: "Sources/App.swift", additions: 2, deletions: 1, preview: "-old\n+new")
        )
        let turn = TranscriptTurnProjector
            .project(messages: [msg("u1", .userText, "You", "Edit", -1), editStatsMessage])
            .turns[0]

        let details = turn.editFileDetails()
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details[0].stats.filePath, "Sources/App.swift")
        XCTAssertEqual(details[0].editDiff?.preview, "-old\n+new")
    }

    func testEditedFilesPreferEditStatsAndFallBackToEditDiff() {
        let editStatsMessage = msg(
            "call:edit",
            .toolCall,
            "Edit",
            "Sources/App.swift",
            0,
            editStats: EditStats(kind: .edit, filePath: "Sources/App.swift", additions: 2, deletions: 1)
        )
        let diffMessage = msg(
            "call:patch",
            .toolCall,
            "apply_patch",
            "Patch",
            1,
            editDiff: EditDiff(kind: .applyPatch, filePath: "Other.swift", additions: 9, deletions: 9, preview: """
            *** Update File: Views/A.swift
            @@
            -old
            +new
            *** Add File: Views/B.swift
            +line 1
            +line 2
            """)
        )

        let files = TranscriptTurnProjector
            .project(messages: [msg("u1", .userText, "You", "Edit", -1), editStatsMessage, diffMessage])
            .turns[0]
            .editedFiles

        XCTAssertEqual(files.map(\.filePath), ["Sources/App.swift", "Views/A.swift", "Views/B.swift"])
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[1].additions, 1)
        XCTAssertEqual(files[1].deletions, 1)
        XCTAssertEqual(files[2].additions, 2)
        XCTAssertEqual(files[2].deletions, 0)
    }

    private func msg(
        _ id: String,
        _ kind: ChatMessage.Kind,
        _ title: String,
        _ body: String,
        _ offset: TimeInterval,
        editStats: EditStats? = nil,
        editDiff: EditDiff? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            kind: kind,
            title: title,
            body: body,
            at: t0.addingTimeInterval(offset),
            editStats: editStats,
            editDiff: editDiff
        )
    }

    private static func flatten(_ item: ChatItem) -> [ChatMessage] {
        switch item {
        case .message(let message):
            return [message]
        case .toolRun(_, let pairs):
            return pairs.flatMap { pair in
                [pair.call] + (pair.result.map { [$0] } ?? [])
            }
        }
    }
}
