import Foundation
import Combine
import ClawdmeterShared

@MainActor
protocol PRCoordinatingClient: AnyObject {
    var lastError: String? { get }

    func getPRStatus(sessionId: UUID) async -> PRStatus?
    func getPRStatusOutcome(sessionId: UUID) async -> AgentControlClient.PRStatusOutcome
    func createPR(
        sessionId: UUID,
        title: String?,
        body: String?,
        baseBranch: String?,
        idempotencyKey: String?
    ) async -> String?
    func merge(
        sessionId: UUID,
        method: PRMergeMethod,
        deleteBranch: Bool,
        auto: Bool,
        adminOverride: Bool,
        idempotencyKey: String?
    ) async -> MergePRResponse?
}

extension AgentControlClient: PRCoordinatingClient {}

@MainActor
final class PRCoordinator: ObservableObject {
    enum Source: String, Sendable {
        case daemon
        case fallbackURL
    }

    struct Snapshot: Equatable, Sendable {
        let url: URL
        let number: Int
        let title: String
        let state: String
        let author: String?
        let additions: Int
        let deletions: Int
        let body: String
        let reviewState: String?
        let checksRollup: String?
        let checks: [PRCheckMirror]
        let lastChecked: Date
        let source: Source
    }

    struct PullRequestIdentity: Equatable, Sendable {
        let repo: String
        let number: Int
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var lastError: String?
    @Published var manualURL: String = ""

    var canUseDaemonActions: Bool { client != nil && !daemonDisowned }

    private let sessionId: UUID
    private weak var client: PRCoordinatingClient?
    private let fallback: PRMirror
    private let runner: ShellRunning
    private let ghLocator: @Sendable () -> String?
    private var pollTask: Task<Void, Never>?
    private var fallbackCancellable: AnyCancellable?
    private var isWatching = false
    /// Set after the daemon reports `.sessionUnknown` for this session id —
    /// stops daemon polling and routes everything through `PRMirror`. We
    /// don't try to recover (the registry won't suddenly learn about a
    /// synthetic preview session); the user would need to spawn the work
    /// through Clawdmeter to get daemon-backed PR actions.
    private var daemonDisowned = false

    init(
        sessionId: UUID,
        client: PRCoordinatingClient?,
        fallback: PRMirror,
        runner: ShellRunning = ShellRunner.shared,
        ghLocator: @escaping @Sendable () -> String? = { ShellRunner.locateBinary("gh") }
    ) {
        self.sessionId = sessionId
        self.client = client
        self.fallback = fallback
        self.runner = runner
        self.ghLocator = ghLocator
        fallbackCancellable = fallback.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.client == nil || self.snapshot?.source != .daemon else { return }
                self.snapshot = state.map(Self.snapshot(from:))
                self.lastError = self.fallback.lastError
            }
    }

    deinit {
        pollTask?.cancel()
        fallbackCancellable?.cancel()
    }

    func attach(chatStore: SessionChatStore?) {
        if let chatStore {
            fallback.attach(chatStore: chatStore)
        }
    }

    func startWatching() {
        isWatching = true
        if client != nil, !daemonDisowned {
            startDaemonPolling()
        } else {
            fallback.startWatching()
        }
    }

    func stopWatching() {
        isWatching = false
        pollTask?.cancel()
        pollTask = nil
        fallback.stopWatching()
    }

    func loadFromManualURL() {
        fallback.manualURL = manualURL
        fallback.loadFromManualURL()
        fallback.startWatching()
    }

    func refreshNow() {
        guard client != nil, !daemonDisowned else {
            fallback.startWatching()
            return
        }
        Task { await refreshDaemonOnce() }
    }

    func createPR() async {
        guard let client, !daemonDisowned else {
            lastError = "Daemon unavailable"
            return
        }
        isMutating = true
        defer { isMutating = false }
        let url = await client.createPR(
            sessionId: sessionId,
            title: nil,
            body: nil,
            baseBranch: nil,
            idempotencyKey: UUID().uuidString
        )
        if let url {
            manualURL = url
            lastError = nil
            await refreshDaemonOnce()
        } else {
            lastError = "Create PR failed"
        }
    }

    func approve() async {
        guard let pr = snapshot else { return }
        guard let gh = ghLocator() else {
            lastError = "gh not found — install GitHub CLI"
            return
        }
        guard let identity = Self.approvalIdentity(for: pr) else {
            lastError = "couldn't parse PR URL"
            return
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let result = try await runner.run(
                executable: gh,
                arguments: ["pr", "review", "--approve", String(identity.number), "--repo", identity.repo],
                cwd: nil,
                environment: nil,
                timeout: 30
            )
            if result.exitStatus != 0 {
                lastError = "approve failed: \(result.stderrString.prefix(200))"
            } else {
                lastError = nil
                await refreshDaemonOnce()
            }
        } catch {
            lastError = "approve failed: \(error)"
        }
    }

    func merge() async {
        guard let client, !daemonDisowned else {
            lastError = "Daemon unavailable"
            return
        }
        isMutating = true
        defer { isMutating = false }
        let response = await client.merge(
            sessionId: sessionId,
            method: .squash,
            deleteBranch: false,
            auto: false,
            adminOverride: false,
            idempotencyKey: UUID().uuidString
        )
        if let response, response.ok {
            lastError = nil
            if let pr = response.pr {
                snapshot = Self.snapshot(from: pr)
            }
            await refreshDaemonOnce()
        } else {
            lastError = response?.error ?? "Merge failed"
        }
    }

    private func startDaemonPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDaemonOnce()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    /// Internal (not private) so `@testable import` can drive a single
    /// refresh without spinning the 30s poll loop. Externally still only
    /// reached via `startWatching` → `startDaemonPolling`.
    func refreshDaemonOnce() async {
        guard isWatching || snapshot == nil else { return }
        guard let client, !daemonDisowned else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        switch await client.getPRStatusOutcome(sessionId: sessionId) {
        case .found(let status):
            snapshot = Self.snapshot(from: status)
            lastError = nil
        case .noPR:
            snapshot = nil
            lastError = nil
        case .sessionUnknown:
            switchToFallback()
        case .unavailable(let message):
            snapshot = nil
            lastError = message
        }
    }

    /// One-way switch: daemon doesn't know about this session, so stop
    /// pestering it and drive the pane from `PRMirror` (chat-scan +
    /// manual-URL paths) instead.
    private func switchToFallback() {
        daemonDisowned = true
        pollTask?.cancel()
        pollTask = nil
        lastError = nil
        fallback.startWatching()
    }

    static func snapshot(from status: PRStatus) -> Snapshot? {
        guard let url = URL(string: status.url) else { return nil }
        return Snapshot(
            url: url,
            number: status.number,
            title: status.title,
            state: status.state.rawValue.uppercased(),
            author: nil,
            additions: status.additions,
            deletions: status.deletions,
            body: status.body,
            reviewState: status.reviewDecision,
            checksRollup: status.checksRollup,
            checks: status.checks ?? [],
            lastChecked: Date(),
            source: .daemon
        )
    }

    private static func snapshot(from state: PRMirror.PRState) -> Snapshot {
        Snapshot(
            url: state.url,
            number: state.number,
            title: state.title,
            state: state.state,
            author: state.author,
            additions: state.additions,
            deletions: state.deletions,
            body: state.body,
            reviewState: state.reviewState,
            checksRollup: nil,
            checks: [],
            lastChecked: state.lastChecked,
            source: .fallbackURL
        )
    }

    static func repoSlug(from url: URL) -> String? {
        pullRequestIdentity(from: url)?.repo
    }

    static func approvalIdentity(for snapshot: Snapshot) -> PullRequestIdentity? {
        guard let identity = pullRequestIdentity(from: snapshot.url),
              identity.number == snapshot.number
        else { return nil }
        return identity
    }

    static func canMerge(snapshot: Snapshot, canUseDaemonActions: Bool) -> Bool {
        guard canUseDaemonActions else { return false }
        return snapshot.checksRollup == nil || snapshot.checksRollup == "success"
    }

    static func pullRequestIdentity(from url: URL) -> PullRequestIdentity? {
        guard url.scheme == "https",
              url.host?.lowercased() == "github.com"
        else { return nil }
        let comps = url.pathComponents
        guard comps.count == 5,
              comps[3] == "pull",
              !comps[1].isEmpty,
              !comps[2].isEmpty,
              let number = Int(comps[4]),
              number > 0
        else { return nil }
        return PullRequestIdentity(repo: "\(comps[1])/\(comps[2])", number: number)
    }
}
