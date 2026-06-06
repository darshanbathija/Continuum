import Foundation

// MARK: - PR + Diff DTOs (Sessions v2 Phase 4)

/// `GET /sessions/:id/pr` response. nil = no PR yet (offer Create).
public struct PRStatus: Codable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case open, merged, closed, draft
    }

    public let url: String
    public let number: Int
    public let title: String
    public let body: String
    public let state: State
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    /// Approve / request-changes / pending / null. From `gh pr view --json`.
    public let reviewDecision: String?
    /// CI checks rolled up: "success" / "pending" / "failure" / null.
    public let checksRollup: String?
    /// Individual check runs/status contexts mirrored from `gh pr view`.
    public let checks: [PRCheckMirror]?
    /// Conservative mergeability derived by the daemon from state + CI.
    public let mergeability: PRMergeability?
    /// Daemon timestamp for the last gh poll backing this snapshot.
    public let lastCheckedAt: Date?

    public init(
        url: String,
        number: Int,
        title: String,
        body: String,
        state: State,
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        reviewDecision: String? = nil,
        checksRollup: String? = nil,
        checks: [PRCheckMirror]? = nil,
        mergeability: PRMergeability? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.url = url
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.reviewDecision = reviewDecision
        self.checksRollup = checksRollup
        self.checks = checks
        self.mergeability = mergeability
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct CreatePRRequest: Codable, Sendable {
    public let title: String?       // nil = AI-generate via Haiku 4.5
    public let body: String?        // nil = AI-generate
    public let baseBranch: String?  // nil = repo default
    public let idempotencyKey: String?

    public init(
        title: String? = nil,
        body: String? = nil,
        baseBranch: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.title = title
        self.body = body
        self.baseBranch = baseBranch
        self.idempotencyKey = idempotencyKey
    }
}

public enum PRMergeMethod: String, Codable, Hashable, Sendable, CaseIterable {
    case merge
    case squash
    case rebase

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = PRMergeMethod(rawValue: raw) ?? .squash
    }
}

public struct MergePRRequest: Codable, Sendable {
    public let method: PRMergeMethod
    public let deleteBranch: Bool
    public let auto: Bool
    public let adminOverride: Bool
    public let idempotencyKey: String?

    public init(
        method: PRMergeMethod = .squash,
        deleteBranch: Bool = false,
        auto: Bool = false,
        adminOverride: Bool = false,
        idempotencyKey: String? = nil
    ) {
        self.method = method
        self.deleteBranch = deleteBranch
        self.auto = auto
        self.adminOverride = adminOverride
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case method, deleteBranch, auto, adminOverride, idempotencyKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.method = (try? c.decodeIfPresent(PRMergeMethod.self, forKey: .method)) ?? .squash
        self.deleteBranch = (try? c.decodeIfPresent(Bool.self, forKey: .deleteBranch)) ?? false
        self.auto = (try? c.decodeIfPresent(Bool.self, forKey: .auto)) ?? false
        self.adminOverride = (try? c.decodeIfPresent(Bool.self, forKey: .adminOverride)) ?? false
        self.idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }
}

public struct MergePRResponse: Codable, Sendable {
    public let ok: Bool
    public let merged: Bool
    public let pr: PRStatus?
    public let receipt: MobileCommandReceipt?
    public let error: String?

    public init(
        ok: Bool,
        merged: Bool,
        pr: PRStatus? = nil,
        receipt: MobileCommandReceipt? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.merged = merged
        self.pr = pr
        self.receipt = receipt
        self.error = error
    }
}

public enum PRReviewAction: String, Codable, Hashable, Sendable, CaseIterable {
    case approve
    case comment
    case requestChanges = "request_changes"

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = PRReviewAction(rawValue: raw) ?? .comment
    }
}

public struct PRReviewRequest: Codable, Sendable {
    public let action: PRReviewAction
    public let body: String?
    public let idempotencyKey: String?

    public init(
        action: PRReviewAction = .approve,
        body: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.action = action
        self.body = body
        self.idempotencyKey = idempotencyKey
    }
}

public struct PRReviewResponse: Codable, Sendable {
    public let ok: Bool
    public let pr: PRStatus?
    public let receipt: MobileCommandReceipt?
    public let error: String?

    public init(
        ok: Bool,
        pr: PRStatus? = nil,
        receipt: MobileCommandReceipt? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.pr = pr
        self.receipt = receipt
        self.error = error
    }
}

/// One file's diff. `hunks` may be empty when the file is too large to
/// inline; the iOS view shows "see full" CTA.
public struct GitDiffFile: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?     // present on renames
    public let status: String       // "A" / "M" / "D" / "R" / "C"
    public let additions: Int
    public let deletions: Int
    public let hunks: [GitDiffHunk]
    public let truncated: Bool
    /// Optional daemon action domain: "unstaged", "staged", "mixed",
    /// or "untracked". Older daemons omit it.
    public let changeState: String?

    public init(
        path: String,
        oldPath: String? = nil,
        status: String,
        additions: Int,
        deletions: Int,
        hunks: [GitDiffHunk] = [],
        truncated: Bool = false,
        changeState: String? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
        self.truncated = truncated
        self.changeState = changeState
    }
}

public enum GitDiffActionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case stageFile = "stage_file"
    case unstageFile = "unstage_file"
    case discardFile = "discard_file"

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = GitDiffActionKind(rawValue: raw) ?? .stageFile
    }
}

public struct GitDiffActionRequest: Codable, Sendable {
    public let action: GitDiffActionKind
    public let idempotencyKey: String?

    public init(action: GitDiffActionKind, idempotencyKey: String? = nil) {
        self.action = action
        self.idempotencyKey = idempotencyKey
    }
}

public struct GitDiffActionResponse: Codable, Sendable {
    public let ok: Bool
    public let files: [GitDiffFile]
    public let receipt: MobileCommandReceipt?
    public let error: String?

    public init(
        ok: Bool,
        files: [GitDiffFile] = [],
        receipt: MobileCommandReceipt? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.files = files
        self.receipt = receipt
        self.error = error
    }
}

public struct GitDiffHunk: Codable, Sendable {
    public let header: String       // @@ -a,b +c,d @@
    public let lines: [Line]

    public struct Line: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case context, addition, deletion }
        public let kind: Kind
        public let text: String
        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public init(header: String, lines: [Line]) {
        self.header = header
        self.lines = lines
    }
}

// MARK: - Preflight cost + rate-limit gate (Phase 8 / D3)

public struct PreflightQuery: Codable, Sendable {
    public let repoKey: String
    public let agent: AgentKind
    public let model: String
    public let effort: ReasoningEffort?
    public let goalLength: Int      // characters, for token-count estimate

    public init(repoKey: String, agent: AgentKind, model: String, effort: ReasoningEffort?, goalLength: Int) {
        self.repoKey = repoKey
        self.agent = agent
        self.model = model
        self.effort = effort
        self.goalLength = goalLength
    }
}

public struct PreflightResponse: Codable, Sendable {
    /// Estimated USD cost for the session. Best-effort from past sessions
    /// of the same model on this repo. nil if no history.
    public let estimatedCostUSD: Double?
    /// Estimated weekly-cap consumption percentage (0.0–1.0). nil if data
    /// is missing or stale.
    public let weeklyCapPct: Double?
    /// True when this session at this model/effort would push weekly usage
    /// over the cap. UI shows the soft-warn banner (D11).
    public let wouldCap: Bool
    /// Suggested alternative model id when wouldCap == true. nil otherwise.
    public let suggestedSwap: String?
    /// True when the underlying usage snapshot is older than 1 hour.
    public let staleData: Bool

    public init(
        estimatedCostUSD: Double? = nil,
        weeklyCapPct: Double? = nil,
        wouldCap: Bool = false,
        suggestedSwap: String? = nil,
        staleData: Bool = false
    ) {
        self.estimatedCostUSD = estimatedCostUSD
        self.weeklyCapPct = weeklyCapPct
        self.wouldCap = wouldCap
        self.suggestedSwap = suggestedSwap
        self.staleData = staleData
    }
}
