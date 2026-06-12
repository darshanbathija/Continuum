import XCTest
@testable import ClawdmeterShared

final class ToolPresentationTests: XCTestCase {

    func test_toolCatalogNormalizesKnownProviderNames() {
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "Bash"), "bash")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "exec_command"), "bash")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "web_search"), "web_search")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "web_fetch"), "web_fetch")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "MultiEdit"), "multiedit")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "Edit"), "edit")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "Grep"), "grep")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "Glob"), "glob")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "AskUserQuestion"), "ask_user")
    }

    func test_toolPresentationCarriesDataOnlyStylingHints() {
        let bash = ToolPresentationCatalog.presentation(for: "exec_command", summary: "git status")
        XCTAssertEqual(bash.displayName, "Bash")
        XCTAssertEqual(bash.systemImageName, "terminal.fill")
        XCTAssertEqual(bash.tone, .shell)
        XCTAssertEqual(bash.summary, "git status")

        let grep = ToolPresentationCatalog.presentation(for: "Grep")
        XCTAssertEqual(grep.normalizedKind, "grep")
        XCTAssertEqual(grep.systemImageName, "line.3.horizontal.decrease.circle")
        XCTAssertEqual(grep.tone, .search)

        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "StrReplace"), "edit")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "codebase_search"), "web_search")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "read_file"), "read")
        XCTAssertEqual(ToolPresentationCatalog.normalizedKind(for: "WebFetch"), "web_fetch")

        let unknown = ToolPresentationCatalog.presentation(for: "future_tool", isError: true)
        XCTAssertEqual(unknown.tone, .warning)
        XCTAssertTrue(unknown.defaultExpanded)
    }

    func test_editDiffParsesClaudeEditAndApplyPatch() {
        let edit = EditDiff.fromClaudeInput([
            "file_path": "/repo/App.swift",
            "old_string": "let a = 1\n",
            "new_string": "let a = 2\nlet b = 3\n"
        ], toolName: "Edit")

        XCTAssertEqual(edit?.kind, .edit)
        XCTAssertEqual(edit?.filePath, "/repo/App.swift")
        XCTAssertEqual(edit?.additions, 2)
        XCTAssertEqual(edit?.deletions, 1)

        let patch = """
        *** Begin Patch
        *** Update File: Sources/App.swift
        @@
        -old
        +new
        +another
        *** End Patch
        """
        let applyPatch = EditDiff.fromPatch(patch)
        XCTAssertEqual(applyPatch.kind, .applyPatch)
        XCTAssertEqual(applyPatch.filePath, "Sources/App.swift")
        XCTAssertEqual(applyPatch.additions, 2)
        XCTAssertEqual(applyPatch.deletions, 1)
    }

    func test_editDiffCapsLargePreview() {
        let large = String(repeating: "x", count: EditDiff.previewCharacterLimit + 10)
        let diff = EditDiff.fromClaudeInput([
            "file_path": "/repo/Large.swift",
            "content": large
        ], toolName: "Write")

        XCTAssertEqual(diff?.preview?.count, EditDiff.previewCharacterLimit)
        XCTAssertEqual(diff?.isTruncated, true)
    }

    func test_bashResultMapsKnownFieldsAndCapsOutput() {
        let output = String(repeating: "o", count: BashResult.outputCharacterLimit + 3)
        let result = BashResult.fromOutputEnvelope([
            "command": "npm test",
            "exit_code": 1,
            "cwd": "/repo",
            "duration_ms": 1200,
            "stdout": output,
            "stderr": "failed"
        ])

        XCTAssertEqual(result.command, "npm test")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.cwd, "/repo")
        XCTAssertEqual(result.durationMS, 1200)
        XCTAssertEqual(result.stdout?.count, BashResult.outputCharacterLimit)
        XCTAssertEqual(result.stderr, "failed")
        XCTAssertTrue(result.isTruncated)
    }

    func test_chatMessageBackwardsDecodesWithoutStructuredPayloads() throws {
        let raw = """
        {
          "id": "m1",
          "kind": "toolCall",
          "title": "Bash",
          "body": "git status",
          "at": "2026-05-24T00:00:00Z",
          "isError": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ChatMessage.self, from: Data(raw.utf8))

        XCTAssertEqual(message.title, "Bash")
        XCTAssertNil(message.editDiff)
        XCTAssertNil(message.bashResult)
    }

    func test_chatMessageRoundTripsStructuredPayloads() throws {
        let message = ChatMessage(
            id: "m2",
            kind: .toolResult,
            title: "Bash",
            body: "done",
            at: Date(timeIntervalSince1970: 0),
            editDiff: EditDiff(kind: .applyPatch, filePath: "App.swift", additions: 1, deletions: 0),
            bashResult: BashResult(command: "git status", exitCode: 0, stdout: "clean")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ChatMessage.self, from: encoder.encode(message))

        XCTAssertEqual(decoded.editDiff?.filePath, "App.swift")
        XCTAssertEqual(decoded.bashResult?.command, "git status")
        XCTAssertEqual(decoded.bashResult?.exitCode, 0)
    }
}
