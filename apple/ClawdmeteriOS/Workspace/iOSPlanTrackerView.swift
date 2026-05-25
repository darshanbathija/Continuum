import SwiftUI
import ClawdmeterShared

/// iOS plan tracker — vertical timeline of steps parsed from pending or
/// approved plan text
/// using the shared `ChatMessageOrdering.extractStepCandidates` heuristic
/// (which has 12-test coverage in ClawdmeterShared).
///
/// Sessions v2 Phase 4. Steps render as a checkbox-style list; the user
/// can tap to manually toggle completion (manual override of the heuristic
/// auto-complete that the Mac PlanTrackerPane uses).
struct iOSPlanTrackerView: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    /// Called when the user taps "Approve & run". The parent SessionDetail
    /// routes this through `AgentControlClient.approvePlan(sessionId:)` or
    /// the iOS `MobileCommandOutbox` so v16 dedup applies. When nil,
    /// the button is hidden (the stub-only path used during demos).
    var onApprove: (() async -> Void)? = nil
    @State private var manuallyCompleted: Set<String> = []
    @State private var isApproving: Bool = false

    private var displayPlanText: String? {
        for candidate in [session.planText, session.approvedPlanText] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { continue }
            return trimmed
        }
        return nil
    }

    var body: some View {
        Group {
            if displayPlanText != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Plan - \(steps.count) steps")
                            .font(TahoeFont.body(11, weight: .bold))
                            .tracking(0.5)
                            .textCase(.uppercase)
                            .foregroundStyle(t.fg3)
                        if let goal = session.goal, !goal.isEmpty {
                            TahoeGlass(radius: 14, tone: .chip) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Goal")
                                        .font(TahoeFont.body(10.5, weight: .bold))
                                        .foregroundStyle(t.fg4)
                                    Text(goal)
                                        .font(TahoeFont.body(12.5, weight: .semibold))
                                        .foregroundStyle(t.fg)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        TahoeGlass(radius: 16, tone: .raised) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                    stepRow(index: index, text: step)
                                    if index < steps.count - 1 {
                                        TahoeHair()
                                    }
                                }
                            }
                        }

                        if session.status == .planning, onApprove != nil {
                            Button {
                                Task { await approve() }
                            } label: {
                                HStack(spacing: 8) {
                                    if isApproving {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        TahoeIcon("check", size: 13, weight: .bold)
                                    }
                                    Text(isApproving ? "Approving..." : "Approve & run")
                                        .font(TahoeFont.body(13, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .disabled(isApproving)
                            .accessibilityLabel("Approve plan and run")
                            .accessibilityHint("Switches the agent out of plan mode into edit mode.")
                        }
                    }
                    .padding(16)
                }
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            TahoeIcon("doc", size: 24)
                .foregroundStyle(t.fg4)
            Text("No plan yet")
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Plans appear here when the agent proposes one.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var steps: [String] {
        guard let planText = displayPlanText else { return [] }
        let candidates = ChatMessageOrdering.extractStepCandidates(from: planText)
        if !candidates.isEmpty { return candidates }
        // Fall back to per-line splitting if the heuristic returned nothing.
        return planText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func stepRow(index: Int, text: String) -> some View {
        let completed = manuallyCompleted.contains(text)
        Button {
            if completed {
                manuallyCompleted.remove(text)
            } else {
                manuallyCompleted.insert(text)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(completed ? Color.green.opacity(0.18) : (index == 0 ? t.accentAlpha(0.18) : t.hair2))
                    .frame(width: 22, height: 22)
                    .overlay {
                        if completed {
                            TahoeIcon("check", size: 11, weight: .bold)
                                .foregroundStyle(.green)
                        } else {
                            Text("\(index + 1)")
                                .font(TahoeFont.mono(11, weight: .bold))
                                .foregroundStyle(index == 0 ? t.accent : t.fg2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(TahoeFont.body(12.5))
                        .strikethrough(completed)
                        .foregroundStyle(completed ? t.fg3 : t.fg)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index + 1). \(text)")
        .accessibilityValue(completed ? "Completed" : "Not completed")
        .accessibilityHint("Double-tap to toggle completion.")
        .accessibilityAddTraits(completed ? [.isButton, .isSelected] : .isButton)
    }

    @MainActor
    private func approve() async {
        isApproving = true
        defer { isApproving = false }
        await onApprove?()
    }
}
