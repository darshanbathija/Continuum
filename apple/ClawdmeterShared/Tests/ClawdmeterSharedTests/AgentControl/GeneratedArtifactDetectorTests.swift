import XCTest
@testable import ClawdmeterShared

final class GeneratedArtifactDetectorTests: XCTestCase {

    func test_claudeWriteInputExtractsMarkdownArtifact() {
        let artifacts = GeneratedArtifactDetector.artifacts(
            fromToolInput: [
                "file_path": "/tmp/review-round.md",
                "content": "# Findings"
            ],
            toolName: "Write"
        )

        XCTAssertEqual(artifacts, [
            GeneratedArtifact(kind: .markdownDocument, path: "/tmp/review-round.md", sourceToolName: "Write")
        ])
    }

    func test_codexWriteFileResponseItemPopulatesGeneratedArtifacts() {
        let json: [String: Any] = [
            "payload": [
                "type": "function_call",
                "name": "write_file",
                "arguments": ##"{"path":"/tmp/codex-output.MDOWN","content":"# Plan"}"##,
                "call_id": "fc_write",
            ],
        ]

        let messages = CodexJSONLParser.decodeResponseItem(
            json: json,
            at: Date(timeIntervalSinceReferenceDate: 0),
            idForSuffix: { _ in "fallback" }
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].generatedArtifacts, [
            GeneratedArtifact(kind: .markdownDocument, path: "/tmp/codex-output.MDOWN", sourceToolName: "write_file")
        ])
    }

    func test_applyPatchHeadersExtractMarkdownPaths() {
        let patch = """
        *** Add File: docs/launch-plan.md
        +# Launch
        *** Update File: NOTES.MARKDOWN
        +edit
        +++ b/reports/status.mdown
        --- b/old/ignore.swift
        """

        let artifacts = GeneratedArtifactDetector.artifacts(fromToolInput: patch, toolName: "apply_patch")

        XCTAssertEqual(artifacts.map(\.path), [
            "docs/launch-plan.md",
            "NOTES.MARKDOWN",
            "reports/status.mdown"
        ])
    }

    func test_genericVendorPathKeysExtractMarkdownArtifacts() {
        let artifacts = GeneratedArtifactDetector.artifacts(
            fromToolInput: [
                "files": [
                    ["targetPath": "docs/decision.markdown"],
                    ["output_path": "/tmp/vendor-report.md"],
                ]
            ],
            toolName: "create_artifact"
        )

        XCTAssertEqual(artifacts.map(\.path), [
            "docs/decision.markdown",
            "/tmp/vendor-report.md"
        ])
    }

    func test_legacyDisplayFallbackExtractsMarkdownPath() {
        let artifacts = GeneratedArtifactDetector.artifactsFromDisplay(
            title: "Write",
            body: "Created release-notes.md",
            detail: "Full output at /tmp/release-notes.md"
        )

        XCTAssertEqual(artifacts.map(\.path), [
            "release-notes.md",
            "/tmp/release-notes.md"
        ])
    }

    func test_nonMarkdownArtifactsAreRejected() {
        let writeArtifacts = GeneratedArtifactDetector.artifacts(
            fromToolInput: ["path": "/tmp/output.txt"],
            toolName: "write_file"
        )
        let patchArtifacts = GeneratedArtifactDetector.artifacts(
            fromToolInput: "*** Add File: Sources/App.swift\n+print(\"hi\")",
            toolName: "apply_patch"
        )

        XCTAssertTrue(writeArtifacts.isEmpty)
        XCTAssertTrue(patchArtifacts.isEmpty)
    }

    func test_noExtensionPathCanBeMarkedMarkdownByMetadata() {
        let artifacts = GeneratedArtifactDetector.artifacts(
            fromToolInput: [
                "path": "/tmp/agent-report",
                "metadata": [
                    "mimeType": "text/markdown"
                ]
            ],
            toolName: "save_file"
        )

        XCTAssertEqual(artifacts, [
            GeneratedArtifact(kind: .markdownDocument, path: "/tmp/agent-report", sourceToolName: "save_file")
        ])
    }

    func test_chatMessageDecodesLegacyWireWithoutArtifacts() throws {
        let json = """
        {
          "id": "call:legacy",
          "kind": "toolCall",
          "title": "Write",
          "body": "README.md",
          "at": 0
        }
        """

        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.generatedArtifacts, [])
    }

    func test_chatMessageEqualityIncludesGeneratedArtifacts() {
        let at = Date(timeIntervalSinceReferenceDate: 0)
        let base = ChatMessage(
            id: "call:same",
            kind: .toolCall,
            title: "Write",
            body: "README.md",
            at: at
        )
        let withArtifact = ChatMessage(
            id: "call:same",
            kind: .toolCall,
            title: "Write",
            body: "README.md",
            at: at,
            generatedArtifacts: [
                GeneratedArtifact(kind: .markdownDocument, path: "README.md", sourceToolName: "Write")
            ]
        )

        XCTAssertNotEqual(base, withArtifact)
        XCTAssertEqual(Set([base, withArtifact]).count, 2)
    }
}
