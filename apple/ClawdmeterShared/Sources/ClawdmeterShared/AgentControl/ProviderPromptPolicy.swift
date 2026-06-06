import Foundation

public enum ProviderPromptOrigin: String, Codable, Hashable, Sendable {
    case legacyClient
    case userComposer
    case userComposerFirstTurn
    case userRecoveryAutoSend
    case scheduledUserFollowUp
    case frontierUserBroadcast
    case liveProviderTest
    case systemProbe
    case systemHeartbeat
    case transportControl

    public var isUserAuthorized: Bool {
        switch self {
        case .userComposer, .userComposerFirstTurn, .userRecoveryAutoSend,
             .scheduledUserFollowUp, .frontierUserBroadcast:
            return true
        case .legacyClient, .liveProviderTest, .systemProbe, .systemHeartbeat,
             .transportControl:
            return false
        }
    }
}

public struct ProviderPromptGuardDecision: Equatable, Sendable {
    public let allowed: Bool
    public let reason: String?

    public static let allowed = ProviderPromptGuardDecision(allowed: true, reason: nil)

    public static func rejected(_ reason: String) -> ProviderPromptGuardDecision {
        ProviderPromptGuardDecision(allowed: false, reason: reason)
    }
}

public enum ProviderPromptGuard {
    public static func validate(
        text: String,
        origin: ProviderPromptOrigin,
        allowLiveProviderSpend: Bool = false
    ) -> ProviderPromptGuardDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected("empty_prompt")
        }

        switch origin {
        case .systemProbe:
            return .rejected("system_probe_prompt_blocked")
        case .systemHeartbeat:
            return .rejected("system_heartbeat_prompt_blocked")
        case .transportControl:
            return .rejected("transport_control_prompt_blocked")
        case .liveProviderTest:
            guard allowLiveProviderSpend else {
                return .rejected("live_provider_spend_not_enabled")
            }
            guard !isSyntheticDiagnostic(trimmed) else {
                return .rejected("synthetic_live_provider_prompt_blocked")
            }
            return .allowed
        case .legacyClient:
            if isSyntheticDiagnostic(trimmed) {
                return .rejected("synthetic_prompt_requires_user_origin")
            }
            return .rejected("legacy_prompt_origin_blocked")
        case .userComposer, .userComposerFirstTurn, .userRecoveryAutoSend,
             .scheduledUserFollowUp, .frontierUserBroadcast:
            return .allowed
        }
    }

    public static func isSyntheticDiagnostic(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return true }
        let exactMatches: Set<String> = [
            "hi",
            "ping",
            "pong",
            "ping pong",
            "heartbeat",
            "keepalive",
            "keep alive",
            "say hi in one short sentence.",
            "say hi in one short sentence",
            "reply with the single word pong and nothing else.",
            "reply with the single word pong and nothing else"
        ]
        if exactMatches.contains(normalized) { return true }
        return normalized.contains("reply with the single word pong")
    }
}

public enum ScheduledFollowUpDeliveryPolicy: String, Codable, Hashable, Sendable {
    case requiresConfirmation
    case autonomousAfterRestart
}
