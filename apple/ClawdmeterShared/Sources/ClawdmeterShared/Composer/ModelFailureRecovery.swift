import Foundation

public struct ModelFailureActionDescriptor: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case retry
        case retryInNewChat
    }

    public let kind: Kind
    public let visibleTitle: String
    public let accessibilityIdentifier: String

    public init(kind: Kind, visibleTitle: String, accessibilityIdentifier: String) {
        self.kind = kind
        self.visibleTitle = visibleTitle
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// Pure helpers for recovering from a provider/model failure row in the
/// transcript (`assistantText` + `isError: true`, turn `.interrupted`).
public enum ModelFailureRecovery {
    /// Walk backward from an error assistant row to the user prompt that
    /// triggered the failed turn.
    public static func retryPrompt(
        forErrorMessageId errorMessageId: String,
        in items: [ChatItem]
    ) -> String? {
        guard let errorIndex = items.firstIndex(where: { item in
            guard case .message(let message) = item else { return false }
            return message.id == errorMessageId
                && message.kind == .assistantText
                && message.isError
        }) else { return nil }

        for index in stride(from: errorIndex - 1, through: 0, by: -1) {
            guard case .message(let message) = items[index],
                  message.kind == .userText
            else { continue }
            let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            return message.body
        }
        return nil
    }

    public static func shouldOfferRetryActions(
        message: ChatMessage,
        isStreamingTail: Bool,
        turnState: TurnState,
        isReadOnly: Bool,
        retryPrompt: String?
    ) -> Bool {
        message.kind == .assistantText
            && message.isError
            && !isStreamingTail
            && turnState == .interrupted
            && !isReadOnly
            && retryPrompt != nil
    }

    public static func actionDescriptors() -> [ModelFailureActionDescriptor] {
        [
            ModelFailureActionDescriptor(
                kind: .retry,
                visibleTitle: "Retry",
                accessibilityIdentifier: "transcript.modelFailure.retry"
            ),
            ModelFailureActionDescriptor(
                kind: .retryInNewChat,
                visibleTitle: "Retry in new chat",
                accessibilityIdentifier: "transcript.modelFailure.retryInNewChat"
            )
        ]
    }
}
