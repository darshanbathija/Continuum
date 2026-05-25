import XCTest
@testable import Clawdmeter

final class DiagnosticsSupportBundleTests: XCTestCase {
    func test_auditRedactorStripsPlaintextPromptFields() {
        let raw = #"{"kind":"send","text":"please fix /Users/darshanbathija_1/project/App.swift","body":"full transcript body","token":"sk-secret"}"#

        let redacted = SupportBundleWriter.redactAuditText(raw)

        XCTAssertFalse(redacted.contains("please fix"))
        XCTAssertFalse(redacted.contains("full transcript body"))
        XCTAssertFalse(redacted.contains("sk-secret"))
        XCTAssertTrue(redacted.contains(#""text":"<redacted-content>""#))
        XCTAssertTrue(redacted.contains(#""body":"<redacted-content>""#))
        XCTAssertTrue(redacted.contains(#""token":"<redacted>""#))
    }

    func test_supportBundleRedactsVisibleDiagnosticsPayloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audit = root.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
        try #"{"kind":"send","text":"do not leak this prompt","authorization":"Bearer sk-secret"}"#
            .write(to: audit.appendingPathComponent("sends.jsonl"), atomically: true, encoding: .utf8)

        let bundle = try SupportBundleWriter.create(
            auditFolderURL: audit,
            wireEntries: [
                #"{"path":"/chat","body":"visible transcript body","message":"private reply"}"#
            ],
            outputRoot: root
        )

        let visible = try String(contentsOf: bundle.appendingPathComponent("visible-diagnostics.jsonl"), encoding: .utf8)
        let redactedAudit = try String(contentsOf: bundle.appendingPathComponent("audit-redacted/sends.jsonl"), encoding: .utf8)

        XCTAssertFalse(visible.contains("visible transcript body"))
        XCTAssertFalse(visible.contains("private reply"))
        XCTAssertFalse(redactedAudit.contains("do not leak this prompt"))
        XCTAssertFalse(redactedAudit.contains("sk-secret"))
        XCTAssertTrue(visible.contains(#""body":"<redacted-content>""#))
        XCTAssertTrue(visible.contains(#""message":"<redacted-content>""#))
    }
}
