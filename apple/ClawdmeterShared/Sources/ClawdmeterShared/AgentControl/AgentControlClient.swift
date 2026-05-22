import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import OSLog

private let clientLogger = Logger(subsystem: "com.clawdmeter.client", category: "AgentControlClient")

/// HTTP + WS client for the Mac daemon. Lives in `ClawdmeterShared` so
/// both the iOS app (UserDefaults-backed pairing) AND the Mac app's
/// loopback client (explicit-arg config) can use the same class.
///
/// Two construction modes:
///
/// 1. **UserDefaults-backed** (existing iOS pairing flow): `AgentControlClient()`
///    reads host / ports / token from UserDefaults. `setPairing(...)` writes
///    them. This is the path the iOS app + iOSNotificationManager have always
///    used.
/// 2. **In-process explicit** (new in PR #24a for Mac loopback):
///    `AgentControlClient(host:httpPort:wsPort:token:)` holds the four
///    values in-memory for this instance only — does NOT read or write
///    UserDefaults. Mac's `MacLoopbackClient` uses this so localhost
///    config doesn't collide with the iOS pairing keys.
///
/// The pairing properties (`host`, `httpPort`, `wsPort`, `token`) check
/// the instance override first and fall back to UserDefaults so the
/// existing iOS code path keeps working unchanged.
public final class AgentControlClient: ObservableObject {

    public static let hostKey = "clawdmeter.sessions.macHost"
    public static let httpPortKey = "clawdmeter.sessions.httpPort"
    public static let wsPortKey = "clawdmeter.sessions.wsPort"
    public static let tokenKey = "clawdmeter.sessions.token"
    /// v0.14.0 (plan v2.1): TCP port on the paired Mac that fronts the
    /// Open Design daemon for iOS. DesignPortForwarder probes from 21732.
    public static let designPortKey = "clawdmeter.sessions.designPort"
    /// v0.14.0 (plan v2.1 T19): per-pairing HKDF-derived design credential.
    /// Stable across daemon restarts; tied to PairingTokenStore lifecycle.
    public static let designTokenKey = "clawdmeter.sessions.designToken"

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

    /// Instance-level overrides for pairing config. Set by the
    /// explicit-arg init; nil for the UserDefaults-backed path. The
    /// computed properties below check these first.
    private let hostOverride: String?
    private let httpPortOverride: Int?
    private let wsPortOverride: Int?
    private let tokenOverride: String?

    /// UserDefaults-backed init — the existing iOS path. Reads pairing
    /// from `UserDefaults.standard`. `setPairing(...)` writes those keys.
    public init() {
        self.hostOverride = nil
        self.httpPortOverride = nil
        self.wsPortOverride = nil
        self.tokenOverride = nil
        self.isConfigured = (UserDefaults.standard.string(forKey: Self.hostKey) != nil
                             && UserDefaults.standard.string(forKey: Self.tokenKey) != nil)
    }

    /// Explicit-config init for in-process clients (Mac loopback). Does
    /// NOT touch UserDefaults — pairing values are held in-memory for
    /// this instance only. `setPairing(...)` is a no-op on instances
    /// constructed this way.
    public init(host: String, httpPort: Int, wsPort: Int, token: String) {
        self.hostOverride = host
        self.httpPortOverride = httpPort
        self.wsPortOverride = wsPort
        self.tokenOverride = token
        self.isConfigured = true
    }

    /// True when this instance was constructed with explicit pairing
    /// values (Mac loopback). Used by `setPairing` / `clearPairing` to
    /// no-op on in-process instances rather than corrupt their in-memory
    /// config.
    private var isExplicitConfig: Bool {
        hostOverride != nil || tokenOverride != nil
    }

    // MARK: - Config

    public var host: String? {
        hostOverride ?? UserDefaults.standard.string(forKey: Self.hostKey)
    }
    public var httpPort: Int {
        httpPortOverride ?? UserDefaults.standard.integer(forKey: Self.httpPortKey).nonZeroOrDefault(21731)
    }
    public var wsPort: Int {
        wsPortOverride ?? UserDefaults.standard.integer(forKey: Self.wsPortKey).nonZeroOrDefault(21732)
    }
    public var token: String? {
        tokenOverride ?? UserDefaults.standard.string(forKey: Self.tokenKey)
    }
    public var designPort: Int {
        UserDefaults.standard.integer(forKey: Self.designPortKey).nonZeroOrDefault(21732)
    }
    public var designToken: String? {
        UserDefaults.standard.string(forKey: Self.designTokenKey)
    }

    public func setPairing(host: String, httpPort: Int, wsPort: Int, token: String) {
        // Mac loopback instances built with the explicit-arg init are
        // immutable — their config came from the local server bootstrap
        // (PR #24a Step 3) and writing to UserDefaults would corrupt the
        // iOS pairing keys that live in the same .plist.
        guard !isExplicitConfig else {
            clientLogger.warning("setPairing called on explicit-config instance — ignored to preserve in-memory loopback config")
            return
        }
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        UserDefaults.standard.set(httpPort, forKey: Self.httpPortKey)
        UserDefaults.standard.set(wsPort, forKey: Self.wsPortKey)
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        DispatchQueue.main.async {
            self.isConfigured = true
        }
    }

    /// v0.14.0 (plan v2.1): set the Design-tab pairing values discovered
    /// from the QR payload. Separate method so callers that don't know
    /// about Design routing don't have to change.
    public func setDesignPairing(designPort: Int, designToken: String) {
        guard !isExplicitConfig else { return }
        UserDefaults.standard.set(designPort, forKey: Self.designPortKey)
        UserDefaults.standard.set(designToken, forKey: Self.designTokenKey)
    }

    public func clearPairing() {
        guard !isExplicitConfig else {
            clientLogger.warning("clearPairing called on explicit-config instance — ignored")
            return
        }
        for key in [Self.hostKey, Self.httpPortKey, Self.wsPortKey, Self.tokenKey, Self.designPortKey, Self.designTokenKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        DispatchQueue.main.async {
            self.isConfigured = false
        }
    }

    // MARK: - REST

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let host, let token else { return nil }
        guard let url = URL(string: "http://\(Self.urlHostLiteral(host)):\(httpPort)\(path)") else { return nil }
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

    /// Wrap raw IPv6 literals in brackets so `URL(string:)` parses the
    /// authority correctly. RFC 3986 requires `[fd7a:...]:port` form, but
    /// the Tailscale `tailscale ip -6` output and the pairing URL's
    /// `url.host` field are both unbracketed. Hostnames and IPv4 are
    /// returned untouched.
    public static func urlHostLiteral(_ host: String) -> String {
        if host.hasPrefix("[") { return host }
        if host.contains(":") { return "[\(host)]" }
        return host
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

    /// True when the paired Mac is running a wire version too old for the
    /// minimum iOS feature surface. Forward-compat: any server at or above
    /// `composeDraftMinimum` is compatible — per-feature flags below handle
    /// the rest (e.g. `supportsGemini`, `supportsChatSubscribe`). Newer
    /// servers (e.g. v7 ↔ v6 client) work fine; the client just won't see
    /// features it doesn't know about. Implementation routed through the
    /// shared `AgentControlWireVersion.hasMismatch(...)` helper so the
    /// `WireMixedVersionPairingTests` suite asserts the exact logic the
    /// iOS client uses.
    @MainActor
    public var hasWireVersionMismatch: Bool {
        AgentControlWireVersion.hasMismatch(serverWireVersion: serverWireVersion)
    }

    @MainActor
    public var supportsGemini: Bool {
        AgentControlWireVersion.supportsGemini(serverWireVersion: serverWireVersion)
    }

    @MainActor
    public var supportsChatSubscribe: Bool {
        AgentControlWireVersion.supportsChatSubscribe(serverWireVersion: serverWireVersion)
    }

    @MainActor
    public var supportsComposeDraft: Bool {
        AgentControlWireVersion.supportsComposeDraft(serverWireVersion: serverWireVersion)
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
    @discardableResult
    public func sendPrompt(sessionId: UUID, text: String, asFollowUp: Bool = true) async -> Bool {
        let ok = await postBody(
            path: "/sessions/\(sessionId.uuidString)/send",
            body: SendPromptRequest(text: text, asFollowUp: asFollowUp)
        )
        if ok {
            await refreshSessions()
        }
        return ok
    }

    /// v0.8 QA F5: answer a CLI permission prompt (e.g. Codex's "Trust
    /// this directory?"). The daemon dispatches the key sequence
    /// corresponding to `optionId` and clears the published prompt on
    /// the session's store. iOS UI calls this from whichever permission-
    /// prompt surface is active for the current chat (the legacy
    /// `iOSPermissionPromptCard` was retired in v0.11 along with
    /// `iOSChatSoloView`; the Tahoe IOSChatView will host the replacement
    /// inline when permission prompts ship).
    public func respondToPermissionPrompt(sessionId: UUID, promptId: String, optionId: String) async {
        await postBody(
            path: "/sessions/\(sessionId.uuidString)/permission-respond",
            body: PermissionRespondRequest(promptId: promptId, optionId: optionId)
        )
    }

    /// Upload raw image bytes to the daemon's per-session staging dir.
    /// The Mac writes them to `~/Library/Application Support/Clawdmeter/
    /// attachments/<sessionId>/<uuid>.<ext>` (or the Codex worktree's
    /// sandbox dir when applicable) and returns the absolute path. The
    /// caller is responsible for prepending `@<path>` to the eventual
    /// `sendPrompt` body so the agent's Read tool resolves the file.
    ///
    /// `ext` is the file extension WITHOUT the dot (`"png"`, `"jpg"`).
    /// Cap is 50MB at the daemon's body-parser layer.
    @MainActor
    public func uploadAttachment(
        sessionId: UUID,
        ext: String,
        data: Data
    ) async -> String? {
        let safeExt = ext.filter { $0.isLetter || $0.isNumber }
        let path = "/sessions/\(sessionId.uuidString)/attachments?ext=\(safeExt)"
        guard var request = makeRequest(path: path, method: "POST", body: data) else {
            return nil
        }
        // The daemon doesn't care about Content-Type for this endpoint
        // (filename ext is what drives the on-disk name), but set it
        // anyway for honest semantics + future-proofing.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        do {
            let result = try await sendChecked(request)
            let decoder = JSONDecoder()
            let resp = try decoder.decode(UploadAttachmentResponse.self, from: result)
            return resp.path
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// Promote a Recent (outside-Clawdmeter) JSONL into a live live
    /// session and optionally post a first prompt. Mirrors the Mac's
    /// `SessionsModel.continueCurrentReadOnly` over the wire so iOS can
    /// initiate the same flow without being on the Mac. Returns the new
    /// live session id, or nil on failure (no CLI session id in the
    /// JSONL header, network error, agent CLI missing).
    @MainActor
    public func continueReadOnly(
        jsonlPath: String,
        repoKey: String,
        agent: AgentKind,
        prompt: String? = nil
    ) async -> UUID? {
        let body = ContinueReadOnlyRequest(
            jsonlPath: jsonlPath,
            repoKey: repoKey,
            agent: agent,
            prompt: prompt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let bodyData = try? encoder.encode(body),
              let request = makeRequest(path: "/sessions/continue-readonly", method: "POST", body: bodyData) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(ContinueReadOnlyResponse.self, from: data)
            return response.sessionId
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
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

    /// D4 (v0.17, wire v12): toggle the Mac's per-provider auto-revive
    /// state from iOS. The Mac daemon fans the call out to the matching
    /// `AppModel.setAutoReviveEnabled` via `setAutoReviveCallback`.
    /// `.unknown` is intentionally not supported (the X3 forward-compat
    /// sentinel — the iOS Live tab never renders an auto-revive toggle
    /// for unknown providers).
    @MainActor
    public func setAutoRevive(provider: AgentKind, enabled: Bool) async {
        guard provider != .unknown else { return }
        await postBody(path: "/providers/\(provider.rawValue)/auto-revive",
                        body: SetAutoReviveRequest(enabled: enabled))
    }

    /// v0.5.4: set or clear the session's user-facing display name. The
    /// daemon normalizes empty/whitespace-only strings to nil. Pass nil
    /// to clear and fall back to `repoDisplayName`.
    @MainActor
    public func renameSession(sessionId: UUID, name: String?) async {
        await postBody(path: "/sessions/\(sessionId.uuidString)/rename",
                        body: RenameSessionRequest(name: name))
        // Refresh the sessions list so the renamed entry shows up with
        // the new label everywhere the iPhone UI reads `displayLabel`.
        await refreshSessions()
    }

    /// v0.5.10: rename a Recent JSONL row (not a Clawdmeter-owned session).
    /// Keyed by absolute path on the daemon side, persisted to
    /// `~/.clawdmeter/jsonl-aliases.json`. Pass nil/empty to clear.
    @MainActor
    public func renameJSONLAlias(path: String, name: String?) async {
        await postBody(path: "/jsonl-aliases/rename",
                        body: RenameJSONLRequest(path: path, name: name))
        // Repo index refresh on the daemon side is fire-and-forget; the
        // next sessions-list poll picks up the new customName.
        await refreshSessions()
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

    /// Persist a user-facing terminal tab title on the Mac daemon and return
    /// the updated pane ref. Empty titles are normalized server-side.
    @MainActor
    public func renameTerminal(sessionId: UUID, terminalRefId: UUID, title: String) async -> TerminalPaneRef? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: ["title": title]) else { return nil }
        guard let request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/terminals/\(terminalRefId.uuidString)",
            method: "PATCH",
            body: bodyData
        ) else { return nil }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let pane = try decoder.decode(TerminalPaneRef.self, from: data)
            await refreshSessions()
            return pane
        } catch {
            self.lastError = error.localizedDescription
            clientLogger.debug("renameTerminal failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch full diff hunks for a single file. The list endpoint can return
    /// truncated rows for compact UI; this route asks the daemon for the
    /// selected path with explicit context.
    @MainActor
    public func fetchDiffFile(sessionId: UUID, path: String, context: Int = 80) async -> GitDiffFile? {
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "/?#")
                return String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
        guard let request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/diff/\(encodedPath)?context=\(context)"
        ) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GitDiffFile.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            clientLogger.debug("fetchDiffFile failed: \(error.localizedDescription)")
            return nil
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
    @discardableResult
    private func postBody<T: Encodable>(path: String, body: T) async -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let bodyData = try? encoder.encode(body),
              let request = makeRequest(path: path, method: "POST", body: bodyData) else {
            return false
        }
        do {
            _ = try await sendChecked(request)
            self.lastError = nil
            return true
        } catch {
            self.lastError = error.localizedDescription
            return false
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
            self.lastError = nil
            // Sessions v2 Phase 10: keep the aggregate Live Activity +
            // watch bridge in sync. These live in the iOS app target
            // (LiveActivityCoordinator, WatchPlanBridgeIOS) and can't be
            // referenced from Shared. Post a notification instead; the
            // iOS-app-side observer handles the bridging.
            NotificationCenter.default.post(
                name: .agentControlSessionsRefreshed,
                object: self,
                userInfo: ["sessions": sessions]
            )
        } catch {
            self.lastError = error.localizedDescription
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
            await refreshSessions()
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

    // MARK: - v0.8 Chat tab

    /// `POST /chat-sessions` — spawn a new chat-kind AgentSession. Gemini
    /// returns 501 in v0.8 (deferred to v0.9 alongside Antigravity-via-agy);
    /// the daemon error surfaces through `lastError` and `nil` return.
    @MainActor
    public func createChatSession(
        provider: AgentKind,
        model: String? = nil,
        codexBackend: CodexChatBackend? = nil,
        effort: ReasoningEffort? = nil
    ) async -> AgentSession? {
        let req = CreateChatSessionRequest(
            provider: provider,
            model: model,
            effort: effort,
            codexChatBackend: codexBackend
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(path: "/chat-sessions", method: "POST", body: body) else {
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

    /// `POST /chat-providers/refresh` — invalidate the Mac probe cache and
    /// return the fresh provider capability matrix.
    @MainActor
    public func refreshChatProviders() async -> ChatProvidersResponse? {
        guard let request = makeRequest(path: "/chat-providers/refresh", method: "POST") else { return nil }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatProvidersResponse.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// `GET /chat-providers` — capability matrix (per provider + Codex
    /// backend sub-rows). Used by the Chat sidebar to gray disabled rows.
    @MainActor
    public func fetchChatProviders() async -> ChatProvidersResponse? {
        guard let request = makeRequest(path: "/chat-providers", method: "GET") else { return nil }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatProvidersResponse.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// Subset of `sessions` filtered to chat sessions (kind=.chat). Used
    /// by the Chat tab sidebar; the Code tab uses the inverse filter.
    public var chatSessions: [AgentSession] {
        sessions.filter { $0.kind == .chat && $0.archivedAt == nil }
    }

    // MARK: - v0.9.x Frontier compare

    /// `POST /chat-sessions/frontier` — spawn a Frontier group with 2-3
    /// model slots. Per-slot results (E2 partial); CM5 idempotency via
    /// `clientRequestId`. Returns nil on transport / decode error.
    @MainActor
    public func createFrontier(
        clientRequestId: UUID = UUID(),
        slots: [FrontierModelSlot]
    ) async -> CreateFrontierResponse? {
        let req = CreateFrontierRequest(clientRequestId: clientRequestId, models: slots)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(path: "/chat-sessions/frontier", method: "POST", body: body) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(CreateFrontierResponse.self, from: data)
            await refreshSessions()
            return response
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// `POST /chat-sessions/frontier/:groupId/send` — fan out a prompt
    /// to every child. Returns true on 2xx, false on transport error.
    @MainActor
    public func frontierSend(groupId: UUID, text: String) async -> Bool {
        let req = SendPromptRequest(text: text, asFollowUp: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(path: "/chat-sessions/frontier/\(groupId.uuidString)/send", method: "POST", body: body) else {
            return false
        }
        do {
            _ = try await sendChecked(request)
            await refreshSessions()
            return true
        } catch {
            self.lastError = error.localizedDescription
            return false
        }
    }

    /// `POST /chat-sessions/frontier/:groupId/pick-winner` — archive
    /// losers, return the winner.
    @MainActor
    public func frontierPickWinner(groupId: UUID, childIndex: Int) async -> AgentSession? {
        let req = PickFrontierWinnerRequest(childIndex: childIndex)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(path: "/chat-sessions/frontier/\(groupId.uuidString)/pick-winner", method: "POST", body: body) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(AgentSession.self, from: data)
            await refreshSessions()
            return session
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// Children of a Frontier group, sorted by childIndex. Filters
    /// archived children so the active-only Frontier UI sees only the
    /// live panes.
    public func frontierChildren(groupId: UUID) -> [AgentSession] {
        sessions
            .filter { $0.frontierGroupId == groupId && $0.archivedAt == nil }
            .sorted { ($0.frontierChildIndex ?? Int.max) < ($1.frontierChildIndex ?? Int.max) }
    }

    /// All live Frontier group IDs from current sessions. Used by the
    /// "Royal Frontier" sidebar inbox entry on iOS.
    public var liveFrontierGroupIds: [UUID] {
        let ids = sessions.compactMap { (s: AgentSession) -> UUID? in
            guard s.archivedAt == nil else { return nil }
            return s.frontierGroupId
        }
        return Array(Set(ids))
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

    public func ackNotifications(through ackId: UInt64) async {
        let body = AckNotificationsRequest(ackId: ackId)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(body),
              let request = makeRequest(path: "/devices/ack-notifications", method: "POST", body: data) else { return }
        do {
            _ = try await sendChecked(request)
        } catch {
            clientLogger.debug("ack notifications failed: \(error.localizedDescription)")
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

    /// Outcome of an X1 compose-draft post. Lets the caller surface the
    /// right UX (toast vs upgrade-Mac prompt vs silent success).
    public enum ComposeDraftResult: Equatable {
        case delivered
        /// v0.7.2 wire v8: delivered + the Mac executed a Codex SDK
        /// resume on the attached threadId. `finalResponse` contains
        /// the agent's response text the iOS UI can render inline.
        case deliveredWithCodexResume(threadId: String, finalResponse: String)
        /// Mac is too old to understand `compose-draft`. The user should
        /// see an "Update your Mac for Open-on-Mac" affordance.
        case macUnsupported(serverWireVersion: Int)
        /// Daemon unreachable or refused (peer/auth/policy).
        case failed(message: String)
    }

    /// X1 cross-Apple handoff: post a compose draft to the paired Mac via
    /// a short-lived WebSocket using op `compose-draft`. The Mac's empty-
    /// state composer listens via NotificationCenter and pre-fills its
    /// text + chip suggestions. We wait for the daemon's 1-byte ACK before
    /// cancelling (no more 200ms-sleep race — review §10 finding).
    @MainActor
    @discardableResult
    public func postComposeDraft(_ draft: ComposeDraft) async -> ComposeDraftResult {
        guard let host, let token else { return .failed(message: "Not paired with a Mac.") }
        // Wire-version gate: older Macs would reject the unknown op via
        // `.unsupportedData` close and the user would get zero feedback.
        // We require a /health refresh to have populated serverWireVersion;
        // if it's missing or too low, fail fast with a recoverable result.
        if let serverWire = serverWireVersion, serverWire < AgentControlWireVersion.composeDraftMinimum {
            return .macUnsupported(serverWireVersion: serverWire)
        }
        guard let url = URL(string: "ws://\(Self.urlHostLiteral(host)):\(wsPort)/") else {
            return .failed(message: "Bad daemon URL.")
        }
        let task = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: 8))
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let envelope: [String: Any] = [
            "op": "compose-draft",
            "token": token,
            "draft": draft.encodedJSONObject()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return .failed(message: "Couldn't encode draft.")
        }
        do {
            try await task.send(.data(data))
            // v0.7.2: if the draft included `codexThreadId`, the Mac
            // dispatches to CodexSDKManager.runResume() and sends a
            // structured `codex_resume_result` (or `codex_resume_error`)
            // frame BEFORE the standard `ok` ACK. We may need to read up
            // to two frames: the optional resume result, then "ok".
            // Timeout extended to 130s to cover the SDK's 120s resume
            // ceiling + a few seconds of network slack.
            let timeoutSec: UInt64 = draft.codexThreadId == nil ? 5 : 130
            var codexResume: (threadId: String, finalResponse: String)?
            for _ in 0..<2 {
                let frame: URLSessionWebSocketTask.Message
                do {
                    frame = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                        group.addTask { try await task.receive() }
                        group.addTask {
                            try await Task.sleep(nanoseconds: timeoutSec * 1_000_000_000)
                            throw URLError(.timedOut)
                        }
                        guard let first = try await group.next() else {
                            group.cancelAll()
                            throw URLError(.cancelled)
                        }
                        group.cancelAll()
                        return first
                    }
                } catch {
                    clientLogger.warning("compose-draft ACK wait failed: \(error.localizedDescription)")
                    return .failed(message: "Mac didn't acknowledge the draft within \(timeoutSec)s.")
                }

                // Try the structured result first.
                if case let .string(s) = frame {
                    if s == "ok" {
                        if let resume = codexResume {
                            return .deliveredWithCodexResume(
                                threadId: resume.threadId,
                                finalResponse: resume.finalResponse
                            )
                        }
                        return .delivered
                    }
                    // Inspect for codex_resume_result / codex_resume_error.
                    if let data = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let type = obj["type"] as? String, type == "codex_resume_result",
                           let tid = obj["threadId"] as? String,
                           let body = obj["finalResponse"] as? String {
                            codexResume = (threadId: tid, finalResponse: body)
                            continue
                        }
                        if let type = obj["type"] as? String, type == "codex_resume_error",
                           let msg = obj["msg"] as? String {
                            clientLogger.warning("compose-draft codex resume failed on Mac: \(msg)")
                            // Still treat the underlying draft as delivered;
                            // surface the resume failure via the result.
                            // For now we fold into `.failed` since the iOS
                            // caller probably wanted the resume to work.
                            return .failed(message: "Mac couldn't resume the Codex thread: \(msg)")
                        }
                    }
                }
                if case let .data(d) = frame, d == Data("ok".utf8) {
                    if let resume = codexResume {
                        return .deliveredWithCodexResume(
                            threadId: resume.threadId,
                            finalResponse: resume.finalResponse
                        )
                    }
                    return .delivered
                }
                // Unknown frame — keep loop alive for one more receive.
            }
            return .failed(message: "Mac sent an unexpected sequence of frames.")
        } catch {
            clientLogger.warning("compose-draft post failed: \(error.localizedDescription)")
            return .failed(message: error.localizedDescription)
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

public extension Notification.Name {
    /// Posted by `AgentControlClient.refreshSessions()` after the
    /// `sessions` array is updated. `userInfo["sessions"]` holds the new
    /// `[AgentSession]`. The iOS app target observes this to drive
    /// LiveActivityCoordinator + WatchPlanBridgeIOS (which live in the iOS
    /// app target and can't be referenced from Shared). The Mac app
    /// ignores the notification — Live Activities and watch bridging are
    /// iPhone-only surfaces.
    static let agentControlSessionsRefreshed = Notification.Name("clawdmeter.agentControl.sessionsRefreshed")
}
