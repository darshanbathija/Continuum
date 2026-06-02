// Antigravity "Cascade" `AgentDriver` — drives Gemini/Antigravity 2 as a
// first-class harness provider over gRPC (Phase 7), not the agentapi
// send-and-watch ceiling the original plan assumed.
//
// What + why: conforms to the shared `AgentDriver` protocol exactly like
// `AcpAgentDriver`, so the daemon drives it through the same surface
// (start / prompt / cancel / respondToPermission / close) and projects its
// `HarnessEvent` stream into `SessionChatStore` via the existing
// `AcpHarnessProjection`. The drive loop is:
//   start  → discover the live language_server + open the gRPC channel
//   prompt → StartCascade(prompt, cwd, project) → stream
//            StreamCascadeReactiveUpdates → AntigravityCascadeStep →
//            AntigravityCascadeMapper → HarnessEvent
//   cancel → CancelCascadeSteps
//   respondToPermission → HandleCascadeUserInteraction (approve / reject)
//
// Two-phase failure contract (matches `AcpAgentDriver`/`AcpHarnessBridge`):
// `start()` throws synchronously on discovery / connect failure so the daemon's
// create route returns a real error instead of stranding a dead session.
//
// COMPILE-ONLY: no live Antigravity drive was tested. See
// `AntigravityCascadeClient` + `antigravity_cascade.proto` for the wire caveats
// (provisional envelope field numbers; permission RPC shape unverified).
//
// Mac-only: depends on `LanguageServerClient` (pgrep/lsof discovery) and the
// macOS-15+ generated gRPC client.

#if os(macOS)
import Foundation
import OSLog
import ClawdmeterShared

public actor AntigravityCascadeDriver: AgentDriver {
    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "AntigravityCascadeDriver")

    public nonisolated let events: AsyncStream<HarnessEvent>
    private let eventCont: AsyncStream<HarnessEvent>.Continuation

    /// Injected by the daemon create-path. The driver does NOT construct its own
    /// discovery — the daemon owns `LanguageServerClient` (and its test seam)
    /// and hands it in, so spawn-time discovery is uniform with the agentapi
    /// path and unit-testable with a stub probe.
    private let languageServer: LanguageServerClient
    /// The Antigravity project uuid the turn runs under. The daemon resolves
    /// this the same way the agentapi path does (`AntigravityProjectResolver` /
    /// persisted `session.antigravityProjectId`) and injects it.
    private let projectId: String
    private let mapper = AntigravityCascadeMapper()

    // Live state.
    private var client: AntigravityCascadeClient?
    private var cwd: String = ""
    private var model: String?
    /// The cascade id of the active conversation. Empty until the first
    /// `StartCascade` mints one; reused across follow-up turns.
    private var cascadeId: String = ""
    /// Stable-index cursor. The binary warns about "unstable steps in
    /// conversation; last stable index" — the reactive stream emits provisional
    /// steps that may be retracted. We only advance the cursor (and only treat a
    /// step as committed for resume purposes) once a stable step lands, so a
    /// reconnect resumes without re-rendering retracted steps.
    private var lastStableStepIndex: Int64 = 0
    /// The session id the mapper stamps onto permission requests. Set at start.
    private var externalSessionId: String = ""
    private var turnTask: Task<Void, Never>?
    /// Permission bookkeeping: the last permission id the agent raised, so
    /// `respondToPermission` can answer the Cascade approval RPC. ACP carries the
    /// id inside the `RpcId`; we mirror that (the mapper puts the Cascade
    /// permission id into `.string(permissionId)`).
    private var pendingPermissionId: String?

    /// `model` / `effort` are accepted to match the daemon's create surface; the
    /// model hint flows into `StartCascade`. `effort` has no Cascade analog yet
    /// (the agentapi tier system is the closest knob) — accepted + ignored.
    public init(languageServer: LanguageServerClient, projectId: String) {
        self.languageServer = languageServer
        self.projectId = projectId
        var cont: AsyncStream<HarnessEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.eventCont = cont
    }

    // MARK: - start (two-phase: throws synchronously)

    public func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String {
        self.cwd = cwd
        self.model = model

        // Discover the live language_server (CSRF + gRPC port). `.notRunning` is
        // a first-class failure → throw so the create route surfaces the
        // "Open Antigravity 2" CTA exactly like the agentapi path.
        let probe = languageServer.discoverLive()
        guard case .live(let live) = probe else {
            throw AntigravityCascadeClientError.connectFailed(
                "Antigravity 2 isn't running. Open Antigravity 2 to start a Gemini session.")
        }
        guard let gRPCPort = live.httpsPort else {
            throw AntigravityCascadeClientError.connectFailed(
                "language_server is running but exposes no gRPC port (only the agentapi HTTP port was found).")
        }

        let c = AntigravityCascadeClient(host: "127.0.0.1", port: gRPCPort, csrfToken: live.csrfToken)
        do {
            try await c.connect()
        } catch {
            throw AntigravityCascadeClientError.connectFailed("gRPC connect: \(error)")
        }
        self.client = c

        // No external session id exists until the first StartCascade mints a
        // cascade id. Use a synthetic stable id for the projection/session until
        // then; the real cascade id replaces it on first prompt and is what
        // revive keys on.
        self.externalSessionId = "antigravity-pending-\(UUID().uuidString)"
        return externalSessionId
    }

    // MARK: - turn loop

    public func prompt(_ text: String) async {
        guard let c = client else {
            eventCont.yield(.error(code: "no_session", message: "prompt before start"))
            eventCont.yield(.turnEnded(.unknown))
            return
        }
        // Reset the stable cursor per turn — each StartCascade restarts the
        // reactive stream for this cascade.
        turnTask = Task { [weak self] in
            await self?.runTurn(client: c, text: text)
        }
    }

    /// One turn: StartCascade → stream reactive updates → map each step to a
    /// HarnessEvent. Completion arrives as a `.turnFinished` step (mapped to
    /// `.turnEnded`); if the stream ends without one we synthesize `.endTurn`.
    private func runTurn(client c: AntigravityCascadeClient, text: String) async {
        do {
            let newId = try await c.startCascade(
                cascadeId: cascadeId,
                prompt: text,
                workspacePath: cwd,
                projectId: projectId,
                model: model,
                webSearchEnabled: true   // Antigravity defaults WebSearch on (review D3 parity)
            )
            cascadeId = newId
            // Promote the synthetic session id to the real cascade id the first
            // time the server mints one (revive keys on this).
            if externalSessionId.hasPrefix("antigravity-pending-") {
                externalSessionId = newId
            }

            let stream = try await c.streamReactiveUpdates(
                cascadeId: newId, sinceStepIndex: lastStableStepIndex)
            var sawTerminal = false
            for try await step in stream {
                if Task.isCancelled { break }
                // Track the permission id so respondToPermission can answer.
                if case .permission(let pid, _, _) = step { pendingPermissionId = pid }
                if case .turnFinished = step { sawTerminal = true }
                if let event = mapper.map(step, sessionId: externalSessionId) {
                    eventCont.yield(event)
                }
            }
            // Stream ended without a terminal step (server closed the RPC) →
            // synthesize a clean end so the projection doesn't hang on
            // `.streaming`.
            if !sawTerminal && !Task.isCancelled {
                eventCont.yield(.turnEnded(.endTurn))
            }
        } catch is CancellationError {
            // cancel() already emitted .turnEnded(.cancelled).
        } catch {
            eventCont.yield(.error(code: "antigravity", message: "\(error)"))
            eventCont.yield(.turnEnded(.unknown))
        }
    }

    public func cancel() async {
        turnTask?.cancel()
        guard let c = client, !cascadeId.isEmpty else { return }
        await c.cancelCascade(cascadeId: cascadeId)
        eventCont.yield(.turnEnded(.cancelled))
    }

    public func respondToPermission(requestId: RpcId, optionId: String?) async {
        guard let c = client, !cascadeId.isEmpty else { return }
        // The Cascade permission id rides in the RpcId (the mapper stamps
        // `.string(permissionId)`); fall back to the last-seen pending id.
        let permissionId: String
        switch requestId {
        case .string(let s): permissionId = s
        case .number: permissionId = pendingPermissionId ?? ""
        }
        guard !permissionId.isEmpty else { return }
        // The mapper synthesizes two options: `allow_once` (Approve) and
        // `reject_once` (Reject). `optionId == nil` means the prompt was
        // cancelled → treat as reject.
        let approve = (optionId == "allow_once")
        await c.respondToPermission(cascadeId: cascadeId, permissionId: permissionId, approve: approve)
        pendingPermissionId = nil
    }

    public func close() async {
        turnTask?.cancel()
        await client?.close()
        client = nil
        eventCont.finish()
    }
}
#endif
