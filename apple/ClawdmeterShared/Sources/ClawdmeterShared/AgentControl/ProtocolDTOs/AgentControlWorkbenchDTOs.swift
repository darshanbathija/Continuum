import Foundation

// MARK: - Code workbench remote runtime (wire v18)

public enum CodeRunProfileStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case idle
    case starting
    case running
    case exited
    case failed

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = CodeRunProfileStatus(rawValue: raw) ?? .idle
    }
}

public enum CodeRunProfileHealthState: String, Codable, Hashable, Sendable, CaseIterable {
    case unknown
    case healthy
    case unhealthy

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = CodeRunProfileHealthState(rawValue: raw) ?? .unknown
    }
}

public struct CodeRunProfileHealth: Codable, Hashable, Sendable {
    public let state: CodeRunProfileHealthState
    public let statusCode: Int?
    public let message: String?
    public let checkedAt: Date?

    public init(
        state: CodeRunProfileHealthState = .unknown,
        statusCode: Int? = nil,
        message: String? = nil,
        checkedAt: Date? = nil
    ) {
        self.state = state
        self.statusCode = statusCode
        self.message = message
        self.checkedAt = checkedAt
    }
}

public struct CodeRunProfileSnapshot: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public let cwd: String?
    public let command: String?
    public let detectedURL: String?
    public let source: String?
    public let status: CodeRunProfileStatus
    public let health: CodeRunProfileHealth
    public let stdoutLines: [String]
    public let stderrLines: [String]
    public let lastExitCode: Int32?
    public let lastError: String?
    public let updatedAt: Date

    public init(
        sessionId: UUID,
        cwd: String? = nil,
        command: String? = nil,
        detectedURL: String? = nil,
        source: String? = nil,
        status: CodeRunProfileStatus = .idle,
        health: CodeRunProfileHealth = CodeRunProfileHealth(),
        stdoutLines: [String] = [],
        stderrLines: [String] = [],
        lastExitCode: Int32? = nil,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.command = command
        self.detectedURL = detectedURL
        self.source = source
        self.status = status
        self.health = health
        self.stdoutLines = stdoutLines
        self.stderrLines = stderrLines
        self.lastExitCode = lastExitCode
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public struct CodeRunProfileResponse: Codable, Sendable {
    public let profile: CodeRunProfileSnapshot

    public init(profile: CodeRunProfileSnapshot) {
        self.profile = profile
    }
}

public struct CodeRunProfileStartRequest: Codable, Sendable {
    public let command: String?
    public let idempotencyKey: String?

    public init(command: String? = nil, idempotencyKey: String? = nil) {
        self.command = command
        self.idempotencyKey = idempotencyKey
    }
}

public struct CodeCheckpointSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sessionId: UUID
    public let refName: String
    public let turnId: String?
    public let createdAt: Date
    public let summary: String?

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        refName: String,
        turnId: String? = nil,
        createdAt: Date = Date(),
        summary: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.refName = refName
        self.turnId = turnId
        self.createdAt = createdAt
        self.summary = summary
    }
}

public struct CodeCheckpointListResponse: Codable, Sendable {
    public let checkpoints: [CodeCheckpointSnapshot]

    public init(checkpoints: [CodeCheckpointSnapshot]) {
        self.checkpoints = checkpoints
    }
}

public struct CodeCheckpointCreateRequest: Codable, Sendable {
    public let summary: String?
    public let idempotencyKey: String?

    public init(summary: String? = nil, idempotencyKey: String? = nil) {
        self.summary = summary
        self.idempotencyKey = idempotencyKey
    }
}

public struct CodeCheckpointCreateResponse: Codable, Sendable {
    public let checkpoint: CodeCheckpointSnapshot

    public init(checkpoint: CodeCheckpointSnapshot) {
        self.checkpoint = checkpoint
    }
}

public struct CodeCheckpointRestorePreview: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let target: CodeCheckpointSnapshot
    public let safety: CodeCheckpointSnapshot
    public let diffStat: String
    public let diffPatch: String
    public let patchTruncated: Bool
    public let dirtyStatusLines: [String]
    public let untrackedOverwritePaths: [String]
    public let untrackedSnapshotPaths: [String]
    public let blockingReasons: [String]

    public var isBlocked: Bool { !blockingReasons.isEmpty }

    public init(
        id: UUID,
        target: CodeCheckpointSnapshot,
        safety: CodeCheckpointSnapshot,
        diffStat: String,
        diffPatch: String,
        patchTruncated: Bool,
        dirtyStatusLines: [String],
        untrackedOverwritePaths: [String],
        untrackedSnapshotPaths: [String],
        blockingReasons: [String]
    ) {
        self.id = id
        self.target = target
        self.safety = safety
        self.diffStat = diffStat
        self.diffPatch = diffPatch
        self.patchTruncated = patchTruncated
        self.dirtyStatusLines = dirtyStatusLines
        self.untrackedOverwritePaths = untrackedOverwritePaths
        self.untrackedSnapshotPaths = untrackedSnapshotPaths
        self.blockingReasons = blockingReasons
    }
}

public struct CodeCheckpointRestorePreviewResponse: Codable, Sendable {
    public let preview: CodeCheckpointRestorePreview

    public init(preview: CodeCheckpointRestorePreview) {
        self.preview = preview
    }
}

public struct CodeCheckpointRestoreRequest: Codable, Sendable {
    public let previewId: UUID
    public let idempotencyKey: String?

    public init(previewId: UUID, idempotencyKey: String? = nil) {
        self.previewId = previewId
        self.idempotencyKey = idempotencyKey
    }
}

public struct CodeCheckpointRestoreResponse: Codable, Sendable {
    public let restored: Bool
    public let checkpoint: CodeCheckpointSnapshot
    public let safety: CodeCheckpointSnapshot?

    public init(restored: Bool, checkpoint: CodeCheckpointSnapshot, safety: CodeCheckpointSnapshot?) {
        self.restored = restored
        self.checkpoint = checkpoint
        self.safety = safety
    }
}

public enum PRReviewState: String, Codable, Hashable, Sendable, CaseIterable {
    case approved
    case changesRequested = "changes_requested"
    case reviewRequired = "review_required"
    case pending
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = PRReviewState(rawValue: raw) ?? .unknown
    }
}

public enum PRMergeability: String, Codable, Hashable, Sendable, CaseIterable {
    case mergeable
    case blocked
    case dirty
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = PRMergeability(rawValue: raw) ?? .unknown
    }
}

public enum PRCheckState: String, Codable, Hashable, Sendable, CaseIterable {
    case success
    case pending
    case failure
    case skipped
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = PRCheckState(rawValue: raw) ?? .unknown
    }
}

public struct PRCheckMirror: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let state: PRCheckState
    public let url: String?
    public let completedAt: Date?

    public init(name: String, state: PRCheckState, url: String? = nil, completedAt: Date? = nil) {
        self.name = name
        self.state = state
        self.url = url
        self.completedAt = completedAt
    }
}

public struct PRMergeResult: Codable, Hashable, Sendable {
    public let merged: Bool
    public let mergedAt: Date?
    public let sha: String?
    public let error: String?

    public init(merged: Bool, mergedAt: Date? = nil, sha: String? = nil, error: String? = nil) {
        self.merged = merged
        self.mergedAt = mergedAt
        self.sha = sha
        self.error = error
    }
}

public struct PRMirrorState: Codable, Hashable, Sendable {
    public let branchName: String?
    public let prURL: String?
    public let number: Int?
    public let title: String?
    public let state: PRStatus.State?
    public let checks: [PRCheckMirror]
    public let checksRollup: PRCheckState
    public let reviewState: PRReviewState
    public let mergeability: PRMergeability
    public let protectedBranchGate: Bool
    public let lastMergeResult: PRMergeResult?
    public let lastCheckedAt: Date?

    public init(
        branchName: String? = nil,
        prURL: String? = nil,
        number: Int? = nil,
        title: String? = nil,
        state: PRStatus.State? = nil,
        checks: [PRCheckMirror] = [],
        checksRollup: PRCheckState = .unknown,
        reviewState: PRReviewState = .unknown,
        mergeability: PRMergeability = .unknown,
        protectedBranchGate: Bool = false,
        lastMergeResult: PRMergeResult? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.branchName = branchName
        self.prURL = prURL
        self.number = number
        self.title = title
        self.state = state
        self.checks = checks
        self.checksRollup = checksRollup
        self.reviewState = reviewState
        self.mergeability = mergeability
        self.protectedBranchGate = protectedBranchGate
        self.lastMergeResult = lastMergeResult
        self.lastCheckedAt = lastCheckedAt
    }
}

/// Where the session executes — the Codex-desktop "mode picker" axis.
/// Switching mode on a live session triggers a restart in the new cwd
/// (D13 overlay flow). Wire-stable: new variants append.
public enum SessionMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Run in the repo's primary checkout. Edits land directly.
    case local
    /// Run inside `.claude/worktrees/<slug>` (git worktree branched off main).
    /// Same repo, isolated working tree.
    case worktree
    /// Reserved for future remote-Mac federation (G20). Disabled in v1 UI.
    case cloud
}

/// Top-level session category (v0.8 schema v5). Distinguishes coding
/// sessions (the existing v0.7.x flow that owns a repo + worktree) from
/// chat sessions (the new v0.8 Chat tab — empty cwd, plan-mode, no repo).
/// Default `.code` on decode so v3/v4 sessions.json files round-trip
/// unchanged.
public enum SessionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case code
    case chat

    /// Lenient decoder. Unknown raws (forward-compat) fall back to `.code`
    /// rather than throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SessionKind(rawValue: raw) ?? .code
    }
}

/// Per-session backend choice for Codex chat (v0.8 schema v5 + RE1
/// resolution). Customer-selectable; default is `.sdk` because the SDK
/// surfaces typed events + multi-subscriber + iOS handoff. CLI is the
/// uniform-with-Claude fallback for users who hit SDK provisioning
/// trouble or just prefer the tmux path.
///
/// **Per-session pinning**: the backend chosen at spawn time is stored on
/// the AgentSession and used for the lifetime of that chat. Flipping the
/// global default in Settings does not migrate live sessions.
public enum CodexChatBackend: String, Codable, Hashable, Sendable, CaseIterable {
    case sdk
    case cli

    /// Lenient decoder. Unknown raws fall back to `.sdk` (the default).
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = CodexChatBackend(rawValue: raw) ?? .sdk
    }
}
