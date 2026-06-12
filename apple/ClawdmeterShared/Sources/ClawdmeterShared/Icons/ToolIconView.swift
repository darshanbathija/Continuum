#if canImport(SwiftUI)
import SwiftUI

/// Renders a tool-kind icon with the catalog's tone tint. Used across the
/// Code tab transcript, Chat V2, and StructuredEventList so every agent
/// action (read, grep, bash, web search, …) gets a distinct glyph.
public struct ToolIconView: View {
    public let toolName: String
    public var size: CGFloat
    public var isError: Bool

    public init(toolName: String, size: CGFloat = 10, isError: Bool = false) {
        self.toolName = toolName
        self.size = size
        self.isError = isError
    }

    public var body: some View {
        let presentation = ToolPresentationCatalog.presentation(for: toolName, isError: isError)
        Image(systemName: presentation.systemImageName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(ToolIconView.tint(for: presentation.tone))
            .accessibilityLabel(presentation.displayName)
    }

    /// Shared tint resolver — keeps ChatItemRowView and StructuredEventList
    /// on the same palette without duplicating switch statements.
    public static func tint(for tone: ToolPresentationTone) -> Color {
        switch tone {
        case .read:     return Color(red: 0.22, green: 0.55, blue: 0.95)
        case .write:    return Color(red: 0.82, green: 0.45, blue: 0.28)
        case .shell:    return Color(red: 0.32, green: 0.77, blue: 0.10)
        case .web:      return Color(red: 0.22, green: 0.55, blue: 0.95)
        case .agent:    return Color(red: 0.90, green: 0.62, blue: 0.10)
        case .search:   return Color(red: 0.55, green: 0.40, blue: 0.90)
        case .explore:  return Color(red: 0.35, green: 0.65, blue: 0.72)
        case .thinking: return Color(red: 0.62, green: 0.52, blue: 0.82)
        case .delete:   return Color(red: 0.90, green: 0.29, blue: 0.29)
        case .warning:  return Color(red: 0.90, green: 0.29, blue: 0.29)
        case .neutral: return .secondary
        }
    }
}
#endif
