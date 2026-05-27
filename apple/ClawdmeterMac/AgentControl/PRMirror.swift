import Foundation
import Combine
import ClawdmeterShared
import OSLog

private let prLogger = Logger(subsystem: "com.clawdmeter.mac", category: "PRMirror")

/// G16: tracks one GitHub PR associated with a session. Auto-detects from
/// chat (when the agent runs `gh pr create` or pastes a URL) or accepts a
/// manual URL. Polls `gh pr view --json` every 30s while the PR is open.
@MainActor
public final class PRMirror: ObservableObject {

    public struct PRState: Sendable, Hashable {
        public let url: URL
        public let number: Int
        public let title: String
        public let state: String         // OPEN, CLOSED, MERGED
        public let author: String
        public let additions: Int
        public let deletions: Int
        public let body: String
        public let reviewState: String?  // APPROVED, CHANGES_REQUESTED, COMMENTED, nil
        public let lastChecked: Date
    }

    @Published public private(set) var state: PRState?
    @Published public private(set) var isPolling: Bool = false
    @Published public private(set) var lastError: String?
    @Published public var manualURL: String = ""

    private let sessionId: UUID
    private var pollTask: Task<Void, Never>?
    private var chatStore: SessionChatStore?
    /// T10 codex tension #7g: track the chat-store snapshot updates so PR
    /// detection picks up URLs that arrive AFTER attach. Without this,
    /// the user opens the PR tab before the agent's `gh pr create` line
    /// has streamed in, and we'd permanently show "No PR detected".
    private var snapshotSubscription: AnyCancellable?
    /// Whether the user has opened the PR tab. Polling only happens when
    /// this is true (codex tension #7e — opt-in start). Auto-detection
    /// still runs in the background so when the user does open the tab
    /// we already have the URL in hand.
    private var isWatching: Bool = false
    /// Last URL we attempted to start polling for (avoids re-firing the
    /// 30s task when the same URL is re-detected on every snapshot).
    private var watchedURL: URL?

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }

    /// Register a chat store as the PR-URL detection source. Does NOT
    /// start polling — the PR tab's `onAppear` calls `startWatching()`
    /// for that. We subscribe to the store's snapshot publisher so new
    /// messages re-trigger URL detection until a URL is found.
    public func attach(chatStore: SessionChatStore) {
        self.chatStore = chatStore
        snapshotSubscription?.cancel()
        // C2 — was `chatStore.$snapshot` pre-C2 when SessionChatStore
        // was `@Published`. With the store now `@Observable` the
        // daemon-side Combine bridge is `snapshotPublisher`.
        snapshotSubscription = chatStore.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.maybeDetectURL()
            }
        // Initial pass against whatever is already in the snapshot.
        maybeDetectURL()
    }

    public func detach() {
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        pollTask?.cancel()
        pollTask = nil
        isWatching = false
    }

    /// Called by `PRReviewPane.onAppear`. Starts the 30s poll loop if we
    /// already have a detected URL; otherwise polling begins as soon as
    /// `maybeDetectURL` finds one.
    public func startWatching() {
        isWatching = true
        if state == nil, let url = watchedURL ?? Self.findPRURL(in: chatStore?.messages ?? []) {
            startPolling(url: url)
        }
    }

    /// Called by `PRReviewPane.onDisappear`. Cancels the 30s poll loop
    /// but keeps the snapshot subscription alive so URLs that arrive
    /// after the user closes the tab are still detected for next open.
    public func stopWatching() {
        isWatching = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// Scan the current chat snapshot for a PR URL. The original
    /// implementation latched the first URL found and never re-checked,
    /// so a session that ran `gh pr create` twice (e.g., agent
    /// re-created the PR on a different branch) would mirror the stale
    /// one forever. We now re-scan on every snapshot update and replace
    /// `watchedURL` if a NEWER URL appears later in the chat — the
    /// scan walks messages in reverse so "newest URL wins" naturally.
    private func maybeDetectURL() {
        guard let store = chatStore else { return }
        guard let url = Self.findPRURL(in: store.messages) else { return }
        if let existing = watchedURL, existing == url { return }
        watchedURL = url
        if isWatching {
            startPolling(url: url)
        }
    }

    public func loadFromManualURL() {
        let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              trimmed.contains("/pull/")
        else {
            lastError = "Not a valid PR URL"
            return
        }
        startPolling(url: url)
    }

    public func approve() async {
        guard let pr = state else { return }
        guard let gh = ShellRunner.locateBinary("gh") else {
            lastError = "gh not found — install GitHub CLI"
            return
        }
        do {
            let result = try await ShellRunner.shared.run(
                executable: gh,
                arguments: ["pr", "review", "--approve", String(pr.number),
                            "--repo", Self.repoSlug(from: pr.url) ?? ""],
                timeout: 30
            )
            if result.exitStatus != 0 {
                lastError = "approve failed: \(result.stderrString.prefix(200))"
            } else {
                lastError = nil
                refreshNow()
            }
        } catch {
            lastError = "approve failed: \(error)"
        }
    }

    // MARK: - Detection

    /// Compiled once at class load. `findPRURL` was previously recompiling
    /// this regex per-message inside the reversed-scan loop — for long
    /// sessions with no PR URL yet, that meant thousands of
    /// `NSRegularExpression(pattern:)` allocations per snapshot tick.
    private static let prURLRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"https://github\.com/[^/\s]+/[^/\s]+/pull/\d+"#
    )

    /// Find a `https://github.com/<owner>/<repo>/pull/<n>` URL anywhere in
    /// the chat (newest assistant turns first).
    public static func findPRURL(in messages: [SessionChatStore.ChatMessage]) -> URL? {
        guard let regex = prURLRegex else { return nil }
        for msg in messages.reversed() {
            let range = NSRange(msg.body.startIndex..., in: msg.body)
            if let match = regex.firstMatch(in: msg.body, range: range),
               let r = Range(match.range, in: msg.body),
               let url = URL(string: String(msg.body[r])) {
                return url
            }
            if let detail = msg.detail {
                let drange = NSRange(detail.startIndex..., in: detail)
                if let match = regex.firstMatch(in: detail, range: drange),
                   let r = Range(match.range, in: detail),
                   let url = URL(string: String(detail[r])) {
                    return url
                }
            }
        }
        return nil
    }

    static func repoSlug(from url: URL) -> String? {
        // /<owner>/<repo>/pull/N
        let comps = url.pathComponents
        guard comps.count >= 5 else { return nil }
        return "\(comps[1])/\(comps[2])"
    }

    static func prNumber(from url: URL) -> Int? {
        let comps = url.pathComponents
        guard comps.count >= 5, let n = Int(comps[4]) else { return nil }
        return n
    }

    // MARK: - Polling

    private func startPolling(url: URL) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(url: url)
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func refreshNow() {
        guard let pr = state else { return }
        Task { await pollOnce(url: pr.url) }
    }

    private func pollOnce(url: URL) async {
        guard let gh = ShellRunner.locateBinary("gh") else {
            lastError = "gh not found"
            return
        }
        guard let slug = Self.repoSlug(from: url),
              let number = Self.prNumber(from: url) else {
            lastError = "couldn't parse PR URL"
            return
        }
        isPolling = true
        defer { isPolling = false }
        do {
            let result = try await ShellRunner.shared.run(
                executable: gh,
                arguments: [
                    "pr", "view", String(number),
                    "--repo", slug,
                    "--json", "number,title,state,author,additions,deletions,body,reviews"
                ],
                timeout: 15
            )
            guard result.exitStatus == 0 else {
                lastError = "gh exit \(result.exitStatus): \(result.stderrString.prefix(200))"
                return
            }
            guard let data = result.stdout.isEmpty ? nil : result.stdout,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                lastError = "couldn't parse gh output"
                return
            }
            let reviewState: String? = {
                guard let reviews = json["reviews"] as? [[String: Any]],
                      let last = reviews.last
                else { return nil }
                return last["state"] as? String
            }()
            let author = (json["author"] as? [String: Any])?["login"] as? String ?? "unknown"
            let parsed = PRState(
                url: url,
                number: number,
                title: (json["title"] as? String) ?? "",
                state: (json["state"] as? String) ?? "OPEN",
                author: author,
                additions: (json["additions"] as? Int) ?? 0,
                deletions: (json["deletions"] as? Int) ?? 0,
                body: (json["body"] as? String) ?? "",
                reviewState: reviewState,
                lastChecked: Date()
            )
            state = parsed
            lastError = nil
        } catch {
            lastError = "gh failed: \(error)"
        }
    }
}
