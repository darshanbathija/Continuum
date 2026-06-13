import SwiftUI
import AppKit
import ClawdmeterShared

/// Rename a sidebar workspace (worktree folder + optionally its git branch).
///
/// Replaces the prior SwiftUI `.alert(_:isPresented:presenting:)`, whose
/// `TextField` silently failed to render on macOS when several `.alert`s were
/// stacked on the same pane — the user saw a title + message + buttons but no
/// editable field. A dedicated sheet renders a real, auto-focused, select-all
/// field and adds the "Also rename branch" decoupling.
struct RenameWorktreeSheet: View {
    let currentName: String
    /// (newName, alsoRenameBranch). Called only on commit; Cancel/Esc dismiss
    /// without invoking it.
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.tahoe) private var t

    @State private var name: String = ""
    @State private var alsoRenameBranch: Bool = true
    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("Rename workspace")
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
            }

            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(TahoeFont.mono(13, weight: .medium))
                .foregroundStyle(t.fg)
                .focused($fieldFocused)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(t.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(fieldFocused ? t.focus : t.hairline, lineWidth: fieldFocused ? 1 : 0.5)
                )
                .onSubmit(commit)
                .accessibilityIdentifier("code.worktree.rename.field")

            Toggle(isOn: $alsoRenameBranch) {
                Text("Also rename branch")
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg2)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("code.worktree.rename.alsoRenameBranch")

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(RenameSheetButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("code.worktree.rename.cancel")
                Button("Rename", action: commit)
                    .buttonStyle(RenameSheetButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("code.worktree.rename.save")
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(t.modal)
        .onAppear {
            name = currentName
            // Focus + select-all so typing replaces the current name (the field
            // is pre-filled). The select-all rides the field editor once it's
            // installed, so it runs a beat after focus lands.
            fieldFocused = true
        }
        .task {
            try? await Task.sleep(nanoseconds: 90_000_000)
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commit() {
        guard canSave else { return }
        onSubmit(trimmed, alsoRenameBranch)
        dismiss()
    }
}

/// Compact primary/secondary button styling for the rename sheet, matching the
/// Quiet Black Workbench buttons (primary = luminance, secondary = ghost).
private struct RenameSheetButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    @Environment(\.tahoe) private var t
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TahoeFont.body(12.5, weight: kind == .primary ? .bold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(kind == .secondary ? t.hairline : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        kind == .primary ? t.primaryText : t.fg2
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            return t.primaryFill.opacity(pressed ? 0.85 : 1)
        case .secondary:
            return pressed ? t.pressed : Color.clear
        }
    }
}
