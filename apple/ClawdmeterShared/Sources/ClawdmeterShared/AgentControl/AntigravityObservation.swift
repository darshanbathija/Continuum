// Abstracts the data source for Antigravity 2 observation. Two modes:
//
//   1. **DiskObservationProvider** — default, zero-Python. Wires together
//      AntigravityInstall + AntigravityStateReader + BrainSummaryIndexer
//      + BrainPlanParser + ConversationProtoParser. Used by everyone who
//      hasn't toggled SDK mode on. Gets full Plan content (task.md +
//      implementation_plan.md are plaintext) + coarse usage signals
//      (turn count from metadata, ~tokens from artifact byte sizes).
//
//   2. **SDKObservationProvider** — opt-in. Wires the Python sidecar
//      (Commit 10) which talks to the running Antigravity language_server
//      via the SDK's `Connection.local()`. Gets real-time message stream
//      + exact `agent.conversation.total_usage`. Stub for v0.6.0 Commit
//      10 — ships full impl behind the SDK-mode toggle.
//
// Consumers (Commits 6-9) program against the protocol so the toggle is
// a hot swap — no impl-specific code in the Plan pane / iOS Plan tab /
// AntigravityUsageParser.

import Foundation

/// Top-level facade. Plan panes, analytics, and usage readers talk through
/// this. Implementations are async because SDK mode involves an out-of-process
/// sidecar; Disk mode resolves immediately.
public protocol AntigravityObservation: Sendable {

    /// Best-effort: is the underlying data source actually usable right
    /// now? Disk impl: returns true iff `~/.gemini/antigravity/` exists.
    /// SDK impl: returns true iff the sidecar process is alive AND has
    /// completed initial handshake.
    func isAvailable() async -> Bool

    /// Returns the human-readable name of the current model (e.g.
    /// `"gemini-3.5-flash"`). Nil when the source can't determine it.
    /// Disk impl: reads `antigravity_state.pbtxt` → resolves opaque
    /// model token via lookup map. SDK impl: reads
    /// `agent.conversation.live_model` from the SDK.
    func currentModel() async -> String?

    /// Returns the migration status from the state file. Used by the
    /// dashboard to render "Antigravity is migrating — wait a moment"
    /// when status is `.pending`.
    func migrationStatus() async -> AntigravityState.MigrationStatus

    /// Returns the brain summary index. Disk impl: parses
    /// `agyhub_summaries_proto.pb`. SDK impl: calls
    /// `Connection.list_conversations()`.
    func brainIndex() async -> BrainSummaryIndex

    /// Returns the parsed plan state for the brain at the given URL.
    /// Disk impl: BrainPlanParser.parse(brainURL:). SDK impl: same plus
    /// task headline pulled from `agent.conversation.task.headline`
    /// (when set by the SDK).
    func planSnapshot(brainURL: URL) async -> PlanState

    /// Returns a usage probe for the given conversation file. Disk impl:
    /// ConversationProtoParser.probe (encrypted detection + metadata
    /// estimate). SDK impl: yields the live `total_usage` struct, never
    /// `.encrypted`.
    func conversationProbe(conversationURL: URL, brainURL: URL?) async -> ConversationProbe

    /// Mode descriptor for the analytics-row subtitle + Settings tab.
    /// nonisolated so callers can read it without crossing actor
    /// boundaries — the value never changes after init.
    nonisolated var modeLabel: String { get }
}

#if os(macOS)

/// Disk-backed implementation. Everything reads from `~/.gemini/antigravity/`
/// via the four parsers from Commits 1-4. No Python, no network, no IPC.
/// All methods are synchronous internally but exposed as async to satisfy
/// the protocol — the actor wrapping keeps thread-safety light.
///
/// Mac-only: AntigravityInstall + the brain dir paths are Mac-only. iOS
/// readers consume observation data via the daemon over Tailscale (the
/// AgentControl client implements the same protocol from the iOS side).
public actor DiskObservationProvider: AntigravityObservation {

    public nonisolated let modeLabel = "disk mode"

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let applicationsRoot: URL

    /// Indexer cache: rebuilt when `agyhub_summaries_proto.pb` mtime
    /// changes. Reads-after-first-call hit the cache.
    private var cachedIndex: BrainSummaryIndex = .empty
    private var indexFileMTime: Date?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsRoot: URL = URL(fileURLWithPath: "/Applications"),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.applicationsRoot = applicationsRoot
    }

    public func isAvailable() async -> Bool {
        let install = AntigravityInstall.detect(
            homeDirectory: homeDirectory,
            applicationsRoot: applicationsRoot,
            fileManager: fileManager
        )
        if case .installed = install { return true }
        return false
    }

    public func currentModel() async -> String? {
        let url = homeDirectory.appendingPathComponent(".gemini/antigravity/antigravity_state.pbtxt")
        guard let state = try? AntigravityStateReader.read(at: url) else { return nil }
        return state.displayModelName
    }

    public func migrationStatus() async -> AntigravityState.MigrationStatus {
        let url = homeDirectory.appendingPathComponent(".gemini/antigravity/antigravity_state.pbtxt")
        guard let state = try? AntigravityStateReader.read(at: url) else { return .unknown }
        return state.migrationStatus
    }

    public func brainIndex() async -> BrainSummaryIndex {
        let url = homeDirectory.appendingPathComponent(".gemini/antigravity/agyhub_summaries_proto.pb")
        // mtime-cached: only re-parse when the file changed.
        if let mtime = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) {
            if mtime != indexFileMTime {
                cachedIndex = BrainSummaryIndexer.read(at: url)
                indexFileMTime = mtime
            }
        } else {
            cachedIndex = .empty
            indexFileMTime = nil
        }
        return cachedIndex
    }

    public func planSnapshot(brainURL: URL) async -> PlanState {
        BrainPlanParser.parse(brainURL: brainURL, fileManager: fileManager)
    }

    public func conversationProbe(conversationURL: URL, brainURL: URL?) async -> ConversationProbe {
        ConversationProtoParser.probe(
            conversationURL: conversationURL,
            brainURL: brainURL,
            fileManager: fileManager
        )
    }

    /// Test-only: clear the indexer cache so the next `brainIndex()`
    /// call re-reads from disk.
    public func resetCacheForTesting() {
        cachedIndex = .empty
        indexFileMTime = nil
    }
}

#endif // os(macOS) — DiskObservationProvider

/// SDK-mode placeholder. Ships full impl in Commit 10 — at that point
/// the constructor takes an `AntigravitySidecarManager` reference and
/// every method forwards a JSON-lines RPC to the Python sidecar's
/// observer.py.
///
/// For Commits 5-9 this stub returns the same shape as Disk mode but
/// with mode label "SDK mode (provisioning)". Useful for the Settings
/// toggle's loading state.
public actor SDKObservationProviderStub: AntigravityObservation {
    public nonisolated let modeLabel = "SDK mode (provisioning)"
    public init() {}
    public func isAvailable() async -> Bool { false }
    public func currentModel() async -> String? { nil }
    public func migrationStatus() async -> AntigravityState.MigrationStatus { .unknown }
    public func brainIndex() async -> BrainSummaryIndex { .empty }
    public func planSnapshot(brainURL: URL) async -> PlanState { .awaitingFirstTurn }
    public func conversationProbe(conversationURL: URL, brainURL: URL?) async -> ConversationProbe {
        ConversationProbe(
            kind: .missing,
            fileSize: 0,
            lastModified: .distantPast,
            turnCount: 0,
            estimatedTokens: 0
        )
    }
}
