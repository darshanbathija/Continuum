import SwiftUI
import ClawdmeterShared

/// G5: live plan timeline. Observes `SessionChatStore.messages` to surface
/// the latest plan + step-by-step progress.
///
/// Heuristic: a "step" is any line in either the planText or a later
/// assistant message that starts with `^\d+\.` ("1.", "2.") or `Step N:`.
/// We collect them in order of first appearance. A step is considered
/// "complete" when:
///   1. A later assistant message contains its text (case-insensitive
///      substring of the first 40 chars), OR
///   2. A tool_call ran AFTER the step first appeared and its title
///      matches a verb in the step text (e.g. "Write" in step body).
///
/// This is a soft heuristic; the user can also tap a step to toggle.
struct PlanTrackerPane: View {
    let session: AgentSession
    @ObservedObject var chatStore: SessionChatStore
    let onApprove: () -> Void

    @State private var manuallyToggled: Set<String> = []

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let goal = session.goal, !goal.isEmpty {
                        goalCard(goal)
                    }
                    if let planText = session.planText, !planText.isEmpty {
                        planCard(planText)
                    }
                    if !steps.isEmpty {
                        stepsSection
                    } else if session.planText == nil {
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
            if session.planText != nil {
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
    private var stepsSection: some View {
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
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                stepRow(index: i, step: step, isComplete: isStepComplete(step))
            }
        }
    }

    private func stepRow(index: Int, step: String, isComplete: Bool) -> some View {
        let key = "\(index):\(step.prefix(40))"
        let manual = manuallyToggled.contains(key)
        let effectivelyComplete = manual ? !isComplete : isComplete
        return Button(action: {
            if manuallyToggled.contains(key) {
                manuallyToggled.remove(key)
            } else {
                manuallyToggled.insert(key)
            }
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: effectivelyComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(effectivelyComplete ? .green : .secondary)
                    .padding(.top, 1)
                Text(step)
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

    // MARK: - Derivations

    /// Collect step strings from planText + later assistant messages, in
    /// first-appearance order. Limit to 24 steps so a runaway plan doesn't
    /// blow up the timeline.
    private var steps: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        let candidates = [session.planText ?? ""]
            + chatStore.messages.filter { $0.kind == .assistantText }.map { $0.body }
        for body in candidates {
            for step in Self.extractSteps(from: body) {
                let key = step.lowercased().prefix(40)
                if !seen.contains(String(key)) {
                    seen.insert(String(key))
                    out.append(step)
                    if out.count >= 24 { return out }
                }
            }
        }
        return out
    }

    /// True if any subsequent assistant message or tool_call appears to
    /// reference this step. Heuristic, not authoritative.
    private func isStepComplete(_ step: String) -> Bool {
        let needle = String(step.lowercased().prefix(30))
        guard !needle.isEmpty else { return false }
        for msg in chatStore.messages {
            switch msg.kind {
            case .assistantText:
                if msg.body.lowercased().contains(needle), msg.body != step {
                    return true
                }
            case .toolCall:
                if msg.body.lowercased().contains(needle) {
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    /// Pull "1.", "Step 1:", or "- " items from a body. Trims numbering.
    static func extractSteps(from body: String) -> [String] {
        var out: [String] = []
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // numbered: "1. ..."
            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let content = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { out.append(content) }
                continue
            }
            // "Step N: ..."
            if let match = line.range(of: #"^Step\s+\d+:?\s+"#,
                                     options: [.regularExpression, .caseInsensitive]) {
                let content = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { out.append(content) }
                continue
            }
        }
        return out
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}
