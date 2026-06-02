import SwiftUI
import ClawdmeterShared

/// Codex-desktop mode picker (G2). Sits above the composer in the workspace
/// view: Local | Worktree | Cloud (disabled).
///
/// Changing mode mid-session is a heavy op — we re-spawn the agent in the
/// new cwd via the D13 overlay flow. The picker fires `onChange(newMode)`
/// and lets the caller decide whether to confirm before restarting.
struct ModePicker: View {
    let mode: SessionMode
    let agent: AgentKind
    let onChange: (SessionMode) -> Void

    @Namespace private var pillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tahoe) private var t

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SessionMode.allCases, id: \.self) { option in
                chip(option)
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        // P3: the selected pill SLIDES between segments (160ms) instead of an
        // instant fill swap — matches EffortDial and the segmented-control spec.
        .animation(SessionsV2Theme.segmentedSelection(reduceMotion: reduceMotion), value: mode)
        // P10: success ring flash when the mode actually changes (matches EffortDial).
        .confirmationPulse(mode, cornerRadius: 7)
    }

    @ViewBuilder
    private func chip(_ option: SessionMode) -> some View {
        let isSelected = (option == mode)
        let isDisabled = (option == .cloud)
        Button(action: {
            guard !isDisabled, option != mode else { return }
            onChange(option)
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon(option))
                    .font(.system(size: 9, weight: .semibold))
                Text(label(option))
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(t.accent)
                        .matchedGeometryEffect(id: "modePill", in: pillNamespace)
                }
            }
            .foregroundStyle(
                isSelected ? Color.white
                    : (isDisabled ? Color.secondary : Color.primary)
            )
            .opacity(isDisabled ? 0.55 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDisabled)
        .help(tooltip(option))
    }

    private func icon(_ mode: SessionMode) -> String {
        switch mode {
        case .local:    return "house"
        case .worktree: return "arrow.triangle.branch"
        case .cloud:    return "cloud"
        }
    }

    private func label(_ mode: SessionMode) -> String {
        switch mode {
        case .local:    return "Local"
        case .worktree: return "Worktree"
        case .cloud:    return "Cloud"
        }
    }

    private func tooltip(_ mode: SessionMode) -> String {
        switch mode {
        case .local:
            return "Edits land in the repo's main checkout. Switching restarts the agent."
        case .worktree:
            return "Run in `.claude/worktrees/<slug>` so the agent can't stomp your edits. Switching restarts the agent in a new worktree."
        case .cloud:
            return "Remote-Mac mode — coming in G3."
        }
    }
}
