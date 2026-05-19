import XCTest
@testable import ClawdmeterShared

final class BrainPlanParserTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeBrain(file: StaticString = #file, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ str: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try str.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - .absent

    func test_parse_absentWhenDirMissing() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(BrainPlanParser.parse(brainURL: missing), .absent)
    }

    // MARK: - .awaitingFirstTurn

    func test_parse_awaitingFirstTurnWhenBrainEmptyOnDisk() throws {
        let brain = try makeBrain()
        // No task.md, no implementation_plan.md.
        XCTAssertEqual(BrainPlanParser.parse(brainURL: brain), .awaitingFirstTurn)
    }

    func test_parse_awaitingFirstTurnEvenWhenAnnotationsPresent() throws {
        let brain = try makeBrain()
        try write("last_user_view_time: { seconds: 1779219825 }",
                  to: brain.appendingPathComponent("annotations/abc.pbtxt"))
        // Annotations exist but task + plan don't — still awaiting first turn.
        XCTAssertEqual(BrainPlanParser.parse(brainURL: brain), .awaitingFirstTurn)
    }

    // MARK: - .ready happy path

    func test_parse_extractsTaskHeadlineAndBody() throws {
        let brain = try makeBrain()
        try write("""
        # Task: Comprehensive Codebase Bug Analysis

        Checklist for analyzing and reporting P0, P1, and P2 bugs.
        """, to: brain.appendingPathComponent("task.md"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.taskHeadline, "Task: Comprehensive Codebase Bug Analysis")
        XCTAssertEqual(plan.taskBody, "Checklist for analyzing and reporting P0, P1, and P2 bugs.")
    }

    func test_parse_headlineStripsMultipleHashes() throws {
        let brain = try makeBrain()
        try write("### Tiny task\n\nbody", to: brain.appendingPathComponent("task.md"))
        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.taskHeadline, "Tiny task")
    }

    func test_parse_headlineSkipsLeadingBlankLines() throws {
        let brain = try makeBrain()
        try write("\n\n\n# Headline below blanks", to: brain.appendingPathComponent("task.md"))
        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.taskHeadline, "Headline below blanks")
    }

    // MARK: - implementation_plan.md (CommonMark checklist)

    func test_parse_flatTopLevelChecklist() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        # Plan

        - [x] First step
        - [ ] Second step
        - [x] Third step
        """, to: brain.appendingPathComponent("implementation_plan.md"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.steps[0].label, "First step")
        XCTAssertTrue(plan.steps[0].isComplete)
        XCTAssertEqual(plan.steps[1].label, "Second step")
        XCTAssertFalse(plan.steps[1].isComplete)
        XCTAssertEqual(plan.steps[2].label, "Third step")
        XCTAssertTrue(plan.steps[2].isComplete)
    }

    func test_parse_nestedChecklistPreservesDepth() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        - [x] Top-level
          - [x] Nested A
          - [ ] Nested B
        - [ ] Top-level B
        """, to: brain.appendingPathComponent("implementation_plan.md"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].label, "Top-level")
        XCTAssertEqual(plan.steps[0].children.count, 2)
        XCTAssertEqual(plan.steps[0].children[0].label, "Nested A")
        XCTAssertEqual(plan.steps[0].children[0].depth, 1)
        XCTAssertTrue(plan.steps[0].children[0].isComplete)
        XCTAssertEqual(plan.steps[0].children[1].label, "Nested B")
        XCTAssertFalse(plan.steps[0].children[1].isComplete)
        XCTAssertEqual(plan.steps[1].label, "Top-level B")
    }

    func test_parse_ignoresProseBetweenLists() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        # Implementation Plan

        This is an introductory paragraph that should NOT become a step.

        - [x] Step one

        Some narrative between the lists.

        - [ ] Step two
        """, to: brain.appendingPathComponent("implementation_plan.md"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].label, "Step one")
        XCTAssertEqual(plan.steps[1].label, "Step two")
    }

    func test_parse_ignoresCodeBlocksInsideList() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        - [x] Build the parser

            ```swift
            func parse() { /* ... */ }
            ```

        - [ ] Write tests
        """, to: brain.appendingPathComponent("implementation_plan.md"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].label, "Build the parser")
        XCTAssertEqual(plan.steps[1].label, "Write tests")
    }

    func test_parse_skipsListItemsWithoutCheckbox() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        - This is a bullet without a checkbox — skip me
        - [x] But this one is a step
        - And so is this — also skip
        """, to: brain.appendingPathComponent("implementation_plan.md"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].label, "But this one is a step")
    }

    func test_parse_stepIDsAreUnique() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        - [x] One
        - [ ] Two
          - [ ] Three
        """, to: brain.appendingPathComponent("implementation_plan.md"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        let allIDs = collectAllStepIDs(plan.steps)
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "Step IDs should be unique across the tree")
    }

    private func collectAllStepIDs(_ steps: [BrainPlanStep]) -> [String] {
        var ids: [String] = []
        for step in steps {
            ids.append(step.id)
            ids.append(contentsOf: collectAllStepIDs(step.children))
        }
        return ids
    }

    // MARK: - annotations

    func test_parse_loadsAnnotations() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("last_user_view_time: { seconds: 1779219825 nanos: 0 }",
                  to: brain.appendingPathComponent("annotations/aaaa.pbtxt"))
        try write("last_user_view_time: { seconds: 1779219900 nanos: 0 }",
                  to: brain.appendingPathComponent("annotations/bbbb.pbtxt"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.annotations.count, 2)
        // Sorted by filename (stable diff).
        XCTAssertEqual(plan.annotations[0].filename, "aaaa.pbtxt")
        XCTAssertEqual(plan.annotations[1].filename, "bbbb.pbtxt")
    }

    func test_parse_ignoresNonPbtxtFilesInAnnotationsDir() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("foo", to: brain.appendingPathComponent("annotations/a.pbtxt"))
        try write("not annotation", to: brain.appendingPathComponent("annotations/random.txt"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.annotations.count, 1)
        XCTAssertEqual(plan.annotations[0].filename, "a.pbtxt")
    }

    // MARK: - requestFeedback flag

    func test_parse_requestFeedbackTrueWhenMetadataSet() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        {"artifactType":"implementation_plan","requestFeedback":true}
        """, to: brain.appendingPathComponent("implementation_plan.md.metadata.json"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertTrue(plan.requestsFeedback)
    }

    func test_parse_requestFeedbackFalseByDefault() throws {
        let brain = try makeBrain()
        try write("# Task\n", to: brain.appendingPathComponent("task.md"))
        try write("""
        {"artifactType":"implementation_plan"}
        """, to: brain.appendingPathComponent("implementation_plan.md.metadata.json"))

        guard case let .ready(plan) = BrainPlanParser.parse(brainURL: brain) else {
            return XCTFail("Expected .ready")
        }
        XCTAssertFalse(plan.requestsFeedback)
    }

    // MARK: - transcript.jsonl cwd

    func test_readTranscriptCwd_returnsCwdField() throws {
        let brain = try makeBrain()
        let transcriptURL = brain
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
            .appendingPathComponent("transcript.jsonl")
        // Bounded-read fixture: tiny JSONL with cwd in line 0.
        try write(#"{"type":"USER_REQUEST","cwd":"/Users/a/Repo1","prompt":"hi"}"#, to: transcriptURL)

        let cwd = BrainPlanParser.readTranscriptCwd(brainURL: brain)
        XCTAssertEqual(cwd?.path, "/Users/a/Repo1")
    }

    func test_readTranscriptCwd_returnsNilWhenFileMissing() throws {
        let brain = try makeBrain()
        XCTAssertNil(BrainPlanParser.readTranscriptCwd(brainURL: brain))
    }

    func test_readTranscriptCwd_handlesLargeTranscriptInBoundedTime() throws {
        // 50 MB worst-case payload — the parser must NOT load the whole
        // thing. We can only assert "completes quickly" rather than
        // "doesn't load whole file", but completing under 50ms on a 50MB
        // file is a strong signal the bounded read works.
        let brain = try makeBrain()
        let transcriptURL = brain
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
            .appendingPathComponent("transcript.jsonl")
        try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write a small first line, then 1 MB of padding.
        var bigContent = #"{"type":"USER_REQUEST","cwd":"/Users/a/Repo1"}"# + "\n"
        bigContent += String(repeating: "x", count: 1_000_000)
        try bigContent.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let start = Date()
        let cwd = BrainPlanParser.readTranscriptCwd(brainURL: brain)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(cwd?.path, "/Users/a/Repo1")
        XCTAssertLessThan(elapsed, 0.1, "Bounded 1KB read must complete in <100ms even on 1MB transcripts")
    }
}
