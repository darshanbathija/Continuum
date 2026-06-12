#if canImport(SwiftUI)
import SwiftUI

/// Renders extended-thinking / reasoning blocks the way Cursor shows them:
/// brain icon, "Thinking" label, and a muted pill with the summary snippet.
public struct ThinkingActionRow: View {
    public let summary: String

    public init(summary: String) {
        self.summary = summary
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolIconView(toolName: "thinking", size: 13)
                .frame(width: 16)

            Text("Thinking")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.primary)

            Text(summaryOneLine)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.14), in: Capsule(style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thinking: \(summaryOneLine)")
    }

    private var summaryOneLine: String {
        summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
