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
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.shortLabel)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode — ⌘⇧1-4 to switch")
    }

    private var icon: String {
        switch mode {
        case .ask:         return "questionmark.circle"
        case .acceptEdits: return "pencil.circle"
        case .plan:        return "map"
        case .bypass:      return "bolt.fill"
        }
    }

    private var background: Color {
        switch mode {
        case .ask:         return Color.secondary.opacity(0.15)
        case .acceptEdits: return SessionsV2Theme.accent.opacity(0.20)
        case .plan:        return SessionsV2Theme.accent.opacity(0.20)
        case .bypass:      return Color.yellow.opacity(0.22)
        }
    }

    private var foreground: Color {
        switch mode {
        case .ask:         return .primary
        case .acceptEdits: return SessionsV2Theme.accent
        case .plan:        return SessionsV2Theme.accent
        case .bypass:      return Color.yellow
        }
    }
}
