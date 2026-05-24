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
    @Environment(\.tahoe) private var t

    @ObservedObject var chatStore: iOSChatStore
    var canApprove: Bool
    var onApprove: (() async -> Void)?

    public init(
        chatStore: iOSChatStore,
        canApprove: Bool = false,
        onApprove: (() async -> Void)? = nil
    ) {
        self.chatStore = chatStore
        self.canApprove = canApprove
        self.onApprove = onApprove
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if chatStore.snapshot.codexTodos.isEmpty {
                    emptyState
                } else {
                    todosList
                }
                if let onApprove {
                    approveButton(onApprove: onApprove)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var header: some View {
        TahoeGlass(radius: 14, tone: .chip) {
            HStack(spacing: 8) {
                TahoeIcon("check", size: 13, weight: .bold)
                    .foregroundStyle(t.accent)
                Text("Codex Plan")
                    .font(TahoeFont.body(13, weight: .bold))
                    .foregroundStyle(t.fg)
                Spacer()
                badge
            }
            .padding(12)
        }
    }

    @ViewBuilder private var badge: some View {
        let total = chatStore.snapshot.codexTodos.count
        let done = chatStore.snapshot.codexTodos.filter(\.isCompleted).count
        Text("\(done)/\(total)")
            .font(TahoeFont.mono(11, weight: .bold))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(t.accentAlpha(0.14), in: Capsule(style: .continuous))
            .foregroundStyle(t.accent)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            TahoeIcon("check", size: 24)
                .foregroundStyle(t.fg4)
            Text("No Codex todos yet")
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Codex plan approval is available as soon as the session is waiting for approval.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func approveButton(onApprove: @escaping () async -> Void) -> some View {
        Button {
            Task { await onApprove() }
        } label: {
            HStack(spacing: 8) {
                TahoeIcon("play", size: 12, weight: .bold)
                Text("Approve & run")
                    .font(TahoeFont.body(13, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .foregroundStyle(.white)
            .opacity(canApprove ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!canApprove)
        .accessibilityLabel("Approve Codex plan and run")
        .accessibilityHint(canApprove ? "Approves the pending Codex plan on the Mac." : "Available when Codex is waiting for plan approval.")
    }

    @ViewBuilder private var todosList: some View {
        let groups: [(String, [CodexTodoItem])] = [
            ("In progress", chatStore.snapshot.codexTodos.filter(\.isInProgress)),
            ("Pending", chatStore.snapshot.codexTodos.filter(\.isPending)),
            ("Done", chatStore.snapshot.codexTodos.filter(\.isCompleted)),
        ]
        VStack(alignment: .leading, spacing: 10) {
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
                .font(TahoeFont.body(10.5, weight: .bold))
                .foregroundStyle(t.fg3)
                .tracking(0.5)
            TahoeGlass(radius: 14, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item: item)
                        if index < items.count - 1 {
                            TahoeHair()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(item: CodexTodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            icon(for: item)
                .frame(width: 20, height: 20)
            Text(item.text)
                .font(TahoeFont.body(12.5))
                .foregroundStyle(item.isCompleted ? t.fg3 : t.fg)
                .strikethrough(item.isCompleted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func icon(for item: CodexTodoItem) -> some View {
        if item.isCompleted {
            TahoeIcon("check", size: 12, weight: .bold)
                .foregroundStyle(.green)
        } else if item.isInProgress {
            Image(systemName: "circle.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(t.accent)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.fg4)
        }
    }
}
