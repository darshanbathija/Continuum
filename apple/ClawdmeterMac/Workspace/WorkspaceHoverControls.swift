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

// MARK: - Message hover copy

enum MessageHoverCopyStyle {
    /// User bubble — copy glyph just outside the bubble's leading edge on hover.
    case userBubble
    /// Assistant body — compact relative time + copy glyph in the row gutter.
    case assistantMessage
}

enum MessageHoverCopyFormatting {
    static func compactRelative(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

struct MessageCopyHoverButton: View {
    @Environment(\.tahoe) private var t

    let text: String
    let onCopy: (String) -> Void

    var body: some View {
        Button(action: ContinuumAnalytics.wrapButton(
                "message_copy",
                {
            onCopy(text)
        
                }
            )) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(t.fg2)
                .frame(width: 24, height: 24)
                .background(t.surfaceSolid2.opacity(t.dark ? 0.98 : 1.0),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(t.hairline.opacity(t.dark ? 0.95 : 1.0), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(t.dark ? 0.28 : 0.10), radius: 5, y: 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .codeHoverChrome(
            cornerRadius: 6,
            help: "Copy message",
            accessibilityLabel: "Copy message",
            accessibilityIdentifier: "chat.message.action.copy"
        )
    }
}

private struct MessageHoverCopyOverlay: ViewModifier {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let text: String
    let onCopy: (String) -> Void
    let style: MessageHoverCopyStyle
    let timestamp: Date?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .overlay(alignment: overlayAlignment) {
                if isHovered {
                    overlayContent
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var overlayAlignment: Alignment {
        switch style {
        case .userBubble: return .topLeading
        case .assistantMessage: return .bottomTrailing
        }
    }

    private var overlayOffset: CGSize {
        switch style {
        case .userBubble:
            return CGSize(width: -30, height: 0)
        case .assistantMessage:
            return .zero
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch style {
        case .userBubble:
            MessageCopyHoverButton(text: text, onCopy: onCopy)
                .offset(overlayOffset)
                .padding(6)
        case .assistantMessage:
            HStack(spacing: 8) {
                if let timestamp {
                    Text(MessageHoverCopyFormatting.compactRelative(since: timestamp))
                        .font(TahoeFont.body(10))
                        .foregroundStyle(t.fg4)
                }
                MessageCopyHoverButton(text: text, onCopy: onCopy)
            }
            .offset(overlayOffset)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
    }
}

extension View {
    func messageHoverCopy(
        text: String,
        onCopy: @escaping (String) -> Void,
        style: MessageHoverCopyStyle,
        timestamp: Date? = nil
    ) -> some View {
        modifier(MessageHoverCopyOverlay(
            text: text,
            onCopy: onCopy,
            style: style,
            timestamp: timestamp
        ))
    }
}
