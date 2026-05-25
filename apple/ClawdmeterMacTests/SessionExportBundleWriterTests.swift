import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class SessionExportBundleWriterTests: XCTestCase {
    func test_exportPresentationStateIsScopedToCurrentSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        let sessionId = UUID()
        let otherSessionId = UUID()
        let session = AgentSession(
            id: sessionId,
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: "Export current session",
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastEventSeq: 1,
            runtimeCwd: repo.path
        )
        let presentation = SessionPresentationSnapshot(
            pinnedSessionIds: [sessionId, otherSessionId],
            unreadSessionIds: [sessionId, otherSessionId],
            titleOverrides: [sessionId: "Current", otherSessionId: "Other secret title"],
            mutedSessionIds: [sessionId],
            messageBookmarks: [sessionId: ["m-current"], otherSessionId: ["m-other"]],
            viewedFiles: [sessionId: [.init(path: "Sources/App.swift", contentHash: "abc")]],
            commandRecents: ["global.palette"],
            promptHistory: ["global prompt secret"],
            savedPrompts: [.init(title: "Secret saved prompt", body: "saved prompt body")],
            recentPathActions: ["/Users/example/private.swift"],
            externalToolPreferences: ["editor": "secret-editor"],
            collapsedDiffHunks: [sessionId: ["Sources/App.swift:1"], otherSessionId: ["Other.swift:2"]],
            fileReviewDispositions: [sessionId: ["Sources/App.swift": .approved], otherSessionId: ["Other.swift": .changesRequested]],
            exportedSessionURLs: ["/tmp/previous-export"]
        )

        let bundle = try SessionExportBundleWriter.export(
            session: session,
            transcriptURL: nil,
            presentation: presentation,
            outputRoot: root
        )
        let exportURL = bundle.appendingPathComponent("presentation-state.json")
        let exportData = try Data(contentsOf: exportURL)
        let exported = String(data: exportData, encoding: .utf8) ?? ""
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: exportData) as? [String: Any])
        let viewedFiles = try XCTUnwrap(json["viewedFiles"] as? [[String: Any]])

        XCTAssertEqual(json["sessionId"] as? String, sessionId.uuidString)
        XCTAssertEqual(json["bookmarks"] as? [String], ["m-current"])
        XCTAssertEqual(viewedFiles.first?["path"] as? String, "Sources/App.swift")
        XCTAssertFalse(exported.contains(otherSessionId.uuidString))
        XCTAssertFalse(exported.contains("Other secret title"))
        XCTAssertFalse(exported.contains("m-other"))
        XCTAssertFalse(exported.contains("global prompt secret"))
        XCTAssertFalse(exported.contains("Secret saved prompt"))
        XCTAssertFalse(exported.contains("saved prompt body"))
        XCTAssertFalse(exported.contains("private.swift"))
        XCTAssertFalse(exported.contains("secret-editor"))
        XCTAssertFalse(exported.contains("previous-export"))
    }
}
