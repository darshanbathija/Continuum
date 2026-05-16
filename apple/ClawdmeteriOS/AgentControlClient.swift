import Foundation
import CryptoKit
import ClawdmeterShared
import OSLog

private let clientLogger = Logger(subsystem: "com.clawdmeter.ios", category: "AgentControlClient")

/// HTTP + WS client for the Mac daemon. Reads pairing config from
/// UserDefaults + Keychain. Used by iOSSessionsView + iOSNotificationManager.
public final class AgentControlClient: ObservableObject {

    public static let hostKey = "clawdmeter.sessions.macHost"
    public static let httpPortKey = "clawdmeter.sessions.httpPort"
    public static let wsPortKey = "clawdmeter.sessions.wsPort"
    public static let tokenKey = "clawdmeter.sessions.token"

    @Published public private(set) var isConfigured: Bool = false
    @Published public private(set) var repos: [AgentRepo] = []
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var lastPolledAt: Date?
    @Published public private(set) var lastError: String?
    /// Sessions v2 Phase 0: fetched from `GET /models`. Defaults to the
    /// bundled catalog so the iOS UI works while paired Mac is unreachable.
    @Published public private(set) var modelCatalog: ModelCatalog = .bundled
    /// Wire-version handshake (E8). Populated on /health refresh. iOS shows
    /// a mismatch banner when local `AgentControlWireVersion.current` differs.
    @Published public private(set) var serverVersion: String?
    @Published public private(set) var serverWireVersion: Int?

    public init() {
        self.isConfigured = (host != nil && token != nil)
    }

    // MARK: - Config

    public var host: String? {
        UserDefaults.standard.string(forKey: Self.hostKey)
    }
    public var httpPort: Int {
        UserDefaults.standard.integer(forKey: Self.httpPortKey).nonZeroOrDefault(21731)
    }
    public var wsPort: Int {
        UserDefaults.standard.integer(forKey: Self.wsPortKey).nonZeroOrDefault(21732)
    }
    public var token: String? {
        UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    public func setPairing(host: String, httpPort: Int, wsPort: Int, token: String) {
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        UserDefaults.standard.set(httpPort, forKey: Self.httpPortKey)
        UserDefaults.standard.set(wsPort, forKey: Self.wsPortKey)
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        DispatchQueue.main.async {
            self.isConfigured = true
        }
    }

    public func clearPairing() {
        for key in [Self.hostKey, Self.httpPortKey, Self.wsPortKey, Self.tokenKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        DispatchQueue.main.async {
            self.isConfigured = false
        }
    }

    // MARK: - REST

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let host, let token else { return nil }
        guard let url = URL(string: "http://\(host):\(httpPort)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = 8
        return req
    }

    private enum ClientHTTPError: LocalizedError {
        case badStatus(Int, String?)

        var errorDescription: String? {
            switch self {
            case .badStatus(let status, let retryAfter):
                if let retryAfter {
                    return "Daemon returned HTTP \(status). Retry after \(retryAfter)s."
                }
                return "Daemon returned HTTP \(status)."
            }
        }
    }

    private func sendChecked(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientHTTPError.badStatus(http.statusCode, http.value(forHTTPHeaderField: "Retry-After"))
        }
        return data
    }

    @MainActor
    public func refreshAll() async {
        await refreshHealth()
        await refreshRepos()
        await refreshSessions()
        await refreshModelCatalog()
    }

    @MainActor
    public func refreshHealth() async {
        guard let request = makeRequest(path: "/health") else { return }
        do {
            let data = try await sendChecked(request)
            if let payload = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                self.serverVersion = payload.serverVersion
                self.serverWireVersion = payload.wireVersion
            }
        } catch {
            clientLogger.debug("refreshHealth failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    public func refreshModelCatalog() async {
        guard let request = makeRequest(path: "/models") else { return }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.modelCatalog = try decoder.decode(ModelCatalog.self, from: data)
        } catch {
            // Bundled catalog is the fallback — keep current value.
            clientLogger.debug("refreshModelCatalog failed: \(error.localizedDescription)")
        }
    }

    /// True when the paired Mac is running a different wire version than
    /// this app expects. iOS shows a banner with a copy-link to the DMG.
    @MainActor
    public var hasWireVersionMismatch: Bool {
        guard let serverWireVersion else { return false }
        return serverWireVersion != AgentControlWireVersion.current
    }

    // MARK: - Sessions v2 mid-session controls

    @MainActor
    @discardableResult
    public func changeModel(sessionId: UUID, request body: ChangeModelRequest) async -> AgentSession? {
        await postJSON(path: "/sessions/\(sessionId.uuidString)/model", body: body)
    }

    @MainActor
    @discardableResult
    public func changeEffort(sessionId: UUID, effort: ReasoningEffort) async -> AgentSession? {
        await postJSON(path: "/sessions/\(sessionId.uuidString)/effort", body: ChangeEffortRequest(effort: effort))
    }

    @MainActor
    @discardableResult
    public func changeMode(sessionId: UUID, mode: SessionMode, planMode: Bool? = nil) async -> AgentSession? {
        await postJSON(path: "/sessions/\(sessionId.uuidString)/mode",
                        body: ChangeModeRequest(mode: mode, planMode: planMode))
    }

    @MainActor
    public func sendPrompt(sessionId: UUID, text: String, asFollowUp: Bool = true) async {
        await postBody(path: "/sessions/\(sessionId.uuidString)/send",
                        body: SendPromptRequest(text: text, asFollowUp: asFollowUp))
    }

    @MainActor
    public func interruptSession(sessionId: UUID) async {
        await postEmpty(path: "/sessions/\(sessionId.uuidString)/interrupt")
    }

    @MainActor
    public func setAutopilot(sessionId: UUID, enabled: Bool) async {
        await postBody(path: "/sessions/\(sessionId.uuidString)/autopilot",
                        body: AutopilotRequest(enabled: enabled))
    }

    // MARK: - T33 multi-pane terminal endpoints

    @MainActor
    public func fetchTerminals(sessionId: UUID) async -> [TerminalPaneRef] {
        guard let request = makeRequest(path: "/sessions/\(sessionId.uuidString)/terminals") else { return [] }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([TerminalPaneRef].self, from: data)
        } catch {
            clientLogger.debug("fetchTerminals failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Spawn a new tmux pane in the session and return its ref. Daemon's
    /// existing handler accepts `{title}` and returns the new TerminalPaneRef.
    @MainActor
    public func addTerminal(sessionId: UUID, title: String) async -> TerminalPaneRef? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: ["title": title]) else { return nil }
        guard let request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/terminals",
            method: "POST", body: bodyData
        ) else { return nil }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TerminalPaneRef.self, from: data)
        } catch {
            clientLogger.debug("addTerminal failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete a pane by its `TerminalPaneRef.id` (not the tmux pane id).
    /// Daemon's DELETE handler matches on the ref UUID, not the underlying
    /// tmux pane id.
    @MainActor
    public func deleteTerminal(sessionId: UUID, terminalRefId: UUID) async {
        guard let request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/terminals/\(terminalRefId.uuidString)",
            method: "DELETE"
        ) else { return }
            do {
                _ = try await sendChecked(request)
            } catch {
                self.lastError = error.localizedDescription
            }
    }

    public enum ArtifactError: LocalizedError {
        case notPaired
        case badStatus(Int)
        case ioError(String)
        public var errorDescription: String? {
            switch self {
            case .notPaired: return "Not paired to a Mac"
            case .badStatus(let code): return "Daemon returned HTTP \(code)"
            case .ioError(let msg): return msg
            }
        }
    }

    /// Fetch artifact bytes via `GET /sessions/:id/artifact?path=…` and
    /// write them to a tempdir for `QLPreviewController`. The local
    /// filename is a SHA-256 of the remote path (with the original
    /// extension preserved) so two artifacts with the same basename in
    /// different remote directories don't collide. If the cached file
    /// already exists, the function returns it without re-fetching.
    @MainActor
    public func downloadArtifact(sessionId: UUID, remotePath: String) async throws -> URL {
        guard let host, let token else { throw ArtifactError.notPaired }
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-artifacts/\(sessionId.uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let localURL = cacheDir.appendingPathComponent(Self.cacheFilename(forRemotePath: remotePath))
        // Cache hit — return without round-tripping the daemon. Comment
        // in the previous shape claimed this was already happening; now
        // the code matches the claim.
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = httpPort
        comps.path = "/sessions/\(sessionId.uuidString)/artifact"
        comps.queryItems = [URLQueryItem(name: "path", value: remotePath)]
        guard let url = comps.url else { throw ArtifactError.ioError("bad URL") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ArtifactError.badStatus(http.statusCode)
        }
        try data.write(to: localURL, options: .atomic)
        return localURL
    }

    /// SHA-256 the full remote path so cache files don't collide on
    /// basename. Preserve the extension so QLPreview infers the type.
    private static func cacheFilename(forRemotePath remotePath: String) -> String {
        let digest = SHA256.hash(data: Data(remotePath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = (remotePath as NSString).pathExtension
        return ext.isEmpty ? hex : "\(hex).\(ext)"
    }

    // MARK: - Phase 8: pre-flight cost banner

    /// Fetch the daemon's pre-flight estimate for the soft-warn cost
    /// banner in the new-session sheet (D3 + D11). Returns nil on any
    /// failure path — the UI hides the banner when the result is nil.
    @MainActor
    public func fetchPreflight(query: PreflightQuery) async -> PreflightResponse? {
        var comps = URLComponents()
        comps.path = "/sessions/preflight"
        comps.queryItems = [
            URLQueryItem(name: "repoKey", value: query.repoKey),
            URLQueryItem(name: "agent", value: query.agent.rawValue),
            URLQueryItem(name: "model", value: query.model),
            URLQueryItem(name: "goalLength", value: String(query.goalLength)),
        ]
        if let effort = query.effort {
            comps.queryItems?.append(URLQueryItem(name: "effort", value: effort.rawValue))
        }
        guard let path = comps.url?.absoluteString,
              let request = makeRequest(path: path) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PreflightResponse.self, from: data)
        } catch {
            clientLogger.debug("fetchPreflight failed: \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    @discardableResult
    private func postJSON<T: Encodable>(path: String, body: T) async -> AgentSession? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let bodyData = try? encoder.encode(body),
              let request = makeRequest(path: path, method: "POST", body: bodyData) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(AgentSession.self, from: data)
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx] = session
            }
            return session
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    private func postBody<T: Encodable>(path: String, body: T) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let bodyData = try? encoder.encode(body),
              let request = makeRequest(path: path, method: "POST", body: bodyData) else {
            return
        }
        do {
            _ = try await sendChecked(request)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    @MainActor
    private func postEmpty(path: String) async {
        guard let request = makeRequest(path: path, method: "POST") else { return }
        do {
            _ = try await sendChecked(request)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    @MainActor
    public func refreshRepos() async {
        guard let request = makeRequest(path: "/repos") else { return }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.repos = try decoder.decode([AgentRepo].self, from: data)
            self.lastPolledAt = Date()
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
            clientLogger.debug("refreshRepos failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    public func refreshSessions() async {
        guard let request = makeRequest(path: "/sessions") else { return }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.sessions = try decoder.decode([AgentSession].self, from: data)
            // Sessions v2 Phase 10: keep the aggregate Live Activity in
            // sync with the latest session list.
            LiveActivityCoordinator.shared.refresh(from: sessions)
            let waiting = sessions.filter { $0.status == .planning && ($0.planText?.isEmpty == false || $0.agent == .codex) }
            let latest = waiting.max(by: { $0.lastEventAt < $1.lastEventAt })
            WatchPlanBridgeIOS.shared.updateContext(
                count: waiting.count,
                latestGoal: latest?.goal,
                latestPlanSummary: latest?.planText,
                latestSessionId: latest?.id
            )
        } catch {
            clientLogger.debug("refreshSessions failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    @discardableResult
    public func createSession(_ req: NewSessionRequest) async -> AgentSession? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(path: "/sessions", method: "POST", body: body) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(AgentSession.self, from: data)
            sessions.append(session)
            return session
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func deleteSession(id: UUID) async {
        guard let request = makeRequest(path: "/sessions/\(id.uuidString)", method: "DELETE") else { return }
        do {
            _ = try await sendChecked(request)
            sessions.removeAll { $0.id == id }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    @MainActor
    public func approvePlan(sessionId: UUID) async {
        guard let request = makeRequest(path: "/sessions/\(sessionId.uuidString)/approve-plan", method: "POST") else { return }
        do {
            _ = try await sendChecked(request)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    @MainActor
    public func archiveSession(id: UUID) async {
        guard let request = makeRequest(path: "/sessions/\(id.uuidString)/archive", method: "POST") else { return }
        do {
            _ = try await sendChecked(request)
            // Optimistic local update — server will confirm on next refresh.
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                let s = sessions[idx]
                sessions[idx] = AgentSession(
                    id: s.id, repoKey: s.repoKey, repoDisplayName: s.repoDisplayName,
                    agent: s.agent, model: s.model, goal: s.goal,
                    worktreePath: s.worktreePath,
                    tmuxWindowId: s.tmuxWindowId, tmuxPaneId: s.tmuxPaneId,
                    status: s.status, planText: s.planText,
                    createdAt: s.createdAt, lastEventAt: Date(),
                    lastEventSeq: s.lastEventSeq,
                    mode: s.mode, archivedAt: Date(),
                    terminalPanes: s.terminalPanes,
                    scheduledFollowUps: s.scheduledFollowUps,
                    parentSessionId: s.parentSessionId
                )
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    @MainActor
    public func unarchiveSession(id: UUID) async {
        guard let request = makeRequest(path: "/sessions/\(id.uuidString)/unarchive", method: "POST") else { return }
        do {
            _ = try await sendChecked(request)
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                let s = sessions[idx]
                sessions[idx] = AgentSession(
                    id: s.id, repoKey: s.repoKey, repoDisplayName: s.repoDisplayName,
                    agent: s.agent, model: s.model, goal: s.goal,
                    worktreePath: s.worktreePath,
                    tmuxWindowId: s.tmuxWindowId, tmuxPaneId: s.tmuxPaneId,
                    status: s.status, planText: s.planText,
                    createdAt: s.createdAt, lastEventAt: Date(),
                    lastEventSeq: s.lastEventSeq,
                    mode: s.mode, archivedAt: nil,
                    terminalPanes: s.terminalPanes,
                    scheduledFollowUps: s.scheduledFollowUps,
                    parentSessionId: s.parentSessionId
                )
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    @MainActor
    public func fetchNeedsAttention() async -> [NotificationEvent] {
        guard let request = makeRequest(path: "/sessions/needs-attention") else { return [] }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(NeedsAttentionResponse.self, from: data)
            self.lastPolledAt = response.serverTime
            return response.events
        } catch {
            clientLogger.debug("needs-attention failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch the latest live Claude + Codex usage gauges from the Mac.
    /// The daemon serves whatever its in-process pollers have — so the
    /// iPhone sees the same numbers the Mac dashboard does, no iCloud
    /// dependency. Returns nil for any failure path; callers fall back
    /// to iCloud KV (when available) or empty state.
    public func fetchUsage() async -> UsageEnvelope? {
        guard let request = makeRequest(path: "/usage") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageEnvelope.self, from: data)
        } catch {
            clientLogger.debug("usage fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch the historical token-analytics snapshot from the Mac. Same
    /// shape the iCloud-KV mirror used to ship; this is the no-iCloud
    /// path. Polled every 60s while the Analytics tab is active.
    public func fetchAnalytics() async -> UsageHistorySnapshot? {
        guard let request = makeRequest(path: "/analytics") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageHistorySnapshot.self, from: data)
        } catch {
            clientLogger.debug("analytics fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch the parsed chat transcript for a JSONL at `path`. Used by
    /// the iOS session detail screens so they can render the actual
    /// conversation instead of a useless "Read-only · JSONL path · Last
    /// write" stub. The Mac daemon parses the JSONL with the same
    /// pipeline `SessionChatStore` uses live, so the rendered messages
    /// match what the Mac shows.
    public func fetchTranscript(path: String, limit: Int = 500) async -> TranscriptEnvelope? {
        guard var components = URLComponents(string: "/transcript") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        guard let query = components.url?.absoluteString,
              let request = makeRequest(path: query)
        else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                clientLogger.warning("transcript fetch HTTP \(http.statusCode) for \(path)")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TranscriptEnvelope.self, from: data)
        } catch {
            clientLogger.warning("transcript fetch failed for \(path): \(error.localizedDescription)")
            return nil
        }
    }
}

private extension Int {
    func nonZeroOrDefault(_ defaultValue: Int) -> Int { self == 0 ? defaultValue : self }
}
