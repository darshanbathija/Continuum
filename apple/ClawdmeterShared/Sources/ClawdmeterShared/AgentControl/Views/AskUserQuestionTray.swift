#if canImport(SwiftUI)
import SwiftUI

/// v0.5.6 interactive answer tray for `AskUserQuestion` tool_use calls.
///
/// Replaces the generic "Ran 1 command" disclosure for AskUserQuestion
/// tool calls. Each parsed `Question` renders as a card with its options
/// as tappable rows; tapping an option fires `onAnswer(question, option)`
    /// which the host wires to `sendPrompt` so the answer routes back through
    /// the session runtime (the daemon's send path appends a trailing newline,
    /// which acts as Enter in Claude Code's interactive picker).
///
/// Once the tool_result lands (the agent has consumed the answer), the
/// host passes `answered=true` to gray out the tray so the user knows
/// it's no longer waiting on them.
public struct AskUserQuestionTray: View {
    public let question: AskUserQuestion
    public let answered: Bool
    /// Selected option per question (by question.header). Drives the
    /// checkmark on the row + tells the host which option fired the
    /// answer. multiSelect questions accumulate; single-select replaces.
    @Binding public var selections: [String: Set<String>]
    /// Called when the user taps Send on a question. The host submits the
    /// joined labels through the session runtime.
    public let onSend: (AskUserQuestion.Question, [AskUserQuestion.Option]) -> Void

    public init(
        question: AskUserQuestion,
        answered: Bool,
        selections: Binding<[String: Set<String>]>,
        onSend: @escaping (AskUserQuestion.Question, [AskUserQuestion.Option]) -> Void
    ) {
        self.question = question
        self.answered = answered
        self._selections = selections
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(question.questions, id: \.header) { q in
                questionCard(q)
            }
        }
        .opacity(answered ? 0.55 : 1.0)
        .allowsHitTesting(!answered)
    }

    @ViewBuilder
    private func questionCard(_ q: AskUserQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(q.header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .textCase(.uppercase)
                if q.multiSelect {
                    Text("· multi-select")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(q.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(q.options) { option in
                    optionRow(question: q, option: option)
                }
            }
            sendButton(for: q)
        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.4), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func optionRow(
        question q: AskUserQuestion.Question,
        option: AskUserQuestion.Option
    ) -> some View {
        let isSelected = (selections[q.header] ?? []).contains(option.label)
        Button {
            toggleSelection(for: q, option: option)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected
                    ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (q.multiSelect ? "square" : "circle"))
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? accent : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                Color.secondary.opacity(isSelected ? 0.18 : 0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sendButton(for q: AskUserQuestion.Question) -> some View {
        let picked = (selections[q.header] ?? [])
        let options = q.options.filter { picked.contains($0.label) }
        Button {
            guard !options.isEmpty else { return }
            onSend(q, options)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(answered ? "Answered" : "Send answer")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .background(
                options.isEmpty
                    ? Color.secondary.opacity(0.15)
                    : accent.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(options.isEmpty ? Color.secondary : accent)
        }
        .buttonStyle(.plain)
        .disabled(options.isEmpty || answered)
    }

    private func toggleSelection(
        for q: AskUserQuestion.Question,
        option: AskUserQuestion.Option
    ) {
        var current = selections[q.header] ?? []
        if q.multiSelect {
            if current.contains(option.label) {
                current.remove(option.label)
            } else {
                current.insert(option.label)
            }
        } else {
            current = [option.label]
        }
        selections[q.header] = current
    }

    private var accent: Color { SessionsV2Theme.accent }
}
#endif
