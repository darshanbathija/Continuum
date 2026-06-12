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

    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 6) {
            ForEach(WorkbenchPaneTab.visibleReviewPaneTabs) { tab in
                ReviewPaneGutterTab(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    onExpand: onExpand
                )
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 36)
        .background(t.glassTintHi.opacity(0.55))
    }
}

private struct ReviewPaneGutterTab: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let tab: WorkbenchPaneTab
    let isSelected: Bool
    let onExpand: (WorkbenchPaneTab) -> Void

    var body: some View {
        Button(action: ContinuumAnalytics.wrapButton("review_gutter_expand_\(tab.accessibilityKey)", { onExpand(tab) })) {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13))
                Text(tab.rawValue)
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 40)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help("Open \(tab.rawValue) pane")
        .accessibilityIdentifier("code.review.gutter.\(tab.accessibilityKey)")
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.secondary.opacity(0.12)
        }
        if isHovered {
            // Canonical row/control hover token (appearance-aware), per
            // DESIGN.md — not the hairline color, which renders too strong
            // in light mode.
            return t.hover
        }
        return .clear
    }
}
