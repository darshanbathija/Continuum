// v0.7.8 — Mac dashboard pane that surfaces the Codex SDK
// `todo_list` event as a structured plan view. Mirrors
// AntigravityPlanPane for Codex SDK sessions; reads codexTodos
// straight off SessionChatStore.snapshot (no daemon endpoint
// needed — the chat-subscribe pipeline already pushes the snapshot
// containing the todos).
//
// Three section pattern matches AntigravityPlanPane:
//   1. Header (Codex SDK badge + agent context)
//   2. Todo checklist grouped by status
//   3. Empty state when no todos have arrived yet

import SwiftUI
import ClawdmeterShared

public struct CodexPlanPane: View {

    // A5 — bind to the per-transcript slice so this pane invalidates
    // only on staging commits that touched codexTodos (or other
    // message-slice fields), NOT on token deltas / permission prompts
    // / activity ticks. The Codex SDK `todo_list` event lands as a
    // staging snapshot mutation that bumps the messages slice.
    @ObservedObject var messagesSlice: ChatMessagesSlice

    public init(chatStore: SessionChatStore) {
        _messagesSlice = ObservedObject(wrappedValue: chatStore.messagesSlice)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if messagesSlice.codexTodos.isEmpty {
                    emptyState
                } else {
                    todosList
                }
            }
            .padding(20)
        }
        .frame(minWidth: 280)
    }

    // MARK: - Sections

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(SessionsV2Theme.codexBlue)
                Text("Codex Plan")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                badge
            }
            Text("Live todo list from the Codex SDK observer. Updated whenever the agent emits a `todo_list` stream event.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var badge: some View {
        let total = messagesSlice.codexTodos.count
        let done = messagesSlice.codexTodos.filter(\.isCompleted).count
        Text("\(done)/\(total)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(SessionsV2Theme.codexBlue.opacity(0.15))
            )
            .foregroundStyle(SessionsV2Theme.codexBlue)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting for the first `todo_list` event…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Codex tends to emit a todo list within the first turn or two of a multi-step task. Ask it to plan something out and the list will populate here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var todosList: some View {
        let groups: [(String, [CodexTodoItem])] = [
            ("In progress", messagesSlice.codexTodos.filter(\.isInProgress)),
            ("Pending", messagesSlice.codexTodos.filter(\.isPending)),
            ("Done", messagesSlice.codexTodos.filter(\.isCompleted)),
        ]
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.0) { (label, items) in
                if !items.isEmpty {
                    section(label: label, items: items)
                }
            }
        }
    }

    @ViewBuilder private func section(label: String, items: [CodexTodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            ForEach(items) { item in
                row(item: item)
            }
        }
    }

    @ViewBuilder private func row(item: CodexTodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            icon(for: item)
                .font(.system(size: 13))
                .frame(width: 16)
            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .strikethrough(item.isCompleted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func icon(for item: CodexTodoItem) -> some View {
        if item.isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SessionsV2Theme.success)
        } else if item.isInProgress {
            Image(systemName: "circle.dotted")
                .foregroundStyle(SessionsV2Theme.codexBlue)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}
