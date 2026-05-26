import SwiftUI

/// Preference keys used by `SessionWorkspaceView` and its descendants
/// to thread layout measurements (workspace width, sidebar viewport vs
/// content height) up through the view tree.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Each key
/// is a pure data type with no observed state, so isolating it has no
/// invalidation cost; it just unclutters the main workspace file.

/// Workspace-level width preference. Drives responsive collapsing of the
/// review pane (and at very narrow widths, the sidebar).
struct WorkspaceWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Visible height of the sidebar viewport (the ScrollView's clipping
/// frame). Compared against `SidebarContentHeightKey` to decide whether
/// to show fade gradients at the top/bottom edges.
struct SidebarViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Total height of the sidebar's scrollable content. Compared against
/// `SidebarViewportHeightKey` to decide whether scrolling is even
/// possible (and therefore whether to render fade gradients).
struct SidebarContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
