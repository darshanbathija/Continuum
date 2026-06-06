import Foundation
import Network
import ClawdmeterShared

@MainActor
extension AgentControlServer {
// MARK: - v0.8 Chat tab (wire v9)

private struct ResolvedChatRuntimeMetadata {
    let vendor: ChatVendor
    let billingProvider: String?
}

private enum ChatRuntimeValidationError: Error {
    case unknownProvider(AgentKind)
    case vendorProviderMismatch(provider: AgentKind, vendor: ChatVendor)
    case billingProviderMismatch(vendor: ChatVendor, expected: String?, actual: String)
}

private func resolveChatRuntimeMetadata(
    provider: AgentKind,
    requestedVendor: ChatVendor?,
    requestedBillingProvider: String?
) throws -> ResolvedChatRuntimeMetadata {
    guard let vendor = requestedVendor ?? ChatVendor.migrated(from: provider) else {
        throw ChatRuntimeValidationError.unknownProvider(provider)
    }
    guard vendor.backingProvider == provider else {
        throw ChatRuntimeValidationError.vendorProviderMismatch(provider: provider, vendor: vendor)
    }

    let normalizedBilling = requestedBillingProvider?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let requestedBilling = (normalizedBilling?.isEmpty == false) ? normalizedBilling : nil
    let expectedBilling = canonicalBillingProvider(for: vendor)
    if let requestedBilling, requestedBilling != expectedBilling {
        throw ChatRuntimeValidationError.billingProviderMismatch(
            vendor: vendor,
            expected: expectedBilling,
            actual: requestedBilling
        )
    }

    return ResolvedChatRuntimeMetadata(
        vendor: vendor,
        billingProvider: expectedBilling
    )
}

private func canonicalBillingProvider(for vendor: ChatVendor) -> String? {
    if let explicit = vendor.billingProvider {
        return explicit
    }
    switch vendor.backingProvider {
    case .claude: return "claude"
    case .codex: return "codex"
    case .gemini: return "antigravity"
    case .cursor: return "cursor"
    case .opencode: return "opencode"
    case .grok: return "grok"
    case .unknown: return nil
    }
}

private func sendChatRuntimeValidationError(
    _ error: ChatRuntimeValidationError,
    on connection: NWConnection
) {
    var body: [String: Any] = ["error": "invalid_chat_runtime_metadata"]
    switch error {
    case .unknownProvider(let provider):
        body["provider"] = provider.rawValue
        body["reason"] = "provider has no chat vendor mapping"
    case .vendorProviderMismatch(let provider, let vendor):
        body["provider"] = provider.rawValue
        body["chatVendor"] = vendor.rawValue
        body["expectedProvider"] = vendor.backingProvider.rawValue
        body["reason"] = "chatVendor does not match provider"
    case .billingProviderMismatch(let vendor, let expected, let actual):
        body["chatVendor"] = vendor.rawValue
        body["billingProvider"] = actual
        if let expected {
            body["expectedBillingProvider"] = expected
        } else {
            body["expectedBillingProvider"] = NSNull()
        }
        body["reason"] = "billingProvider must be derived by the server for the selected chatVendor"
    }
    guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        sendResponse(.internalError, on: connection)
        return
    }
    sendResponse(HTTPResponse(
        status: 400,
        reason: "Bad Request",
        contentType: "application/json",
        body: data
    ), on: connection)
}

private func chatRuntimeValidationMessage(_ error: ChatRuntimeValidationError) -> String {
    switch error {
    case .unknownProvider(let provider):
        return "invalid_chat_runtime_metadata: provider \(provider.rawValue) has no chat vendor mapping"
    case .vendorProviderMismatch(let provider, let vendor):
        return "invalid_chat_runtime_metadata: chatVendor \(vendor.rawValue) does not match provider \(provider.rawValue)"
    case .billingProviderMismatch(let vendor, let expected, let actual):
        let expectedText = expected ?? "nil"
        return "invalid_chat_runtime_metadata: billingProvider \(actual) does not match \(expectedText) for \(vendor.rawValue)"
    }
}

private func frontierProviderUnavailableReason(provider: AgentKind) async -> String? {
    switch provider {
    case .cursor, .opencode:
        return await chatProviderUnavailableReason(provider: provider)
    default:
        return nil
    }
}

/// `POST /chat-sessions`: spawn a new chat-kind AgentSession in an
/// empty per-session chat-cwd. Forces plan-mode. Codex, Gemini, Cursor, and
/// Grok dispatch through the harness; Claude keeps tmux and OpenCode keeps SSE.
func handlePostChatSession(request: HTTPRequest, connection: NWConnection) async {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let req = try? decoder.decode(CreateChatSessionRequest.self, from: request.body) else {
        sendResponse(.badRequest, on: connection)
        return
    }
    let metadata: ResolvedChatRuntimeMetadata
    do {
        metadata = try resolveChatRuntimeMetadata(
            provider: req.provider,
            requestedVendor: req.chatVendor,
            requestedBillingProvider: req.billingProvider
        )
    } catch let error as ChatRuntimeValidationError {
        sendChatRuntimeValidationError(error, on: connection)
        return
    } catch {
        sendResponse(.badRequest, on: connection)
        return
    }
    if let reason = providerDisabledReason(provider: req.provider, vendor: metadata.vendor) {
        sendProviderDisabled(provider: req.provider, reason: reason, on: connection)
        return
    }
    // Harness is the Chat drive path for Codex, Gemini, Grok, and Cursor: a
    // chat session created here gets a live AcpHarnessBridge, and the
    // send/interrupt/permission handlers route through
    // SessionCommandRouter.harnessBridge.
    if req.provider == .codex {
        await handleCreateHarnessChatSession(req: req, metadata: metadata, connection: connection)
        return
    }
    if req.provider == .grok {
        // Grok chat drives over ACP via the harness — Grok has no legacy chat
        // path (it was Sessions/Code-only before), so it always uses the harness.
        await handleCreateHarnessChatSession(req: req, metadata: metadata, connection: connection)
        return
    }
    if req.provider == .gemini {
        // Gemini chat always drives through the harness — the headless `agy`
        // CLI. The legacy agentapi one-shot + Cascade gRPC chat paths are gone.
        await handleCreateHarnessChatSession(req: req, metadata: metadata, connection: connection)
        return
    }
    if req.provider == .opencode {
        await handlePostOpencodeChatSession(request: req, metadata: metadata, connection: connection)
        return
    }
    if req.provider == .cursor {
        if let reason = await chatProviderUnavailableReason(provider: .cursor) {
            sendChatProviderUnavailable(provider: .cursor, reason: reason, on: connection)
            return
        }
        // Cursor chat drives over ACP via the harness (the legacy tmux argv
        // path is deprecated; Phase 9 removes it).
        await handleCreateHarnessChatSession(req: req, metadata: metadata, connection: connection)
        return
    }
    // Create the session record first (assigns a UUID we can use to
    // name the chat-cwd). v0.23 (Chat V2): persist deepResearch on
    // the session so respawn/restore preserves it (Codex outside-
    // voice review P1 #6).
    let session: AgentSession
    do {
        session = try await registry.createChat(
            provider: req.provider,
            model: req.model,
            chatCwd: "",  // placeholder; we'll patch it post-cwd-creation
            codexChatBackend: nil,
            effort: req.effort,
            deepResearch: req.deepResearch,
            chatVendor: metadata.vendor,
            billingProvider: metadata.billingProvider
        )
    } catch {
        serverLogger.error("createChat write-ahead failed: \(error.localizedDescription, privacy: .public)")
        sendResponse(.internalError, on: connection); return
    }
    let chatCwd: String
    do {
        let url = try ChatCwdManager.ensure(for: session.id)
        chatCwd = url.path
    } catch {
        serverLogger.error("chat-cwd create failed for \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        try? await registry.delete(id: session.id)
        sendResponse(.internalError, on: connection)
        return
    }
    // Patch the worktreePath on the created session so effectiveCwd
    // resolves to the chat-cwd. The createChat helper stored it as
    // empty-string; rewrite via the existing update pattern.
    try? await registry.updateRuntime(
        id: session.id,
        worktreePath: chatCwd,
        tmuxWindowId: nil,
        tmuxPaneId: nil,
        mode: .local
    )
    // Spawn dispatch. Harness-backed providers returned above; this path is
    // for tmux-backed Claude chat.
    let updatedSession = registry.session(id: session.id) ?? session
    // Claude chat: pre-trust the throwaway chat-cwd so the CLI boots
    // straight to the composer instead of blocking at the first-run trust
    // dialog. Without this the warmup poll still dismisses the prompt, but
    // the ~9s it takes exceeds the mobile send timeout. (No-op for other
    // agents — they don't read ~/.claude.json.)
    if updatedSession.agent == .claude {
        ChatCwdManager.markTrustedForClaude(path: chatCwd)
    }
    let argv = AgentSpawner.argv(for: updatedSession)
    if argv.isEmpty {
        // No binary on PATH for this provider — clean up + surface 503.
        try? await registry.delete(id: session.id)
        try? ChatCwdManager.remove(for: session.id)
        sendResponse(HTTPResponse(
            status: 503, reason: "Service Unavailable",
            contentType: "application/json",
            body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
        ), on: connection)
        return
    } else if claudePtyEnabled && updatedSession.agent == .claude {
        // Track A: Claude chat over a per-session PTY (flag on). chat-cwd
        // is pre-trusted above (markTrustedForClaude), so no warmup is
        // needed; SessionChatStore resolves the JSONL by cwd (tmux-pane-
        // independent), so chat rendering is unchanged. Single-flight
        // resume-or-spawn the host; store NO tmux pane.
        guard let host = await claudePtyHost(for: updatedSession) else {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
            ), on: connection)
            return
        }
        _ = host
        try? await registry.updateRuntime(
            id: session.id,
            worktreePath: chatCwd,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            mode: .local
        )
    } else {
        // CLI chat path: spawn tmux window in the chat-cwd. v0.8 QA
        // surfaced a wedged-tmux scenario where tmux.newWindow hung
        // forever — the handler never returned, AgentSession +
        // chat-cwd were left orphaned in the registry. Use a
        // continuation-race timeout that returns even when the
        // underlying tmux await is unrecoverably stuck (Swift Task
        // cancellation is cooperative; tmux.command's
        // withCheckedThrowingContinuation never resumes on a wedged
        // PTY). The spawn task may leak if tmux stays wedged, but
        // leaking one wrapping Task is much better than leaking a
        // registry entry + chat-cwd dir + a confused user.
        let tmuxRef = self.tmux
        let spawnResult: (windowId: String, paneId: String)? = await withCheckedContinuation { (cont: CheckedContinuation<(String, String)?, Never>) in
            let resumedBox = ResumeOnceBox()
            Task {
                do {
                    try await tmuxRef.start()
                    let window = try await tmuxRef.newWindow(cwd: chatCwd, child: argv)
                    if resumedBox.tryClaim() { cont.resume(returning: (window.windowId, window.paneId)) }
                } catch {
                    if resumedBox.tryClaim() { cont.resume(returning: nil) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if resumedBox.tryClaim() { cont.resume(returning: nil) }
            }
        }
        guard let spawn = spawnResult else {
            serverLogger.error("chat spawn failed or timed out for \(session.id.uuidString, privacy: .public) — tmux unresponsive after 10s")
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(HTTPResponse(
                status: 504, reason: "Gateway Timeout",
                contentType: "application/json",
                body: Data(#"{"error":"tmux_unresponsive","hint":"Quit Clawdmeter and relaunch; if the issue persists, kill any stale tmux processes with: pkill -9 -f tmux"}"#.utf8)
            ), on: connection)
            return
        }
        try? await registry.updateRuntime(
            id: session.id,
            worktreePath: chatCwd,
            tmuxWindowId: spawn.windowId,
            tmuxPaneId: spawn.paneId,
            mode: .local
        )
        // v0.8 QA: dismiss Codex CLI's in-pane prompts (update, trust)
        // before the first send. Claude chat cwd is pre-trusted above and
        // current Claude Code remote-control composers accept normal
        // fresh-client key sends once rendered, so do not hold first-send
        // behind a Claude warmup task.
        // Runs in the background so chat-session creation returns
        // immediately — handleSendPrompt awaits the task before pasting
        // so the user's first send doesn't race the dismissal.
        if updatedSession.agent != .claude {
            let warmupSession = registry.session(id: session.id) ?? session
            let warmupPane = spawn.paneId
            let warmupTask = Task { [weak self] in
                await self?.warmupCLIPane(session: warmupSession, paneId: warmupPane)
                await MainActor.run { [weak self] in
                    self?.chatWarmupTasks[warmupSession.id] = nil
                }
            }
            chatWarmupTasks[session.id] = warmupTask
        }
    }
    AgentEventStream.recordEvent(
        sessionId: session.id, kind: .sessionCreated,
        payload: ["chat": "true", "provider": req.provider.rawValue]
    )
    let finalSession = registry.session(id: session.id) ?? session
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let body = try? encoder.encode(finalSession) {
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    } else {
        sendResponse(.internalError, on: connection)
    }
}

/// Create a Chat session driven by the harness (no tmux pane). The chat
/// send/interrupt/permission handlers already route to a live
/// `AcpHarnessBridge` (`SessionCommandRouter.harnessBridge`); this wires
/// chat-CREATE to build + register one for a non-Claude provider.
///
/// CRUCIAL: the session is created without legacy backend axes
/// (`codexChatBackend: nil`, no agentapi conversation), so the router resolves
/// `.harnessBridge` once the bridge is live. Mirrors `handleSpawnHarnessSession`
/// Steps 2-4 but over a chat session + sandbox cwd (no worktree).
/// Errors from the harness chat-session core. The Solo handler maps these to
/// HTTP responses; the Frontier per-child path maps them to a slot reason.
private enum HarnessChatSpawnError: Error {
    case createFailed(String)
    case cwdFailed(String)
    case storeAcquireFailed
    case noAntigravityProjects
    case unsupportedProvider
    case startFailed(String)

    var slotReason: String {
        switch self {
        case .createFailed(let d): return "create_failed: \(d)"
        case .cwdFailed(let d): return "chat_cwd_create_failed: \(d)"
        case .storeAcquireFailed: return "chat_store_acquire_failed"
        case .noAntigravityProjects: return "antigravity_no_projects"
        case .unsupportedProvider: return "unsupported_provider"
        case .startFailed(let d): return "acp_start_failed: \(d)"
        }
    }
}

/// Whether a provider's CHAT/FRONTIER child drives through the harness (vs a
/// legacy backend). Grok/Cursor drive ACP, Gemini drives headless `agy`, Codex
/// drives `codex app-server`, Claude drives tmux, and OpenCode drives SSE.
private func isChatHarnessEligible(_ provider: AgentKind) -> Bool {
    switch provider {
    // Codex chat now ALWAYS drives over `codex app-server` (same engine as
    // Code, readOnly+never posture) — the legacy SDK relay is removed.
    case .grok, .cursor, .gemini, .codex: return true
    default: return false
    }
}

/// Core harness chat-session creation — NO HTTP response. Builds + starts +
/// registers an AcpHarnessBridge for a non-Claude provider over a chat
/// session + sandbox cwd, returning the created AgentSession (throws
/// HarnessChatSpawnError on any failure, cleaning up partial state).
///
/// Shared by the Solo Chat create handler AND the Frontier per-child spawn.
/// The session is created without legacy backend axes (codexChatBackend nil,
/// no agentapi conversation) so SessionCommandRouter resolves `.harnessBridge`
/// once the bridge is live. frontierGroupId /
/// frontierChildIndex bind a broadcast child to its group (nil for Solo).
private func createHarnessChatSessionCore(
    provider: AgentKind,
    model: String?,
    effort: ReasoningEffort?,
    deepResearch: Bool?,
    chatVendor: ChatVendor?,
    billingProvider: String?,
    frontierGroupId: UUID? = nil,
    frontierChildIndex: Int? = nil
) async throws -> AgentSession {
        // Step 1: write-ahead the chat session. codexChatBackend stays nil so
        // SessionCommandRouter resolves `.harnessBridge` for this session.
    let session: AgentSession
    do {
        session = try await registry.createChat(
            provider: provider,
            model: model,
            chatCwd: "",  // patched after cwd creation
            codexChatBackend: nil,
            effort: effort,
            frontierGroupId: frontierGroupId,
            frontierChildIndex: frontierChildIndex,
            deepResearch: deepResearch ?? false,
            chatVendor: chatVendor,
            billingProvider: billingProvider
        )
    } catch {
        throw HarnessChatSpawnError.createFailed(error.localizedDescription)
    }
    // Step 2: per-session sandbox cwd.
    let chatCwd: String
    do {
        chatCwd = try ChatCwdManager.ensure(for: session.id).path
    } catch {
        try? await registry.delete(id: session.id)
        throw HarnessChatSpawnError.cwdFailed(error.localizedDescription)
    }
    try? await registry.updateRuntime(
        id: session.id, worktreePath: chatCwd,
        tmuxWindowId: nil, tmuxPaneId: nil, mode: .local
    )
    let staged = registry.session(id: session.id) ?? session
    // Step 3: acquire the per-session chat store the bridge projects into
    // (long-lived writer — pin against idle eviction; released on teardown).
    guard let store = chatStoreRegistry.acquire(for: staged) else {
        try? await registry.delete(id: session.id)
        try? ChatCwdManager.remove(for: session.id)
        throw HarnessChatSpawnError.storeAcquireFailed
    }
    // Step 4: build the per-provider bridge.
    let display = providerDisplayName(provider)
    let binary: String?
    let arguments: [String]
    let bridge: AcpHarnessBridge
    switch provider {
    case .codex:
        binary = ShellRunner.locateBinary("codex") ?? "codex"
        arguments = ["app-server"]
        bridge = .codexAppServer(
            sessionId: session.id, store: store,
            model: model, agentDisplayName: display
        )
    case .cursor:
        // ACP stdio agent. Chat has no repoKey → no fs trust gate; the
        // agent's fs/terminal caps stay unadvertised and it runs in the
        // per-session sandbox cwd.
        guard let support = Self.acpSupport(for: provider) else {
            chatStoreRegistry.release(sessionId: session.id)
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            throw HarnessChatSpawnError.unsupportedProvider
        }
        binary = AgentSpawner.cursorBinaryPath() ?? support.binaryName
        arguments = support.spawnArgv(model: nil, effort: nil, alwaysApprove: false)
        bridge = .acp(
            sessionId: session.id, support: support, store: store,
            model: model, agentDisplayName: display,
            trustGate: nil, onFileAccess: nil,
            cursorUsageSurface: .chat,
            cursorUsageRepo: nil
        )
    case .grok:
        // Grok has no ACP server — it drives headless. Transport-owning: the
        // GrokHeadlessDriver spawns `grok` per turn, so there's no persistent
        // stdio child (binary stays nil).
        guard let grokPath = ShellRunner.locateBinary("grok") else {
            chatStoreRegistry.release(sessionId: session.id)
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            throw HarnessChatSpawnError.startFailed("grok binary not found on PATH")
        }
        binary = nil
        arguments = []
        bridge = .transportOwning(
            sessionId: session.id, store: store,
            model: model, agentDisplayName: display,
            driver: GrokHeadlessDriver(binaryPath: grokPath),
            usageProvider: .grok,
            usageRepo: chatCwd
        )
    case .gemini:
        // Antigravity 2.0: headless `agy` CLI (no app, no gRPC). The Cascade
        // gRPC drive was removed once agy was live-verified. Transport-owning
        // (no stdio child), so binary stays nil.
        guard let agyPath = ShellRunner.locateBinary("agy") else {
            chatStoreRegistry.release(sessionId: session.id)
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            throw HarnessChatSpawnError.startFailed("agy binary not found on PATH (install Antigravity 2)")
        }
        binary = nil
        arguments = []
        bridge = .transportOwning(
            sessionId: session.id, store: store,
            model: model, agentDisplayName: display,
            driver: AntigravityHeadlessDriver(binaryPath: agyPath)
        )
    default:
        chatStoreRegistry.release(sessionId: session.id)
        try? await registry.delete(id: session.id)
        try? ChatCwdManager.remove(for: session.id)
        throw HarnessChatSpawnError.unsupportedProvider
    }
    // Step 5: start the bridge. Chat inherits the daemon env (PATH/HOME) and
    // runs in the sandbox cwd.
    let childEnv = ProcessInfo.processInfo.environment
    do {
        try await bridge.start(
            binary: binary, arguments: arguments,
            cwd: chatCwd, env: childEnv, effort: nil, alwaysApprove: false
        )
    } catch {
        await bridge.teardown()
        chatStoreRegistry.release(sessionId: session.id)
        try? await registry.delete(id: session.id)
        try? ChatCwdManager.remove(for: session.id)
        throw HarnessChatSpawnError.startFailed(error.localizedDescription)
    }
    // Step 6: register the live bridge + return.
    harnessRegistry.register(bridge, for: session.id)
    AgentEventStream.recordEvent(
        sessionId: session.id, kind: .sessionCreated,
        payload: ["chat": "true", "provider": provider.rawValue, "harness": "true",
                  "frontier": frontierGroupId != nil ? "true" : "false"]
    )
    return registry.session(id: session.id) ?? staged
}

/// Solo Chat-tab create over the harness — thin wrapper over the core that
/// maps spawn errors to HTTP responses.
private func handleCreateHarnessChatSession(
    req: CreateChatSessionRequest,
    metadata: ResolvedChatRuntimeMetadata,
    connection: NWConnection
) async {
    do {
        let session = try await createHarnessChatSessionCore(
            provider: req.provider, model: req.model, effort: req.effort,
            deepResearch: req.deepResearch, chatVendor: metadata.vendor,
            billingProvider: metadata.billingProvider
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    } catch HarnessChatSpawnError.noAntigravityProjects {
        sendResponse(HTTPResponse(
            status: 503, reason: "Service Unavailable", contentType: "application/json",
            body: Data(#"{"error":"antigravity_no_projects","cta":"Open any repo in Antigravity 2 first."}"#.utf8)
        ), on: connection)
    } catch let HarnessChatSpawnError.startFailed(detail) {
        let payload = ["error": "acp_start_failed", "detail": detail]
        let body = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"error":"acp_start_failed"}"#.utf8)
        sendResponse(HTTPResponse(status: 503, reason: "Service Unavailable",
                                  contentType: "application/json", body: body), on: connection)
    } catch {
        serverLogger.error("harness chat create failed: \(String(describing: error), privacy: .public)")
        sendResponse(.internalError, on: connection)
    }
}

private func handlePostOpencodeChatSession(
    request req: CreateChatSessionRequest,
    metadata: ResolvedChatRuntimeMetadata,
    connection: NWConnection
) async {
    if let reason = await chatProviderUnavailableReason(provider: .opencode) {
        sendChatProviderUnavailable(provider: .opencode, reason: reason, on: connection)
        return
    }
    guard let _ = await OpencodeProcessManager.shared.ensureRunning() else {
        let body: String
        switch OpencodeProcessManager.shared.state {
        case .notInstalled:
            body = #"{"error":"opencode_not_installed","hint":"Install OpenCode, then add an OpenRouter key in Settings."}"#
        case .failed(let detail):
            body = #"{"error":"opencode_serve_failed","detail":"\#(detail)"}"#
        default:
            body = #"{"error":"opencode_not_running"}"#
        }
        sendResponse(HTTPResponse(
            status: 503, reason: "Service Unavailable",
            contentType: "application/json",
            body: Data(body.utf8)
        ), on: connection)
        return
    }

    OpencodeSSEAdapter.shared.start()
    if OpencodeSSEAdapter.shared.chatStoreAccessor == nil {
        let registry = self.registry
        let chatStoreRegistry = self.chatStoreRegistry
        OpencodeSSEAdapter.shared.chatStoreAccessor = { [weak registry, weak chatStoreRegistry] uuid in
            guard let registry, let chatStoreRegistry else { return nil }
            guard let session = registry.session(id: uuid) else { return nil }
            return chatStoreRegistry.acquire(for: session)
        }
    }

    let vendor = metadata.vendor
    let session: AgentSession
    do {
        session = try await registry.createChat(
            provider: .opencode,
            model: req.model,
            chatCwd: "",
            effort: req.effort,
            deepResearch: req.deepResearch,
            chatVendor: vendor,
            billingProvider: metadata.billingProvider
        )
    } catch {
        serverLogger.error("createChat write-ahead failed: \(error.localizedDescription, privacy: .public)")
        sendResponse(.internalError, on: connection); return
    }
    let chatCwd: String
    do {
        let url = try ChatCwdManager.ensure(for: session.id)
        chatCwd = url.path
    } catch {
        try? await registry.delete(id: session.id)
        sendResponse(.internalError, on: connection)
        return
    }
    try? await registry.updateRuntime(
        id: session.id,
        worktreePath: chatCwd,
        runtimeCwd: .some(chatCwd),
        tmuxWindowId: nil,
        tmuxPaneId: nil,
        mode: .local
    )

    guard var sessionReq = await OpencodeProcessManager.shared.makeAuthorizedRequest(
        path: "/session",
        directory: chatCwd
    ) else {
        try? await registry.delete(id: session.id)
        try? ChatCwdManager.remove(for: session.id)
        sendResponse(.internalError, on: connection)
        return
    }
    sessionReq.httpMethod = "POST"
    sessionReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let title = req.model.map { "\(vendor.displayName) - \($0)" } ?? "Chat - \(vendor.displayName)"
    sessionReq.httpBody = try? JSONSerialization.data(withJSONObject: [
        "title": String(title.prefix(60))
    ])

    let opencodeID: String
    do {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: sessionReq)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(.internalError, on: connection)
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(.internalError, on: connection)
            return
        }
        opencodeID = id
    } catch {
        serverLogger.error("opencode chat /session POST failed: \(error.localizedDescription, privacy: .public)")
        try? await registry.delete(id: session.id)
        try? ChatCwdManager.remove(for: session.id)
        sendResponse(.internalError, on: connection)
        return
    }

    let updated = registry.session(id: session.id) ?? session
    OpencodeSSEAdapter.shared.register(
        clawdmeterID: updated.id,
        opencodeID: opencodeID,
        repo: chatCwd
    )
    _ = chatStoreRegistry.snapshotStore(for: updated)
    AgentEventStream.recordEvent(
        sessionId: updated.id,
        kind: .sessionCreated,
        payload: [
            "chat": "true",
            "provider": "opencode",
            "chatVendor": vendor.rawValue,
            "opencodeID": opencodeID
        ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let body = try? encoder.encode(updated) {
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    } else {
        sendResponse(.internalError, on: connection)
    }
}

private func chatProviderUnavailableReason(provider: AgentKind) async -> String? {
    if provider == .cursor {
        let cursorState = await CursorModelProbe.shared.currentState()
        guard cursorState.binaryPath != nil else {
            return cursorState.reason ?? "Cursor Agent CLI not found or failed identity check"
        }
        guard cursorState.authenticated else {
            return cursorState.reason ?? "Run cursor-agent login, then try again."
        }
        return nil
    }
    let response = await ChatProviderProbe.shared.currentProviders()
    let row = response.providers.first {
        $0.provider == provider
    }
    guard let row else {
        return "Provider probe did not return \(provider.rawValue)"
    }
    guard row.available, row.authenticated, row.capabilityProbePassed else {
        return row.reason ?? "\(provider.rawValue) is unavailable"
    }
    return nil
}

func providerDisabledReason(provider: AgentKind, vendor: ChatVendor? = nil) -> String? {
    guard ProviderEnablement.isEnabled(provider) else {
        return "Enable \(vendor?.displayName ?? providerDisplayName(provider)) in Settings → Providers."
    }
    return nil
}

func providerDisplayName(_ provider: AgentKind) -> String {
    switch provider {
    case .claude: return "Claude"
    case .codex: return "ChatGPT"
    case .gemini: return "Antigravity"
    case .cursor: return "Cursor"
    case .opencode: return "OpenRouter"
    case .grok: return "Grok"
    case .unknown: return "this provider"
    }
}

func sendProviderDisabled(provider: AgentKind, reason: String, on connection: NWConnection) {
    let body = [
        "error": "provider_disabled",
        "provider": provider.rawValue,
        "reason": reason,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        sendResponse(.internalError, on: connection)
        return
    }
    sendResponse(HTTPResponse(
        status: 403,
        reason: "Forbidden",
        contentType: "application/json",
        body: data
    ), on: connection)
}

private func sendChatProviderUnavailable(provider: AgentKind, reason: String, on connection: NWConnection) {
    let body = [
        "error": "chat_provider_unavailable",
        "provider": provider.rawValue,
        "reason": reason,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        sendResponse(.internalError, on: connection)
        return
    }
    sendResponse(HTTPResponse(
        status: 503,
        reason: "Service Unavailable",
        contentType: "application/json",
        body: data
    ), on: connection)
}

/// `GET /chat-providers`: returns the per-provider availability +
/// auth + capability-probe state per DG4. v0.8 ships a minimal
/// implementation that checks binary-on-PATH; the full P1-actor
/// ChatProviderProbe + CM3 ChatProviderAuthObserver land in v0.8.x
/// polish phase. Gemini row is hardcoded `available: false, reason:
/// "v0.9"` until Antigravity (agy) replacement ships.
func handleGetChatProviders(connection: NWConnection) async {
    // v0.9.x: delegate to the ChatProviderProbe actor. Cache +
    // in-flight de-dup live there now; the inline binary checks
    // are gone. Auth state reflects ChatProviderAuthObserver
    // overrides (Claude/Codex stderr + JSONL parsers, Antigravity
    // agentapi 401 catch) when set.
    let resp = await ChatProviderProbe.shared.currentProviders()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let body = try? encoder.encode(resp) {
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    } else {
        sendResponse(.internalError, on: connection)
    }
}

func handleRefreshChatProviders(connection: NWConnection) async {
    await ChatProviderProbe.shared.invalidate()
    await OpenRouterModelProbe.shared.invalidate()
    await CursorModelProbe.shared.invalidate()
    await handleGetChatProviders(connection: connection)
}

/// Frontier handlers. These routes create live sibling chat sessions,
/// stream per-slot state, and persist winner choices for the comparison UI.
// MARK: - v0.9 Frontier handlers

/// POST /chat-sessions/frontier — spawn 2-3 sibling chat sessions
/// sharing a `frontierGroupId`, one per `FrontierModelSlot` in the
/// request. Returns per-slot results (E2): each spawn is independent
/// so a partial Frontier (e.g. Gemini fails because Antigravity isn't
/// running) still surfaces the live slots + the failure reason.
/// CM5: replays the cached response when `clientRequestId` repeats.
func handlePostFrontier(request: HTTPRequest, connection: NWConnection) async {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let req = try? decoder.decode(CreateFrontierRequest.self, from: request.body) else {
        sendResponse(.badRequest, on: connection); return
    }
    // CM5 idempotency: if we've seen this clientRequestId before,
    // return the cached response verbatim.
    if let cached = frontierGroupIdempotency[req.clientRequestId] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(cached.response) {
            sendResponse(HTTPResponse(
                status: 200, reason: "OK (idempotent replay)",
                contentType: "application/json", body: body
            ), on: connection)
            return
        }
    }
    // Slot count guard: 2-3 per v0.9 spec.
    guard (2...3).contains(req.models.count) else {
        sendResponse(HTTPResponse(
            status: 400, reason: "Bad Request",
            contentType: "application/json",
            body: Data(#"{"error":"frontier_slot_count","reason":"frontier requires 2-3 slots"}"#.utf8)
        ), on: connection)
        return
    }

    let groupId = UUID()
    var slotResults: [FrontierSlotResult] = []
    for (idx, slot) in req.models.enumerated() {
        // Per-child spawn timeout: a child that HANGS (a wedged tmux claude
        // pane, or a driver handshake that never completes) must not hang the
        // whole broadcast → the "request timed out" the user hits. Time the
        // slot out so the other providers still come through. Mirrors the
        // continuation-race timeout handlePostChatSession uses for tmux.
        let slotResult: FrontierSlotResult = await withCheckedContinuation { (cont: CheckedContinuation<FrontierSlotResult, Never>) in
            let box = ResumeOnceBox()
            // Hold the timeout task so the spawn path can cancel it — otherwise
            // the 25s sleep lingers (and accumulates across broadcasts) even on
            // the common success path where the spawn wins the race in ~2-5s.
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if box.tryClaim() {
                    cont.resume(returning: FrontierSlotResult(index: idx, sessionId: nil, reason: "spawn_timeout"))
                }
            }
            Task { @MainActor in
                let r: FrontierSlotResult
                do {
                    let session = try await self.spawnFrontierChild(groupId: groupId, childIndex: idx, slot: slot)
                    r = FrontierSlotResult(index: idx, sessionId: session.id, reason: nil)
                } catch let SpawnFailure.message(reason) {
                    r = FrontierSlotResult(index: idx, sessionId: nil, reason: reason)
                } catch {
                    r = FrontierSlotResult(index: idx, sessionId: nil, reason: error.localizedDescription)
                }
                if box.tryClaim() { cont.resume(returning: r) }
                timeout.cancel()   // spawn settled (or timeout already fired) — stop the sleep
            }
        }
        slotResults.append(slotResult)
    }
    let response = CreateFrontierResponse(groupId: groupId, slots: slotResults)
    // Cache for CM5 replay. Trim oldest entries when crossing 256.
    frontierGroupIdempotency[req.clientRequestId] = (groupId, response, Date())
    if frontierGroupIdempotency.count > 256 {
        let cutoff = frontierGroupIdempotency.values
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(64)
            .map { $0.groupId }
        frontierGroupIdempotency = frontierGroupIdempotency.filter {
            !cutoff.contains($0.value.groupId)
        }
    }
    frontierUpdateCounters[groupId] = 1
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    if let body = try? encoder.encode(response) {
        sendResponse(HTTPResponse(
            status: 201, reason: "Created",
            contentType: "application/json", body: body
        ), on: connection)
    } else {
        sendResponse(.internalError, on: connection)
    }
}

/// POST /chat-sessions/frontier/:groupId/send — fan out the prompt
/// to every live (non-archived) child. Each child is a regular chat
/// session so we reuse the existing /sessions/:id/send semantics by
/// dispatching to the underlying send logic per child.
///
/// v0.23.9: accepts both `FrontierSendRequest` (preferred — supports
/// per-child text overrides for broadcast attachments) and the
/// legacy `SendPromptRequest` shape for back-compat with the
/// smoke script + first iOS build.
func handleFrontierSend(
    request: HTTPRequest,
    connection: NWConnection,
    groupId: String
) async {
    guard let uuid = UUID(uuidString: groupId) else {
        sendResponse(.badRequest, on: connection); return
    }
    // Frontier sends must only hit live children. Archived siblings
    // (e.g. losers after a pick-winner) keep their JSONL for the
    // history sidebar but should never receive new prompts.
    let children = registry.frontierGroupChildren(groupId: uuid)
    guard !children.isEmpty else {
        sendResponse(.notFound, on: connection); return
    }
    let decoder = JSONDecoder()
    let frontierReq = try? decoder.decode(FrontierSendRequest.self, from: request.body)
    let legacyReq = frontierReq == nil ? try? decoder.decode(SendPromptRequest.self, from: request.body) : nil
    let sharedText: String
    let perChild: [String: String]?
    if let frontierReq {
        sharedText = frontierReq.text
        perChild = frontierReq.perChildText
    } else if let legacyReq {
        sharedText = legacyReq.text
        perChild = nil
    } else {
        sendResponse(.badRequest, on: connection); return
    }
    var results: [FrontierChildSendResult] = []
    for child in children {
        let text = perChild?[child.id.uuidString] ?? sharedText
        results.append(await forwardFrontierChildSend(session: child, text: text))
    }
    let response = FrontierSendResponse(groupId: uuid, childCount: children.count, results: results)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let body = (try? encoder.encode(response)) ?? Data("{\"ok\":false}".utf8)
    sendResponse(HTTPResponse(
        status: 202, reason: "Accepted",
        contentType: "application/json",
        body: body
    ), on: connection)
    if let counter = frontierUpdateCounters[uuid] {
        frontierUpdateCounters[uuid] = counter + 1
    }
}

/// Best-effort send to one Frontier child. Mirrors the dispatch
/// inside handleSendPrompt (agentapi vs SDK vs tmux) but does NOT
/// touch the HTTP connection — Frontier fan-out caller already
/// returned a 202. Errors are logged + dropped.
private func forwardFrontierChildSend(session: AgentSession, text: String) async -> FrontierChildSendResult {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty, bytes.count <= 1_000_000 else {
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "invalid_prompt")
    }
    // v0.23.9 adversarial-review fix: handleFrontierSend snapshots
    // the child list before iterating, then awaits per-child sends
    // serially. While we're awaiting child[i]'s tmux/SDK/agentapi
    // call, a concurrent /pick-winner can archive child[i+1] on
    // the same @MainActor registry. Re-fetch the live session
    // immediately before each send so a just-archived loser
    // doesn't still receive the prompt.
    let currentArchivedAt = registry.session(id: session.id)?.archivedAt
    if currentArchivedAt != nil {
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "archived_mid_send")
    }
    guard RateLimiter.shared.tryAcquireSend(sessionId: session.id) else {
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "rate_limited")
    }
    // Harness-driven children (codex app-server / gemini gRPC / grok+cursor
    // ACP) drive through their live bridge — not the legacy per-agent dispatch
    // below. A registered bridge is authoritative (mirrors the Solo send path's
    // SessionCommandRouter `.harnessBridge` route).
    if let bridge = harnessRegistry.bridge(for: session.id) {
        await bridge.prompt(text)
        await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
    }
    // OpenCode sidecar
    if session.kind == .chat && session.agent == .opencode {
        do {
            try await forwardOpencodePrompt(session: session, prompt: text)
            await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
        } catch {
            serverLogger.warning("frontier child opencode send failed: \(error.localizedDescription, privacy: .public)")
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: error.localizedDescription)
        }
    }
    // Track A: Claude PTY child (flag on) — submit via the host, no pane.
    if SessionCommandRouter.resolve(routeContext(for: session)) == .claudePty {
        guard let host = await claudePtyHost(for: session) else {
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "agent_cli_not_found")
        }
        await host.submitPrompt(text, isChat: session.kind == .chat, isFollowUp: true)
        await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
    }
    // CLI (Claude / Codex CLI)
    guard let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
        serverLogger.warning("frontier child has no pane id — skipping send")
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "missing_pane_id")
    }
    do {
        let bytes = text.data(using: .utf8) ?? Data()
        try await tmux.pasteBytes(paneId: paneId, bytes: bytes + Data([0x0D]))
        await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
    } catch {
        serverLogger.warning("frontier child tmux paste failed: \(error.localizedDescription, privacy: .public)")
        return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: error.localizedDescription)
    }
}

/// POST /chat-sessions/frontier/:groupId/retry-slot — replace one
/// child session with a fresh spawn of the same provider/model.
/// Useful when one slot failed at create time (D10) and the user
/// wants to try again.
func handleFrontierRetrySlot(
    request: HTTPRequest,
    connection: NWConnection,
    groupId: String
) async {
    guard let uuid = UUID(uuidString: groupId),
          let req = try? JSONDecoder().decode(RetryFrontierSlotRequest.self, from: request.body) else {
        sendResponse(.badRequest, on: connection); return
    }
    let children = registry.frontierGroupChildren(groupId: uuid)
    guard !children.isEmpty else {
        sendResponse(.notFound, on: connection); return
    }
    // Find the existing child at this index (may exist with failed
    // status, or may have been hard-deleted). Either way, look up
    // the original slot spec from one of the surviving siblings'
    // peer entries — we don't persist the slot spec separately, so
    // we reconstruct it from the child's session record itself.
    guard let existing = children.first(where: { $0.frontierChildIndex == req.index }) else {
        sendResponse(HTTPResponse(
            status: 404, reason: "Not Found",
            contentType: "application/json",
            body: Data(#"{"error":"slot_not_found","index":\#(req.index)}"#.utf8)
        ), on: connection)
        return
    }
    let slot = FrontierModelSlot(
        provider: existing.agent,
        model: existing.model,
        effort: existing.effort,
        codexChatBackend: existing.codexChatBackend,
        deepResearch: existing.deepResearch,
        chatVendor: existing.runtimeBinding?.metadata["chatVendor"].flatMap(ChatVendor.init(rawValue:)),
        billingProvider: existing.runtimeBinding?.billingProvider
    )
    // Delete the old session (cleans up chat-cwd + chat store entry).
    // Stop a harness child first (no-op for legacy children).
    await harnessRegistry.remove(existing.id)
    if let wiring = sessionWiring.removeValue(forKey: existing.id) {
        wiring.stop()
    }
    chatStoreRegistry.evict(sessionId: existing.id)
    if existing.kind == .chat {
        try? ChatCwdManager.remove(for: existing.id)
    }
    try? await registry.delete(id: existing.id)
    // Re-spawn with the same childIndex.
    do {
        let fresh = try await spawnFrontierChild(
            groupId: uuid,
            childIndex: req.index,
            slot: slot
        )
        if let counter = frontierUpdateCounters[uuid] {
            frontierUpdateCounters[uuid] = counter + 1
        }
        let result = FrontierSlotResult(index: req.index, sessionId: fresh.id, reason: nil)
        let encoder = JSONEncoder()
        if let body = try? encoder.encode(result) {
            sendResponse(HTTPResponse(
                status: 200, reason: "OK",
                contentType: "application/json", body: body
            ), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    } catch let SpawnFailure.message(reason) {
        let result = FrontierSlotResult(index: req.index, sessionId: nil, reason: reason)
        let encoder = JSONEncoder()
        if let body = try? encoder.encode(result) {
            sendResponse(HTTPResponse(
                status: 200, reason: "OK (still failed)",
                contentType: "application/json", body: body
            ), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    } catch {
        sendResponse(.internalError, on: connection)
    }
}

/// POST /chat-sessions/frontier/:groupId/pick-winner — archive the
/// non-winning children and promote the winner out of the broadcast
/// group so the sidebar/history treat it as a normal Solo chat.
/// Returns the promoted winner session (with `frontierGroupId` /
/// `frontierChildIndex` cleared).
///
/// v0.23.9: previously the winner kept its `frontierGroupId`, which
/// meant follow-up sends still mapped back to the Frontier group
/// and the snapshot WS still considered the group "live". Both UIs
/// now also flip `openTarget` to `.solo(winner.id)` after this call
/// returns. Belt + suspenders: Frontier send / snapshot also filter
/// `archivedAt == nil` so even before the next refresh, the
/// archived losers cannot receive sends.
func handlePickFrontierWinner(
    request: HTTPRequest,
    connection: NWConnection,
    groupId: String
) async {
    guard let uuid = UUID(uuidString: groupId),
          let req = try? JSONDecoder().decode(PickFrontierWinnerRequest.self, from: request.body) else {
        sendResponse(.badRequest, on: connection); return
    }
    // Enumerate everyone (including any already-archived siblings)
    // so we cleanly archive the full loser set even if pick-winner
    // is invoked a second time.
    let allChildren = registry.frontierGroupChildren(groupId: uuid, includeArchived: true)
    guard let winner = allChildren.first(where: { $0.frontierChildIndex == req.childIndex && $0.archivedAt == nil }) else {
        sendResponse(.notFound, on: connection); return
    }
    // Archive the losers. Existing archive path persists archivedAt
    // and the sidebar's Show-Archived toggle keeps them reachable.
    for child in allChildren where child.id != winner.id && child.archivedAt == nil {
        // Stop the loser's harness child process (ACP/app-server/gRPC) so
        // archiving doesn't leak a running agent, AND release the chat store
        // the harness child acquired at create (createHarnessChatSessionCore)
        // so it can idle-evict. Legacy children used snapshotStore (no
        // acquire), so only release when this was actually a harness child.
        let wasHarness = harnessRegistry.contains(child.id)
        await harnessRegistry.remove(child.id)
        if wasHarness {
            chatStoreRegistry.release(sessionId: child.id)
        }
        try? await registry.archive(id: child.id)
    }
    // Promote the winner out of the Frontier group. From this point
    // on, every history/search row, every Frontier send, and every
    // FrontierWebSocket snapshot treats this session as a regular
    // Solo chat.
    try? await registry.clearFrontierGroupBinding(id: winner.id)
    let promoted = registry.session(id: winner.id) ?? winner
    if let counter = frontierUpdateCounters[uuid] {
        frontierUpdateCounters[uuid] = counter + 1
    }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    if let body = try? encoder.encode(promoted) {
        sendResponse(HTTPResponse(
            status: 200, reason: "OK",
            contentType: "application/json", body: body
        ), on: connection)
    } else {
        sendResponse(.internalError, on: connection)
    }
}

func handleSetFrontierTurnWinner(
    request: HTTPRequest,
    connection: NWConnection,
    groupId: String
) async {
    guard let uuid = UUID(uuidString: groupId),
          let req = try? JSONDecoder().decode(SetFrontierTurnWinnerRequest.self, from: request.body) else {
        sendResponse(.badRequest, on: connection); return
    }
    let children = registry.frontierGroupChildren(groupId: uuid)
    guard children.contains(where: { $0.frontierChildIndex == req.childIndex }) else {
        sendResponse(.notFound, on: connection); return
    }
    let winner = FrontierTurnWinner(groupId: uuid, turnId: req.turnId, childIndex: req.childIndex)
    var group = frontierTurnWinners[uuid] ?? [:]
    group[req.turnId] = winner
    frontierTurnWinners[uuid] = group
    saveFrontierTurnWinners()
    if let counter = frontierUpdateCounters[uuid] {
        frontierUpdateCounters[uuid] = counter + 1
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let body = try? encoder.encode(winner) {
        sendResponse(HTTPResponse(
            status: 200, reason: "OK",
            contentType: "application/json", body: body
        ), on: connection)
    } else {
        sendResponse(.internalError, on: connection)
    }
}

/// Internal spawn dispatch shared by handlePostFrontier +
/// handleFrontierRetrySlot. Throws SpawnFailure.message on per-slot
/// failure so the caller can surface a per-slot reason string.
private enum SpawnFailure: Error {
    case message(String)
}

private func spawnFrontierChild(
    groupId: UUID,
    childIndex: Int,
    slot: FrontierModelSlot
) async throws -> AgentSession {
    let metadata: ResolvedChatRuntimeMetadata
    do {
        metadata = try resolveChatRuntimeMetadata(
            provider: slot.provider,
            requestedVendor: slot.chatVendor,
            requestedBillingProvider: slot.billingProvider
        )
    } catch let error as ChatRuntimeValidationError {
        throw SpawnFailure.message(chatRuntimeValidationMessage(error))
    }

    if let reason = providerDisabledReason(provider: slot.provider, vendor: metadata.vendor) {
        throw SpawnFailure.message(reason)
    }

    if let reason = await frontierProviderUnavailableReason(provider: slot.provider) {
        throw SpawnFailure.message(reason)
    }

    // Harness is the default drive path for non-Claude broadcast children
    // (codex app-server / gemini headless agy / grok+cursor ACP), exactly as
    // Solo chat. Reuse the shared core; map its errors to a slot failure reason.
    // Claude → tmux and opencode → SSE fall through to the per-provider switch
    // below.
    if isChatHarnessEligible(slot.provider) {
        do {
            return try await createHarnessChatSessionCore(
                provider: slot.provider, model: slot.model, effort: slot.effort,
                deepResearch: slot.deepResearch, chatVendor: metadata.vendor,
                billingProvider: metadata.billingProvider,
                frontierGroupId: groupId, frontierChildIndex: childIndex
            )
        } catch let harnessError as HarnessChatSpawnError {
            throw SpawnFailure.message(harnessError.slotReason)
        }
    }

    switch slot.provider {
    case .claude:
        // Reuse the same plumbing as Solo chat: createChat → chat-cwd →
        // spawn tmux → warm chat store. We don't need the full HTTP wrapper
        // since we already have all the data.
        let session = try await registry.createChat(
            provider: slot.provider,
            model: slot.model,
            chatCwd: "",
            codexChatBackend: nil,
            effort: slot.effort,
            frontierGroupId: groupId,
            frontierChildIndex: childIndex,
            deepResearch: slot.deepResearch,
            chatVendor: metadata.vendor,
            billingProvider: metadata.billingProvider
        )
        let chatCwd: String
        do {
            let url = try ChatCwdManager.ensure(for: session.id)
            chatCwd = url.path
        } catch {
            try? await registry.delete(id: session.id)
            throw SpawnFailure.message("chat_cwd_create_failed: \(error.localizedDescription)")
        }
        try? await registry.updateRuntime(
            id: session.id, worktreePath: chatCwd,
            tmuxWindowId: nil, tmuxPaneId: nil, mode: .local
        )
        if slot.provider == .claude {
            ChatCwdManager.markTrustedForClaude(path: chatCwd)
        }
        let updated = registry.session(id: session.id) ?? session
        let argv = AgentSpawner.argv(for: updated)
        if argv.isEmpty {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            throw SpawnFailure.message("agent_cli_not_found")
        }
        // CLI: spawn tmux. Best-effort — children that fail to spawn
        // are surfaced as a slot failure, not a 500.
        do {
            try await tmux.start()
            let window = try await tmux.newWindow(cwd: chatCwd, child: argv)
            try? await registry.updateRuntime(
                id: session.id, worktreePath: chatCwd,
                tmuxWindowId: window.windowId, tmuxPaneId: window.paneId, mode: .local
            )
            _ = chatStoreRegistry.snapshotStore(for: registry.session(id: session.id) ?? updated)
            return registry.session(id: session.id) ?? updated
        } catch {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            throw SpawnFailure.message("tmux_spawn_failed: \(error.localizedDescription)")
        }
    case .codex:
        throw SpawnFailure.message("codex_unexpected_legacy_frontier_path")
    case .gemini:
        // Unreachable: gemini is always harness-eligible (isChatHarnessEligible),
        // so a broadcast gemini child spawns via createHarnessChatSessionCore
        // above — the headless `agy` driver (Antigravity 2.0), bound to this
        // frontier group exactly like the grok/cursor/codex children. The legacy
        // agentapi one-shot frontier path has been retired.
        throw SpawnFailure.message("gemini_unexpected_legacy_frontier_path")
    case .opencode:
        guard let _ = await OpencodeProcessManager.shared.ensureRunning() else {
            switch OpencodeProcessManager.shared.state {
            case .notInstalled:
                throw SpawnFailure.message("opencode_not_installed")
            case .failed(let detail):
                throw SpawnFailure.message("opencode_serve_failed: \(detail)")
            default:
                throw SpawnFailure.message("opencode_not_running")
            }
        }
        OpencodeSSEAdapter.shared.start()
        if OpencodeSSEAdapter.shared.chatStoreAccessor == nil {
            let registry = self.registry
            let chatStoreRegistry = self.chatStoreRegistry
            OpencodeSSEAdapter.shared.chatStoreAccessor = { [weak registry, weak chatStoreRegistry] uuid in
                guard let registry, let chatStoreRegistry else { return nil }
                guard let session = registry.session(id: uuid) else { return nil }
                return chatStoreRegistry.acquire(for: session)
            }
        }
        let session = try await registry.createChat(
            provider: .opencode,
            model: slot.model,
            chatCwd: "",
            effort: slot.effort,
            frontierGroupId: groupId,
            frontierChildIndex: childIndex,
            deepResearch: slot.deepResearch,
            chatVendor: metadata.vendor,
            billingProvider: metadata.billingProvider
        )
        let chatCwd: String
        do {
            let url = try ChatCwdManager.ensure(for: session.id)
            chatCwd = url.path
        } catch {
            try? await registry.delete(id: session.id)
            throw SpawnFailure.message("chat_cwd_create_failed: \(error.localizedDescription)")
        }
        try? await registry.updateRuntime(
            id: session.id,
            worktreePath: chatCwd,
            runtimeCwd: .some(chatCwd),
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            mode: .local
        )
        guard var request = await OpencodeProcessManager.shared.makeAuthorizedRequest(
            path: "/session",
            directory: chatCwd
        ) else {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            throw SpawnFailure.message("opencode_not_running")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": "Frontier #\(childIndex + 1) - OpenCode"
        ])
        let opencodeID: String
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("opencode_session_create_failed")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String else {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("opencode_bad_session_response")
            }
            opencodeID = id
        } catch let failure as SpawnFailure {
            throw failure
        } catch {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            throw SpawnFailure.message("opencode_session_create_failed: \(error.localizedDescription)")
        }
        let updated = registry.session(id: session.id) ?? session
        OpencodeSSEAdapter.shared.register(
            clawdmeterID: updated.id, opencodeID: opencodeID, repo: chatCwd
        )
        _ = chatStoreRegistry.snapshotStore(for: updated)
        AgentEventStream.recordEvent(
            sessionId: updated.id,
            kind: .sessionCreated,
            payload: ["repo": chatCwd, "agent": "opencode", "opencodeID": opencodeID]
        )
        return updated
    case .unknown, .grok, .cursor:
        // Unreachable for cursor/grok: both are harness-eligible
        // (isChatHarnessEligible) and return via createHarnessChatSessionCore
        // above, so they never reach this legacy tmux switch. .unknown is the
        // forward-compat catch-all. Defensive: surface a slot failure.
        throw SpawnFailure.message("unknown_agent_kind")
    }
}

/// D1 (first-message-becomes-title): if the OpenCode session has no
/// customName yet, derive a 40-char title from the prompt body and
/// persist via `registry.rename(...)`. Future renames via /rename
/// override this.
/// v0.23.2 P1-04: send a prompt into an OpenCode session.
///
/// Flow:
///   1. Echo the user prompt into the SessionChatStore so the
///      composer clears the "sending…" state and the user bubble
///      renders immediately (mirrors how sendChatSDKPrompt does it).
///   2. Resolve the opencode session id (registered when the
///      AgentSession was spawned via `handleSpawnOpencodeSession`).
///   3. POST to `opencode serve`'s `/session/<oc-id>/message` with
///      a minimal `parts: [{type: "text", text: <prompt>}]` body.
///      opencode picks the user's default provider+model — we
///      don't override unless a session-specific override is set.
///   4. Return 200; the reply streams back asynchronously via
///      `message.added` SSE events that OpencodeSSEAdapter routes
///      into the same SessionChatStore.
///
/// Error surfaces:
///   - opencode serve down → 503 `opencode_server_unreachable`
///   - no opencode session-id registered → 503 `opencode_session_not_registered`
///     (caller should retry after a brief delay; the SSE
///     `session.created` event populates the map asynchronously)
///   - opencode returns non-2xx → 502 `opencode_send_failed` w/
///     the upstream status code
func sendOpencodePrompt(
    session: AgentSession,
    prompt: String,
    idempotencyKey: String? = nil,
    payloadHash: String = "",
    connection: NWConnection
) async {
    // First-prompt naming, same convention as sendChatSDKPrompt.
    if (session.customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let cap = 40
            let truncated = trimmed.count <= cap
                ? trimmed
                : String(trimmed[..<trimmed.index(trimmed.startIndex, offsetBy: cap - 1)]) + "…"
            try? await registry.rename(id: session.id, name: truncated)
        }
    }
    // Echo the user prompt into the chat store so the UI clears
    // its "sending…" state and the user bubble renders without
    // waiting on the SSE round-trip.
    if let store = chatStoreRegistry.snapshotStore(for: session) {
        let userMsgId = "opencode-user-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
        store.appendSDKMessages([
            ChatMessage(
                id: userMsgId,
                kind: .userText,
                title: "You",
                body: prompt,
                at: Date()
            )
        ])
    }
    // Resolve the opencode session id.
    guard let opencodeID = await OpencodeSSEAdapter.shared.opencodeSessionId(for: session.id) else {
        serverLogger.warning("opencode send: no session-id mapping for \(session.id.uuidString, privacy: .public)")
        sendResponse(HTTPResponse(
            status: 503, reason: "Service Unavailable",
            contentType: "application/json",
            body: Data(#"{"error":"opencode_session_not_registered","detail":"Opencode session has not been registered yet — retry in a moment."}"#.utf8)
        ), on: connection)
        return
    }
    // Build the upstream POST.
    guard var req = await OpencodeProcessManager.shared.makeAuthorizedRequest(
        path: "/session/\(opencodeID)/message",
        directory: session.effectiveCwd
    ) else {
        sendResponse(HTTPResponse(
            status: 503, reason: "Service Unavailable",
            contentType: "application/json",
            body: Data(#"{"error":"opencode_server_unreachable","detail":"opencode serve is not running"}"#.utf8)
        ), on: connection)
        return
    }
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // OpenCode's local OpenAPI expects a single text part plus an
    // optional `model` object (`providerID`/`modelID`) and `variant`.
    // Keep the body inside that schema so current and older serve
    // builds reject neither unknown top-level provider fields nor
    // missing default-model state.
    let body = opencodeMessageBody(session: session, prompt: prompt)
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 20

    do {
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200..<300).contains(http.statusCode) {
            serverLogger.warning("opencode send: upstream returned \(http.statusCode, privacy: .public)")
            let detailBody = #"{"error":"opencode_send_failed","upstreamStatus":\#(http.statusCode)}"#
            sendResponse(HTTPResponse(
                status: 502, reason: "Bad Gateway",
                contentType: "application/json",
                body: Data(detailBody.utf8)
            ), on: connection)
            return
        }
        // v16 outbox: idempotency receipt + cache. Routing through
        // sendCommandResponse so a retried request with the same key
        // returns the cached ok-response without re-posting to the
        // OpenCode sidecar (which would double-send the user's prompt).
        await sendCommandResponse(
            body: ["ok": true],
            key: idempotencyKey,
            kind: .send,
            sessionId: session.id,
            payloadHash: payloadHash,
            on: connection
        )
    } catch {
        serverLogger.warning("opencode send: \(error.localizedDescription, privacy: .public)")
        sendResponse(HTTPResponse(
            status: 503, reason: "Service Unavailable",
            contentType: "application/json",
            body: Data(#"{"error":"opencode_server_unreachable","detail":"\#(error.localizedDescription)"}"#.utf8)
        ), on: connection)
    }
}

private func forwardOpencodePrompt(session: AgentSession, prompt: String) async throws {
    if let store = chatStoreRegistry.snapshotStore(for: session) {
        let userMsgId = "opencode-user-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
        store.appendSDKMessages([
            ChatMessage(
                id: userMsgId,
                kind: .userText,
                title: "You",
                body: prompt,
                at: Date()
            )
        ])
    }
    guard let opencodeID = await OpencodeSSEAdapter.shared.opencodeSessionId(for: session.id) else {
        throw NSError(
            domain: "AgentControlServer.OpenCode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "opencode_session_not_registered"]
        )
    }
    guard var req = await OpencodeProcessManager.shared.makeAuthorizedRequest(
        path: "/session/\(opencodeID)/message",
        directory: session.effectiveCwd
    ) else {
        throw NSError(
            domain: "AgentControlServer.OpenCode",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "opencode_server_unreachable"]
        )
    }
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: opencodeMessageBody(session: session, prompt: prompt))
    req.timeoutInterval = 20
    let (_, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        throw NSError(
            domain: "AgentControlServer.OpenCode",
            code: status,
            userInfo: [NSLocalizedDescriptionKey: "opencode_send_failed: \(status)"]
        )
    }
}

/// Body posted to `opencode serve`'s `/session/<id>/message`
/// endpoint. v0.29.9: stripped of the `model`/`variant` override —
/// auth and model selection now flow entirely from the user's
/// `opencode` CLI configuration (`opencode auth login` + the CLI's
/// own default-model state). The serve daemon picks the upstream
/// provider and model from its own state; Clawdmeter no longer
/// second-guesses that selection.
private func opencodeMessageBody(session: AgentSession, prompt: String) -> [String: Any] {
    var body: [String: Any] = [
        "parts": [
            ["type": "text", "text": prompt]
        ]
    ]
    // Honor the picked model. registry.create stored the OpenRouter slug
    // on session.model, but until now it was dropped here and OpenCode
    // silently ran its own opencode.json default — so the 320-model picker
    // was cosmetic. OpenCode's /session/:id/message takes an optional
    // `model:{providerID,modelID}`; the OpenRouter-backed vendor always
    // routes via providerID "openrouter" with the full slug as modelID.
    if let model = Self.opencodeModelObject(forModelId: session.model) {
        body["model"] = model
    }
    return body
}

/// Maps a session's selected OpenRouter model id to OpenCode's message
/// `{providerID, modelID}` object. Returns nil for the "opencode-default"
/// sentinel (or no selection) so OpenCode keeps its own default model.
nonisolated static func opencodeModelObject(forModelId raw: String?) -> [String: String]? {
    guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !id.isEmpty, id != "opencode-default" else { return nil }
    return ["providerID": "openrouter", "modelID": id]
}

}
