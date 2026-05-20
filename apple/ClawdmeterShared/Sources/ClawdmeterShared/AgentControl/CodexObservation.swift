// Abstracts the data source for Codex CLI observation. Two modes:
//
//   1. **DiskCodexObservationProvider** — default, zero-Node. Reads from
//      `~/.codex/sessions/*.jsonl` via the existing CodexUsageParser +
//      CodexSource. Same behavior Clawdmeter has shipped since v0.3.0.
//
//   2. **SDKCodexObservationProvider** — opt-in, mirrors the v0.6.0
//      Antigravity SDK pattern. Talks to a Node.js sidecar (Commit C2)
//      which wraps `@openai/codex-sdk`. The SDK's `runStreamed()` emits
//      `item.completed` + `turn.completed` events with token usage,
//      cutting JSONL tail latency from ~1s to live streaming.
//
// **Critical auth note** (confirmed against `~/.codex/auth.json` on this
// machine, 2026-05-20): when the user runs `codex login` and selects
// the ChatGPT plan path, auth.json sets `auth_mode: "chatgpt"` and
// stores OAuth tokens locally. The Codex SDK piggybacks on this — no
// API key required, no per-token billing. Usage draws against the
// ChatGPT subscription quota. This is the structural reason the SDK
// is opt-in-safe for paid ChatGPT users in a way the Claude Agent SDK
// isn't (Anthropic explicitly disallows claude.ai login in third-party
// SDK products).
//
// Consumers program against the protocol so the toggle is a hot swap —
// no impl-specific code in the Sessions IDE chat pane or
// CodexUsageParser call sites.

import Foundation

/// Top-level facade. Every Codex reader (chat pane, analytics, model
/// catalog) talks through this. Implementations are async because SDK
/// mode involves an out-of-process Node sidecar; Disk mode resolves
/// immediately.
public protocol CodexObservation: Sendable {

    /// Best-effort: is the underlying data source usable? Disk impl:
    /// `~/.codex/sessions/` exists. SDK impl: sidecar process alive
    /// AND completed initial handshake.
    func isAvailable() async -> Bool

    /// Latest rate-limit snapshot. Disk impl: most recent rollout's
    /// `session_meta`. SDK impl: live `turn.completed.usage` aggregated
    /// per active window.
    func latestUsage() async -> CodexUsageSnapshot?

    /// Mode descriptor for the analytics-row subtitle.
    nonisolated var modeLabel: String { get }
}

/// Coarse usage snapshot decoupled from `UsageData`. Disk mode populates
/// from JSONL `session_meta`; SDK mode populates from
/// `turn.completed.usage` event accumulation.
public struct CodexUsageSnapshot: Equatable, Sendable {
    /// 5-hour session window percentage used (0...100).
    public let sessionPct: Int
    /// Minutes until session window reset.
    public let sessionResetMins: Int
    /// Epoch seconds of the current session-window reset.
    public let sessionEpoch: Int
    /// Last-modified timestamp.
    public let updatedAt: Date

    public init(sessionPct: Int, sessionResetMins: Int, sessionEpoch: Int, updatedAt: Date) {
        self.sessionPct = sessionPct
        self.sessionResetMins = sessionResetMins
        self.sessionEpoch = sessionEpoch
        self.updatedAt = updatedAt
    }
}

#if os(macOS)

/// Disk-backed implementation. Wraps the existing `~/.codex/sessions/`
/// parsing path. No Node, no IPC. This is what `AppRuntime` instantiates
/// by default; the SDK toggle swaps in `SDKCodexObservationProvider`
/// when the user opts in.
///
/// Mac-only: `~/.codex/sessions/` only exists on macOS. iOS reads
/// observation via the daemon over Tailscale (the AgentControl client
/// implements the same protocol from the iOS side).
public actor DiskCodexObservationProvider: CodexObservation {

    public nonisolated let modeLabel = "disk mode"

    private let codexSessionsRoot: URL
    private let fileManager: FileManager

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.codexSessionsRoot = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    public func isAvailable() async -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: codexSessionsRoot.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func latestUsage() async -> CodexUsageSnapshot? {
        // Per-file scan would be expensive on long history. Pick the
        // newest rollout's session_meta — that's where the active
        // 5-hour window state lives.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: codexSessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let jsonl = entries.filter { $0.pathExtension == "jsonl" }
        guard let newest = jsonl.max(by: { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }) else { return nil }

        return parseUsageFromRollout(at: newest)
    }

    /// Tiny header-only parse: reads up to 64KB and looks for the
    /// `session_meta` line that Codex writes near the top. Bounded so
    /// long rollouts don't load multi-MB just to read rate-limit state.
    /// `nonisolated` is fine here — file I/O on Foundation primitives.
    nonisolated private func parseUsageFromRollout(at url: URL) -> CodexUsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: head, encoding: .utf8) else {
            return nil
        }
        try? handle.close()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if (json["type"] as? String) != "session_meta" { continue }
            guard let payload = json["payload"] as? [String: Any] else { continue }
            return decode(payload: payload)
        }
        return nil
    }

    nonisolated private func decode(payload: [String: Any]) -> CodexUsageSnapshot? {
        let pct = payload["session_pct"] as? Int ?? payload["sessionPct"] as? Int ?? 0
        let resetMins = payload["session_reset_mins"] as? Int ?? payload["sessionResetMins"] as? Int ?? 0
        let epoch = payload["session_epoch"] as? Int ?? payload["sessionEpoch"] as? Int ?? 0
        return CodexUsageSnapshot(
            sessionPct: pct,
            sessionResetMins: resetMins,
            sessionEpoch: epoch,
            updatedAt: Date()
        )
    }
}

#endif // os(macOS) — DiskCodexObservationProvider

/// SDK-mode placeholder. Ships full impl in C3+ — at that point the
/// constructor takes a `CodexSDKManager` reference and every method
/// forwards a JSON-lines RPC to the Node sidecar's main.ts.
///
/// For now this stub returns the same shape but with mode label "SDK
/// mode (provisioning)". Useful for the Settings toggle's loading state.
public actor SDKCodexObservationProviderStub: CodexObservation {
    public nonisolated let modeLabel = "SDK mode (provisioning)"
    public init() {}
    public func isAvailable() async -> Bool { false }
    public func latestUsage() async -> CodexUsageSnapshot? { nil }
}
