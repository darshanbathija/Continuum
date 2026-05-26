import SwiftUI
import ClawdmeterShared

/// Thin vertical strip on the right edge of the center pane shown when the
/// review pane is collapsed. Each icon is a tap target that opens the
/// review pane focused on that tab — the CTA the user asked for. When the
/// pane is expanded the gutter hides; the pane's own × button collapses
/// it back to this strip.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Owns a
/// single `@Binding selectedTab` plus an action closure; no observed
/// state of its own. Isolating it lets the gutter's body re-render
/// independently of the parent workspace.
struct ReviewPaneGutter: View {
    @Binding var selectedTab: WorkbenchPaneTab
    let onExpand: (WorkbenchPaneTab) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 6) {
            ForEach(WorkbenchPaneTab.allCases) { tab in
                Button(action: { onExpand(tab) }) {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13))
                        Text(tab.rawValue)
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(
                        selectedTab == tab
                            ? Color.secondary.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(tab.rawValue) pane")
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(width: 52)
        .background(t.glassTintHi.opacity(0.55))
    }

    private var gutterBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.95, green: 0.95, blue: 0.95)
    }
}
