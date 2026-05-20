import SwiftUI
import ClawdmeterShared

/// Compact pill on the left of the composer's bottom bar that opens a
/// "Mode" menu (Ask permissions / Accept edits / Plan / Bypass).
/// Replaces the standalone AutopilotChip + Plan-mode toggle.
///
/// The chip's color encodes the active mode at a glance:
///   • Ask permissions → secondary
///   • Accept edits    → accent
///   • Plan mode       → accent
///   • Bypass          → yellow (matches Claude Code's "Auto" warning hue)
struct PermissionModeChip: View {
    let mode: PermissionMode
    /// Available modes vary by context — the empty-state composer hides
    /// `.bypass` (no session yet) and the read-only composer hides
    /// everything except a stub. Callers pass the eligible list.
    let availableModes: [PermissionMode]
    let onChange: (PermissionMode) -> Void

    var body: some View {
        Menu {
            Section("Mode") {
                ForEach(Array(availableModes.enumerated()), id: \.element) { (idx, candidate) in
                    Button(action: { onChange(candidate) }) {
                        HStack {
                            Text(candidate.displayName)
                            if candidate == mode {
                                Image(systemName: "checkmark")
                            }
                            Spacer()
                            Text("\(idx + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command, .shift])
                }
            }
        } label: {
            // v0.7.13: chip styled identically to ModelEffortChip — same
            // Capsule background (Color.secondary.opacity(0.10)), same
            // 11pt-medium label + 8pt chevron, same padding. The icon +
            // mode-specific tint are dropped because the popover already
            // carries the active mode (checkmark on the row), and visual
            // weight should match the right-side model/effort chip so
            // the bottom bar feels balanced instead of chip-soup.
            HStack(spacing: 6) {
                Text(mode.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode — ⌘⇧1-4 to switch")
    }
}
