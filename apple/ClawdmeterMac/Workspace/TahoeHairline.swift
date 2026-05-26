import SwiftUI
import ClawdmeterShared

/// Minimal 0.5pt divider that picks up the tahoe theme's hairline color.
/// Used throughout the workspace to separate panes, tab bars, and rows.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Pure
/// leaf view; isolating it cannot change invalidation behavior.
struct TahoeHairline: View {
    @Environment(\.tahoe) private var t
    var vertical: Bool = false

    var body: some View {
        Rectangle()
            .fill(t.hairline)
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}
