// v0.7.8 — iOS Plan tab for Codex SDK sessions. Mirrors
// `iOSAntigravityPlanView` but reads structured todos from the
// chat-subscribe pipeline's WireChatSnapshot.codexTodos rather than
// from a dedicated daemon endpoint.
//
// Activation: shown for Codex sessions only. Other agents fall
// through to the existing Plan tab (which mines from chat text).

import SwiftUI
import ClawdmeterShared

public struct iOSCodexPlanView: View {

    @ObservedObject var chatStore: iOSChatStore

    public init(chatStore: iOSChatStore) {
        self.chatStore = chatStore
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if chatStore.snapshot.codexTodos.isEmpty {
                    emptyState
                } else {
                    todosList
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(Color.blue)
                Text("Codex Plan")
                    .font(.headline)
                Spacer()
                badge
            }
            Text("Live todo list from the Codex SDK observer. Updates whenever the agent emits a `todo_list` event.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var badge: some View {
        let total = chatStore.snapshot.codexTodos.count
        let done = chatStore.snapshot.codexTodos.filter(\.isCompleted).count
        Text("\(done)/\(total)")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.blue.opacity(0.15)))
            .foregroundStyle(.blue)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting for the first `todo_list` event…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Ask Codex to plan something multi-step and the list will populate here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var todosList: some View {
        let groups: [(String, [CodexTodoItem])] = [
            ("In progress", chatStore.snapshot.codexTodos.filter(\.isInProgress)),
            ("Pending", chatStore.snapshot.codexTodos.filter(\.isPending)),
            ("Done", chatStore.snapshot.codexTodos.filter(\.isCompleted)),
        ]
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.0) { (label, items) in
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(label.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)
                        ForEach(items) { row(item: $0) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(item: CodexTodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            icon(for: item)
                .font(.system(size: 14))
                .frame(width: 18)
            Text(item.text)
                .font(.system(size: 14))
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
                .foregroundStyle(.green)
        } else if item.isInProgress {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.blue)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}
