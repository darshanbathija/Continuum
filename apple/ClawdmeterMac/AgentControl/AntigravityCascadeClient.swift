// Thin grpc-swift v2 wrapper over Antigravity 2's `language_server`
// `exa.language_server_pb.LanguageServerService` Cascade drive surface.
//
// What + why: the daemon already discovers the transport facts via
// `LanguageServerClient.discoverLive()` — the per-launch CSRF token + the gRPC
// port (`httpsPort`, exposed as `httpsBaseURL = https://127.0.0.1:<port>`).
// This client takes (host, gRPC port, csrf), opens an HTTP/2 channel that
// ACCEPTS the self-signed per-launch cert (the CSRF on request metadata is the
// real auth, not the cert), and exposes the four Cascade RPCs we drive:
//   startCascade · streamCascadeReactiveUpdates (server-stream) ·
//   cancelCascadeSteps · handleCascadeUserInteraction (approve/reject).
// Each streamed update is decoded into the existing, transport-neutral
// `AntigravityCascadeStep` model (in ClawdmeterShared) so the SAME
// `AntigravityCascadeMapper` → `HarnessEvent` path the spike specced lands it
// in `SessionChatStore`.
//
// COMPILE-ONLY: no live Antigravity drive was tested. The proto envelope shapes
// (`antigravity_cascade.proto`) are a curated minimal subset with PROVISIONAL
// request/response field numbers — wire compatibility is a live-verify
// follow-up. proto3's unknown-field tolerance means correctly-transcribed inner
// fields (cascade_id, etc.) still decode even if a wrapper number is wrong.
//
// Mac-only: Antigravity.app + the gRPC transport are macOS surfaces, and the
// generated client requires macOS 15+ (the `@available` the plugin stamps).

#if os(macOS)
import Foundation
import OSLog
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import ClawdmeterShared

/// Errors surfaced by the Cascade gRPC client. The driver turns each into a
/// `.error` HarnessEvent / a thrown `start()` failure (two-phase contract).
public enum AntigravityCascadeClientError: Error, Sendable {
    /// The gRPC channel could not be established / run (transport-level).
    case connectFailed(String)
    /// An RPC was rejected or failed mid-call. Carries the gRPC message.
    case rpcFailed(String)
    /// `startCascade` returned an empty cascade id (server didn't mint one).
    case missingCascadeId
}

/// Owns one long-lived gRPC channel to a single live `language_server` and the
/// generated Cascade service client. An `actor` so concurrent prompt/cancel/
/// permission calls from the driver are serialized on the client state.
///
/// Lifecycle mirrors grpc-swift v2's `withGRPCClient`: a background task runs
/// `client.runConnections()` for the channel's lifetime; `close()` calls
/// `beginGracefulShutdown()` and awaits that task. We DON'T use the scoped
/// `withGRPCClient` helper because the driver is long-lived across many turns,
/// not a single request.
public actor AntigravityCascadeClient {
    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "AntigravityCascadeClient")

    private let host: String
    private let port: Int
    private let csrfToken: String

    // The concrete transport + grpc client + generated service client. Built in
    // `connect()`; nil until then.
    private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?
    private var serviceClient: Exa_LanguageServerPb_LanguageServerService.Client<HTTP2ClientTransport.Posix>?
    private var runTask: Task<Void, Never>?

    public init(host: String, port: Int, csrfToken: String) {
        self.host = host
        self.port = port
        self.csrfToken = csrfToken
    }

    // MARK: - connect / close

    /// Build the HTTP/2 transport, start the client's connection loop, and make
    /// the generated service client. Throws on transport construction failure
    /// (the driver's two-phase `start()` contract surfaces it).
    ///
    /// TLS: `serverCertificateVerification = .noVerification` accepts the
    /// self-signed per-launch cert. This mirrors `LanguageServerClient`'s
    /// loopback-scoped `URLSessionDelegate` trust — the connection is to
    /// 127.0.0.1 and the CSRF token is the real authenticator.
    public func connect() async throws {
        guard grpcClient == nil else { return } // idempotent
        let transport: HTTP2ClientTransport.Posix
        do {
            transport = try HTTP2ClientTransport.Posix(
                target: .ipv4(address: host, port: port),
                transportSecurity: .tls { config in
                    // Loopback self-signed cert: accept it. CSRF is the auth.
                    config.serverCertificateVerification = .noVerification
                }
            )
        } catch {
            throw AntigravityCascadeClientError.connectFailed("transport init: \(error)")
        }

        let client = GRPCClient(transport: transport)
        self.grpcClient = client
        self.serviceClient = Exa_LanguageServerPb_LanguageServerService.Client(wrapping: client)

        // Run the connection loop for the channel's lifetime. `runConnections()`
        // returns only after `beginGracefulShutdown()`; a thrown transport error
        // is logged (the next RPC will then fail with a clear gRPC error the
        // driver maps to `.error`).
        runTask = Task { [weak self, client] in
            do {
                try await client.runConnections()
            } catch {
                await self?.logRunFailure(error)
            }
        }
    }

    private func logRunFailure(_ error: Error) {
        logger.error("gRPC runConnections ended with error: \(String(describing: error), privacy: .public)")
    }

    /// Graceful teardown: stop accepting RPCs, let in-flight ones drain, await
    /// the run loop. Safe to call more than once.
    public func close() async {
        grpcClient?.beginGracefulShutdown()
        await runTask?.value
        runTask = nil
        grpcClient = nil
        serviceClient = nil
    }

    // MARK: - metadata

    /// The CSRF token on request metadata. gRPC/HTTP-2 header names are
    /// lowercase; `x-csrf-token` mirrors the `X-CSRF-Token` header
    /// `LanguageServerClient.currentModel()` sends over plain HTTPS.
    private func authMetadata() -> Metadata {
        var md = Metadata()
        md.addString(csrfToken, forKey: "x-csrf-token")
        return md
    }

    private func client() throws -> Exa_LanguageServerPb_LanguageServerService.Client<HTTP2ClientTransport.Posix> {
        guard let c = serviceClient else {
            throw AntigravityCascadeClientError.connectFailed("client used before connect()")
        }
        return c
    }

    // MARK: - drive surface

    /// StartCascade — begin a turn. Returns the cascade id the reactive stream
    /// is keyed on (server-minted on the first turn; echoed on follow-ups).
    /// `cascadeId` empty → first turn.
    public func startCascade(
        cascadeId: String,
        prompt: String,
        workspacePath: String,
        projectId: String,
        model: String?,
        webSearchEnabled: Bool
    ) async throws -> String {
        var req = Exa_LanguageServerPb_StartCascadeRequest()
        req.cascadeID = cascadeId
        req.prompt = prompt
        req.workspacePath = workspacePath
        req.projectID = projectId
        if let model { req.model = model }
        req.webSearchEnabled = webSearchEnabled

        let c = try client()
        do {
            let resp = try await c.startCascade(req, metadata: authMetadata())
            let id = resp.cascadeID.isEmpty ? cascadeId : resp.cascadeID
            guard !id.isEmpty else { throw AntigravityCascadeClientError.missingCascadeId }
            return id
        } catch let e as AntigravityCascadeClientError {
            throw e
        } catch {
            throw AntigravityCascadeClientError.rpcFailed("StartCascade: \(error)")
        }
    }

    /// StreamCascadeReactiveUpdates — server-streams step deltas for a cascade.
    /// Returns an `AsyncThrowingStream<AntigravityCascadeStep>` the driver folds
    /// through `AntigravityCascadeMapper`. `sinceStepIndex` is a resume cursor.
    ///
    /// Each gRPC `CascadeReactiveUpdate` frame carries a `trajectory_steps`
    /// batch; we decode each step into `AntigravityCascadeStep` and yield it.
    /// The stream finishes when the server closes the RPC; it throws on RPC
    /// failure so the driver can emit `.error` + a `.turnFinished(.failed)`.
    public func streamReactiveUpdates(
        cascadeId: String,
        sinceStepIndex: Int64 = 0
    ) async throws -> AsyncThrowingStream<AntigravityCascadeStep, Error> {
        // Build the request as an immutable `let`: the streaming Task closure
        // captures it, and a generated SwiftProtobuf message is `Sendable`, so
        // capturing an immutable value avoids the Swift 6 sending-closure data
        // race a captured `var` would trip.
        let req: Exa_LanguageServerPb_StreamCascadeReactiveUpdatesRequest = {
            var r = Exa_LanguageServerPb_StreamCascadeReactiveUpdatesRequest()
            r.cascadeID = cascadeId
            r.sinceStepIndex = sinceStepIndex
            return r
        }()
        let c = try client()
        let md = authMetadata()

        return AsyncThrowingStream<AntigravityCascadeStep, Error> { continuation in
            let task = Task {
                do {
                    // The closure receives a server-streaming response; iterate
                    // `messages` and decode each frame's steps. The RPC stays
                    // open until the server closes it (turn end) or the task is
                    // cancelled.
                    try await c.streamCascadeReactiveUpdates(req, metadata: md) { response in
                        for try await update in response.messages {
                            for pbStep in update.trajectorySteps {
                                continuation.yield(Self.decodeStep(pbStep))
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// CancelCascadeSteps — cancel the in-flight turn. Best-effort: a failure is
    /// logged, not thrown (the driver's `cancel()` is `async` with no throw).
    public func cancelCascade(cascadeId: String) async {
        var req = Exa_LanguageServerPb_CancelCascadeStepsRequest()
        req.cascadeID = cascadeId
        do {
            let c = try client()
            _ = try await c.cancelCascadeSteps(req, metadata: authMetadata())
        } catch {
            logger.error("CancelCascadeSteps failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// HandleCascadeUserInteraction — answer a permission/approval the agent
    /// raised. `approve` true = approve the proposed steps, false = reject.
    /// Best-effort + logged (the driver's `respondToPermission` is non-throwing).
    public func respondToPermission(cascadeId: String, permissionId: String, approve: Bool) async {
        var req = Exa_LanguageServerPb_HandleCascadeUserInteractionRequest()
        req.cascadeID = cascadeId
        req.permissionID = permissionId
        req.approve = approve
        do {
            let c = try client()
            _ = try await c.handleCascadeUserInteraction(req, metadata: authMetadata())
        } catch {
            logger.error("HandleCascadeUserInteraction failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - step decode (protobuf → transport-neutral model)

    /// Decode one generated `CascadeStep` into the shared `AntigravityCascadeStep`
    /// model. Pure + static so it's testable without a live channel. Unknown /
    /// empty payloads fall to `.unknown` (preserved, never dropped) — mirrors the
    /// lenient decode posture of `ACPModels`.
    static func decodeStep(_ s: Exa_LanguageServerPb_CascadeStep) -> AntigravityCascadeStep {
        switch s.stepPayload {
        case .assistantText(let text):
            return .assistantText(text)
        case .thinking(let text):
            return .thinking(text)
        case .toolCall(let tc):
            return .toolCall(
                id: tc.toolCallID,
                title: tc.toolName.isEmpty ? nil : tc.toolName,
                kind: nil,
                status: mapToolStatus(tc.status)
            )
        case .fileDiff(let fd):
            return .fileDiff(
                path: fd.filePath,
                unifiedDiff: fd.unifiedDiff.isEmpty ? nil : fd.unifiedDiff
            )
        case .permission(let p):
            return .permission(
                permissionId: p.permissionID,
                title: nil,
                proposalToolCalls: p.proposalToolCalls
            )
        case .error(let e):
            return .error(message: e.message)
        case .completion(let comp):
            return .turnFinished(mapOutcome(comp.outcome))
        case .none:
            return .unknown(kind: "empty_step_payload")
        }
    }

    private static func mapToolStatus(_ s: Exa_LanguageServerPb_CascadeToolCallStatus) -> HarnessToolCall.Status {
        switch s {
        case .pending: return .pending
        case .inProgress: return .inProgress
        case .completed: return .completed
        case .failed: return .failed
        case .unspecified, .UNRECOGNIZED: return .unknown
        }
    }

    private static func mapOutcome(_ o: Exa_LanguageServerPb_CascadeTurnOutcome) -> AntigravityTurnOutcome {
        switch o {
        case .completed: return .completed
        case .cancelled: return .cancelled
        // Treat unspecified the same as failed: a completion frame with no clear
        // outcome should not claim a clean end (mirrors the mapper's `.failed →
        // .unknown` stop-reason posture).
        case .failed, .unspecified, .UNRECOGNIZED: return .failed
        }
    }
}
#endif
