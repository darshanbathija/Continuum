import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(OSLog)
import OSLog
#endif

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
    // v0.27.0: designPortKey / designTokenKey UserDefaults keys removed
    // along with the Design tab + DesignPortForwarder.

    @Published public private(set) var isConfigured: Bool = false
    @Published public private(set) var repos: [AgentRepo] = []
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var workspaces: [CodeWorkspaceRecord] = []
    @Published public private(set) var lastPolledAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isDesktopEventSyncConnected: Bool = false
    @Published public private(set) var desktopEventSyncLastEventAt: Date?
    @Published public private(set) var desktopEventSyncLastError: String?
    @Published public private(set) var desktopEventSyncLastSeq: UInt64 = 0
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
    private var desktopEventSyncTask: Task<Void, Never>?
    private var desktopEventResyncTask: Task<Void, Never>?

    #if DEBUG
    public static let codeTabVerificationSessionId = UUID(uuidString: "8D70F169-9D3A-45C8-9F7F-04E02E55A201")!
    private var codeTabVerificationFixtureInstalled: Bool = false
    private var codeTabVerificationSnapshots: [UUID: WireChatSnapshot] = [:]
    private var codeTabVerificationDiffs: [UUID: [GitDiffFile]] = [:]
    private var codeTabVerificationPRs: [UUID: PRStatus] = [:]
    #endif

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

    #if DEBUG
    /// Launch-argument-only fixture used by screenshot verification. It seeds
    /// the same public client/session/chat/diff/PR DTOs that production panes
    /// consume, so design screenshots exercise shipped view paths instead of
    /// a parallel demo renderer.
    public convenience init(codeTabVerificationFixture: Bool) {
        self.init()
        if codeTabVerificationFixture {
            installCodeTabVerificationFixture()
        }
    }
    #endif

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

    deinit {
        desktopEventSyncTask?.cancel()
        desktopEventResyncTask?.cancel()
    }

    #if DEBUG
    public func installCodeTabVerificationFixture(now: Date = Date()) {
        let sessionId = Self.codeTabVerificationSessionId
        let repoKey = "/Users/darshanbathija/workspaces/defx-frontend"
        let worktreePath = "\(repoKey)/.claude/worktrees/settlement-dedupe"
        let planText = """
        1. Replace settlement dedupe with an atomic insert path.
        2. Add a unique index on `settlements.fill_id`.
        3. Lift cache invalidation to daemon scope.
        4. Add a 200-writer regression test.
        5. Run the settlement-store smoke gate.
        """
        let primary = AgentSession(
            id: sessionId,
            repoKey: repoKey,
            repoDisplayName: "defx-frontend",
            agent: .claude,
            model: "Sonnet 4.5",
            goal: "Refactor settlement store dedupe",
            worktreePath: worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .planning,
            planText: planText,
            createdAt: now.addingTimeInterval(-24 * 60),
            lastEventAt: now.addingTimeInterval(-90),
            lastEventSeq: 84,
            mode: .worktree,
            runtimeCwd: worktreePath,
            chatCwd: repoKey,
            effort: .high,
            customName: "Settlement store dedupe"
        )
        let running = AgentSession(
            id: UUID(uuidString: "32E0D70B-2C91-445D-9B49-56A6243403E8")!,
            repoKey: repoKey,
            repoDisplayName: "defx-frontend",
            agent: .codex,
            model: "gpt-5",
            goal: "Wire WS reconnect backoff",
            worktreePath: "\(repoKey)/.codex/worktrees/ws-reconnect",
            tmuxWindowId: "@18",
            tmuxPaneId: "%27",
            status: .running,
            planText: nil,
            createdAt: now.addingTimeInterval(-42 * 60),
            lastEventAt: now.addingTimeInterval(-25),
            lastEventSeq: 53,
            mode: .worktree,
            runtimeCwd: "\(repoKey)/.codex/worktrees/ws-reconnect",
            chatCwd: repoKey,
            effort: .xhigh,
            customName: "WS reconnect backoff"
        )
        let archived = AgentSession(
            id: UUID(uuidString: "B283B3D3-7CF7-4DAB-9B66-A51AFD98D688")!,
            repoKey: repoKey,
            repoDisplayName: "defx-frontend",
            agent: .gemini,
            model: "antigravity-pro",
            goal: "Review order book reconciliation",
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .done,
            planText: nil,
            createdAt: now.addingTimeInterval(-3 * 60 * 60),
            lastEventAt: now.addingTimeInterval(-58 * 60),
            lastEventSeq: 41,
            mode: .local,
            archivedAt: now.addingTimeInterval(-45 * 60),
            customName: "Order book reconciliation"
        )

        self.isConfigured = true
        self.sessions = [primary, running, archived]
        self.lastPolledAt = now
        self.lastError = nil
        self.codeTabVerificationFixtureInstalled = true
        self.codeTabVerificationSnapshots = [sessionId: Self.makeCodeTabVerificationSnapshot(sessionId: sessionId, now: now)]
        self.codeTabVerificationDiffs = [sessionId: Self.makeCodeTabVerificationDiff()]
        self.codeTabVerificationPRs = [sessionId: Self.makeCodeTabVerificationPR()]
    }

    public func codeTabVerificationChatSnapshot(sessionId: UUID) -> WireChatSnapshot? {
        guard codeTabVerificationFixtureInstalled else { return nil }
        return codeTabVerificationSnapshots[sessionId]
    }

    public func codeTabVerificationDiff(sessionId: UUID) -> [GitDiffFile]? {
        guard codeTabVerificationFixtureInstalled else { return nil }
        return codeTabVerificationDiffs[sessionId]
    }

    public func codeTabVerificationDiffFile(sessionId: UUID, path: String) -> GitDiffFile? {
        guard codeTabVerificationFixtureInstalled else { return nil }
        return codeTabVerificationDiffs[sessionId]?.first { $0.path == path }
    }

    public func codeTabVerificationPRStatus(sessionId: UUID) -> PRStatus? {
        guard codeTabVerificationFixtureInstalled else { return nil }
        return codeTabVerificationPRs[sessionId]
    }

    private static func makeCodeTabVerificationSnapshot(sessionId: UUID, now: Date) -> WireChatSnapshot {
        let toolCall = ChatMessage(
            id: "tool-call-test",
            kind: .toolCall,
            title: "bash",
            body: "Run settlement store regression tests",
            detail: "pnpm test settlement-store",
            at: now.addingTimeInterval(-260),
            bashResult: BashResult(command: "pnpm test settlement-store", cwd: "/Users/darshanbathija/workspaces/defx-frontend")
        )
        let toolResult = ChatMessage(
            id: "tool-result-test",
            kind: .toolResult,
            title: "bash",
            body: "12 passed in 1.8s\nsettlement-store.test.ts completed",
            at: now.addingTimeInterval(-248)
        )
        let diffCall = ChatMessage(
            id: "tool-call-diff",
            kind: .toolCall,
            title: "bash",
            body: "Inspect changed files",
            detail: "git diff --stat",
            at: now.addingTimeInterval(-180),
            bashResult: BashResult(command: "git diff --stat", cwd: "/Users/darshanbathija/workspaces/defx-frontend")
        )
        let diffResult = ChatMessage(
            id: "tool-result-diff",
            kind: .toolResult,
            title: "bash",
            body: "4 files changed, 182 insertions(+), 47 deletions(-)",
            at: now.addingTimeInterval(-174)
        )
        return WireChatSnapshot(
            sessionId: sessionId,
            items: [
                .message(ChatMessage(
                    id: "user-goal",
                    kind: .userText,
                    title: "You",
                    body: "Make settlement writes idempotent under concurrent fills.",
                    at: now.addingTimeInterval(-420)
                )),
                .message(ChatMessage(
                    id: "assistant-plan",
                    kind: .assistantText,
                    title: "Claude",
                    body: "I found the race in `writeSettlement`. The fix is a DB-backed uniqueness guarantee plus a narrower cache invalidation path.",
                    at: now.addingTimeInterval(-360)
                )),
                .toolRun(id: "test-run", pairs: [ToolPair(id: "test-run", call: toolCall, result: toolResult)]),
                .toolRun(id: "diff-run", pairs: [ToolPair(id: "diff-run", call: diffCall, result: diffResult)]),
                .message(ChatMessage(
                    id: "assistant-ready",
                    kind: .assistantText,
                    title: "Claude",
                    body: "Plan is ready for approval. CI and diff review are clean enough to proceed.",
                    at: now.addingTimeInterval(-100)
                ))
            ],
            planSteps: [
                PlanStep(id: "1", text: "Replace settlement dedupe with an atomic insert path.", isComplete: true),
                PlanStep(id: "2", text: "Add a unique index on settlements.fill_id.", isComplete: true),
                PlanStep(id: "3", text: "Lift cache invalidation to daemon scope.", isComplete: false),
                PlanStep(id: "4", text: "Add a 200-writer regression test.", isComplete: false),
                PlanStep(id: "5", text: "Run the settlement-store smoke gate.", isComplete: false)
            ],
            sourceEntries: [
                SourceEntry(
                    id: "f:settlement-store",
                    kind: .file,
                    label: "apps/web/src/lib/settlement-store.ts",
                    payload: "/Users/darshanbathija/workspaces/defx-frontend/apps/web/src/lib/settlement-store.ts",
                    count: 4
                ),
                SourceEntry(
                    id: "f:schema",
                    kind: .file,
                    label: "packages/db/schema.ts",
                    payload: "/Users/darshanbathija/workspaces/defx-frontend/packages/db/schema.ts",
                    count: 2
                ),
                SourceEntry(
                    id: "u:runbook",
                    kind: .url,
                    label: "github.com/defx/settlement-runbook",
                    payload: "https://github.com/defx/settlement-runbook",
                    count: 1
                )
            ],
            artifactEntries: [
                ArtifactEntry(path: "/Users/darshanbathija/workspaces/defx-frontend/.context/settlement-store.patch"),
                ArtifactEntry(path: "/Users/darshanbathija/workspaces/defx-frontend/.context/regression-output.txt"),
                ArtifactEntry(path: "/Users/darshanbathija/workspaces/defx-frontend/.context/pr-body.md")
            ],
            totalInputTokens: 18_420,
            totalOutputTokens: 6_184,
            cacheReadTokens: 9_202,
            cacheCreationTokens: 1_112,
            lastEventAt: now.addingTimeInterval(-90),
            updateCounter: 42,
            currentTurnState: .streaming
        )
    }

    private static func makeCodeTabVerificationDiff() -> [GitDiffFile] {
        [
            GitDiffFile(
                path: "apps/web/src/lib/settlement-store.ts",
                status: "M",
                additions: 88,
                deletions: 21,
                hunks: [
                    GitDiffHunk(header: "@@ -48,12 +48,18 @@", lines: [
                        .init(kind: .context, text: "export async function writeSettlement(fill: Fill) {"),
                        .init(kind: .deletion, text: "  if (cache.has(fill.id)) return"),
                        .init(kind: .addition, text: "  const inserted = await insertSettlementOnce(fill)"),
                        .init(kind: .addition, text: "  if (!inserted) return"),
                        .init(kind: .context, text: "  await invalidateSettlementCache(fill.accountId)")
                    ])
                ]
            ),
            GitDiffFile(
                path: "apps/web/src/lib/settlement-store.test.ts",
                status: "A",
                additions: 72,
                deletions: 0
            ),
            GitDiffFile(
                path: "packages/db/migrations/20260518_fill_id_unique.sql",
                status: "A",
                additions: 18,
                deletions: 0
            ),
            GitDiffFile(
                path: "apps/web/src/lib/cache.ts",
                status: "M",
                additions: 4,
                deletions: 26
            )
        ]
    }

    private static func makeCodeTabVerificationPR() -> PRStatus {
        PRStatus(
            url: "https://github.com/defx/defx-frontend/pull/184",
            number: 184,
            title: "fix: make settlement writes idempotent",
            body: "Adds DB-backed fill id uniqueness and narrows cache invalidation around concurrent settlement writes.",
            state: .open,
            additions: 182,
            deletions: 47,
            changedFiles: 4,
            reviewDecision: "approved",
            checksRollup: "success"
        )
    }
    #endif

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
    // v0.27.0: designPort + designToken accessors removed along with the
    // Design tab + DesignPortForwarder.

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

    // v0.27.0: setDesignPairing(...) removed along with the Design tab.

    public func clearPairing() {
        guard !isExplicitConfig else {
            clientLogger.warning("clearPairing called on explicit-config instance — ignored")
            return
        }
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
        let (data, response) = try await runRequest(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientHTTPError.badStatus(http.statusCode, http.value(forHTTPHeaderField: "Retry-After"))
        }
        return data
    }

    private func runRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        struct NetResult: Sendable {
            let data: Data
            let response: URLResponse
        }

        let result: NetResult = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: NetResult(data: data, response: response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
        return (result.data, result.response)
    }

    @MainActor
    public func refreshAll() async {
        await refreshHealth()
        await refreshRepos()
        await refreshSessions()
        if supportsWorkspaces {
            await refreshWorkspaces()
        }
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

    @MainActor
    public var supportsCursor: Bool {
        AgentControlWireVersion.supportsCursor(serverWireVersion: serverWireVersion)
    }

    @MainActor
    public var supportsWorkspaces: Bool {
        AgentControlWireVersion.supportsWorkspaces(serverWireVersion: serverWireVersion)
    }

    @MainActor
    public var supportsCodeWorkbenchRemote: Bool {
        AgentControlWireVersion.supportsCodeWorkbenchRemote(serverWireVersion: serverWireVersion)
    }

    @MainActor
    public var supportsAntigravityPlan: Bool {
        AgentControlWireVersion.supportsAntigravityPlan(serverWireVersion: serverWireVersion)
    }

    // MARK: - Desktop event sync

    /// Keep the iOS/macOS client mirror aligned with the paired Mac's live
    /// session registry. The daemon already exposes an `events` WebSocket
    /// with cursor replay; this loop consumes it and uses HTTP refreshes as
    /// the authoritative state repair path for incremental events.
    @MainActor
    public func startDesktopEventSync() {
        guard desktopEventSyncTask == nil else { return }
        desktopEventSyncTask = Task { [weak self] in
            await self?.runDesktopEventSyncLoop()
        }
    }

    @MainActor
    public func stopDesktopEventSync() {
        desktopEventSyncTask?.cancel()
        desktopEventSyncTask = nil
        desktopEventResyncTask?.cancel()
        desktopEventResyncTask = nil
        isDesktopEventSyncConnected = false
    }

    @MainActor
    private func runDesktopEventSyncLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            guard let host, let token else {
                isDesktopEventSyncConnected = false
                desktopEventSyncLastError = "Not paired with a Mac."
                await sleepDesktopEventSync(seconds: 5)
                continue
            }
            guard let url = URL(string: "ws://\(Self.urlHostLiteral(host)):\(wsPort)/") else {
                isDesktopEventSyncConnected = false
                desktopEventSyncLastError = "Bad daemon WebSocket URL."
                await sleepDesktopEventSync(seconds: 5)
                continue
            }

            do {
                try await runDesktopEventSocket(url: url, token: token)
                attempt = 0
            } catch is CancellationError {
                break
            } catch {
                attempt += 1
                isDesktopEventSyncConnected = false
                desktopEventSyncLastError = error.localizedDescription
                clientLogger.debug("desktop event sync dropped: \(error.localizedDescription)")
                await sleepDesktopEventSync(seconds: backoffDelay(forDesktopEventAttempt: attempt))
            }
        }
        isDesktopEventSyncConnected = false
    }

    @MainActor
    private func runDesktopEventSocket(url: URL, token: String) async throws {
        let task = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: 8))
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let envelope: [String: Any] = [
            "op": "events",
            "token": token,
            "since": desktopEventSyncLastSeq
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        try await task.send(.data(body))
        isDesktopEventSyncConnected = true
        desktopEventSyncLastError = nil

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let body):
                data = body
            case .string(let string):
                data = Data(string.utf8)
            @unknown default:
                continue
            }
            let event = try decoder.decode(AgentEvent.self, from: data)
            await applyDesktopSyncEvent(event, scheduleAuthoritativeRefresh: true)
        }
    }

    @MainActor
    internal func applyDesktopSyncEvent(
        _ event: AgentEvent,
        scheduleAuthoritativeRefresh: Bool
    ) async {
        desktopEventSyncLastSeq = max(desktopEventSyncLastSeq, event.eventSeq)
        desktopEventSyncLastEventAt = event.at
        switch event.kind {
        case .snapshot:
            guard let data = event.payload.data(using: .utf8) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let snapshot = try? decoder.decode(AgentEventSnapshot.self, from: data) else { return }
            desktopEventSyncLastSeq = max(desktopEventSyncLastSeq, snapshot.asOfSeq)
            publishSessions(snapshot.sessions)
            if supportsWorkspaces {
                await refreshWorkspaces()
            }
        case .sessionDeleted:
            sessions.removeAll { $0.id == event.sessionId }
            publishSessions(sessions)
            if scheduleAuthoritativeRefresh {
                scheduleDesktopEventAuthoritativeRefresh()
            }
        case .sessionCreated, .statusChanged, .planReady, .doneDetected, .paused, .tmuxServerLost, .tmuxServerRecovered:
            if scheduleAuthoritativeRefresh {
                scheduleDesktopEventAuthoritativeRefresh()
            }
        }
    }

    @MainActor
    private func scheduleDesktopEventAuthoritativeRefresh() {
        desktopEventResyncTask?.cancel()
        desktopEventResyncTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            await self?.refreshSessions()
            if self?.supportsWorkspaces == true {
                await self?.refreshWorkspaces()
            }
        }
    }

    @MainActor
    private func publishSessions(_ next: [AgentSession]) {
        sessions = next
        lastPolledAt = Date()
        lastError = nil
        NotificationCenter.default.post(
            name: .agentControlSessionsRefreshed,
            object: self,
            userInfo: ["sessions": sessions]
        )
    }

    private func sleepDesktopEventSync(seconds: TimeInterval) async {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            // Cancellation is the normal stop path.
        }
    }

    private func backoffDelay(forDesktopEventAttempt attempt: Int) -> TimeInterval {
        let base = min(30.0, pow(2.0, Double(max(0, attempt - 1))))
        return base + Double.random(in: 0...(base * 0.2))
    }

    // MARK: - Sessions v2 mid-session controls

    @MainActor
    @discardableResult
    public func changeModel(sessionId: UUID, request body: ChangeModelRequest) async -> AgentSession? {
        await postJSON(path: "/sessions/\(sessionId.uuidString)/model", body: body)
    }

    @MainActor
    @discardableResult
    public func changeEffort(
        sessionId: UUID,
        effort: ReasoningEffort,
        idempotencyKey: String? = nil
    ) async -> AgentSession? {
        await postJSON(
            path: "/sessions/\(sessionId.uuidString)/effort",
            body: ChangeEffortRequest(effort: effort, idempotencyKey: idempotencyKey)
        )
    }

    @MainActor
    @discardableResult
    public func changeMode(
        sessionId: UUID,
        mode: SessionMode,
        planMode: Bool? = nil,
        idempotencyKey: String? = nil
    ) async -> AgentSession? {
        await postJSON(
            path: "/sessions/\(sessionId.uuidString)/mode",
            body: ChangeModeRequest(mode: mode, planMode: planMode, idempotencyKey: idempotencyKey)
        )
    }

    @MainActor
    @discardableResult
    public func sendPrompt(
        sessionId: UUID,
        text: String,
        asFollowUp: Bool = true,
        idempotencyKey: String? = nil
    ) async -> Bool {
        let ok = await postBody(
            path: "/sessions/\(sessionId.uuidString)/send",
            body: SendPromptRequest(text: text, asFollowUp: asFollowUp, idempotencyKey: idempotencyKey)
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
    @discardableResult
    public func interruptSession(sessionId: UUID, idempotencyKey: String? = nil) async -> Bool {
        // v16 outbox: optional key. nil keeps the legacy empty-body POST.
        // Returns true on HTTP 2xx so the outbox can detect offline
        // failures and reschedule retries. Legacy fire-and-forget callers
        // discard the return via @discardableResult.
        if let key = idempotencyKey {
            return await postBody(
                path: "/sessions/\(sessionId.uuidString)/interrupt",
                body: InterruptRequest(idempotencyKey: key)
            )
        } else {
            return await postEmpty(path: "/sessions/\(sessionId.uuidString)/interrupt")
        }
    }

    @MainActor
    @discardableResult
    public func setAutopilot(sessionId: UUID, enabled: Bool, idempotencyKey: String? = nil) async -> Bool {
        return await postBody(
            path: "/sessions/\(sessionId.uuidString)/autopilot",
            body: AutopilotRequest(enabled: enabled, idempotencyKey: idempotencyKey)
        )
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
        #if DEBUG
        if let fixture = codeTabVerificationDiffFile(sessionId: sessionId, path: path) {
            return fixture
        }
        #endif
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

    @MainActor
    public func fetchAntigravityPlan(sessionId: UUID) async throws -> AntigravityPlanSnapshot {
        guard let request = makeRequest(path: "/sessions/\(sessionId.uuidString)/antigravity-plan") else {
            throw ArtifactError.notPaired
        }
        let data = try await sendChecked(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AntigravityPlanSnapshot.self, from: data)
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
        let (data, response) = try await runRequest(req)
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
            let (data, response) = try await runRequest(request)
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
    @discardableResult
    private func postEmpty(path: String) async -> Bool {
        guard let request = makeRequest(path: path, method: "POST") else { return false }
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
            publishSessions(try decoder.decode([AgentSession].self, from: data))
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
        effort: ReasoningEffort? = nil,
        deepResearch: Bool = false
    ) async -> AgentSession? {
        let req = CreateChatSessionRequest(
            provider: provider,
            model: model,
            effort: effort,
            codexChatBackend: codexBackend,
            deepResearch: deepResearch
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

    /// v0.23 (Chat V2 wire v14): `GET /chat-sessions/search?q=<query>`
    /// — full-history substring scan across the daemon's known chat
    /// JSONLs. Bounded by a 200ms hard timeout + 50-result cap server-
    /// side; the client just passes through. Used by the V2 sidebar's
    /// search-as-you-type to find chats the local in-memory cache
    /// doesn't hold (iOS LRU-2 / Mac cap 20).
    ///
    /// Returns nil only on transport / decode error. An empty-query or
    /// no-match scenario returns an empty matches array (`truncated:
    /// false`). Callers SHOULD debounce input by 200ms to avoid
    /// keypress-storm-ing the daemon — the loop already self-throttles
    /// via the deadline but a debounce on the typing side keeps the
    /// daemon's load proportional to user intent.
    @MainActor
    public func searchChatHistory(query: String, limit: Int = 50) async -> ChatSessionSearchResponse? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ChatSessionSearchResponse(matches: [], truncated: false)
        }
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let path = "/chat-sessions/search?q=\(escaped)&limit=\(limit)"
        guard let request = makeRequest(path: path, method: "GET") else { return nil }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatSessionSearchResponse.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
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

    /// Chat V2 convenience wrapper for the broadcast first-send path.
    @MainActor
    public func createBroadcastChat(
        clientRequestId: UUID = UUID(),
        slots: [FrontierModelSlot]
    ) async -> CreateFrontierResponse? {
        await createFrontier(clientRequestId: clientRequestId, slots: slots)
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

    /// `POST /chat-sessions/frontier/:groupId/send`. The optional
    /// `perChildText` map lets the UI override the prompt for specific
    /// children (used by the broadcast attachment path so each child's
    /// staging path is only `@`-mentioned in its own prompt — uploading
    /// the same bytes once per child).
    @MainActor
    public func sendFrontierPrompt(
        groupId: UUID,
        text: String,
        perChildText: [UUID: String]? = nil
    ) async -> FrontierSendResponse? {
        let req = FrontierSendRequest(text: text, asFollowUp: false, perChildText: perChildText)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(path: "/chat-sessions/frontier/\(groupId.uuidString)/send", method: "POST", body: body) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(FrontierSendResponse.self, from: data)
            await refreshSessions()
            return response
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func setFrontierTurnWinner(groupId: UUID, turnId: String, childIndex: Int) async -> FrontierTurnWinner? {
        let req = SetFrontierTurnWinnerRequest(turnId: turnId, childIndex: childIndex)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(path: "/chat-sessions/frontier/\(groupId.uuidString)/turn-winner", method: "POST", body: body) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FrontierTurnWinner.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
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

    @MainActor
    public func continueFrontierFromWinner(groupId: UUID, childIndex: Int) async -> AgentSession? {
        await frontierPickWinner(groupId: groupId, childIndex: childIndex)
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
    @discardableResult
    public func approvePlan(sessionId: UUID, idempotencyKey: String? = nil) async -> Bool {
        // v16 outbox: encode an InterruptRequest-shaped body when the
        // caller supplies a key so the server can dedup. The legacy
        // empty-body POST stays the no-key path. Returns true on
        // HTTP 2xx; outbox dispatch reads this to detect failures and
        // reschedule, while legacy fire-and-forget callers discard.
        let path = "/sessions/\(sessionId.uuidString)/approve-plan"
        if let key = idempotencyKey {
            let body = (try? JSONEncoder().encode(InterruptRequest(idempotencyKey: key))) ?? Data()
            guard var request = makeRequest(path: path, method: "POST", body: body) else { return false }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                _ = try await sendChecked(request)
                self.lastError = nil
                return true
            } catch {
                self.lastError = error.localizedDescription
                return false
            }
        } else {
            guard let request = makeRequest(path: path, method: "POST") else { return false }
            do {
                _ = try await sendChecked(request)
                self.lastError = nil
                return true
            } catch {
                self.lastError = error.localizedDescription
                return false
            }
        }
    }

    // MARK: - v16 PR + merge

    /// `GET /sessions/:id/pr`. Returns nil when the daemon reports no PR
    /// for the session's current branch.
    @MainActor
    public func getPRStatus(sessionId: UUID) async -> PRStatus? {
        #if DEBUG
        if let fixture = codeTabVerificationPRStatus(sessionId: sessionId) {
            return fixture
        }
        #endif
        guard let request = makeRequest(path: "/sessions/\(sessionId.uuidString)/pr") else { return nil }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let status = try? decoder.decode(PRStatus.self, from: data) {
                self.lastError = nil
                return status
            }
            if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               dict["pr"] is NSNull {
                self.lastError = nil
                return nil
            }
            self.lastError = "couldn't parse PR status"
            return nil
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// `POST /sessions/:id/create-pr`. Returns the PR URL (created or
    /// already existing) on success. v16+ supports the idempotency key
    /// so a retry doesn't create a duplicate PR.
    @MainActor
    public func createPR(
        sessionId: UUID,
        title: String? = nil,
        body: String? = nil,
        baseBranch: String? = nil,
        idempotencyKey: String? = nil
    ) async -> String? {
        let req = CreatePRRequest(
            title: title,
            body: body,
            baseBranch: baseBranch,
            idempotencyKey: idempotencyKey
        )
        let encoded = (try? JSONEncoder().encode(req)) ?? Data()
        guard var request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/create-pr",
            method: "POST",
            body: encoded
        ) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let data = try await sendChecked(request)
            if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let url = dict["url"] as? String {
                return url
            }
            return nil
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// `POST /sessions/:id/merge`. Returns the parsed `MergePRResponse`
    /// on success. v16+ supports the idempotency key.
    @MainActor
    public func merge(
        sessionId: UUID,
        method: PRMergeMethod = .squash,
        deleteBranch: Bool = false,
        auto: Bool = false,
        adminOverride: Bool = false,
        idempotencyKey: String? = nil
    ) async -> MergePRResponse? {
        let req = MergePRRequest(
            method: method,
            deleteBranch: deleteBranch,
            auto: auto,
            adminOverride: adminOverride,
            idempotencyKey: idempotencyKey
        )
        let encoded = (try? JSONEncoder().encode(req)) ?? Data()
        guard var request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/merge",
            method: "POST",
            body: encoded
        ) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(MergePRResponse.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// `POST /sessions/:id/pr/review`. Runs `gh pr review` on the paired
    /// Mac and returns the refreshed PR snapshot when available.
    @MainActor
    public func reviewPR(
        sessionId: UUID,
        action: PRReviewAction = .approve,
        body: String? = nil,
        idempotencyKey: String? = nil
    ) async -> PRReviewResponse? {
        let req = PRReviewRequest(action: action, body: body, idempotencyKey: idempotencyKey)
        let encoded = (try? JSONEncoder().encode(req)) ?? Data()
        guard var request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/pr/review",
            method: "POST",
            body: encoded
        ) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(PRReviewResponse.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    /// `POST /sessions/:id/diff-action/:path`. File-level staged/unstaged
    /// operations backed by git on the paired Mac.
    @MainActor
    public func applyDiffAction(
        sessionId: UUID,
        path: String,
        action: GitDiffActionKind,
        idempotencyKey: String? = nil
    ) async -> GitDiffActionResponse? {
        let req = GitDiffActionRequest(action: action, idempotencyKey: idempotencyKey)
        let encoded = (try? JSONEncoder().encode(req)) ?? Data()
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var request = makeRequest(
                path: "/sessions/\(sessionId.uuidString)/diff-action/\(encodedPath)",
                method: "POST",
                body: encoded
              )
        else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(GitDiffActionResponse.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - v16 workspaces

    /// `GET /workspaces`. Returns the persisted per-repo workspaces. iOS
    /// surfaces these to seed defaults in the new-session sheet. Older
    /// Macs (wire < 16) return 404; this method yields an empty array.
    @MainActor
    public func listWorkspaces() async -> [CodeWorkspaceRecord] {
        if let serverWireVersion, serverWireVersion < AgentControlWireVersion.workspacesMinimum {
            workspaces = []
            return []
        }
        guard let request = makeRequest(path: "/workspaces", method: "GET") else { return [] }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(WorkspaceListResponse.self, from: data)
            workspaces = envelope.workspaces
            lastError = nil
            return envelope.workspaces
        } catch {
            self.lastError = error.localizedDescription
            return []
        }
    }

    @MainActor
    public func refreshWorkspaces() async {
        _ = await listWorkspaces()
    }

    /// `PATCH /workspaces/:id`. Updates provider defaults; returns the
    /// updated record on success.
    @MainActor
    public func updateWorkspaceDefaults(
        workspaceId: UUID,
        defaults: WorkspaceProviderDefaults,
        idempotencyKey: String? = nil
    ) async -> CodeWorkspaceRecord? {
        let req = UpdateWorkspaceDefaultsRequest(
            providerDefaults: defaults,
            idempotencyKey: idempotencyKey
        )
        let encoded = (try? JSONEncoder().encode(req)) ?? Data()
        guard var request = makeRequest(
            path: "/workspaces/\(workspaceId.uuidString)",
            method: "PATCH",
            body: encoded
        ) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // PATCH returns the updated record at the top level + an
            // optional receipt key — decode just the record.
            let updated = try decoder.decode(CodeWorkspaceRecord.self, from: data)
            if let idx = workspaces.firstIndex(where: { $0.id == updated.id }) {
                workspaces[idx] = updated
            } else {
                workspaces.append(updated)
            }
            lastError = nil
            return updated
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - v18 Code workbench remote runtime

    @MainActor
    public func fetchRunProfile(sessionId: UUID) async -> CodeRunProfileSnapshot? {
        guard let request = makeRequest(path: "/sessions/\(sessionId.uuidString)/run-profile", method: "GET") else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodeRunProfileResponse.self, from: data).profile
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func startRunProfile(sessionId: UUID, command: String) async -> CodeRunProfileSnapshot? {
        let req = CodeRunProfileStartRequest(command: command)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(
                path: "/sessions/\(sessionId.uuidString)/run-profile/start",
                method: "POST",
                body: body
              ) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodeRunProfileResponse.self, from: data).profile
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func stopRunProfile(sessionId: UUID) async -> CodeRunProfileSnapshot? {
        guard let request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/run-profile/stop",
            method: "POST"
        ) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodeRunProfileResponse.self, from: data).profile
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func listCheckpoints(sessionId: UUID) async -> [CodeCheckpointSnapshot] {
        guard let request = makeRequest(path: "/sessions/\(sessionId.uuidString)/checkpoints", method: "GET") else {
            return []
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodeCheckpointListResponse.self, from: data).checkpoints
        } catch {
            self.lastError = error.localizedDescription
            return []
        }
    }

    @MainActor
    public func createCheckpoint(sessionId: UUID, summary: String? = nil) async -> CodeCheckpointSnapshot? {
        let req = CodeCheckpointCreateRequest(summary: summary)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(
                path: "/sessions/\(sessionId.uuidString)/checkpoints",
                method: "POST",
                body: body
              ) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodeCheckpointCreateResponse.self, from: data).checkpoint
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func prepareCheckpointRestore(
        sessionId: UUID,
        checkpointId: UUID
    ) async -> CodeCheckpointRestorePreview? {
        guard let request = makeRequest(
            path: "/sessions/\(sessionId.uuidString)/checkpoints/\(checkpointId.uuidString)/prepare-restore",
            method: "POST"
        ) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodeCheckpointRestorePreviewResponse.self, from: data).preview
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func restoreCheckpoint(
        sessionId: UUID,
        checkpointId: UUID,
        previewId: UUID
    ) async -> CodeCheckpointRestoreResponse? {
        let req = CodeCheckpointRestoreRequest(previewId: previewId)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let request = makeRequest(
                path: "/sessions/\(sessionId.uuidString)/checkpoints/\(checkpointId.uuidString)/restore",
                method: "POST",
                body: body
              ) else {
            return nil
        }
        do {
            let data = try await sendChecked(request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodeCheckpointRestoreResponse.self, from: data)
        } catch {
            self.lastError = error.localizedDescription
            return nil
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
                    parentSessionId: s.parentSessionId,
                    workspaceId: s.workspaceId,
                    runtimeCwd: s.runtimeCwd,
                    chatCwd: s.chatCwd,
                    runtimeBinding: s.runtimeBinding,
                    prMirrorState: s.prMirrorState,
                    effort: s.effort,
                    abPairSessionId: s.abPairSessionId,
                    abPairDecidedAt: s.abPairDecidedAt,
                    customName: s.customName,
                    kind: s.kind,
                    frontierGroupId: s.frontierGroupId,
                    frontierChildIndex: s.frontierChildIndex,
                    codexChatBackend: s.codexChatBackend,
                    codexChatThreadId: s.codexChatThreadId,
                    geminiBackend: s.geminiBackend,
                    antigravityConversationId: s.antigravityConversationId,
                    antigravityProjectId: s.antigravityProjectId,
                    deepResearch: s.deepResearch
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
                    parentSessionId: s.parentSessionId,
                    workspaceId: s.workspaceId,
                    runtimeCwd: s.runtimeCwd,
                    chatCwd: s.chatCwd,
                    runtimeBinding: s.runtimeBinding,
                    prMirrorState: s.prMirrorState,
                    effort: s.effort,
                    abPairSessionId: s.abPairSessionId,
                    abPairDecidedAt: s.abPairDecidedAt,
                    customName: s.customName,
                    kind: s.kind,
                    frontierGroupId: s.frontierGroupId,
                    frontierChildIndex: s.frontierChildIndex,
                    codexChatBackend: s.codexChatBackend,
                    codexChatThreadId: s.codexChatThreadId,
                    geminiBackend: s.geminiBackend,
                    antigravityConversationId: s.antigravityConversationId,
                    antigravityProjectId: s.antigravityProjectId,
                    deepResearch: s.deepResearch
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
            let (data, response) = try await runRequest(request)
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
            let (data, response) = try await runRequest(request)
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
        await fetchTranscript(path: path, beforeId: nil, limit: limit)
    }

    /// v0.23 (Chat V2 — T13): paginated transcript fetch. When
    /// `beforeId` is non-nil, returns the `limit` messages immediately
    /// before that id; used by the V2 transcript's scroll-up-past-the-
    /// top trigger to lazy-load older history beyond the in-memory
    /// 1000-row window. When `beforeId` is nil, returns the tail
    /// window (existing behavior — back-compat with v0.5.3 clients).
    public func fetchTranscript(
        path: String,
        beforeId: String?,
        limit: Int = 500
    ) async -> TranscriptEnvelope? {
        guard var components = URLComponents(string: "/transcript") else { return nil }
        var items = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let beforeId, !beforeId.isEmpty {
            items.append(URLQueryItem(name: "beforeId", value: beforeId))
        }
        components.queryItems = items
        guard let query = components.url?.absoluteString,
              let request = makeRequest(path: query)
        else { return nil }
        do {
            let (data, response) = try await runRequest(request)
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
