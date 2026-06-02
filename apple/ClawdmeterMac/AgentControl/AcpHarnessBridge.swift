import Foundation
import ClawdmeterShared

/// Owns one ACP agent session end to end on the daemon: spawns the agent as a
/// piped stdio child, runs the `AcpAgentDriver`, and projects its `HarnessEvent`
/// stream into the session's `SessionChatStore` so chat / plan / tool / turn-
/// state / permission render exactly like the tmux + SDK backends. This is the
/// daemon integration of the Phase-2 ACP core (Grok is the first agent).
@MainActor
final class AcpHarnessBridge {
    let sessionId: UUID
    private let child = AcpStdioChild()
    private let connection: NdjsonRpcConnection
    private let driver: AcpAgentDriver
    private let store: SessionChatStore
    private let model: String?
    private var projection = AcpHarnessProjection()
    /// Maps a surfaced permission prompt id back to the ACP request id so the
    /// daemon's `/permission-respond` route can answer the agent.
    private var pendingPermissionRpcIds: [String: RpcId] = [:]
    private var consumeTask: Task<Void, Never>?
    private(set) var externalSessionId: String?

    init(sessionId: UUID, support: AcpAgentSupport, store: SessionChatStore, model: String?) {
        self.sessionId = sessionId
        self.store = store
        self.model = model
        self.connection = NdjsonRpcConnection(writer: child)
        self.driver = AcpAgentDriver(
            connection: connection,
            support: support,
            clientInfo: ACPClientInfo(name: "clawdmeter", version: AcpHarnessBridge.appVersion)
        )
    }

    /// Spawn + handshake + session/new. Throws synchronously on any setup
    /// failure (two-phase contract) so the create route returns a real error.
    func start(
        binary: String,
        arguments: [String],
        cwd: String?,
        env: [String: String],
        effort: String?,
        alwaysApprove: Bool
    ) async throws {
        guard let executable = AcpStdioChild.resolve(binary) else {
            throw ACPError.startFailed("\(binary) not found on PATH. Install/sign in to \(binary) first.")
        }
        // pump child stdout -> connection; child exit -> fail in-flight requests
        let conn = connection
        await child.setOnStdout { data in await conn.feed(data) }
        await child.setOnExit { code in Task { await conn.close(code: code) } }
        do {
            try await child.launch(executable: executable, arguments: arguments, cwd: cwd, env: env)
        } catch {
            throw ACPError.startFailed("failed to launch \(binary): \(error)")
        }
        externalSessionId = try await driver.start(
            model: model, effort: effort, cwd: cwd ?? "", alwaysApprove: alwaysApprove
        )
        startConsuming()
    }

    func prompt(_ text: String) async {
        store.setCurrentTurnState(.streaming)
        await driver.prompt(text)
    }

    func cancel() async {
        await driver.cancel()
    }

    /// Answer a permission prompt the agent raised. Returns true if it matched a
    /// pending ACP request.
    @discardableResult
    func respondToPermission(promptId: String, optionId: String?) async -> Bool {
        guard let rpcId = pendingPermissionRpcIds.removeValue(forKey: promptId) else { return false }
        await driver.respondToPermission(requestId: rpcId, optionId: optionId)
        store.setPendingPermissionPrompt(nil)
        return true
    }

    func teardown() async {
        consumeTask?.cancel()
        if let text = projection.drainAssistantBuffer() { apply(.appendAssistantText(text)) }
        await child.terminate()
        await driver.close()
    }

    // MARK: event consumption

    private func startConsuming() {
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.driver.events {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: HarnessEvent) {
        // Capture the ACP request id before projecting so respond can map it.
        if case .permissionRequest(let req) = event {
            pendingPermissionRpcIds[AcpHarnessProjection.permissionPromptId(for: req.requestId)] = req.requestId
        }
        for op in projection.apply(event) { apply(op) }
    }

    private func apply(_ op: AcpStoreOp) {
        switch op {
        case .appendAssistantText(let text):
            store.appendSDKMessages([msg(.assistantText, title: "Grok", body: text)], model: model)
        case .appendToolCall(let title, let status):
            store.appendSDKMessages([msg(.toolCall, title: title, body: status)])
        case .setPlanText(let text):
            store.setPlanText(text)
        case .setTurnState(let state):
            store.setCurrentTurnState(state)
        case .setPermissionPrompt(let prompt):
            store.setPendingPermissionPrompt(prompt)
        case .appendErrorText(let text):
            store.appendSDKMessages([msg(.assistantText, title: "Grok", body: text, isError: true)])
        }
    }

    private func msg(_ kind: ChatMessage.Kind, title: String, body: String, isError: Bool = false) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, kind: kind, title: title, body: body, at: Date(), isError: isError)
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}

/// Daemon-side registry of live ACP harness bridges, keyed by Clawdmeter session
/// id. Mirrors how `OpencodeProcessManager` / `CodexSDKManager` hold their
/// per-session runtime state. Held by `AgentControlServer`.
@MainActor
final class HarnessSessionRegistry {
    private var bridges: [UUID: AcpHarnessBridge] = [:]

    func register(_ bridge: AcpHarnessBridge, for id: UUID) { bridges[id] = bridge }
    func bridge(for id: UUID) -> AcpHarnessBridge? { bridges[id] }
    func contains(_ id: UUID) -> Bool { bridges[id] != nil }

    func remove(_ id: UUID) async {
        guard let bridge = bridges.removeValue(forKey: id) else { return }
        await bridge.teardown()
    }
}
