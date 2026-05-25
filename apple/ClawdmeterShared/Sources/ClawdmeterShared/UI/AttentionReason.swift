import Foundation

public enum AttentionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case awaitingInput
    case planReady
    case pullRequest
    case checksFailed
    case providerBlocked
    case unread
    case outboxPending
    case degraded

    public var label: String {
        switch self {
        case .awaitingInput: return "Needs input"
        case .planReady: return "Plan ready"
        case .pullRequest: return "PR"
        case .checksFailed: return "Checks failed"
        case .providerBlocked: return "Provider blocked"
        case .unread: return "Unread"
        case .outboxPending: return "Outbox"
        case .degraded: return "Degraded"
        }
    }

    public var priority: Int {
        switch self {
        case .providerBlocked, .degraded, .checksFailed: return 0
        case .awaitingInput, .planReady: return 1
        case .pullRequest, .outboxPending: return 2
        case .unread: return 3
        }
    }
}

public struct AttentionSummary: Codable, Hashable, Sendable {
    public var sessionId: UUID
    public var reasons: [AttentionReason]

    public init(sessionId: UUID, reasons: [AttentionReason]) {
        self.sessionId = sessionId
        self.reasons = reasons.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.rawValue < rhs.rawValue
        }
    }

    public var primary: AttentionReason? { reasons.first }
    public var needsAttention: Bool { !reasons.isEmpty }
}

public enum AttentionReasonResolver {
    public static func reasons(
        for session: AgentSession,
        unread: Bool = false,
        outboxPending: Bool = false,
        providerBlocked: Bool = false,
        snoozedUntil: Date? = nil,
        now: Date = Date()
    ) -> [AttentionReason] {
        if let snoozedUntil, snoozedUntil > now {
            return []
        }
        var reasons = Set<AttentionReason>()
        if unread { reasons.insert(.unread) }
        if outboxPending { reasons.insert(.outboxPending) }
        if providerBlocked { reasons.insert(.providerBlocked) }
        if session.status == .degraded { reasons.insert(.degraded) }
        if session.status == .paused { reasons.insert(.awaitingInput) }
        if let plan = session.planText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty,
           session.approvedPlanText != session.planText {
            reasons.insert(.planReady)
        }
        if let pr = session.prMirrorState {
            if pr.prURL != nil {
                reasons.insert(.pullRequest)
            }
            if pr.checksRollup == .failure {
                reasons.insert(.checksFailed)
            }
        }
        return reasons.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.rawValue < rhs.rawValue
        }
    }
}
