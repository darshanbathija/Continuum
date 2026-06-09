import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeReviewPlanPane: View {
    @Environment(\.tahoe) private var t
    let pendingPlanText: String?
    let approvedPlanText: String?
    let chatStore: SessionChatStore?
    var onApprove: (() -> Void)?

    struct Presentation: Equatable {
        enum Source: String {
            case pending
            case approved
            case todos
            case empty
        }

        struct ActionDescriptor: Equatable {
            let visibleTitle: String
            let accessibilityLabel: String
            let accessibilityIdentifier: String
            let isEnabled: Bool
        }

        let source: Source
        let steps: [String]
        let stateTitle: String
        let emptyTitle: String
        let emptyCopy: String
        let approveAction: ActionDescriptor?

        var headerTitle: String {
            "Plan · \(steps.count) steps"
        }
    }

    static func presentation(
        pendingPlanText: String?,
        approvedPlanText: String?,
        todoTexts: [String],
        canApprovePendingPlan: Bool
    ) -> Presentation {
        if let pending = reviewablePlanText(pendingPlanText) {
            return Presentation(
                source: .pending,
                steps: TahoePlanParser.steps(from: pending, cap: 8),
                stateTitle: "Pending approval",
                emptyTitle: "No parsed plan steps",
                emptyCopy: "The pending plan is present, but no list steps were detected.",
                approveAction: Presentation.ActionDescriptor(
                    visibleTitle: "Approve & run",
                    accessibilityLabel: "Approve plan and run",
                    accessibilityIdentifier: "code.plan-pane.approve",
                    isEnabled: canApprovePendingPlan
                )
            )
        }

        if let approved = reviewablePlanText(approvedPlanText) {
            return Presentation(
                source: .approved,
                steps: TahoePlanParser.steps(from: approved, cap: 8),
                stateTitle: "Approved",
                emptyTitle: "No parsed plan steps",
                emptyCopy: "The approved plan is present, but no list steps were detected.",
                approveAction: nil
            )
        }

        let todos = Array(todoTexts.prefix(8))
        if !todos.isEmpty {
            return Presentation(
                source: .todos,
                steps: todos,
                stateTitle: "From active todos",
                emptyTitle: "No approved plan",
                emptyCopy: emptyPlanCopy,
                approveAction: nil
            )
        }

        return Presentation(
            source: .empty,
            steps: [],
            stateTitle: "No plan",
            emptyTitle: "No approved plan",
            emptyCopy: emptyPlanCopy,
            approveAction: nil
        )
    }

    private static let emptyPlanCopy = "No approved plan file has been captured for this session."

    private var presentation: Presentation {
        Self.presentation(
            pendingPlanText: pendingPlanText,
            approvedPlanText: approvedPlanText,
            todoTexts: chatStore?.snapshot.codexTodos.map(\.text) ?? [],
            canApprovePendingPlan: onApprove != nil
        )
    }

    private static func reviewablePlanText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    var body: some View {
        let presentation = presentation
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(presentation.headerTitle)
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(t.fg3)
                    Spacer(minLength: 8)
                    Text(presentation.stateTitle)
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(t.fg4)
                        .accessibilityIdentifier("code.plan-pane.state")
                }
                .padding(.bottom, 10)

                if presentation.steps.isEmpty {
                    TahoeEmptyReviewState(icon: "doc", title: presentation.emptyTitle, body: presentation.emptyCopy)
                        .accessibilityIdentifier("code.plan-pane.empty")
                } else {
                    TahoeReviewPlanRows(steps: presentation.steps)
                        .accessibilityIdentifier("code.plan-pane.steps")
                }

                if let approveAction = presentation.approveAction {
                    TahoeHairline()
                        .padding(.vertical, 12)
                    HStack(spacing: 8) {
                        Spacer(minLength: 8)
                        TahoeAccentButton(size: .m, disabled: !approveAction.isEnabled) {
                            onApprove?()
                        } label: {
                            Text(approveAction.visibleTitle)
                        }
                        .accessibilityLabel(approveAction.accessibilityLabel)
                        .accessibilityIdentifier(approveAction.accessibilityIdentifier)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.plan-pane")
    }
}
