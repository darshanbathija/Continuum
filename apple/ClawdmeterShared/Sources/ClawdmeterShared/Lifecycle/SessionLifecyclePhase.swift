import Foundation

public enum SessionLifecyclePhase: String, Codable, Hashable, Sendable, CaseIterable {
    case draft
    case preflightBlocked
    case spawning
    case researching
    case planning
    case awaitingApproval
    case running
    case needsInput
    case reviewing
    case validating
    case prDrafting
    case prOpen
    case checksBlocked
    case readyToMerge
    case merged
    case archived

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SessionLifecyclePhase(rawValue: raw) ?? .running
    }
}

public enum LifecycleBlockerKind: String, Codable, Hashable, Sendable, CaseIterable {
    case providerAuth
    case repoState
    case preflight
    case providerUnsupported
    case runtimeDegraded
    case needsUserInput
    case validationFailing
    case ciPending
    case ciFailing
    case reviewPending
    case mergeBlocked
    case mergeConflict
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = LifecycleBlockerKind(rawValue: raw) ?? .unknown
    }
}

public struct LifecycleBlocker: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue):\(summary)" }

    public let kind: LifecycleBlockerKind
    public let summary: String
    public let resolution: String?
    public let canOverride: Bool

    public init(
        kind: LifecycleBlockerKind,
        summary: String,
        resolution: String? = nil,
        canOverride: Bool = false
    ) {
        self.kind = kind
        self.summary = summary
        self.resolution = resolution
        self.canOverride = canOverride
    }
}

public enum LifecycleEvidenceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case preflight
    case plan
    case approvedPlan
    case checkpoint
    case diff
    case validationRun
    case pr
    case prCheck
    case deploy
    case transcript
    case runtime
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = LifecycleEvidenceKind(rawValue: raw) ?? .unknown
    }
}

public struct LifecycleEvidencePayload: Codable, Hashable, Sendable {
    public let text: String?
    public let url: String?
    public let refId: String?
    public let metadata: [String: String]

    public init(
        text: String? = nil,
        url: String? = nil,
        refId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.text = text
        self.url = url
        self.refId = refId
        self.metadata = metadata
    }
}

public struct LifecycleEvidence: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: LifecycleEvidenceKind
    public let title: String
    public let createdAt: Date
    public let payload: LifecycleEvidencePayload

    public init(
        id: UUID = UUID(),
        kind: LifecycleEvidenceKind,
        title: String,
        createdAt: Date = Date(),
        payload: LifecycleEvidencePayload = LifecycleEvidencePayload()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.payload = payload
    }
}

public enum SessionLifecycleNextActionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case startSession
    case resolvePreflight
    case approvePlan
    case answerQuestion
    case inspectDiff
    case runValidation
    case createPR
    case inspectChecks
    case mergePR
    case openPR
    case restoreCheckpoint
    case none
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SessionLifecycleNextActionKind(rawValue: raw) ?? .unknown
    }
}

public struct SessionLifecycleNextAction: Codable, Hashable, Sendable {
    public let kind: SessionLifecycleNextActionKind
    public let title: String
    public let deeplink: String?
    public let idempotencyKey: String?

    public init(
        kind: SessionLifecycleNextActionKind,
        title: String,
        deeplink: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.deeplink = deeplink
        self.idempotencyKey = idempotencyKey
    }
}

public struct SessionGoalSnapshot: Codable, Hashable, Sendable {
    public let text: String
    public let source: String
    public let createdAt: Date?

    public init(text: String, source: String = "session", createdAt: Date? = nil) {
        self.text = text
        self.source = source
        self.createdAt = createdAt
    }
}

public struct SessionLifecycleBranchInfo: Codable, Hashable, Sendable {
    public let repoKey: String?
    public let repoDisplayName: String
    public let mode: SessionMode
    public let worktreePath: String?
    public let runtimeCwd: String?
    public let branchName: String?
    public let baseBranch: String?

    public init(
        repoKey: String?,
        repoDisplayName: String,
        mode: SessionMode,
        worktreePath: String? = nil,
        runtimeCwd: String? = nil,
        branchName: String? = nil,
        baseBranch: String? = nil
    ) {
        self.repoKey = repoKey
        self.repoDisplayName = repoDisplayName
        self.mode = mode
        self.worktreePath = worktreePath
        self.runtimeCwd = runtimeCwd
        self.branchName = branchName
        self.baseBranch = baseBranch
    }
}

public struct SessionLifecyclePRInfo: Codable, Hashable, Sendable {
    public let number: Int?
    public let title: String?
    public let url: String?
    public let state: PRStatus.State?
    public let checksRollup: PRCheckState
    public let reviewState: PRReviewState
    public let mergeability: PRMergeability
    public let protectedBranchGate: Bool
    public let lastCheckedAt: Date?

    public init(
        number: Int? = nil,
        title: String? = nil,
        url: String? = nil,
        state: PRStatus.State? = nil,
        checksRollup: PRCheckState = .unknown,
        reviewState: PRReviewState = .unknown,
        mergeability: PRMergeability = .unknown,
        protectedBranchGate: Bool = false,
        lastCheckedAt: Date? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checksRollup = checksRollup
        self.reviewState = reviewState
        self.mergeability = mergeability
        self.protectedBranchGate = protectedBranchGate
        self.lastCheckedAt = lastCheckedAt
    }
}

public enum SessionLifecycleValidationState: String, Codable, Hashable, Sendable, CaseIterable {
    case notConfigured
    case idle
    case running
    case passed
    case failed
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SessionLifecycleValidationState(rawValue: raw) ?? .unknown
    }
}

public struct SessionLifecycleValidationStatus: Codable, Hashable, Sendable {
    public let state: SessionLifecycleValidationState
    public let title: String?
    public let summary: String?
    public let updatedAt: Date?

    public init(
        state: SessionLifecycleValidationState,
        title: String? = nil,
        summary: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.state = state
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

public struct SessionLifecycleCheckpointStatus: Codable, Hashable, Sendable {
    public let latest: CodeCheckpointSnapshot?
    public let count: Int
    public let canRestore: Bool

    public init(latest: CodeCheckpointSnapshot? = nil, count: Int = 0, canRestore: Bool = false) {
        self.latest = latest
        self.count = count
        self.canRestore = canRestore
    }
}

public struct SessionLifecycleProviderCapabilities: Codable, Hashable, Sendable {
    public let agent: AgentKind
    public let supportsPlanApproval: Bool
    public let supportsResume: Bool
    public let supportsTranscriptImport: Bool
    public let supportsInterrupt: Bool
    public let supportsPRs: Bool
    public let supportsCheckpoints: Bool
    public let supportsProviderHandoff: Bool

    public init(
        agent: AgentKind,
        supportsPlanApproval: Bool,
        supportsResume: Bool,
        supportsTranscriptImport: Bool,
        supportsInterrupt: Bool,
        supportsPRs: Bool,
        supportsCheckpoints: Bool,
        supportsProviderHandoff: Bool
    ) {
        self.agent = agent
        self.supportsPlanApproval = supportsPlanApproval
        self.supportsResume = supportsResume
        self.supportsTranscriptImport = supportsTranscriptImport
        self.supportsInterrupt = supportsInterrupt
        self.supportsPRs = supportsPRs
        self.supportsCheckpoints = supportsCheckpoints
        self.supportsProviderHandoff = supportsProviderHandoff
    }
}

public enum SessionLifecycleLedgerEntryKind: String, Codable, Hashable, Sendable, CaseIterable {
    case phaseChanged
    case blockerAdded
    case blockerCleared
    case evidenceAdded
    case actionTaken
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SessionLifecycleLedgerEntryKind(rawValue: raw) ?? .unknown
    }
}

public struct SessionLifecycleLedgerEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sessionId: UUID
    public let seq: UInt64
    public let kind: SessionLifecycleLedgerEntryKind
    public let phase: SessionLifecyclePhase?
    public let title: String
    public let createdAt: Date
    public let evidence: [LifecycleEvidence]

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        seq: UInt64,
        kind: SessionLifecycleLedgerEntryKind,
        phase: SessionLifecyclePhase? = nil,
        title: String,
        createdAt: Date = Date(),
        evidence: [LifecycleEvidence] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.kind = kind
        self.phase = phase
        self.title = title
        self.createdAt = createdAt
        self.evidence = evidence
    }
}

public struct SessionLifecycleSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let sessionId: UUID
    public var id: UUID { sessionId }

    public let phase: SessionLifecyclePhase
    public let goal: SessionGoalSnapshot?
    public let blockers: [LifecycleBlocker]
    public let evidence: [LifecycleEvidence]
    public let nextAction: SessionLifecycleNextAction?
    public let branchInfo: SessionLifecycleBranchInfo
    public let prInfo: SessionLifecyclePRInfo?
    public let providerCapabilities: SessionLifecycleProviderCapabilities
    public let validationStatus: SessionLifecycleValidationStatus?
    public let checkpointStatus: SessionLifecycleCheckpointStatus?
    public let updatedAt: Date
    public let seq: UInt64

    public init(
        sessionId: UUID,
        phase: SessionLifecyclePhase,
        goal: SessionGoalSnapshot? = nil,
        blockers: [LifecycleBlocker] = [],
        evidence: [LifecycleEvidence] = [],
        nextAction: SessionLifecycleNextAction? = nil,
        branchInfo: SessionLifecycleBranchInfo,
        prInfo: SessionLifecyclePRInfo? = nil,
        providerCapabilities: SessionLifecycleProviderCapabilities,
        validationStatus: SessionLifecycleValidationStatus? = nil,
        checkpointStatus: SessionLifecycleCheckpointStatus? = nil,
        updatedAt: Date = Date(),
        seq: UInt64 = 0
    ) {
        self.sessionId = sessionId
        self.phase = phase
        self.goal = goal
        self.blockers = blockers
        self.evidence = evidence
        self.nextAction = nextAction
        self.branchInfo = branchInfo
        self.prInfo = prInfo
        self.providerCapabilities = providerCapabilities
        self.validationStatus = validationStatus
        self.checkpointStatus = checkpointStatus
        self.updatedAt = updatedAt
        self.seq = seq
    }
}

public struct SessionLifecycleSnapshotResponse: Codable, Hashable, Sendable {
    public let snapshot: SessionLifecycleSnapshot

    public init(snapshot: SessionLifecycleSnapshot) {
        self.snapshot = snapshot
    }
}
