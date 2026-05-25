import SwiftUI
import ClawdmeterShared

/// G5: plan timeline. This pane only renders explicit pending or approved
/// plan text; it must not promote review/verifier chat prose into a plan.
struct PlanTrackerPane: View {
    let session: AgentSession
    @ObservedObject var chatStore: SessionChatStore
    let onApprove: () -> Void

    /// Per-step manual override: when the user taps a step, their explicit
    /// state wins over the heuristic. Storing the override as a `Bool`
    /// (not a `Set<String>` toggle) avoids a silent flip when the
    /// heuristic later decides `step.isComplete` changed — the user's
    /// last intent is preserved regardless of what the heuristic thinks.
    @State private var manualOverride: [String: Bool] = [:]

    @Environment(\.colorScheme) private var colorScheme

    private var displayPlanText: String? {
        for candidate in [session.planText, session.approvedPlanText] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { continue }
            return trimmed
        }
        return nil
    }

    private var canApprovePendingPlan: Bool {
        session.status == .planning
            && session.planText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var displaySteps: [PlanStep] {
        guard let planText = displayPlanText else { return [] }
        let candidates = ChatMessageOrdering.extractStepCandidates(from: planText)
        let texts = candidates.isEmpty
            ? planText
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            : candidates
        return texts.enumerated().map { index, text in
            PlanStep(id: "plan-\(index)", text: text, isComplete: false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let goal = session.goal, !goal.isEmpty {
                        goalCard(goal)
                    }
                    if let planText = displayPlanText {
                        planCard(planText)
                    }
                    if !displaySteps.isEmpty {
                        stepsSection(displaySteps)
                    } else if displayPlanText == nil {
                        emptyState
                    }
                }
                .padding(14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Plan")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if canApprovePendingPlan {
                Button("Approve & run", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .tint(terraCotta)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func goalCard(_ goal: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "scope")
                .foregroundStyle(terraCotta)
                .font(.system(size: 11))
            Text(goal)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(terraCotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func planCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text("Plan")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func stepsSection(_ steps: [PlanStep]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "list.number")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text("Steps")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            ForEach(steps) { step in
                stepRow(step)
            }
        }
    }

    private func stepRow(_ step: PlanStep) -> some View {
        let effectivelyComplete = manualOverride[step.id] ?? step.isComplete
        return Button(action: {
            // Tap inverts the CURRENT shown state (not the heuristic
            // alone), so once the user explicitly sets a step's status
            // it sticks even if the heuristic later re-evaluates.
            manualOverride[step.id] = !effectivelyComplete
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: effectivelyComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(effectivelyComplete ? .green : .secondary)
                    .padding(.top, 1)
                Text(step.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .strikethrough(effectivelyComplete)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No plan yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Once the agent emits a plan (or numbered steps), they'll appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}
