import Foundation
import AppKit
import Network
import OSLog
import ClawdmeterShared

private let repoOnboardingHandlerLogger = Logger(
    subsystem: "com.clawdmeter.mac",
    category: "AgentControlServer+RepoOnboarding"
)

/// Wire v23 — Add-Repo workspace onboarding handlers. These are extension
/// methods on `AgentControlServer` for the five new routes:
///
///   `POST /workspaces/open-local`   → focus Mac + NSOpenPanel, 423 if locked
///   `POST /workspaces/from-github`  → gh repo clone (or git fallback)
///   `POST /workspaces/quick-start`  → mkdir + git init
///   `POST /workspaces/wake-mac`     → caffeinate display
///   `GET  /workspaces/allow-list`   → resolved allow + deny list
///
/// All write endpoints route through `MobileCommandOutbox` for
/// idempotency-key dedup. Path inputs are validated against
/// `PathAllowList` (A9-B). The open-local handler additionally enforces
/// `CGSessionLiveness` (A3-A) so a sleeping Mac returns 423 instead of
/// stranding an invisible modal.
extension AgentControlServer {

    // MARK: - Open Local Folder (NSOpenPanel-driven)

    func handleOpenLocalFolder(request: HTTPRequest, connection: NWConnection) async {
        let req = (try? JSONDecoder().decode(OpenLocalFolderRequest.self, from: request.body))
            ?? OpenLocalFolderRequest()
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)

        // A3-A: refuse if the Mac can't visibly bring NSOpenPanel forward.
        let liveness = cgSession.state
        if liveness != .awake {
            await respondLocked(req: req, payloadHash: payloadHash, connection: connection, state: liveness)
            return
        }

        // Focus the app + run the picker with a 5-minute zombie-prevention
        // timeout (per the critical-gap mitigation in the plan).
        NSApp.activate(ignoringOtherApps: true)
        let path: String?
        do {
            path = try await runOpenPanelWithTimeout(seconds: 300)
        } catch {
            await respondInternal(
                req: req,
                payloadHash: payloadHash,
                connection: connection,
                error: .persistenceFailed(message: "NSOpenPanel error: \(error.localizedDescription)")
            )
            return
        }
        guard let chosenPath = path else {
            // User cancelled. 204 No Content — write the receipt so retries
            // don't re-open the panel.
            await sendNoContentReceipt(req: req, payloadHash: payloadHash, connection: connection)
            return
        }

        do {
            let record = try await repoOnboardingService.registerWorkspace(
                at: chosenPath,
                allowNonGit: true
            )
            await respondWithWorkspace(
                record: record,
                req: req,
                kind: .openLocalFolder,
                payloadHash: payloadHash,
                connection: connection
            )
        } catch let err as RepoOnboardingError {
            await respondOnboardingError(
                err,
                req: req,
                kind: .openLocalFolder,
                payloadHash: payloadHash,
                connection: connection
            )
        } catch {
            await respondInternal(
                req: req,
                payloadHash: payloadHash,
                connection: connection,
                error: .persistenceFailed(message: error.localizedDescription)
            )
        }
    }

    // MARK: - Clone from GitHub

    func handleCloneFromGitHub(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(CloneFromGitHubRequest.self, from: request.body) else {
            sendResponse(AgentControlServer.HTTPResponse.badRequest, on: connection); return
        }
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)

        // A9-B: gate the destination parent against the allow-list.
        let parent = req.destinationParent ?? defaultParentOrFallback()
        let validated: String
        switch PathAllowList.validate(parent) {
        case .success(let canonical):
            validated = canonical
        case .failure(let err):
            await respondOnboardingError(
                err,
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                kind: .cloneFromGitHub,
                payloadHash: payloadHash,
                connection: connection
            )
            return
        }

        do {
            let record = try await repoOnboardingService.cloneFromGitHub(
                spec: req.spec,
                destinationParent: validated
            )
            await respondWithWorkspace(
                record: record,
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                kind: .cloneFromGitHub,
                payloadHash: payloadHash,
                connection: connection
            )
        } catch let err as RepoOnboardingError {
            await respondOnboardingError(
                err,
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                kind: .cloneFromGitHub,
                payloadHash: payloadHash,
                connection: connection
            )
        } catch {
            await respondInternal(
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                payloadHash: payloadHash,
                connection: connection,
                error: .cloneFailed(stderr: error.localizedDescription)
            )
        }
    }

    // MARK: - Quick Start

    func handleQuickStartRepo(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(QuickStartRepoRequest.self, from: request.body) else {
            sendResponse(AgentControlServer.HTTPResponse.badRequest, on: connection); return
        }
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)

        let parent = req.parent ?? defaultParentOrFallback()
        let validated: String
        switch PathAllowList.validate(parent) {
        case .success(let canonical):
            validated = canonical
        case .failure(let err):
            await respondOnboardingError(
                err,
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                kind: .quickStartRepo,
                payloadHash: payloadHash,
                connection: connection
            )
            return
        }

        do {
            let record = try await repoOnboardingService.quickStart(
                name: req.name,
                in: validated
            )
            await respondWithWorkspace(
                record: record,
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                kind: .quickStartRepo,
                payloadHash: payloadHash,
                connection: connection
            )
        } catch let err as RepoOnboardingError {
            await respondOnboardingError(
                err,
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                kind: .quickStartRepo,
                payloadHash: payloadHash,
                connection: connection
            )
        } catch {
            await respondInternal(
                req: PathReceiptCarrier(idempotencyKey: req.idempotencyKey),
                payloadHash: payloadHash,
                connection: connection,
                error: .gitInitFailed(stderr: error.localizedDescription)
            )
        }
    }

    // MARK: - Wake Mac

    func handleWakeMac(request: HTTPRequest, connection: NWConnection) async {
        let req = (try? JSONDecoder().decode(WakeMacRequest.self, from: request.body))
            ?? WakeMacRequest()
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)

        // Two-step wake strategy. Track `sentWake` separately from "we
        // tried a binary" — we report success ONLY when at least one
        // wake command actually exited 0. Reporting success on "binary
        // exists but exited non-zero" would let iOS show "Wake signal
        // sent" when nothing was sent.
        var sentWake = false
        var attempts: [String] = []
        var errors: [String] = []

        // 1. Tailscale wake — wakes a tailnet peer via Wake-on-LAN if
        //    the user has it set up. `tailscale status --self --json`
        //    must succeed AND the wake command must exit 0 to count.
        if let tailscale = ShellRunner.locateBinary("tailscale") {
            attempts.append("tailscale")
            if let hostname = await currentTailscaleHostname() {
                do {
                    let result = try await ShellRunner.shared.run(
                        executable: tailscale,
                        arguments: ["wake", hostname],
                        timeout: 5
                    )
                    if result.exitStatus == 0 {
                        sentWake = true
                    } else {
                        errors.append("tailscale wake exit \(result.exitStatus): \(result.stderrString.prefix(200))")
                    }
                } catch {
                    errors.append("tailscale wake failed: \(error.localizedDescription)")
                }
            } else {
                errors.append("tailscale status --self --json unavailable")
            }
        }

        // 2. Local caffeinate — nudges the display awake on a screen-
        //    dimmed-but-still-running Mac. Counts as a wake only if
        //    the binary actually exits 0.
        if let caffeinate = ShellRunner.locateBinary("caffeinate") {
            attempts.append("caffeinate")
            do {
                let result = try await ShellRunner.shared.run(
                    executable: caffeinate,
                    arguments: ["-u", "-t", "5"],
                    timeout: 10
                )
                if result.exitStatus == 0 {
                    sentWake = true
                } else {
                    errors.append("caffeinate exit \(result.exitStatus): \(result.stderrString.prefix(200))")
                }
            } catch {
                errors.append("caffeinate failed: \(error.localizedDescription)")
            }
        }

        if attempts.isEmpty {
            sendResponse(
                serviceUnavailable(reason: "neither tailscale nor caffeinate is installed"),
                on: connection
            )
            return
        }
        if !sentWake {
            // Every wake attempt failed. Return 503 with the collected
            // errors so iOS doesn't claim "wake signal sent" when no
            // signal was sent.
            let combined = errors.joined(separator: "; ")
            sendResponse(
                serviceUnavailable(reason: "all wake attempts failed: \(combined)"),
                on: connection
            )
            return
        }
        await sendCommandResponse(
            body: [
                "ok": true,
                "attempted": attempts.joined(separator: ","),
                "errors": errors.joined(separator: "; "),
            ],
            key: req.idempotencyKey,
            kind: MobileCommandKind.wakeMac,
            sessionId: nil as UUID?,
            payloadHash: payloadHash,
            on: connection
        )
    }

    /// Best-effort: read the local Tailscale hostname from `tailscale status
    /// --self --json` if it parses. Returns nil if Tailscale is offline,
    /// not configured, or the JSON shape is unexpected.
    private func currentTailscaleHostname() async -> String? {
        guard let tailscale = ShellRunner.locateBinary("tailscale") else { return nil }
        let result: ShellRunner.Result
        do {
            result = try await ShellRunner.shared.run(
                executable: tailscale,
                arguments: ["status", "--self", "--json"],
                timeout: 3
            )
        } catch {
            return nil
        }
        guard result.exitStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let self_ = json["Self"] as? [String: Any],
              let dns = self_["DNSName"] as? String,
              !dns.isEmpty
        else { return nil }
        // DNSName ends with `.`; strip for `tailscale wake` arg.
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }

    // MARK: - Allow-list (GET — no idempotency needed)

    func handleGetWorkspaceAllowList(connection: NWConnection) {
        let response = WorkspaceAllowListResponse(
            allowedRoots: PathAllowList.resolveAllowedRoots(),
            deniedSubpaths: PathAllowList.resolveDeniedSubpaths()
        )
        sendCodableValue(response, on: connection)
    }

    // MARK: - Response helpers

    /// Common return path for write endpoints. Encodes the record as JSON
    /// and inlines the idempotency receipt so iOS can match the outbox
    /// entry by key.
    private func respondWithWorkspace<R: HasIdempotencyKey>(
        record: CodeWorkspaceRecord,
        req: R,
        kind: MobileCommandKind,
        payloadHash: String,
        connection: NWConnection
    ) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let recordData = try? encoder.encode(record),
              var dict = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any]
        else {
            sendResponse(AgentControlServer.HTTPResponse.internalError, on: connection); return
        }
        await sendCommandResponse(
            body: dict,
            key: req.idempotencyKey,
            kind: kind,
            sessionId: nil,
            payloadHash: payloadHash,
            on: connection
        )
        _ = dict // silence unused-warning in case sendCommandResponse early-returns
    }

    /// Common return path for `RepoOnboardingError`. Encodes the error as
    /// a structured JSON body + appropriate HTTP status (.alreadyRegistered
    /// = 200, .pathNotAllowed = 403, .ghAuthFailed = 401, others = 500).
    private func respondOnboardingError<R: HasIdempotencyKey>(
        _ error: RepoOnboardingError,
        req: R,
        kind: MobileCommandKind,
        payloadHash: String,
        connection: NWConnection
    ) async {
        let status: Int
        switch error {
        // 409 Conflict — the workspace already exists. Critical: must NOT
        // be 200, because the client's success path tries to decode
        // CodeWorkspaceRecord and the alreadyRegistered body is a
        // RepoOnboardingError. Returning 200 here made the iOS sheet's
        // `.alreadyRegistered` branch unreachable; the user saw "unknown
        // reason" instead of the duplicate-add toast.
        case .alreadyRegistered:    status = 409
        case .pathNotAllowed:       status = 403
        case .ghAuthFailed:         status = 401
        case .pathMissing,
             .notADirectory,
             .notAGitRepo:          status = 404
        default:                    status = 500
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(error) else {
            sendResponse(AgentControlServer.HTTPResponse.internalError, on: connection); return
        }
        // Best-effort: record an idempotency receipt for the failure too,
        // so retries replay the same error rather than re-attempting.
        if let key = req.idempotencyKey {
            await mobileCommandOutbox.recordFailure(
                key: key,
                kind: kind,
                error: "\(error)",
                responseStatus: status,
                responseBody: body
            )
        }
        let resp = AgentControlServer.HTTPResponse(
            status: status,
            reason: HTTPStatusReason.text(for: status),
            contentType: "application/json",
            body: body
        )
        sendResponse(resp, on: connection)
    }

    /// 423 Locked response for `/workspaces/open-local` when CGSession
    /// reports a non-awake state.
    private func respondLocked(
        req: OpenLocalFolderRequest,
        payloadHash: String,
        connection: NWConnection,
        state: CGSessionLivenessState
    ) async {
        let body: [String: Any] = [
            "error": "mac-not-awake",
            "state": state.rawValue,
            "wakeEndpoint": "/workspaces/wake-mac",
        ]
        let bytes = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        if let key = req.idempotencyKey {
            await mobileCommandOutbox.recordFailure(
                key: key,
                kind: .openLocalFolder,
                error: "mac-not-awake:\(state.rawValue)",
                responseStatus: 423,
                responseBody: bytes
            )
        }
        let resp = AgentControlServer.HTTPResponse(
            status: 423,
            reason: "Locked",
            contentType: "application/json",
            body: bytes
        )
        sendResponse(resp, on: connection)
    }

    private func respondInternal<R: HasIdempotencyKey>(
        req: R,
        payloadHash: String,
        connection: NWConnection,
        error: RepoOnboardingError
    ) async {
        await respondOnboardingError(
            error,
            req: req,
            kind: .openLocalFolder,
            payloadHash: payloadHash,
            connection: connection
        )
    }

    /// 204 No Content for user-cancelled open-local. Records the receipt so
    /// a retry replays the cancel.
    private func sendNoContentReceipt(
        req: OpenLocalFolderRequest,
        payloadHash: String,
        connection: NWConnection
    ) async {
        if let key = req.idempotencyKey {
            await mobileCommandOutbox.record(
                key: key,
                kind: .openLocalFolder,
                responseBody: Data("{}".utf8),
                responseContentType: "application/json",
                responseStatus: 204
            )
        }
        let resp = AgentControlServer.HTTPResponse(
            status: 204,
            reason: "No Content",
            contentType: "application/json",
            body: Data()
        )
        sendResponse(resp, on: connection)
    }

    private func serviceUnavailable(reason: String) -> AgentControlServer.HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": reason])) ?? Data("{}".utf8)
        return AgentControlServer.HTTPResponse(
            status: 503, reason: "Service Unavailable",
            contentType: "application/json", body: body
        )
    }

    private func defaultParentOrFallback() -> String {
        // Real home, not NSHomeDirectory() — sandboxed builds resolve the
        // latter to the container, which would then mismatch PathAllowList's
        // real-home allow-list and the daemon would reject its own default.
        UserDefaults.standard.string(forKey: PathAllowList.defaultParentKey)
            ?? (ClawdmeterRealHome.path() as NSString).appendingPathComponent("code")
    }

    /// NSOpenPanel-as-async with a hard timeout to prevent zombie modals
    /// (critical-gap mitigation in the plan). Returns the picked path or
    /// nil on user-cancel; throws on timeout.
    private func runOpenPanelWithTimeout(seconds: TimeInterval) async throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.title = "Open project"
        panel.message = "Pick a folder to add to your Clawdmeter projects on this Mac."

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            // Race the user against a timeout.
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                panel.cancel(nil)
            }
            panel.begin { response in
                timeoutTask.cancel()
                if response == .OK {
                    cont.resume(returning: panel.urls.first?.path)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Codable encode helper that doesn't collide with the private
    /// `sendCodable` already on AgentControlServer.
    private func sendCodableValue<T: Encodable>(_ value: T, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            sendResponse(AgentControlServer.HTTPResponse.internalError, on: connection); return
        }
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    }
}

// MARK: - Helpers

/// Protocol so the response helpers can accept any request carrying an
/// `idempotencyKey` without forcing each handler to construct the right
/// wrapper. All v23 request DTOs conform.
private protocol HasIdempotencyKey {
    var idempotencyKey: String? { get }
}
extension OpenLocalFolderRequest: HasIdempotencyKey {}
extension CloneFromGitHubRequest: HasIdempotencyKey {}
extension QuickStartRepoRequest: HasIdempotencyKey {}
extension WakeMacRequest: HasIdempotencyKey {}

/// Used when a handler needs to pass an idempotency key around AFTER the
/// original request DTO has been consumed (e.g., when we've validated the
/// path and want to surface a 403 without re-decoding).
private struct PathReceiptCarrier: HasIdempotencyKey {
    let idempotencyKey: String?
}

/// Short reason-phrase mapper for ad-hoc HTTP statuses we emit.
private enum HTTPStatusReason {
    static func text(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 423: return "Locked"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default:  return "Status"
        }
    }
}
