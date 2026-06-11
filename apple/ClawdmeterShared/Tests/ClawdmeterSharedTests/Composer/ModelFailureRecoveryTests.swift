import XCTest
@testable import ClawdmeterShared

final class ModelFailureRecoveryTests: XCTestCase {
    func test_retryPrompt_walksBackToPrecedingUserMessage() {
        let items: [ChatItem] = [
            .message(ChatMessage(id: "u1", kind: .userText, title: "", body: "hello", at: Date())),
            .message(ChatMessage(id: "e1", kind: .assistantText, title: "Claude", body: "failed", at: Date(), isError: true))
        ]

        XCTAssertEqual(
            ModelFailureRecovery.retryPrompt(forErrorMessageId: "e1", in: items),
            "hello"
        )
    }

    func test_retryPrompt_skipsNonUserRows() {
        let items: [ChatItem] = [
            .message(ChatMessage(id: "u1", kind: .userText, title: "", body: "first", at: Date())),
            .toolRun(id: "run1", pairs: []),
            .message(ChatMessage(id: "e1", kind: .assistantText, title: "Claude", body: "failed", at: Date(), isError: true))
        ]

        XCTAssertEqual(
            ModelFailureRecovery.retryPrompt(forErrorMessageId: "e1", in: items),
            "first"
        )
    }

    func test_shouldOfferRetryActions_requiresInterruptedTurnAndPrompt() {
        let error = ChatMessage(
            id: "e1",
            kind: .assistantText,
            title: "Claude",
            body: "failed",
            at: Date(),
            isError: true
        )

        XCTAssertTrue(
            ModelFailureRecovery.shouldOfferRetryActions(
                message: error,
                isStreamingTail: false,
                turnState: .interrupted,
                isReadOnly: false,
                retryPrompt: "hello"
            )
        )
        XCTAssertFalse(
            ModelFailureRecovery.shouldOfferRetryActions(
                message: error,
                isStreamingTail: true,
                turnState: .interrupted,
                isReadOnly: false,
                retryPrompt: "hello"
            )
        )
        XCTAssertFalse(
            ModelFailureRecovery.shouldOfferRetryActions(
                message: error,
                isStreamingTail: false,
                turnState: .completed,
                isReadOnly: false,
                retryPrompt: "hello"
            )
        )
        XCTAssertFalse(
            ModelFailureRecovery.shouldOfferRetryActions(
                message: error,
                isStreamingTail: false,
                turnState: .interrupted,
                isReadOnly: true,
                retryPrompt: "hello"
            )
        )
    }

    func test_actionDescriptorsExposeRetryAndRetryInNewChat() {
        XCTAssertEqual(
            ModelFailureRecovery.actionDescriptors(),
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
        )
    }
}
