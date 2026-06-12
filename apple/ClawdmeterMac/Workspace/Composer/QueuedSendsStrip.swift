import SwiftUI
import ClawdmeterShared

/// Compact queued follow-up strip rendered above the composer text field.
/// Messages queue by default while a turn runs; hover each row to edit,
/// delete, or steer (send mid-turn).
struct QueuedSendsStrip: View {
    let drafts: [QueuedWorkbenchSend]
    let sessionIsRunning: Bool
    let isDispatching: Bool
    let onUpdateText: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onSteer: (QueuedWorkbenchSend) -> Void

    @State private var editingId: UUID?
    @State private var focusedIndex: Int = 0
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(t.fg4)

            ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                QueuedSendRow(
                    draft: draft,
                    isFocused: index == focusedIndex,
                    isEditing: editingId == draft.id,
                    sessionIsRunning: sessionIsRunning,
                    isDispatching: isDispatching,
                    onBeginEdit: { editingId = draft.id },
                    onUpdateText: { onUpdateText(draft.id, $0) },
                    onDelete: { onDelete(draft.id) },
                    onSteer: { onSteer(draft) }
                )
            }

            if drafts.count > 1 {
                navigatePill
            }
        }
        .accessibilityIdentifier("code.queue.panel")
        .onChange(of: drafts.count) { _, newCount in
            if focusedIndex >= newCount {
                focusedIndex = max(0, newCount - 1)
            }
        }
        .onChange(of: drafts.map(\.id)) { _, _ in
            if editingId != nil && !drafts.contains(where: { $0.id == editingId }) {
                editingId = nil
            }
        }
    }

    private var headerText: String {
        drafts.count == 1 ? "1 queued message" : "\(drafts.count) queued messages"
    }

    private var navigatePill: some View {
        HStack(spacing: 6) {
            Button {
                moveFocus(by: -1)
            } label: {
                TahoeIcon("chevU", size: 9, weight: .bold)
                    .foregroundStyle(t.fg3)
            }
            .buttonStyle(.plain)
            .help("Previous queued message")

            Button {
                moveFocus(by: 1)
            } label: {
                TahoeIcon("chevD", size: 9, weight: .bold)
                    .foregroundStyle(t.fg3)
            }
            .buttonStyle(.plain)
            .help("Next queued message")

            Text("navigate")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(t.fg4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(t.hair2, in: Capsule())
        .accessibilityIdentifier("code.queue.navigate")
    }

    private func moveFocus(by delta: Int) {
        guard !drafts.isEmpty else { return }
        let next = (focusedIndex + delta + drafts.count) % drafts.count
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            focusedIndex = next
            editingId = nil
        }
    }
}

private struct QueuedSendRow: View {
    let draft: QueuedWorkbenchSend
    let isFocused: Bool
    let isEditing: Bool
    let sessionIsRunning: Bool
    let isDispatching: Bool
    let onBeginEdit: () -> Void
    let onUpdateText: (String) -> Void
    let onDelete: () -> Void
    let onSteer: () -> Void

    @State private var isHovered = false
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsActions: Bool {
        isHovered || isEditing
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isEditing {
                    TextField(
                        "Queued prompt",
                        text: Binding(
                            get: { draft.text },
                            set: onUpdateText
                        ),
                        axis: .vertical
                    )
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("code.queue.prompt")
                } else {
                    Text(previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(t.fg)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("code.queue.prompt")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isFocused ? t.hair2.opacity(t.dark ? 1.1 : 1.0) : t.hair2.opacity(0.65),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            if showsActions {
                HStack(spacing: 2) {
                    actionButton(
                        icon: "pencil",
                        help: "Edit queued message",
                        identifier: "code.queue.edit",
                        action: onBeginEdit
                    )
                    actionButton(
                        icon: "trash",
                        help: "Delete queued message",
                        identifier: "code.queue.delete",
                        action: onDelete
                    )
                    actionButton(
                        icon: "arrowU",
                        help: steerHelp,
                        identifier: "code.queue.steer",
                        action: onSteer,
                        disabled: isDispatching,
                        accent: true
                    )
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsActions)
    }

    private var previewText: String {
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if !draft.attachmentPaths.isEmpty {
                return "\(draft.attachmentPaths.count) attachment\(draft.attachmentPaths.count == 1 ? "" : "s")"
            }
            return "Queued prompt"
        }
        return ClawdmeterTextUtilities.collapsedWhitespacePreview(trimmed, limit: 160)
    }

    private var steerHelp: String {
        if sessionIsRunning {
            return "Steer — send mid-turn to the agent"
        }
        return "Send queued message now"
    }

    private func actionButton(
        icon: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void,
        disabled: Bool = false,
        accent: Bool = false
    ) -> some View {
        Button(action: action) {
            Group {
                if icon == "pencil" {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                } else if icon == "trash" {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    TahoeIcon(icon, size: 11, weight: .bold)
                }
            }
            .foregroundStyle(accent && !disabled ? t.accent : t.fg3)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}
