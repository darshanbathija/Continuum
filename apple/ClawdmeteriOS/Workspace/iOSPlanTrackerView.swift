import SwiftUI
import ClawdmeterShared

/// iOS plan tracker — vertical timeline of steps parsed from `planText`
/// using the shared `ChatMessageOrdering.extractStepCandidates` heuristic
/// (which has 12-test coverage in ClawdmeterShared).
///
/// Sessions v2 Phase 4. Steps render as a checkbox-style list; the user
/// can tap to manually toggle completion (manual override of the heuristic
/// auto-complete that the Mac PlanTrackerPane uses).
struct iOSPlanTrackerView: View {
    let session: AgentSession
    /// Called when the user taps "Approve & run". The parent SessionDetail
    /// routes this through `AgentControlClient.approvePlan(sessionId:)` or
    /// the iOS `MobileCommandOutbox` so v16 dedup applies. When nil,
    /// the button is hidden (the stub-only path used during demos).
    var onApprove: (() async -> Void)? = nil
    @State private var manuallyCompleted: Set<String> = []
    @State private var isApproving: Bool = false

    var body: some View {
        Group {
            if let planText = session.planText, !planText.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let goal = session.goal, !goal.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Goal")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(goal)
                                    .font(.callout.weight(.medium))
                            }
                            .padding(.bottom, 4)
                        }

                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            stepRow(index: index, text: step)
                        }

                        if session.status == .planning, onApprove != nil {
                            Button {
                                Task { await approve() }
                            } label: {
                                if isApproving {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Label("Approve & run", systemImage: "checkmark.seal.fill")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SessionsV2Theme.accent)
                            .disabled(isApproving)
                            .frame(minHeight: 44)
                            .padding(.top, 12)
                            .accessibilityLabel("Approve plan and run")
                            .accessibilityHint("Switches the agent out of plan mode into edit mode.")
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No plan yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Plans appear here when Claude exits plan mode with a proposal.")
                )
            }
        }
    }

    private var steps: [String] {
        guard let planText = session.planText else { return [] }
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
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(completed ? SessionsV2Theme.accent : .secondary)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step \(index + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.callout)
                        .strikethrough(completed)
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
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
