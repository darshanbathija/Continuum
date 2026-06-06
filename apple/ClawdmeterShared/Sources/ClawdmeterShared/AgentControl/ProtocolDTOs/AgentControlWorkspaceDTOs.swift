import Foundation

// MARK: - Repo + Session

/// One session JSONL file that wasn't spawned by Clawdmeter but lived in a
/// repo we know about. Surfaced in the sidebar so the user can revisit any
/// past Claude / Codex session as read-only chat.
public struct RecentSession: Codable, Hashable, Sendable, Identifiable {
    /// Absolute path to the JSONL on disk. Doubles as our stable id —
    /// JSONL files don't move once written.
    public let path: String
    /// Most recent mtime we observed (for sorting + "X ago" label).
    public let lastModified: Date
    /// Which provider wrote this JSONL.
    public let provider: AgentKind
    /// First user prompt extracted from the JSONL. Used as the sidebar row
    /// title so a list of past sessions reads like a list of intents
    /// instead of "Claude session" five times in a row. Optional —
    /// empty / parse-failed JSONLs fall back to the generic label.
    public let firstPrompt: String?
    /// User-supplied memorable name. When non-empty wins over `firstPrompt`
    /// as the sidebar row title. Persisted on the Mac in
    /// `~/.clawdmeter/jsonl-aliases.json` keyed by `path`.
    public let customName: String?
    public var id: String { path }

    public init(
        path: String,
        lastModified: Date,
        provider: AgentKind,
        firstPrompt: String? = nil,
        customName: String? = nil
    ) {
        self.path = path
        self.lastModified = lastModified
        self.provider = provider
        self.firstPrompt = firstPrompt
        self.customName = customName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.lastModified = try c.decode(Date.self, forKey: .lastModified)
        self.provider = try c.decode(AgentKind.self, forKey: .provider)
        self.firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        // v0.5.10 addition. Decoder-tolerant — older clients omit the field.
        self.customName = try c.decodeIfPresent(String.self, forKey: .customName)
    }

    private enum CodingKeys: String, CodingKey {
        case path, lastModified, provider, firstPrompt, customName
    }
}

/// `POST /jsonl-aliases/rename` body. Sent from iOS to the Mac daemon to
/// rename a Recent JSONL row. `name` nil-or-empty clears the alias.
public struct RenameJSONLRequest: Codable, Sendable {
    public let path: String
    public let name: String?

    public init(path: String, name: String?) {
        self.path = path
        self.name = name
    }
}

// MARK: - Sidebar grouping / sorting

/// How the Sessions sidebar buckets rows. Repo is the legacy default
/// (one section per cwd). Date / Status / Agent flatten across repos and
/// re-bucket by the chosen field. None renders a flat list.
public enum SessionGrouping: String, Codable, CaseIterable, Sendable {
    case repo
    case date
    case status
    case agent
    case none

    public var displayName: String {
        switch self {
        case .repo:   return "Repo"
        case .date:   return "Date"
        case .status: return "Status"
        case .agent:  return "Agent"
        case .none:   return "None"
        }
    }
}

/// Sort order within each group.
public enum SessionSorting: String, Codable, CaseIterable, Sendable {
    case recency
    case created
    case name

    public var displayName: String {
        switch self {
        case .recency: return "Recency"
        case .created: return "Created"
        case .name:    return "Name"
        }
    }
}

/// Status filter. `.all` shows everything; `.active` keeps planning + running +
/// paused; `.done` keeps done; `.archived` keeps archived-only (the existing
/// `showArchived` toggle still wins for backwards compat).
public enum SessionStatusFilter: String, Codable, CaseIterable, Sendable {
    case all
    case active
    case inReview
    case done
    case archived

    public var displayName: String {
        switch self {
        case .all:      return "All"
        case .active:   return "Active"
        case .inReview: return "In Review"
        case .done:     return "Done"
        case .archived: return "Archived"
        }
    }
}

/// Stable identifier for a repo, mirrors `RepoKey` from the existing
/// Analytics layer. Use `RepoIdentity.normalize(_:)` to convert raw cwds.
public struct AgentRepo: Codable, Hashable, Sendable {
    /// Canonical repo path (or `RepoKey.other` for non-git bucket).
    public let key: String
    /// Human-friendly display name (last path component, or "Other").
    public let displayName: String
    /// True when this repo currently has at least one live agent session
    /// (one Clawdmeter spawned). Distinct from `liveSessionCount`.
    public let hasActiveSessions: Bool
    /// Count of session JSONLs under this repo with mtime within the last
    /// 5 minutes — agents actively writing RIGHT NOW. This is the narrow
    /// "live now" signal (green dot in UI). Optional (default 0) so old
    /// wire stays valid.
    public let liveSessionCount: Int
    /// Sessions (outside-Clawdmeter) that wrote to disk within the recent
    /// activity window (30 days by default). Each entry is one JSONL the
    /// user can open as read-only chat. Sorted newest-first.
    public let recentSessions: [RecentSession]

    public init(
        key: String,
        displayName: String,
        hasActiveSessions: Bool,
        liveSessionCount: Int = 0,
        recentSessions: [RecentSession] = []
    ) {
        self.key = key
        self.displayName = displayName
        self.hasActiveSessions = hasActiveSessions
        self.liveSessionCount = liveSessionCount
        self.recentSessions = recentSessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.hasActiveSessions = try c.decode(Bool.self, forKey: .hasActiveSessions)
        self.liveSessionCount = (try? c.decode(Int.self, forKey: .liveSessionCount)) ?? 0
        self.recentSessions = (try? c.decodeIfPresent([RecentSession].self, forKey: .recentSessions)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case key, displayName, hasActiveSessions, liveSessionCount, recentSessions
    }
}

/// Which agent runtime owns the session.
public enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex
    /// Gemini Code Assist via Google's `gemini` CLI. Added in wire v6
    /// (2026-05-19).
    case gemini
    /// OpenCode adapter (D11/D12, v1.1 — wire v13). The Mac spawns a
    /// shared `opencode serve` process (P1 singleton) and registers
    /// per-Clawdmeter-session SSE clients against it. Underlying model
    /// is provider-of-the-user's-choice (Anthropic, OpenAI, Google);
    /// analytics tag the spend under `.opencode` regardless.
    case opencode
    /// Cursor Agent CLI / SDK-backed sessions. The Mac launches Cursor via
    /// `cursor-agent` or `agent`; iOS requests are proxied to the paired Mac.
    case cursor
    /// xAI Grok via `grok agent --no-leader stdio` (ACP v0.11.3). Added for the
    /// harness build (wire v26, 2026-06-02); auth id `grok.com`, resolved from
    /// `initialize.authMethods` (never hardcoded).
    case grok
    /// Forward-compat sentinel for unknown agent kinds (X3, v0.17, wire
    /// v12). Older v12 clients connecting to a v13 Mac decode the
    /// `.opencode` raw into `.unknown` instead of `.claude` —
    /// preventing the silent mislabeling Codex flagged in the
    /// eng-review. UI sites render `.unknown` as a neutral
    /// "Other agent" tile.
    ///
    /// `.unknown` is intentionally NOT user-selectable (`allCases`
    /// excludes it via the custom override below); it only appears on
    /// the read path when decoding payloads we don't recognize.
    case unknown = "__unknown__"

    /// Filter `.unknown` out of `allCases` so pickers and provider
    /// segmented controls don't accidentally render it as a choice.
    /// `.opencode` and `.cursor` are included as real picker options.
    public static var allCases: [AgentKind] {
        [.claude, .codex, .gemini, .opencode, .cursor, .grok]
    }

    /// Lenient decoder (X3 — wire v12). Forward-compat readers keep
    /// parsing payloads from newer Macs whose `agent` field carries a
    /// value this binary doesn't recognize. Unknown raws fold to
    /// `.unknown` so UI surfaces show "Other agent" instead of
    /// silently mislabeling as Claude.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = AgentKind(rawValue: raw) ?? .unknown
    }
}

// MARK: - Code V2 control plane (wire v15)

/// Concrete runtime transport backing a session. This is intentionally
/// separate from `AgentKind`: OpenCode can run Anthropic/OpenAI/Google
/// models underneath; Codex can be CLI or SDK; Gemini is agentapi rather
/// than the old standalone CLI.
public enum SessionRuntimeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case claudeCLI = "claude_cli"
    case codexCLI = "codex_cli"
    case codexSDK = "codex_sdk"
    case opencodeServer = "opencode_server"
    case cursorCLI = "cursor_cli"
    case cursorSDK = "cursor_sdk"
    case vscodeBridge = "vscode_bridge"
    /// Native ACP drivers (wire v26). Per-agent (not a single `.acp`) for
    /// diagnostic/migration fidelity — Grok and Cursor differ in
    /// spawn/auth/config/resume behavior.
    case acpGrok = "acp_grok"
    case acpCursor = "acp_cursor"
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SessionRuntimeKind(rawValue: raw) ?? .unknown
    }

    public static func inferred(
        agent: AgentKind,
        codexBackend: CodexChatBackend? = nil
    ) -> SessionRuntimeKind {
        switch agent {
        case .claude:
            return .claudeCLI
        case .codex:
            return codexBackend == .sdk ? .codexSDK : .codexCLI
        case .gemini:
            // Gemini drives via the headless `agy` harness bridge; no legacy
            // runtime kind. Routing keys off the live bridge, not this.
            return .unknown
        case .opencode:
            return .opencodeServer
        case .cursor:
            // Phase 5: Cursor is now driven over the native ACP harness
            // (`cursor-agent acp`), not the legacy tmux/poll CLI path.
            return .acpCursor
        case .grok:
            return .acpGrok
        case .unknown:
            return .unknown
        }
    }

    /// True for the native ACP harness runtime kinds (Grok, Cursor) — the
    /// daemon drives these through `AcpHarnessBridge`, not tmux/SDK/serve.
    public var isACPDriven: Bool { self == .acpGrok || self == .acpCursor }
}

/// How trustworthy a cost/usage value is. Provider-reported costs should
/// survive unchanged; local pricing only fills gaps and must be labelled.
public enum BillingConfidence: String, Codable, Hashable, Sendable, CaseIterable {
    case providerReported = "provider_reported"
    case locallyPriced = "locally_priced"
    case estimated
    case unavailable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = BillingConfidence(rawValue: raw) ?? .unavailable
    }
}

public struct SessionRuntimeCapabilities: Codable, Hashable, Sendable {
    public let supportsStreaming: Bool
    public let supportsCancel: Bool
    public let supportsPermissionPrompts: Bool
    public let supportsUsage: Bool
    public let supportsTerminal: Bool
    public let supportsPRMirror: Bool
    public let supportsArtifacts: Bool

    public init(
        supportsStreaming: Bool = true,
        supportsCancel: Bool = false,
        supportsPermissionPrompts: Bool = false,
        supportsUsage: Bool = false,
        supportsTerminal: Bool = false,
        supportsPRMirror: Bool = true,
        supportsArtifacts: Bool = true
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsCancel = supportsCancel
        self.supportsPermissionPrompts = supportsPermissionPrompts
        self.supportsUsage = supportsUsage
        self.supportsTerminal = supportsTerminal
        self.supportsPRMirror = supportsPRMirror
        self.supportsArtifacts = supportsArtifacts
    }

    public static func defaults(for runtime: SessionRuntimeKind) -> SessionRuntimeCapabilities {
        switch runtime {
        case .claudeCLI, .codexCLI, .cursorCLI:
            return SessionRuntimeCapabilities(
                supportsCancel: true,
                supportsPermissionPrompts: true,
                supportsUsage: true,
                supportsTerminal: true
            )
        case .codexSDK:
            return SessionRuntimeCapabilities(
                supportsCancel: true,
                supportsPermissionPrompts: false,
                supportsUsage: true,
                supportsTerminal: false
            )
        case .cursorSDK:
            return SessionRuntimeCapabilities(
                supportsCancel: true,
                supportsPermissionPrompts: false,
                supportsUsage: true,
                supportsTerminal: false
            )
        case .opencodeServer:
            return SessionRuntimeCapabilities(
                supportsCancel: true,
                supportsPermissionPrompts: true,
                supportsUsage: true,
                supportsTerminal: true
            )
        case .vscodeBridge:
            return SessionRuntimeCapabilities(
                supportsCancel: true,
                supportsPermissionPrompts: true,
                supportsUsage: false,
                supportsTerminal: true
            )
        case .acpGrok, .acpCursor:
            // ACP drivers: full turn loop + permission prompts + usage.
            // Terminal stays off until the Phase 6 fs/terminal trust model.
            return SessionRuntimeCapabilities(
                supportsCancel: true,
                supportsPermissionPrompts: true,
                supportsUsage: true,
                supportsTerminal: false
            )
        case .unknown:
            return SessionRuntimeCapabilities(supportsStreaming: false)
        }
    }
}

/// Runtime/provider binding for a session. This is the durable replacement
/// for overloading `AgentKind` with transport, billing, and external ids.
public struct SessionRuntimeBinding: Codable, Hashable, Sendable {
    public let runtimeKind: SessionRuntimeKind
    public let externalSessionId: String?
    public let externalThreadId: String?
    public let projectId: String?
    public let providerModelId: String?
    public let billingProvider: String?
    public let capabilities: SessionRuntimeCapabilities
    public let cancelSupported: Bool
    public let billingConfidence: BillingConfidence
    public let boundAt: Date
    public let metadata: [String: String]

    public init(
        runtimeKind: SessionRuntimeKind,
        externalSessionId: String? = nil,
        externalThreadId: String? = nil,
        projectId: String? = nil,
        providerModelId: String? = nil,
        billingProvider: String? = nil,
        capabilities: SessionRuntimeCapabilities? = nil,
        cancelSupported: Bool? = nil,
        billingConfidence: BillingConfidence = .unavailable,
        boundAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        let resolvedCapabilities = capabilities ?? SessionRuntimeCapabilities.defaults(for: runtimeKind)
        self.runtimeKind = runtimeKind
        self.externalSessionId = externalSessionId
        self.externalThreadId = externalThreadId
        self.projectId = projectId
        self.providerModelId = providerModelId
        self.billingProvider = billingProvider
        self.capabilities = resolvedCapabilities
        self.cancelSupported = cancelSupported ?? resolvedCapabilities.supportsCancel
        self.billingConfidence = billingConfidence
        self.boundAt = boundAt
        self.metadata = metadata
    }

    public func updating(
        externalSessionId: String?? = nil,
        externalThreadId: String?? = nil,
        projectId: String?? = nil,
        providerModelId: String?? = nil,
        billingProvider: String?? = nil,
        billingConfidence: BillingConfidence? = nil,
        metadata: [String: String]? = nil
    ) -> SessionRuntimeBinding {
        SessionRuntimeBinding(
            runtimeKind: runtimeKind,
            externalSessionId: Self.resolve(externalSessionId, fallback: self.externalSessionId),
            externalThreadId: Self.resolve(externalThreadId, fallback: self.externalThreadId),
            projectId: Self.resolve(projectId, fallback: self.projectId),
            providerModelId: Self.resolve(providerModelId, fallback: self.providerModelId),
            billingProvider: Self.resolve(billingProvider, fallback: self.billingProvider),
            capabilities: capabilities,
            cancelSupported: cancelSupported,
            billingConfidence: billingConfidence ?? self.billingConfidence,
            boundAt: boundAt,
            metadata: metadata ?? self.metadata
        )
    }

    private static func resolve<T>(_ candidate: T??, fallback: T?) -> T? {
        switch candidate {
        case .none: return fallback
        case .some(let value): return value
        }
    }
}

public struct WorkspaceProviderDefaults: Codable, Hashable, Sendable {
    public let defaultAgent: AgentKind
    public let defaultModelByProvider: [String: String]
    public let defaultRuntimeByProvider: [String: SessionRuntimeKind]
    public let defaultEffort: ReasoningEffort?

    public init(
        defaultAgent: AgentKind = .claude,
        defaultModelByProvider: [String: String] = [:],
        defaultRuntimeByProvider: [String: SessionRuntimeKind] = [:],
        defaultEffort: ReasoningEffort? = nil
    ) {
        self.defaultAgent = defaultAgent
        self.defaultModelByProvider = defaultModelByProvider
        self.defaultRuntimeByProvider = defaultRuntimeByProvider
        self.defaultEffort = defaultEffort
    }
}

public enum WorkspaceFilesToCopyMode: String, Codable, Hashable, Sendable, CaseIterable {
    case patterns
    case allIgnored = "all_ignored"
}

public struct WorkspaceFilesToCopySettings: Codable, Hashable, Sendable {
    public static let defaultPatterns: [String] = [".env*"]
    public static let defaultMaxFiles: Int = 100_000
    public static let defaultMaxBytesPerFile: Int64 = 2 * 1024 * 1024 * 1024
    public static let defaultMaxTotalBytes: Int64 = 10 * 1024 * 1024 * 1024

    public let enabled: Bool
    public let mode: WorkspaceFilesToCopyMode
    public let patterns: [String]
    public let maxFiles: Int
    public let maxBytesPerFile: Int64
    public let maxTotalBytes: Int64
    public let allowDirectories: Bool

    public init(
        // Default is `.patterns` with `.env*`, NOT `.allIgnored`. `.allIgnored`
        // copies EVERY gitignored file into the new worktree — for a real
        // project that means node_modules / .next / build caches (axtior-platform
        // = 315k ignored files, 2.6 GB), which trips the file/byte cap, throws,
        // and fails the entire session spawn ("the + button makes a branch but
        // never starts a session"). Conductor copies a small curated set
        // (`.env`), and so do we now. Users can still opt into `.allIgnored`.
        enabled: Bool = true,
        mode: WorkspaceFilesToCopyMode = .patterns,
        patterns: [String] = WorkspaceFilesToCopySettings.defaultPatterns,
        maxFiles: Int = WorkspaceFilesToCopySettings.defaultMaxFiles,
        maxBytesPerFile: Int64 = WorkspaceFilesToCopySettings.defaultMaxBytesPerFile,
        maxTotalBytes: Int64 = WorkspaceFilesToCopySettings.defaultMaxTotalBytes,
        allowDirectories: Bool = true
    ) {
        self.enabled = enabled
        self.mode = mode
        self.patterns = patterns
        self.maxFiles = maxFiles
        self.maxBytesPerFile = maxBytesPerFile
        self.maxTotalBytes = maxTotalBytes
        self.allowDirectories = allowDirectories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        self.mode = (try? c.decodeIfPresent(WorkspaceFilesToCopyMode.self, forKey: .mode)) ?? .patterns
        self.patterns = (try? c.decodeIfPresent([String].self, forKey: .patterns)) ?? Self.defaultPatterns
        self.maxFiles = (try? c.decodeIfPresent(Int.self, forKey: .maxFiles)) ?? Self.defaultMaxFiles
        self.maxBytesPerFile = (try? c.decodeIfPresent(Int64.self, forKey: .maxBytesPerFile)) ?? Self.defaultMaxBytesPerFile
        self.maxTotalBytes = (try? c.decodeIfPresent(Int64.self, forKey: .maxTotalBytes)) ?? Self.defaultMaxTotalBytes
        self.allowDirectories = (try? c.decodeIfPresent(Bool.self, forKey: .allowDirectories)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, patterns, maxFiles, maxBytesPerFile, maxTotalBytes, allowDirectories
    }
}

public enum WorktreeFileCopyPatternSource: String, Codable, Hashable, Sendable, CaseIterable {
    case worktreeinclude
    case settings
    case defaultPatterns = "default"
    case disabled
}

public struct WorktreeFileCopySummary: Codable, Hashable, Sendable {
    public let source: WorktreeFileCopyPatternSource
    public let mode: WorkspaceFilesToCopyMode
    public let patterns: [String]
    public let copiedFileCount: Int
    public let copiedDirectoryCount: Int
    public let skippedFileCount: Int
    public let failedFileCount: Int
    public let copiedBytes: Int64
    public let manifestPath: String?
    public let failureSummary: String?

    public init(
        source: WorktreeFileCopyPatternSource,
        mode: WorkspaceFilesToCopyMode = .patterns,
        patterns: [String],
        copiedFileCount: Int = 0,
        copiedDirectoryCount: Int = 0,
        skippedFileCount: Int = 0,
        failedFileCount: Int = 0,
        copiedBytes: Int64 = 0,
        manifestPath: String? = nil,
        failureSummary: String? = nil
    ) {
        self.source = source
        self.mode = mode
        self.patterns = patterns
        self.copiedFileCount = copiedFileCount
        self.copiedDirectoryCount = copiedDirectoryCount
        self.skippedFileCount = skippedFileCount
        self.failedFileCount = failedFileCount
        self.copiedBytes = copiedBytes
        self.manifestPath = manifestPath
        self.failureSummary = failureSummary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decode(WorktreeFileCopyPatternSource.self, forKey: .source)
        self.mode = (try? c.decodeIfPresent(WorkspaceFilesToCopyMode.self, forKey: .mode)) ?? .patterns
        self.patterns = (try? c.decodeIfPresent([String].self, forKey: .patterns)) ?? []
        self.copiedFileCount = (try? c.decodeIfPresent(Int.self, forKey: .copiedFileCount)) ?? 0
        self.copiedDirectoryCount = (try? c.decodeIfPresent(Int.self, forKey: .copiedDirectoryCount)) ?? 0
        self.skippedFileCount = (try? c.decodeIfPresent(Int.self, forKey: .skippedFileCount)) ?? 0
        self.failedFileCount = (try? c.decodeIfPresent(Int.self, forKey: .failedFileCount)) ?? 0
        self.copiedBytes = (try? c.decodeIfPresent(Int64.self, forKey: .copiedBytes)) ?? 0
        self.manifestPath = try c.decodeIfPresent(String.self, forKey: .manifestPath)
        self.failureSummary = try c.decodeIfPresent(String.self, forKey: .failureSummary)
    }

    private enum CodingKeys: String, CodingKey {
        case source, mode, patterns, copiedFileCount, copiedDirectoryCount,
             skippedFileCount, failedFileCount, copiedBytes, manifestPath,
             failureSummary
    }
}

public struct WorktreeProvisioningMetadata: Codable, Hashable, Sendable {
    public let ownershipMarkerId: String
    public let branchName: String?
    public let worktreePath: String
    public let storageRoot: String?
    public let projectSlug: String?
    public let workspaceSlug: String?
    public let branchAliasPath: String?
    public let filesToCopy: WorktreeFileCopySummary
    public let createdAt: Date

    public init(
        ownershipMarkerId: String,
        branchName: String?,
        worktreePath: String,
        storageRoot: String? = nil,
        projectSlug: String? = nil,
        workspaceSlug: String? = nil,
        branchAliasPath: String? = nil,
        filesToCopy: WorktreeFileCopySummary,
        createdAt: Date = Date()
    ) {
        self.ownershipMarkerId = ownershipMarkerId
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.storageRoot = storageRoot
        self.projectSlug = projectSlug
        self.workspaceSlug = workspaceSlug
        self.branchAliasPath = branchAliasPath
        self.filesToCopy = filesToCopy
        self.createdAt = createdAt
    }
}

public struct WorkspaceArchiveMetadata: Codable, Hashable, Sendable {
    public let archivedAt: Date?
    public let finalStatus: String?
    public let selectedWinnerSessionId: UUID?
    public let summary: String?

    public init(
        archivedAt: Date? = nil,
        finalStatus: String? = nil,
        selectedWinnerSessionId: UUID? = nil,
        summary: String? = nil
    ) {
        self.archivedAt = archivedAt
        self.finalStatus = finalStatus
        self.selectedWinnerSessionId = selectedWinnerSessionId
        self.summary = summary
    }
}

/// Persisted Code V2 workspace/worktree entity. A Project owns one or more
/// repos; each repo can expose many isolated workspaces/worktrees; sessions
/// bind into those workspaces through `AgentSession.workspaceId`.
public struct CodeWorkspaceRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let projectId: UUID
    public let repoRoot: String
    public let repoDisplayName: String
    public let defaultBranch: String?
    public let worktreeRoot: String?
    public let runtimeCwd: String
    public let chatCwd: String?
    public let providerDefaults: WorkspaceProviderDefaults
    public let filesToCopy: WorkspaceFilesToCopySettings
    public let activeSessionIds: [UUID]
    public let branchName: String?
    public let prMirrorState: PRMirrorState?
    public let archiveMetadata: WorkspaceArchiveMetadata?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        repoRoot: String,
        repoDisplayName: String,
        defaultBranch: String? = nil,
        worktreeRoot: String? = nil,
        runtimeCwd: String,
        chatCwd: String? = nil,
        providerDefaults: WorkspaceProviderDefaults = WorkspaceProviderDefaults(),
        filesToCopy: WorkspaceFilesToCopySettings = WorkspaceFilesToCopySettings(),
        activeSessionIds: [UUID] = [],
        branchName: String? = nil,
        prMirrorState: PRMirrorState? = nil,
        archiveMetadata: WorkspaceArchiveMetadata? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.repoRoot = repoRoot
        self.repoDisplayName = repoDisplayName
        self.defaultBranch = defaultBranch
        self.worktreeRoot = worktreeRoot
        self.runtimeCwd = runtimeCwd
        self.chatCwd = chatCwd
        self.providerDefaults = providerDefaults
        self.filesToCopy = filesToCopy
        self.activeSessionIds = activeSessionIds
        self.branchName = branchName
        self.prMirrorState = prMirrorState
        self.archiveMetadata = archiveMetadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.projectId = try c.decode(UUID.self, forKey: .projectId)
        self.repoRoot = try c.decode(String.self, forKey: .repoRoot)
        self.repoDisplayName = try c.decode(String.self, forKey: .repoDisplayName)
        self.defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        self.worktreeRoot = try c.decodeIfPresent(String.self, forKey: .worktreeRoot)
        self.runtimeCwd = try c.decode(String.self, forKey: .runtimeCwd)
        self.chatCwd = try c.decodeIfPresent(String.self, forKey: .chatCwd)
        self.providerDefaults = (try? c.decodeIfPresent(WorkspaceProviderDefaults.self, forKey: .providerDefaults)) ?? WorkspaceProviderDefaults()
        self.filesToCopy = (try? c.decodeIfPresent(WorkspaceFilesToCopySettings.self, forKey: .filesToCopy)) ?? WorkspaceFilesToCopySettings()
        self.activeSessionIds = (try? c.decodeIfPresent([UUID].self, forKey: .activeSessionIds)) ?? []
        self.branchName = try c.decodeIfPresent(String.self, forKey: .branchName)
        self.prMirrorState = try c.decodeIfPresent(PRMirrorState.self, forKey: .prMirrorState)
        self.archiveMetadata = try c.decodeIfPresent(WorkspaceArchiveMetadata.self, forKey: .archiveMetadata)
        self.createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        self.updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? self.createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, repoRoot, repoDisplayName, defaultBranch, worktreeRoot,
             runtimeCwd, chatCwd, providerDefaults, filesToCopy, activeSessionIds,
             branchName, prMirrorState, archiveMetadata, createdAt, updatedAt
    }
}

/// Normalized provider event stream used by mobile and desktop projections.
public enum ProviderEventKind: String, Codable, Hashable, Sendable, CaseIterable {
    case turnStarted = "turn_started"
    case messageAdded = "message_added"
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case usageDelta = "usage_delta"
    case turnCompleted = "turn_completed"
    case turnFailed = "turn_failed"
    case permissionPrompt = "permission_prompt"
    case summaryUpdated = "summary_updated"

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = ProviderEventKind(rawValue: raw) ?? .messageAdded
    }
}

public struct ProviderEventEnvelope: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionId: UUID
    public let runtimeBinding: SessionRuntimeBinding?
    public let kind: ProviderEventKind
    public let at: Date
    public let cursor: UInt64?
    /// Variant-specific JSON payload encoded as a string to keep the shared
    /// protocol strict and forward-compatible.
    public let payload: String

    public init(
        id: String = UUID().uuidString,
        sessionId: UUID,
        runtimeBinding: SessionRuntimeBinding? = nil,
        kind: ProviderEventKind,
        at: Date = Date(),
        cursor: UInt64? = nil,
        payload: String = "{}"
    ) {
        self.id = id
        self.sessionId = sessionId
        self.runtimeBinding = runtimeBinding
        self.kind = kind
        self.at = at
        self.cursor = cursor
        self.payload = payload
    }
}

public enum MobileCommandKind: String, Codable, Hashable, Sendable, CaseIterable {
    case send
    case approve
    case interrupt
    case permissionResponse = "permission_response"
    case terminalInput = "terminal_input"
    case createPR = "create_pr"
    case reviewPR = "review_pr"
    case mergePR = "merge_pr"
    /// v16: every write endpoint that the iOS outbox can issue gets a
    /// kind for audit/UX disambiguation.
    case changeModel = "change_model"
    case changeEffort = "change_effort"
    case changeMode = "change_mode"
    case setAutopilot = "set_autopilot"
    case pickWinner = "pick_winner"
    case updateWorkspace = "update_workspace"
    /// v23: workspace onboarding (Add Repo flow).
    case openLocalFolder = "open_local_folder"
    case cloneFromGitHub = "clone_from_github"
    case quickStartRepo = "quick_start_repo"
    case wakeMac = "wake_mac"
    /// v25: respawn a degraded session's dead tmux pane.
    case revive

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = MobileCommandKind(rawValue: raw) ?? .send
    }
}

public enum MobileCommandStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case queued
    case sent
    case acknowledged
    case failed

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = MobileCommandStatus(rawValue: raw) ?? .failed
    }
}

public struct MobileCommandEnvelope: Codable, Hashable, Sendable, Identifiable {
    public var id: String { idempotencyKey }
    public let idempotencyKey: String
    public let deviceId: String
    public let sessionId: UUID?
    public let kind: MobileCommandKind
    public let status: MobileCommandStatus
    public let createdAt: Date
    public let lastAttemptAt: Date?
    public let retryCount: Int
    public let payload: String

    public init(
        idempotencyKey: String,
        deviceId: String,
        sessionId: UUID? = nil,
        kind: MobileCommandKind,
        status: MobileCommandStatus = .queued,
        createdAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        retryCount: Int = 0,
        payload: String = "{}"
    ) {
        self.idempotencyKey = idempotencyKey
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.retryCount = retryCount
        self.payload = payload
    }
}

public struct MobileCommandReceipt: Codable, Hashable, Sendable, Identifiable {
    public var id: String { idempotencyKey }
    public let idempotencyKey: String
    public let status: MobileCommandStatus
    public let receivedAt: Date
    public let processedAt: Date?
    public let serverReceiptId: String
    public let error: String?

    public init(
        idempotencyKey: String,
        status: MobileCommandStatus,
        receivedAt: Date = Date(),
        processedAt: Date? = nil,
        serverReceiptId: String = UUID().uuidString,
        error: String? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.receivedAt = receivedAt
        self.processedAt = processedAt
        self.serverReceiptId = serverReceiptId
        self.error = error
    }

    /// JSON dictionary representation suitable for inlining into an
    /// existing `[String: Any]` response body without round-tripping
    /// through JSONEncoder. ISO8601 dates, raw status string. Server
    /// uses this when an endpoint still returns an ad-hoc dict (most
    /// of them do) but needs to attach a `"receipt"` key.
    public var jsonDictionary: [String: Any] {
        let iso = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "idempotencyKey": idempotencyKey,
            "status": status.rawValue,
            "receivedAt": iso.string(from: receivedAt),
            "serverReceiptId": serverReceiptId,
        ]
        if let processedAt { dict["processedAt"] = iso.string(from: processedAt) }
        if let error { dict["error"] = error }
        return dict
    }
}

/// `POST /sessions/:id/interrupt` body. v15 and earlier sent no body;
/// v16+ accepts an optional `InterruptRequest` so the outbox can dedupe
/// a re-issued Stop. Server tolerates empty / missing body and treats
/// the request as no-key (i.e. always-process).
public struct InterruptRequest: Codable, Sendable {
    public let idempotencyKey: String?

    public init(idempotencyKey: String? = nil) {
        self.idempotencyKey = idempotencyKey
    }
}

/// `POST /sessions/:id/revive` body (v25). Respawns a degraded session's
/// dead tmux pane. Carries only the optional idempotency key so a retried
/// revive replays the cached response instead of double-spawning.
public struct ReviveRequest: Codable, Sendable {
    public let idempotencyKey: String?

    public init(idempotencyKey: String? = nil) {
        self.idempotencyKey = idempotencyKey
    }
}

/// `GET /workspaces` response — top-level array carrier so the daemon's
/// `sendCodable` path emits a proper top-level type (Swift's
/// JSONEncoder can't encode raw Arrays as top-level today without a
/// shim). v16+. Older Macs 404 the endpoint; iOS treats that as "no
/// persisted workspaces" and falls back to per-session repo bucketing.
public struct WorkspaceListResponse: Codable, Sendable {
    public let workspaces: [CodeWorkspaceRecord]

    public init(workspaces: [CodeWorkspaceRecord]) {
        self.workspaces = workspaces
    }
}

/// `PATCH /workspaces/:id` request — partial update to a workspace's
/// provider defaults. Only the fields provided are overwritten; the
/// rest of the record (sessions, archive metadata) is untouched.
public struct UpdateWorkspaceDefaultsRequest: Codable, Sendable {
    public let providerDefaults: WorkspaceProviderDefaults?
    public let filesToCopy: WorkspaceFilesToCopySettings?
    public let idempotencyKey: String?

    public init(
        providerDefaults: WorkspaceProviderDefaults? = nil,
        filesToCopy: WorkspaceFilesToCopySettings? = nil,
        idempotencyKey: String? = nil
    ) {
        self.providerDefaults = providerDefaults
        self.filesToCopy = filesToCopy
        self.idempotencyKey = idempotencyKey
    }
}

// MARK: - Workspace onboarding (Add Repo flow, wire v23)

/// `POST /workspaces/open-local` body. iOS triggers the Mac to focus and
/// open NSOpenPanel. The Mac is the picker host; iOS is the remote.
/// CGSession-asleep → 423 Locked (use `/workspaces/wake-mac` to wake).
public struct OpenLocalFolderRequest: Codable, Sendable {
    public let idempotencyKey: String?

    public init(idempotencyKey: String? = nil) {
        self.idempotencyKey = idempotencyKey
    }
}

/// `POST /workspaces/from-github` body. Daemon shells `gh repo clone` or
/// falls back to `git clone https://github.com/<spec>.git`. `spec` accepts
/// `owner/repo`, `https://github.com/owner/repo[.git]`, or
/// `git@github.com:owner/repo.git`; daemon normalizes to `owner/repo`.
/// `destinationParent` must canonicalize under `defaultParent` or one of
/// the configured scan roots; otherwise → 403.
public struct CloneFromGitHubRequest: Codable, Sendable {
    public let spec: String
    public let destinationParent: String?
    public let idempotencyKey: String?

    public init(
        spec: String,
        destinationParent: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.spec = spec
        self.destinationParent = destinationParent
        self.idempotencyKey = idempotencyKey
    }
}

/// `POST /workspaces/quick-start` body. Daemon `mkdir`s `parent/name` then
/// `git init`s the new directory. `name` must be non-empty, no `/`, no
/// leading `.`. `parent` is gated like `CloneFromGitHubRequest.destinationParent`.
public struct QuickStartRepoRequest: Codable, Sendable {
    public let name: String
    public let parent: String?
    public let idempotencyKey: String?

    public init(name: String, parent: String? = nil, idempotencyKey: String? = nil) {
        self.name = name
        self.parent = parent
        self.idempotencyKey = idempotencyKey
    }
}

/// `POST /workspaces/wake-mac` body. iOS calls this when an
/// `/workspaces/open-local` request returned 423 Locked.
///
/// **Honest scope:** the daemon can only run when the Mac is already
/// reachable. A fully-asleep Mac cannot serve this endpoint at all —
/// the iOS request never arrives. What the daemon *can* do:
///   1. Run `tailscale wake <hostname>` if Tailscale is installed and a
///      Wake-on-LAN peer is configured. This actually wakes a sleeping
///      Mac if WoL is set up on the LAN.
///   2. Run `caffeinate -u -t 5` to nudge the display awake. This helps
///      when the screen is dimmed/asleep but the Mac is still running
///      (the common case when the daemon receives this request).
/// Neither of these unlocks a screen-locked Mac — that still requires
/// the user to enter their password. The 200 response means a wake
/// signal was sent, NOT that the Mac is now usable for NSOpenPanel.
/// iOS surfaces "Wake signal sent" in the banner and the user must
/// physically unlock if the lock screen is up.
/// 503 returns when neither Tailscale nor caffeinate is available.
public struct WakeMacRequest: Codable, Sendable {
    public let idempotencyKey: String?

    public init(idempotencyKey: String? = nil) {
        self.idempotencyKey = idempotencyKey
    }
}

/// `GET /workspaces/allow-list` response. iOS caches with a 5-min TTL and
/// pre-validates parent paths in the Clone / Quick Start sheets so a bad
/// path fails inline instead of after a round-trip.
public struct WorkspaceAllowListResponse: Codable, Sendable {
    public let allowedRoots: [String]
    public let deniedSubpaths: [String]

    public init(allowedRoots: [String], deniedSubpaths: [String]) {
        self.allowedRoots = allowedRoots
        self.deniedSubpaths = deniedSubpaths
    }
}

/// Typed error surface for the Add-Repo flow. Used by Mac UI (LocalizedError
/// conformance lives on the Mac side in `RepoOnboardingError+Localized.swift`)
/// AND by iOS (decoded from non-2xx daemon response bodies). Conforms to
/// `Codable` + `Error` here in shared so both surfaces see the same shape.
public enum RepoOnboardingError: Error, Codable, Sendable, Equatable {
    case pathMissing
    case notADirectory
    case alreadyRegistered(workspaceId: UUID)
    case notAGitRepo
    case ghAuthFailed
    case cloneFailed(stderr: String)
    case gitInitFailed(stderr: String)
    case persistenceFailed(message: String)
    case pathNotAllowed(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, workspaceId, stderr, message, reason
    }

    private enum Kind: String, Codable {
        case pathMissing, notADirectory, alreadyRegistered, notAGitRepo
        case ghAuthFailed, cloneFailed, gitInitFailed, persistenceFailed, pathNotAllowed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .pathMissing: self = .pathMissing
        case .notADirectory: self = .notADirectory
        case .alreadyRegistered:
            self = .alreadyRegistered(workspaceId: try c.decode(UUID.self, forKey: .workspaceId))
        case .notAGitRepo: self = .notAGitRepo
        case .ghAuthFailed: self = .ghAuthFailed
        case .cloneFailed:
            self = .cloneFailed(stderr: try c.decode(String.self, forKey: .stderr))
        case .gitInitFailed:
            self = .gitInitFailed(stderr: try c.decode(String.self, forKey: .stderr))
        case .persistenceFailed:
            self = .persistenceFailed(message: try c.decode(String.self, forKey: .message))
        case .pathNotAllowed:
            self = .pathNotAllowed(reason: try c.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pathMissing:
            try c.encode(Kind.pathMissing, forKey: .kind)
        case .notADirectory:
            try c.encode(Kind.notADirectory, forKey: .kind)
        case .alreadyRegistered(let workspaceId):
            try c.encode(Kind.alreadyRegistered, forKey: .kind)
            try c.encode(workspaceId, forKey: .workspaceId)
        case .notAGitRepo:
            try c.encode(Kind.notAGitRepo, forKey: .kind)
        case .ghAuthFailed:
            try c.encode(Kind.ghAuthFailed, forKey: .kind)
        case .cloneFailed(let stderr):
            try c.encode(Kind.cloneFailed, forKey: .kind)
            try c.encode(stderr, forKey: .stderr)
        case .gitInitFailed(let stderr):
            try c.encode(Kind.gitInitFailed, forKey: .kind)
            try c.encode(stderr, forKey: .stderr)
        case .persistenceFailed(let message):
            try c.encode(Kind.persistenceFailed, forKey: .kind)
            try c.encode(message, forKey: .message)
        case .pathNotAllowed(let reason):
            try c.encode(Kind.pathNotAllowed, forKey: .kind)
            try c.encode(reason, forKey: .reason)
        }
    }
}
