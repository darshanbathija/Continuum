import SwiftUI
import ClawdmeterShared

/// Custom DisclosureGroup style with a tighter chevron + no default
/// "Show more / Show less" hover chrome. Matches the Codex-desktop
/// "Ran N commands ⌄" / "Ran <description> ⌄" look.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Stateless
/// `DisclosureGroupStyle`; the only mutable state lives inside the
/// configuration's `isExpanded` binding, so isolating the style cannot
/// affect invalidation.
struct QuietDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
