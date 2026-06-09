import Foundation
import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Track A END-TO-END: boots a real AgentControlServer, points the `claude`
/// binary at a fake stub (via the clawdmeter.binaries.claude override that
/// ShellRunner.locateBinary honors), then drives a Claude chat session through
/// the REAL HTTP handlers:
/// create → send → interrupt → delete. Verifies the session routes .claudePty,
/// gets a live PTY host, the prompt reaches the child, and delete tears the
/// host down. Deterministic — no real `claude`, no login, no network.
@MainActor
final class ClaudePtyE2ETests: XCTestCase {
    private var tempDir: URL!
    private var server: AgentControlServer!
    private var registry: AgentSessionRegistry!
    private var stubPath: String!
    private var savedBinaryOverride: Any?

    private struct RawResponse { let status: Int; let data: Data }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdmeter-pty-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ChatCwdManager.setChatSessionsRootOverrideForTesting(
            tempDir.appendingPathComponent("chat-sessions", isDirectory: true)
        )
        ChatCwdManager.setClaudeConfigURLOverrideForTesting(
            tempDir.appendingPathComponent("claude.json")
        )

        // Fake `claude`: prints a ready marker, echoes each input line, exits on QUIT.
        stubPath = tempDir.appendingPathComponent("claude").path
        let script = """
        #!/bin/sh
        echo "READY_MARKER"
        while IFS= read -r line; do
          echo "GOT:$line"
          case "$line" in *QUIT*) exit 0;; esac
        done
        """
        try script.write(toFile: stubPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)

        // Point the daemon's real spawn plan at the stub.
        savedBinaryOverride = UserDefaults.standard.object(forKey: "clawdmeter.binaries.claude")
        UserDefaults.standard.set(stubPath, forKey: "clawdmeter.binaries.claude")

        let sessionsURL = tempDir.appendingPathComponent("sessions.json")
        registry = AgentSessionRegistry(storeURL: sessionsURL)
        let resolver = SessionFileResolver(
            codexSessionsRoot: tempDir.appendingPathComponent("codex", isDirectory: true),
            geminiTmpRoot: tempDir.appendingPathComponent("gemini", isDirectory: true),
            resolveClaudeURL: { _ in nil }
        )
        let portBase = UInt16(Int.random(in: 30_000...60_000))
        server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: registry,
            notifications: NotificationDispatcher(),
            chatStoreRegistry: DaemonChatStoreRegistry(resolveURL: { _, _ in nil }),
            chatFileResolver: resolver,
            workspaceStore: WorkspaceStore(
                storeURL: tempDir.appendingPathComponent("workspaces.json"),
                sessionsURL: sessionsURL
            ),
            mobileCommandOutbox: MobileCommandOutbox(replaysAuditLogOnStart: false),
            listenPortRange: portBase...(portBase + 20),
            writesServerMetadata: false
        )
        server.start()
        XCTAssertNotNil(server.boundPort, "test server must bind a port")
    }

    override func tearDown() async throws {
        // Tear down any live host for cleanliness across the shared registry.
        for s in registry?.sessions ?? [] { await ClaudePtyRegistry.shared.suspend(s.id) }
        server?.stop()
        server = nil
        await registry?.closeEventStoreForTesting()
        registry = nil
        ChatCwdManager.setChatSessionsRootOverrideForTesting(nil)
        ChatCwdManager.setClaudeConfigURLOverrideForTesting(nil)
        if let savedBinaryOverride { UserDefaults.standard.set(savedBinaryOverride, forKey: "clawdmeter.binaries.claude") }
        else { UserDefaults.standard.removeObject(forKey: "clawdmeter.binaries.claude") }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - request helpers

    private func request(_ path: String, method: String, body: Data? = nil) async throws -> RawResponse {
        let port = try XCTUnwrap(server.boundPort)
        var req = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        req.httpMethod = method
        req.timeoutInterval = 12
        req.setValue("Bearer \(server.localLoopbackToken)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for attempt in 0..<25 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                return RawResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, data: data)
            } catch {
                if attempt == 24 { throw error }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private func waitUntil(_ timeout: TimeInterval = 6, _ cond: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return await cond()
    }

    // MARK: - the E2E

    func test_e2e_claudeChat_create_send_interrupt_delete_overPTY() async throws {
        // 1. CREATE via the real handler.
        let createBody = try JSONEncoder().encode(
            CreateChatSessionRequest(provider: .claude, model: "claude-opus-4-8")
        )
        let create = try await request("/chat-sessions", method: "POST", body: createBody)
        XCTAssertEqual(create.status, 200, "chat create should succeed; body=\(String(decoding: create.data, as: UTF8.self))")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: create.data)
        XCTAssertEqual(session.agent, .claude)
        XCTAssertEqual(session.kind, .chat)
        XCTAssertNil(session.tmuxPaneId, "PTY session must have NO tmux pane")
        XCTAssertNil(session.tmuxWindowId, "PTY session must have NO tmux window")

        // 2. The daemon's own routing decision resolves to .claudePty.
        XCTAssertEqual(SessionCommandRouter.resolve(server.routeContext(for: session)), .claudePty)

        // 3. A live PTY host exists and reaches the ready marker.
        let ready = await waitUntil {
            guard let host = await ClaudePtyRegistry.shared.host(for: session.id) else { return false }
            return await host.recentOutput().contains("READY_MARKER")
        }
        XCTAssertTrue(ready, "PTY host should spawn the (fake) claude and reach READY")

        // 4. SEND via the real handler → the prompt reaches the child.
        let sendBody = try JSONEncoder().encode(
            SendPromptRequest(
                text: "hello-e2e-xyz",
                asFollowUp: false,
                idempotencyKey: UUID().uuidString,
                origin: .userComposer
            )
        )
        let send = try await request("/sessions/\(session.id.uuidString)/send", method: "POST", body: sendBody)
        XCTAssertEqual(send.status, 200, "send should succeed; body=\(String(decoding: send.data, as: UTF8.self))")
        let echoed = await waitUntil {
            guard let host = await ClaudePtyRegistry.shared.host(for: session.id) else { return false }
            return await host.recentOutput().contains("hello-e2e-xyz")
        }
        XCTAssertTrue(echoed, "submitted prompt must reach the PTY child")

        // 5. INTERRUPT via the real handler (writes ESC; host stays live).
        let interrupt = try await request("/sessions/\(session.id.uuidString)/interrupt", method: "POST", body: Data("{}".utf8))
        XCTAssertEqual(interrupt.status, 200, "interrupt should succeed for a PTY session")

        // 6. DELETE via the real handler → the host is torn down.
        let del = try await request("/sessions/\(session.id.uuidString)", method: "DELETE")
        XCTAssertTrue(del.status == 200 || del.status == 204, "delete should succeed; status=\(del.status)")
        let gone = await waitUntil { await ClaudePtyRegistry.shared.host(for: session.id) == nil }
        XCTAssertTrue(gone, "delete must suspend the PTY host")
    }
}
