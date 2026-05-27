import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class SessionChatStoreMarkdownArtifactTests: XCTestCase {

    func test_incrementalIngestAndRetainedRebuildDedupeMarkdownArtifacts() async throws {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.start()
        defer { store.stop() }

        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        var messages: [ChatMessage] = []
        for index in 0..<197 {
            messages.append(ChatMessage(
                id: "user-\(index)",
                kind: .userText,
                title: "You",
                body: "message \(index)",
                at: base.addingTimeInterval(TimeInterval(index))
            ))
        }
        messages.append(ChatMessage(
            id: "call:typed-md",
            kind: .toolCall,
            title: "write_file",
            body: "/tmp/report.md",
            at: base.addingTimeInterval(197),
            generatedArtifacts: [
                GeneratedArtifact(kind: .markdownDocument, path: "/tmp/report.md", sourceToolName: "write_file")
            ]
        ))
        messages.append(ChatMessage(
            id: "call:legacy-md",
            kind: .toolCall,
            title: "write_file",
            body: "Created /tmp/report.md",
            at: base.addingTimeInterval(198)
        ))
        messages.append(ChatMessage(
            id: "call:no-extension-md",
            kind: .toolCall,
            title: "save_file",
            body: "/tmp/agent-report",
            at: base.addingTimeInterval(199),
            generatedArtifacts: [
                GeneratedArtifact(kind: .markdownDocument, path: "/tmp/agent-report", sourceToolName: "save_file")
            ]
        ))
        messages.append(ChatMessage(
            id: "user-tail",
            kind: .userText,
            title: "You",
            body: "tail",
            at: base.addingTimeInterval(200)
        ))

        store.appendSDKMessages(messages, at: base, suppressMirror: true)
        await waitForStoreCommit {
            store.messagesSlice.messages.count == 200
                && store.messagesSlice.artifactEntries.count == 2
        }

        XCTAssertEqual(store.messagesSlice.messages.count, 200)
        XCTAssertEqual(store.messagesSlice.artifactEntries.map(\.path), [
            "/tmp/report.md",
            "/tmp/agent-report"
        ])
    }

    private func waitForStoreCommit(predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for SessionChatStore artifact commit")
    }
}
