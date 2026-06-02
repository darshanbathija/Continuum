import SwiftUI
import ClawdmeterShared

/// Tiny chip showing autopilot on/off state. Tapping calls the parent's
/// handler, which is expected to show a confirmation sheet (the toggle
/// respawns the CLI, interrupting the current turn) before flipping state.
struct AutopilotChip: View {
    let isOn: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text("Auto")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isOn ? AnyShapeStyle(Color.green.opacity(0.18)) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .foregroundStyle(isOn ? Color.green : Color.secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isOn ? Color.green.opacity(0.4) : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(isOn
              ? "Autopilot ON — auto-approves tool calls. Tap to disable."
              : "Tap to enable autopilot. Will interrupt the current turn to respawn the CLI with --dangerously-* flags.")
    }
}
