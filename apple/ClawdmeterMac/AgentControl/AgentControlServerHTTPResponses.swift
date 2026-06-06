import Foundation
import Network
import ClawdmeterShared

extension AgentControlServer {
    // MARK: - Response sending

    /// HTTP responses used by daemon handlers. Sessions v2 promoted the
    /// enum to a struct so endpoints can emit arbitrary statuses (409
    /// Conflict, 426 Upgrade Required, 503 Service Unavailable) with a
    /// structured JSON body. Common cases stay reachable via static
    /// constants / factories so existing call sites don't change.
    struct HTTPResponse {
        let status: Int
        let reason: String
        let contentType: String
        let body: Data
        /// Extra response headers (e.g. `Retry-After`). Emitted verbatim
        /// after the standard headers in `httpResponseBytes`. Empty for
        /// most responses; the static `tooManyRequests` factories set it.
        let extraHeaders: [(String, String)]

        init(status: Int, reason: String, contentType: String, body: Data, extraHeaders: [(String, String)] = []) {
            self.status = status
            self.reason = reason
            self.contentType = contentType
            self.body = body
            self.extraHeaders = extraHeaders
        }

        static func ok(contentType: String, body: Data) -> HTTPResponse {
            HTTPResponse(status: 200, reason: "OK", contentType: contentType, body: body)
        }
        static let badRequest = HTTPResponse(
            status: 400, reason: "Bad Request",
            contentType: "text/plain", body: Data("Bad Request\n".utf8)
        )
        static func badRequest(detail: String) -> HTTPResponse {
            HTTPResponse(
                status: 400, reason: "Bad Request",
                contentType: "text/plain",
                body: Data("Bad Request: \(detail)\n".utf8)
            )
        }
        static let notFound = HTTPResponse(
            status: 404, reason: "Not Found",
            contentType: "text/plain", body: Data("Not Found\n".utf8)
        )
        static let unauthorized = HTTPResponse(
            status: 401, reason: "Unauthorized",
            contentType: "text/plain", body: Data("Unauthorized\n".utf8)
        )
        static let internalError = HTTPResponse(
            status: 500, reason: "Internal Server Error",
            contentType: "text/plain", body: Data("Internal Server Error\n".utf8)
        )
        /// 403 Forbidden with a JSON body for policy denials (e.g. autopilot
        /// enable on an untrusted repo — review §3 finding 2026-05-18).
        static func forbidden(body: Data) -> HTTPResponse {
            HTTPResponse(
                status: 403, reason: "Forbidden",
                contentType: "application/json", body: body
            )
        }
        /// Generic 429 (kept for the dispatch-time auth/peer rejection
        /// path). Prefer `tooManyRequestsSend` / `tooManyRequestsSwap` from
        /// the per-handler call sites — those set a real `Retry-After`.
        static let tooManyRequests = tooManyRequestsSwap

        static let tooManyRequestsSend = HTTPResponse(
            status: 429, reason: "Too Many Requests",
            contentType: "application/json",
            body: Data(#"{"error":"rate_limited","retryAfterSeconds":1}"#.utf8),
            extraHeaders: [("Retry-After", "1")]
        )
        static let tooManyRequestsSwap = HTTPResponse(
            status: 429, reason: "Too Many Requests",
            contentType: "application/json",
            body: Data(#"{"error":"rate_limited","retryAfterSeconds":5}"#.utf8),
            extraHeaders: [("Retry-After", "5")]
        )
    }

    /// P1-Mac-7: validate untrusted repoKey before forwarding to tmux. The
    /// path must be absolute, contain no `..` segments, hold no CR/LF or
    /// control bytes, and resolve under the user's home directory.
    ///
    /// Codex follow-up: also resolve symlinks before the home-prefix
    /// check. The earlier patch only standardized (collapses `..` /
    /// `./`); a symlink at `/Users/me/link → /etc` would pass the
    /// hasPrefix test and let tmux escape the home sandbox. Resolve the
    /// real path and re-check.
    static func isValidRepoKey(_ key: String) -> Bool {
        // v0.7.7: delegated to the shared PathValidator helper that
        // consolidates the three near-clone validators that used to
        // live across this file + iOSArtifactsPane.
        PathValidator.isValidRepoKey(key)
    }

    /// Codex follow-up to P1-Mac-7: also validate jsonlPath in the
    /// continue-readonly handler. The repoKey check alone left a
    /// trust-boundary gap — a compromised client could send a valid
    /// repoKey and a jsonlPath pointing at an unrelated session, and
    /// the handler would happily resume that one. Restrict jsonlPath
    /// to live under the user's Claude/Codex project directories and
    /// reject the same traversal / control-byte / symlink-escape shapes
    /// covered by isValidRepoKey.
    static func isValidJsonlPath(_ path: String) -> Bool {
        // v0.7.7: delegated to PathValidator. Allowlist of agent project
        // directories lives in the shared helper now.
        PathValidator.isValidJsonlPath(path, homeDirectory: ClawdmeterRealHome.path())
    }

    static let markdownDocumentMaxBytes = 2 * 1024 * 1024

    static func standardizedMarkdownDocumentPath(_ rawPath: String, relativeTo cwd: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PathValidator.isEmpty(trimmed),
              !PathValidator.containsControlBytes(trimmed),
              !PathValidator.containsTraversal(trimmed)
        else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            guard !cwd.isEmpty,
                  cwd.hasPrefix("/"),
                  !PathValidator.containsControlBytes(cwd),
                  !PathValidator.containsTraversal(cwd)
            else { return nil }
            absolute = (cwd as NSString).appendingPathComponent(expanded)
        }
        return (absolute as NSString).standardizingPath
    }

    static func markdownDocumentAllowedRoots(
        relativeTo cwd: String,
        homeDirectory: String = ClawdmeterRealHome.path()
    ) -> [String] {
        var roots: [String] = []
        if let cwdRoot = standardizedMarkdownDocumentRoot(cwd) {
            roots.append(cwdRoot)
        }
        let generatedDocsRoot = (homeDirectory as NSString)
            .appendingPathComponent(".gstack/projects")
        if let gstackRoot = standardizedMarkdownDocumentRoot(generatedDocsRoot) {
            roots.append(gstackRoot)
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    static func isMarkdownDocumentPathAllowed(
        _ path: String,
        relativeTo cwd: String,
        homeDirectory: String = ClawdmeterRealHome.path()
    ) -> Bool {
        let canonical = (path as NSString).standardizingPath
        let resolved = (canonical as NSString).resolvingSymlinksInPath
        for root in markdownDocumentAllowedRoots(relativeTo: cwd, homeDirectory: homeDirectory) {
            let rootStandard = (root as NSString).standardizingPath
            let rootResolved = (rootStandard as NSString).resolvingSymlinksInPath
            if pathIsInside(canonical, root: rootStandard)
                && pathIsInside(resolved, root: rootResolved) {
                return true
            }
        }
        return false
    }

    private static func standardizedMarkdownDocumentRoot(_ rawRoot: String) -> String? {
        let trimmed = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PathValidator.isEmpty(trimmed),
              trimmed.hasPrefix("/"),
              !PathValidator.containsControlBytes(trimmed),
              !PathValidator.containsTraversal(trimmed)
        else { return nil }
        return (trimmed as NSString).standardizingPath
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    // v0.27.0: isSafeDesignImportBase(_:) removed along with the Design
    // tab + Open Design /design/import-folder route.

    func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let bytes = httpResponseBytes(
            status: response.status,
            statusText: response.reason,
            contentType: response.contentType,
            body: response.body,
            extraHeaders: response.extraHeaders
        )
        // T18 Wire Inspector: record outgoing response on a best-effort
        // Task; bypassing the actor would let the inspector skew under
        // load. Read the request context stashed in dispatch() so the
        // outbound row carries the original method+path (without this,
        // every response showed `— —`, useless for request/response
        // correlation).
        //
        // Hot-path gate: only build the closure + retain the body when
        // the inspector is on. For the /artifact endpoint (up to 50MB)
        // this avoids pinning the full Data behind a detached Task that
        // the actor would just drop inside.
        if WireInspector.isEnabledFast {
            let peerString = Self.endpointString(connection.endpoint)
            let ctx = pendingRequests.removeValue(forKey: ObjectIdentifier(connection))
            let method = ctx?.method ?? "—"
            let path = ctx?.path ?? "—"
            let status = response.status
            let contentType = response.contentType
            let body = response.body
            Task.detached { @Sendable in
                await WireInspector.shared.recordResponse(
                    method: method, path: path, peer: peerString,
                    status: status, body: body.isEmpty ? nil : body,
                    contentType: contentType
                )
            }
        } else {
            // Still drop the per-connection map entry so it can't leak
            // if the inspector flips on between request and response.
            pendingRequests.removeValue(forKey: ObjectIdentifier(connection))
        }
        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()  // HTTP/1.1 keep-alive is not implemented; close after each response
        })
    }

    func sendJSON(_ object: [String: Any], on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    }

    // MARK: - v16 idempotency helpers

    /// Atomically starts an idempotent command. Returns false after writing a
    /// replay or in-flight response; returns true when the caller may execute.
    @discardableResult
    func beginIdempotentCommand(
        key: String?,
        on connection: NWConnection,
        payloadHash: String? = nil
    ) async -> Bool {
        switch await mobileCommandOutbox.entryOrReserve(key: key) {
        case .noKey, .reserved:
            return true
        case .cached(let cached):
            sendCachedIdempotentResponse(cached, key: key ?? "", on: connection, payloadHash: payloadHash)
            return false
        case .inFlight:
            let body = Data(#"{"error":"another-request-with-same-idempotency-key-is-in-flight"}"#.utf8)
            sendResponse(
                HTTPResponse(
                    status: 409,
                    reason: "Conflict",
                    contentType: "application/json",
                    body: body
                ),
                on: connection
            )
            return false
        }
    }

    /// Returns true after writing a cached response to `connection`.
    /// The caller short-circuits its handler logic in that case so the
    /// side effect (send to tmux, swap model, merge PR) doesn't repeat.
    /// `kind` is recorded into the audit log but is not strictly required
    /// for the lookup itself — keys are globally unique by construction.
    ///
    /// `payloadHash` (optional) enables the payload-mismatch gate. When
    /// supplied AND the cached entry has a stored hash that DIFFERS, the
    /// daemon sends `422 Unprocessable` instead of replaying — protects
    /// against an iOS retry that reused the persisted key but edited
    /// the request body (e.g. user edited the GitHub spec between
    /// taps). Callers without a hash skip the check (back-compat).
    @discardableResult
    func tryReplayIdempotent(
        key: String?,
        on connection: NWConnection,
        payloadHash: String? = nil
    ) async -> Bool {
        guard let key, !key.isEmpty else { return false }
        guard let cached = await mobileCommandOutbox.entry(forKey: key) else { return false }
        sendCachedIdempotentResponse(cached, key: key, on: connection, payloadHash: payloadHash)
        return true
    }

    private func sendCachedIdempotentResponse(
        _ cached: MobileCommandOutbox.CachedEntry,
        key: String,
        on connection: NWConnection,
        payloadHash: String? = nil
    ) {
        // Payload-mismatch gate. Cached entries without a stored hash
        // (audit-log replay seeds, old entries from before this field)
        // skip the check — we can't distinguish a real mismatch from a
        // missing-record without the hash, and we'd rather replay than
        // surface a spurious 422.
        if let incoming = payloadHash,
           let stored = cached.payloadHash,
           !stored.isEmpty,
           incoming != stored {
            let body = Data(#"{"error":"idempotency-key-reused-with-different-payload"}"#.utf8)
            sendResponse(
                HTTPResponse(
                    status: 422,
                    reason: "Unprocessable",
                    contentType: "application/json",
                    body: body
                ),
                on: connection
            )
            serverLogger.warning("idempotent payload mismatch (key=\(key.prefix(8), privacy: .public)…)")
            return
        }
        // Re-emit the cached response bytes. When the cache only carried
        // the receipt (audit-log replay path, no body), synthesize a
        // minimal JSON body that still carries the receipt so iOS can
        // mark the outbox entry done.
        let body: Data
        let contentType: String
        if let cachedBody = cached.responseBody {
            body = cachedBody
            contentType = cached.responseContentType
        } else {
            let payload: [String: Any] = ["receipt": cached.receipt.jsonDictionary, "replay": true]
            body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            contentType = "application/json"
        }
        let response: HTTPResponse
        if cached.responseStatus == 200 {
            response = .ok(contentType: contentType, body: body)
        } else {
            // Non-200 cached responses (failed commands) replay with
            // the original status code so iOS preserves the original
            // error treatment.
            response = HTTPResponse(
                status: cached.responseStatus,
                reason: "Cached Response",
                contentType: contentType,
                body: body
            )
        }
        sendResponse(response, on: connection)
        serverLogger.info("idempotent replay (key=\(key.prefix(8), privacy: .public)…, kind=\(cached.kind.rawValue, privacy: .public))")
    }

    /// Cache a freshly-processed command's response under `key` so the
    /// next retry with the same key replays. Also writes a hashed audit
    /// row to `~/.clawdmeter/audit/mobile-commands.jsonl`.
    func recordIdempotent(
        key: String?,
        kind: MobileCommandKind,
        sessionId: UUID?,
        connection: NWConnection,
        payloadHash: String,
        responseBody: Data?,
        responseContentType: String = "application/json",
        responseStatus: Int = 200,
        failed: Bool = false,
        errorMessage: String? = nil
    ) async {
        guard let key, !key.isEmpty else { return }
        let entry: MobileCommandOutbox.CachedEntry
        if failed {
            entry = await mobileCommandOutbox.recordFailure(
                key: key,
                kind: kind,
                error: errorMessage ?? "unknown",
                responseStatus: responseStatus,
                responseBody: responseBody,
                payloadHash: payloadHash
            )
        } else {
            entry = await mobileCommandOutbox.record(
                key: key,
                kind: kind,
                responseBody: responseBody,
                responseContentType: responseContentType,
                responseStatus: responseStatus,
                payloadHash: payloadHash
            )
        }
        await AuditLog.shared.recordMobileCommand(
            idempotencyKey: key,
            kind: kind.rawValue,
            sessionId: sessionId,
            sourcePeer: Self.endpointString(connection.endpoint),
            status: entry.receipt.status.rawValue,
            payloadHash: payloadHash,
            serverReceiptId: entry.receipt.serverReceiptId
        )
    }

    /// One-shot helper for idempotent JSON success responses. Inlines the
    /// receipt into the body dict so iOS can match by idempotencyKey,
    /// caches the bytes for replay, and writes the audit row. Equivalent
    /// to `sendJSON(body)` when `key` is nil (legacy clients).
    func sendCommandResponse(
        body: [String: Any],
        key: String?,
        kind: MobileCommandKind,
        sessionId: UUID?,
        payloadHash: String,
        on connection: NWConnection
    ) async {
        var body = body
        if let key, !key.isEmpty {
            let receipt = MobileCommandReceipt(
                idempotencyKey: key,
                status: .acknowledged,
                processedAt: Date()
            )
            body["receipt"] = receipt.jsonDictionary
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: body) else {
            sendResponse(.internalError, on: connection)
            return
        }
        if key != nil {
            await recordIdempotent(
                key: key,
                kind: kind,
                sessionId: sessionId,
                connection: connection,
                payloadHash: payloadHash,
                responseBody: bytes,
                responseStatus: 200
            )
        }
        sendResponse(.ok(contentType: "application/json", body: bytes), on: connection)
    }

    func sendCommandJSONError(
        _ body: [String: Any],
        status: Int,
        key: String?,
        kind: MobileCommandKind,
        sessionId: UUID?,
        payloadHash: String,
        on connection: NWConnection
    ) async {
        var body = body
        let errorMessage = (body["error"] as? String) ?? "command_failed"
        if let key, !key.isEmpty {
            let receipt = MobileCommandReceipt(
                idempotencyKey: key,
                status: .failed,
                processedAt: Date(),
                error: errorMessage
            )
            body["receipt"] = receipt.jsonDictionary
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: body) else {
            sendResponse(.internalError, on: connection)
            return
        }
        if key != nil {
            await recordIdempotent(
                key: key,
                kind: kind,
                sessionId: sessionId,
                connection: connection,
                payloadHash: payloadHash,
                responseBody: bytes,
                responseStatus: status,
                failed: true,
                errorMessage: errorMessage
            )
        }
        sendResponse(
            HTTPResponse(
                status: status,
                reason: Self.reasonPhrase(forStatus: status),
                contentType: "application/json",
                body: bytes
            ),
            on: connection
        )
    }

    func sendCommandCodableResponse<T: Encodable>(
        _ value: T,
        key: String?,
        kind: MobileCommandKind,
        sessionId: UUID?,
        payloadHash: String,
        status: Int = 200,
        failed: Bool = false,
        errorMessage: String? = nil,
        on connection: NWConnection
    ) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            sendResponse(.internalError, on: connection)
            return
        }
        if key != nil {
            await recordIdempotent(
                key: key,
                kind: kind,
                sessionId: sessionId,
                connection: connection,
                payloadHash: payloadHash,
                responseBody: body,
                responseStatus: status,
                failed: failed,
                errorMessage: errorMessage
            )
        }
        sendResponse(
            HTTPResponse(
                status: status,
                reason: Self.reasonPhrase(forStatus: status),
                contentType: "application/json",
                body: body
            ),
            on: connection
        )
    }

    private static func reasonPhrase(forStatus status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    func sendCodable<T: Encodable>(_ value: T, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    }

    /// v0.14.0: sendJSON with arbitrary HTTP status (used by T20 design
    /// bridge proxy to surface 503/400/502 with structured error JSON).
    func sendJSON(_ object: [String: Any], on connection: NWConnection, status: Int) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        case 501: reason = "Not Implemented"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        default:  reason = "Status"
        }
        sendResponse(
            HTTPResponse(status: status, reason: reason, contentType: "application/json", body: body),
            on: connection
        )
    }

    private func httpResponseBytes(
        status: Int,
        statusText: String,
        contentType: String,
        body: Data,
        extraHeaders: [(String, String)] = []
    ) -> Data {
        var out = Data()
        out.append(Data("HTTP/1.1 \(status) \(statusText)\r\n".utf8))
        out.append(Data("Content-Type: \(contentType)\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n".utf8))
        for (name, value) in extraHeaders {
            out.append(Data("\(name): \(value)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }
}
