import Foundation
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

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }

    public func attach(chatStore: SessionChatStore) {
        self.chatStore = chatStore
        // Try auto-detection on attach.
        if let url = Self.findPRURL(in: chatStore.messages) {
            startPolling(url: url)
        }
    }

    public func detach() {
        pollTask?.cancel()
        pollTask = nil
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

    /// Find a `https://github.com/<owner>/<repo>/pull/<n>` URL anywhere in
    /// the chat (newest assistant turns first).
    public static func findPRURL(in messages: [SessionChatStore.ChatMessage]) -> URL? {
        let pattern = #"https://github\.com/[^/\s]+/[^/\s]+/pull/\d+"#
        for msg in messages.reversed() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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
