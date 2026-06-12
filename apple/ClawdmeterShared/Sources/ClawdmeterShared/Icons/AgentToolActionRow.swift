#if canImport(SwiftUI)
import SwiftUI

/// Cursor-style flat row for a single agent tool action: icon, primary
/// label ("Read 80 lines", "grep"), and optional file chip or detail pill.
public struct AgentToolActionRow: View {
    public let toolName: String
    public let callBody: String
    public let detail: String?
    public let resultBody: String?
    public let isError: Bool

    public init(
        toolName: String,
        callBody: String,
        detail: String? = nil,
        resultBody: String? = nil,
        isError: Bool = false
    ) {
        self.toolName = toolName
        self.callBody = callBody
        self.detail = detail
        self.resultBody = resultBody
        self.isError = isError
    }

    public init(pair: ToolPair) {
        self.init(
            toolName: pair.call.title,
            callBody: pair.call.body,
            detail: pair.call.detail,
            resultBody: pair.result?.body,
            isError: pair.result?.isError ?? false
        )
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolIconView(toolName: toolName, size: 13, isError: isError)
                .frame(width: 16)

            Text(primaryLabel)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let path = filePath {
                FilePathChip(path: path)
            } else if let pill = detailPill {
                detailPillView(pill)
            }

            if isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var primaryLabel: String {
        ToolActionSummary.primaryLabel(
            toolName: toolName,
            callBody: callBody,
            resultBody: resultBody
        )
    }

    private var filePath: String? {
        guard ToolActionSummary.showsFileChip(toolName: toolName) else { return nil }
        return ToolActionSummary.filePath(toolName: toolName, callBody: callBody, detail: detail)
    }

    /// Secondary detail shown as a muted pill — used for Thinking summaries
    /// and long grep/bash descriptions when no file chip applies.
    private var detailPill: String? {
        if ToolPresentationCatalog.normalizedKind(for: toolName) == "thinking" {
            return trimmedNonEmpty(resultBody) ?? trimmedNonEmpty(callBody)
        }
        if filePath != nil { return nil }
        let body = trimmedNonEmpty(callBody)
        if let body, body != primaryLabel { return body }
        return trimmedNonEmpty(detail)
    }

    private func detailPillView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.14), in: Capsule(style: .continuous))
    }

    private func trimmedNonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
