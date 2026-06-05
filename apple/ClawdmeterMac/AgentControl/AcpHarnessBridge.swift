import Foundation
import ClawdmeterShared

/// Owns one harness-driven agent session end to end on the daemon: runs an
/// `AgentDriver` and projects its `HarnessEvent` stream into the session's
/// `SessionChatStore` so chat / plan / tool / turn-state / permission render
/// exactly like the tmux + SDK backends. Transport is per-driver:
///   • stdio (Grok/Cursor over ACP, Codex over app-server) — the bridge owns an
///     `AcpStdioChild` + `NdjsonRpcConnection` and pumps stdout→connection;
///   • gRPC (Antigravity Cascade) — the driver owns its channel; child == nil.
/// The consume/projection/permission core is identical regardless of transport.
@MainActor
final class AcpHarnessBridge {
    let sessionId: UUID
    /// The spawned child's PID + binary name, captured at start for the orphan
    /// reaper. nil for transport-owning (gRPC) drivers — they have no child
    /// process to reap.
    private(set) var reapablePid: Int32?
    private(set) var reapableBinary: String?
    /// stdio transport (nil for drivers that own their own transport, e.g. gRPC).
    private let child: AcpStdioChild?
    private let connection: NdjsonRpcConnection?
    private let driver: any AgentDriver
    private let store: SessionChatStore
    private let model: String?
    private let usageProvider: UsageRecord.Provider?
    private let usageRepo: String?
    private let usageLedgerURL: URL?
    private let agentDisplayName: String
    private let cursorUsageSurface: CursorACPUsageLedgerRecord.Surface?
    private let cursorUsageRepo: String?
    private let cursorUsageLedgerURL: URL?
    private var projection: AcpHarnessProjection
    /// Maps a surfaced permission prompt id back to the driver's request id so the
    /// daemon's `/permission-respond` route can answer the agent.
    private var pendingPermissionRpcIds: [String: RpcId] = [:]
    private var consumeTask: Task<Void, Never>?
    private(set) var externalSessionId: String?
    private var usageSequence: UInt64 = 0
    private var lastUsageUpdate: HarnessUsage?

    /// Designated init — an already-constructed driver + its optional stdio
    /// transport. Use the static factories below rather than calling this
    /// directly so transport wiring stays consistent per driver kind.
    init(
        sessionId: UUID,
        store: SessionChatStore,
        model: String?,
        agentDisplayName: String,
        driver: any AgentDriver,
        child: AcpStdioChild?,
        connection: NdjsonRpcConnection?,
        usageProvider: UsageRecord.Provider? = nil,
        usageRepo: String? = nil,
        usageLedgerURL: URL? = nil,
        cursorUsageSurface: CursorACPUsageLedgerRecord.Surface? = nil,
        cursorUsageRepo: String? = nil,
        cursorUsageLedgerURL: URL? = nil
    ) {
        self.sessionId = sessionId
        self.store = store
        self.model = model
        self.usageProvider = usageProvider
        self.usageRepo = usageRepo
        self.usageLedgerURL = usageLedgerURL
        self.agentDisplayName = agentDisplayName
        self.cursorUsageSurface = cursorUsageSurface
        self.cursorUsageRepo = cursorUsageRepo
        self.cursorUsageLedgerURL = cursorUsageLedgerURL
        self.projection = AcpHarnessProjection(agentDisplayName: agentDisplayName)
        self.driver = driver
        self.child = child
        self.connection = connection
    }

    /// ACP stdio agent (Grok, Cursor): child + NdjsonRpc + `AcpAgentDriver`.
    /// `trustGate` (non-nil only for autopilot-trusted repos) enables the agent's
    /// fs read/write capability, validated through the gate; `onFileAccess` is
    /// the daemon's audit hook.
    static func acp(
        sessionId: UUID, support: AcpAgentSupport, store: SessionChatStore,
        model: String?, agentDisplayName: String,
        trustGate: RepoTrustGate? = nil,
        onFileAccess: (@Sendable (String, String, Bool) async -> Void)? = nil,
        usageProvider: UsageRecord.Provider? = nil,
        usageRepo: String? = nil,
        usageLedgerURL: URL? = nil,
        cursorUsageSurface: CursorACPUsageLedgerRecord.Surface? = nil,
        cursorUsageRepo: String? = nil,
        cursorUsageLedgerURL: URL? = nil
    ) -> AcpHarnessBridge {
        let child = AcpStdioChild()
        let connection = NdjsonRpcConnection(writer: child)
        let driver = AcpAgentDriver(
            connection: connection, support: support,
            clientInfo: ACPClientInfo(name: "clawdmeter", version: appVersion),
            trustGate: trustGate,
            onFileAccess: onFileAccess
        )
        return AcpHarnessBridge(sessionId: sessionId, store: store, model: model,
                                agentDisplayName: agentDisplayName, driver: driver,
                                child: child, connection: connection,
                                usageProvider: usageProvider,
                                usageRepo: usageRepo,
                                usageLedgerURL: usageLedgerURL,
                                cursorUsageSurface: cursorUsageSurface,
                                cursorUsageRepo: cursorUsageRepo,
                                cursorUsageLedgerURL: cursorUsageLedgerURL)
    }

    /// Codex over `codex app-server` (stdio JSON-RPC): same stdio transport as
    /// ACP, different driver dialect.
    static func codexAppServer(
        sessionId: UUID, store: SessionChatStore, model: String?, agentDisplayName: String,
        usageProvider: UsageRecord.Provider? = nil,
        usageRepo: String? = nil,
        usageLedgerURL: URL? = nil
    ) -> AcpHarnessBridge {
        let child = AcpStdioChild()
        let connection = NdjsonRpcConnection(writer: child)
        let driver = CodexAppServerDriver(
            connection: connection,
            clientInfo: ACPClientInfo(name: "clawdmeter", version: appVersion)
        )
        return AcpHarnessBridge(sessionId: sessionId, store: store, model: model,
                                agentDisplayName: agentDisplayName, driver: driver,
                                child: child, connection: connection,
                                usageProvider: usageProvider,
                                usageRepo: usageRepo,
                                usageLedgerURL: usageLedgerURL)
    }

    /// A driver that owns its own transport (gRPC — Antigravity Cascade). No
    /// stdio child; `start(binary:)` skips the launch and just starts the driver.
    static func transportOwning(
        sessionId: UUID, store: SessionChatStore, model: String?,
        agentDisplayName: String, driver: any AgentDriver,
        usageProvider: UsageRecord.Provider? = nil,
        usageRepo: String? = nil,
        usageLedgerURL: URL? = nil
    ) -> AcpHarnessBridge {
        AcpHarnessBridge(sessionId: sessionId, store: store, model: model,
                         agentDisplayName: agentDisplayName, driver: driver,
                         child: nil, connection: nil,
                         usageProvider: usageProvider,
                         usageRepo: usageRepo,
                         usageLedgerURL: usageLedgerURL)
    }

    /// Spawn (stdio drivers) + handshake + session creation. Throws
    /// synchronously on any setup failure (two-phase contract) so the create
    /// route returns a real error. `binary`/`arguments`/`env` are ignored for
    /// transport-owning (gRPC) drivers.
    func start(
        binary: String?,
        arguments: [String],
        cwd: String?,
        env: [String: String],
        effort: String?,
        alwaysApprove: Bool
    ) async throws {
        if let child, let connection {
            guard let binary, let executable = AcpStdioChild.resolve(binary) else {
                throw ACPError.startFailed("\(binary ?? "agent") not found on PATH. Install/sign in first.")
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
            // Capture PID + binary for the orphan reaper (stdio drivers only).
            self.reapablePid = await child.pid
            self.reapableBinary = binary
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
        await child?.terminate()
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
        if case .usage(let usage) = event {
            recordHarnessUsage(usage)
        }
        if case .turnEnded = event {
            lastUsageUpdate = nil
        }
        // Capture the ACP request id before projecting so respond can map it.
        if case .permissionRequest(let req) = event {
            pendingPermissionRpcIds[AcpHarnessProjection.permissionPromptId(for: req.requestId)] = req.requestId
        }
        if case .usage(let usage) = event {
            recordCursorUsage(usage)
        }
        for op in projection.apply(event) { apply(op) }
    }

    private func recordHarnessUsage(_ usage: HarnessUsage) {
        guard usageProvider == .grok else { return }
        guard let delta = Self.ledgerDelta(for: usage, after: lastUsageUpdate) else {
            lastUsageUpdate = usage
            return
        }
        lastUsageUpdate = usage
        usageSequence &+= 1
        guard let entry = GrokUsageLedger.Entry(
            usage: delta,
            sessionId: sessionId.uuidString,
            repo: usageRepo,
            model: model,
            sequence: usageSequence
        ) else { return }
        do {
            try GrokUsageLedger.append(entry, to: usageLedgerURL)
            var userInfo: [String: Any] = [:]
            if let record = entry.usageRecord() {
                userInfo["record"] = record
            }
            NotificationCenter.default.post(name: .grokUsageRecorded, object: nil, userInfo: userInfo)
        } catch {
            // Analytics must never break chat streaming. The next harness event
            // still projects even if Application Support is temporarily unwritable.
        }
    }

    nonisolated static func ledgerDelta(for current: HarnessUsage, after previous: HarnessUsage?) -> HarnessUsage? {
        let currentEffectiveTotal = effectiveTotal(current)
        guard currentEffectiveTotal > 0 else { return nil }

        guard let previous else {
            return current
        }

        let previousEffectiveTotal = effectiveTotal(previous)
        let comparablePairs = [
            (current.inputTokens, previous.inputTokens),
            (current.outputTokens, previous.outputTokens),
            (current.totalTokens, previous.totalTokens)
        ].compactMap { current, previous -> (Int, Int)? in
            guard let current, let previous else { return nil }
            return (max(0, current), max(0, previous))
        }

        let fieldsAreMonotonic = comparablePairs.allSatisfy { current, previous in
            current >= previous
        }
        guard currentEffectiveTotal >= previousEffectiveTotal, fieldsAreMonotonic else {
            return current
        }

        let totalDelta = currentEffectiveTotal - previousEffectiveTotal
        guard totalDelta > 0 else { return nil }

        let currentInput = max(0, current.inputTokens ?? 0)
        let currentOutput = max(0, current.outputTokens ?? 0)
        let previousInput = max(0, previous.inputTokens ?? 0)
        let previousOutput = max(0, previous.outputTokens ?? 0)
        let currentSplitTotal = currentInput + currentOutput
        let previousSplitTotal = previousInput + previousOutput
        let splitMatchesEffectiveTotals =
            currentSplitTotal > 0
            && currentSplitTotal == currentEffectiveTotal
            && previousSplitTotal == previousEffectiveTotal

        if splitMatchesEffectiveTotals {
            return HarnessUsage(
                inputTokens: current.inputTokens.map { max(0, $0 - previousInput) },
                outputTokens: current.outputTokens.map { max(0, $0 - previousOutput) },
                totalTokens: totalDelta
            )
        }

        return HarnessUsage(inputTokens: totalDelta, totalTokens: totalDelta)
    }

    nonisolated private static func effectiveTotal(_ usage: HarnessUsage) -> Int {
        let input = max(0, usage.inputTokens ?? 0)
        let output = max(0, usage.outputTokens ?? 0)
        let total = max(0, usage.totalTokens ?? 0)
        return max(total, input + output)
    }

    private func recordCursorUsage(_ usage: HarnessUsage) {
        guard let cursorUsageSurface else { return }
        CursorACPUsageLedger.append(CursorACPUsageLedgerRecord(
            surface: cursorUsageSurface,
            sessionId: sessionId,
            externalSessionId: externalSessionId,
            repo: cursorUsageRepo,
            model: usage.model ?? model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            totalTokens: usage.totalTokens,
            costUSD: usage.costUSD
        ), url: cursorUsageLedgerURL)
    }

    private func apply(_ op: AcpStoreOp) {
        switch op {
        case .appendAssistantText(let text):
            store.appendSDKMessages([msg(.assistantText, title: agentDisplayName, body: text)], model: model)
        case .appendToolCall(let title, let status):
            store.appendSDKMessages([msg(.toolCall, title: title, body: status)])
        case .setPlanText(let text):
            store.setPlanText(text)
        case .setTurnState(let state):
            store.setCurrentTurnState(state)
        case .setPermissionPrompt(let prompt):
            store.setPendingPermissionPrompt(prompt)
        case .appendErrorText(let text):
            store.appendSDKMessages([msg(.assistantText, title: agentDisplayName, body: text, isError: true)])
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

    func register(_ bridge: AcpHarnessBridge, for id: UUID) {
        bridges[id] = bridge
        // Record the child PID for the orphan reaper (stdio drivers only; gRPC
        // transport-owning bridges expose no reapablePid).
        if let pid = bridge.reapablePid, let binary = bridge.reapableBinary {
            HarnessProcessReaper.shared.record(sessionId: id, pid: pid, binary: binary)
        }
    }
    func bridge(for id: UUID) -> AcpHarnessBridge? { bridges[id] }
    func contains(_ id: UUID) -> Bool { bridges[id] != nil }

    func remove(_ id: UUID) async {
        guard let bridge = bridges.removeValue(forKey: id) else { return }
        HarnessProcessReaper.shared.remove(sessionId: id)
        await bridge.teardown()
    }
}
