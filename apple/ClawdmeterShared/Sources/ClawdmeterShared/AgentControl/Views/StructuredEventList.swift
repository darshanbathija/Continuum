#if canImport(SwiftUI)
import SwiftUI

/// Renders a vertical list of structured agent events (messages + tool
/// calls) for the Mac + iOS Sessions detail panel. Mobile defaults to this
/// view per D1; Mac users can toggle into it from the terminal pane.
///
/// Each event is a simple card:
/// - Assistant text → speech-bubble-ish card with serif font for the agent's
///   prose, sans for tool calls.
/// - Tool call → mono name + args summary, color-coded by kind (read = blue,
///   edit/write = warm orange, bash = green, etc).
public struct StructuredEventList: View {

    public struct Item: Identifiable, Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case userMessage
            case assistantMessage
            case toolCall
            case toolResult
            case planReady
            case done
        }
        public let id: String
        public let kind: Kind
        public let title: String
        public let body: String
        public let at: Date

        public init(id: String, kind: Kind, title: String, body: String, at: Date) {
            self.id = id
            self.kind = kind
            self.title = title
            self.body = body
            self.at = at
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if items.isEmpty {
                    emptyState
                } else {
                    ForEach(items) { item in
                        eventRow(item)
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Waiting for the agent to speak…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    @ViewBuilder
    private func eventRow(_ item: Item) -> some View {
        switch item.kind {
        case .userMessage:
            messageBubble(item, color: terraCotta.opacity(0.15), align: .trailing)
        case .assistantMessage:
            messageBubble(item, color: secondaryBg, align: .leading, useSerif: true)
        case .toolCall:
            toolCallCard(item)
        case .toolResult:
            toolResultCard(item)
        case .planReady, .done:
            statusCard(item)
        }
    }

    private func messageBubble(
        _ item: Item,
        color: Color,
        align: HorizontalAlignment,
        useSerif: Bool = false
    ) -> some View {
        HStack {
            if align == .trailing { Spacer(minLength: 32) }
            VStack(alignment: align, spacing: 4) {
                Text(item.body)
                    .font(useSerif
                        ? .system(size: 14, design: .serif)
                        : .system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color, in: RoundedRectangle(cornerRadius: 10))
            if align == .leading { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    private func toolCallCard(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 11))
                .foregroundStyle(toolTintColor(item.title))
            Text(item.title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(toolTintColor(item.title))
            Text(item.body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(secondaryBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolResultCard(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(item.body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func statusCard(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .planReady ? "doc.text" : "checkmark.circle.fill")
                .foregroundStyle(terraCotta)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(item.at.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(terraCotta.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toolTintColor(_ name: String) -> Color {
        switch name {
        case "Read", "Glob", "Grep": return .blue
        case "Write", "Edit": return terraCotta
        case "Bash": return .green
        default: return .purple
        }
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    private var secondaryBg: Color {
        #if os(iOS)
        Color(.secondarySystemBackground)
        #else
        Color(white: 0.15)
        #endif
    }
}
#endif
