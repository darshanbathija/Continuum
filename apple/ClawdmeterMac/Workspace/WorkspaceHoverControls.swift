import SwiftUI
import ClawdmeterShared

/// Small shared hover chrome for Code workspace leaf controls.
/// Keep hover state inside the leaf so sidebar rows and composer parents do
/// not re-render just because an icon button is highlighted.
struct CodeHoverChrome: ViewModifier {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let cornerRadius: CGFloat
    let help: String?
    let accessibilityLabel: String?
    let accessibilityIdentifier: String?

    func body(content: Content) -> some View {
        content
            .background(
                isHovered ? t.hair2.opacity(t.dark ? 0.95 : 1.0) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isHovered ? t.hairline : .clear, lineWidth: 0.5)
            )
            .help(help ?? accessibilityLabel ?? "")
            .accessibilityLabel(accessibilityLabel ?? help ?? "")
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    func codeHoverChrome(
        cornerRadius: CGFloat = 7,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        modifier(CodeHoverChrome(
            cornerRadius: cornerRadius,
            help: help,
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier
        ))
    }
}
