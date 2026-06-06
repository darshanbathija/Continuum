import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// LIVE end-to-end drive verification for every non-Claude harness connector.
///
/// These hit the REAL, authenticated provider CLIs and burn provider quota, so
/// they are GATED behind both `CLAWDMETER_LIVE_VERIFY=1` and an explicit
/// `~/.continuum-live-verify` marker, then auto-skip when the provider's
/// binary / project isn't available. Each test drives the exact production path
/// the daemon uses (`AcpHarnessBridge` factory → `start` → `prompt`) and
/// asserts a real assistant reply reaches the `SessionChatStore` and the turn
/// completes.
///
/// Run:
///   CLAWDMETER_LIVE_VERIFY=1 xcodebuild test \
///     -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" \
///     -destination 'platform=macOS' \
///     -only-testing:ClawdmeterMacTests/LiveDriveTests
@MainActor
final class LiveDriveTests: XCTestCase {

    private var stores: [SessionChatStore] = []
    private var cwd: String = "/tmp"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CLAWDMETER_LIVE_VERIFY"] == "1" else {
            throw XCTSkip("Set CLAWDMETER_LIVE_VERIFY=1 and create ~/.continuum-live-verify to run live provider drives (uses real CLIs + quota).")
        }
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".continuum-live-verify")
        guard FileManager.default.fileExists(atPath: marker) else {
            throw XCTSkip("Create ~/.continuum-live-verify after setting CLAWDMETER_LIVE_VERIFY=1 to run live provider drives (uses real CLIs + quota).")
        }
        // A throwaway git repo as the agent cwd (agents expect a workspace root).
        let dir = NSTemporaryDirectory() + "continuum-live-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init", "-q", dir]; try? p.run(); p.waitUntilExit()
        cwd = dir
    }

    override func tearDown() async throws {
        for s in stores { s.stop() }
        stores.removeAll()
    }

    // Poll a predicate until true or timeout.
    private func waitUntil(_ timeout: TimeInterval = 90, _ pred: @MainActor @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await pred() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func makeStore() -> SessionChatStore {
        let s = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        s.start()
        stores.append(s)
        return s
    }

    /// Shared assertion: after start+prompt, an assistant text row appears and
    /// the turn reaches a terminal state. Returns the assistant body for logging.
    private func driveAndAssert(_ bridge: AcpHarnessBridge, store: SessionChatStore,
                                binary: String?, arguments: [String], provider: String) async throws {
        // Children REPLACE their environment, so pass the full inherited env
        // (PATH/HOME) like the daemon does — plus the common install dirs so the
        // CLIs resolve their own deps under the test runner's minimal PATH.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extra)" }) ?? extra
        if env["HOME"] == nil { env["HOME"] = home }
        try await bridge.start(binary: binary, arguments: arguments, cwd: cwd,
                               env: env, effort: nil, alwaysApprove: true)
        await bridge.prompt("Reply with the single word PONG and nothing else.")
        // Require the literal PONG in an assistant row — a driver/transport error
        // (e.g. gRPC "StartCascade: unavailable") would surface as an .error event
        // or a non-PONG body, and must NOT be mistaken for a real reply.
        let gotReply = await waitUntil {
            store.messages.contains { $0.kind == .assistantText && ($0.body ?? "").uppercased().contains("PONG") }
        }
        let body = store.messages.last { $0.kind == .assistantText }?.body ?? "<none>"
        let turnDone = await waitUntil(30) {
            let t = store.snapshot.currentTurnState
            return t == .completed || t == .interrupted
        }
        await bridge.teardown()
        XCTAssertTrue(gotReply, "[\(provider)] expected a non-empty assistant reply; got: \(body)")
        XCTAssertTrue(turnDone, "[\(provider)] turn never reached a terminal state")
        print("✅ LIVE \(provider) replied: \(body.prefix(120))")
    }

    // MARK: - Grok (headless one-shot driver)

    func testGrokLiveDrive() async throws {
        guard let grok = ShellRunner.locateBinary("grok") else { throw XCTSkip("grok not on PATH") }
        let store = makeStore()
        let bridge = AcpHarnessBridge.transportOwning(
            sessionId: UUID(), store: store, model: nil, agentDisplayName: "Grok",
            driver: GrokHeadlessDriver(binaryPath: grok))
        try await driveAndAssert(bridge, store: store, binary: nil, arguments: [], provider: "Grok")
    }

    // MARK: - Cursor (true ACP: cursor-agent acp)

    func testCursorLiveDrive() async throws {
        guard ShellRunner.locateBinary("cursor-agent") != nil || ShellRunner.locateBinary("agent") != nil else {
            throw XCTSkip("cursor-agent not on PATH")
        }
        let support = CursorAcpSupport()
        let store = makeStore()
        let bridge = AcpHarnessBridge.acp(
            sessionId: UUID(), support: support, store: store, model: nil, agentDisplayName: "Cursor")
        try await driveAndAssert(bridge, store: store,
                                 binary: (AgentSpawner.cursorBinaryPath() ?? support.binaryName),
                                 arguments: support.spawnArgv(model: nil, effort: nil, alwaysApprove: true),
                                 provider: "Cursor")
    }

    // MARK: - Codex (codex app-server JSON-RPC)

    func testCodexLiveDrive() async throws {
        guard ShellRunner.locateBinary("codex") != nil else { throw XCTSkip("codex not on PATH") }
        let store = makeStore()
        let bridge = AcpHarnessBridge.codexAppServer(
            sessionId: UUID(), store: store, model: nil, agentDisplayName: "Codex")
        try await driveAndAssert(bridge, store: store,
                                 binary: (ShellRunner.locateBinary("codex") ?? "codex"), arguments: ["app-server"], provider: "Codex")
    }

    // MARK: - Antigravity / Gemini (headless `agy` CLI — Antigravity 2.0)

    /// Drives the DEFAULT production Gemini path: the headless `agy` CLI. No
    /// desktop app, no gRPC. The legacy Cascade gRPC driver is the opt-in
    /// fallback (`antigravity.grpc.enabled`) and is intentionally NOT exercised
    /// here — it requires Antigravity 2 running and a provisional proto handshake.
    func testAntigravityLiveDrive() async throws {
        guard let agy = ShellRunner.locateBinary("agy") else {
            throw XCTSkip("agy not on PATH — install Antigravity 2 (the agy CLI) first.")
        }
        let store = makeStore()
        let bridge = AcpHarnessBridge.transportOwning(
            sessionId: UUID(), store: store, model: nil, agentDisplayName: "Gemini",
            driver: AntigravityHeadlessDriver(binaryPath: agy))
        try await driveAndAssert(bridge, store: store, binary: nil, arguments: [], provider: "Gemini")
    }
}
