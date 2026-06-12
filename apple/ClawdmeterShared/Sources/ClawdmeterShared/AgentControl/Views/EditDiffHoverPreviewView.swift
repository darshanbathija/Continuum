#if canImport(SwiftUI)
import SwiftUI

public struct EditDiffHoverPreviewDisplayLine: Identifiable, Equatable {
    public enum Kind: Equatable {
        case context
        case addition
        case deletion
        case header
        case noNewline
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(
        id: Int,
        kind: Kind,
        text: String,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

public enum EditDiffHoverPreviewModel {
    public static let defaultHoverLineLimit = 30

    public static func displayLines(from preview: String, lineLimit: Int? = defaultHoverLineLimit) -> [EditDiffHoverPreviewDisplayLine] {
        let parsed = EditDiffPreviewModel.lines(from: preview)
        var oldNumber = 0
        var newNumber = 0
        var rows: [EditDiffHoverPreviewDisplayLine] = []

        for (index, line) in parsed.enumerated() {
            if line.kind == .header, let header = line.oldText ?? line.newText, header.hasPrefix("@@") {
                let numbers = parseHunkHeader(header)
                oldNumber = numbers.old
                newNumber = numbers.new
                rows.append(.init(id: index, kind: .header, text: header))
                continue
            }

            switch line.kind {
            case .deletion:
                let text = line.oldText ?? ""
                rows.append(.init(id: index, kind: .deletion, text: text, oldLineNumber: oldNumber))
                oldNumber += 1
            case .addition:
                let text = line.newText ?? ""
                rows.append(.init(id: index, kind: .addition, text: text, newLineNumber: newNumber))
                newNumber += 1
            case .context:
                let text = line.newText ?? line.oldText ?? ""
                rows.append(.init(
                    id: index,
                    kind: .context,
                    text: text,
                    oldLineNumber: oldNumber,
                    newLineNumber: newNumber
                ))
                oldNumber += 1
                newNumber += 1
            case .header:
                let text = line.oldText ?? line.newText ?? ""
                if text.hasPrefix("\\ No newline") {
                    rows.append(.init(id: index, kind: .noNewline, text: text))
                } else {
                    rows.append(.init(id: index, kind: .header, text: text))
                }
            }
        }

        guard let lineLimit else { return rows }
        return Array(rows.prefix(lineLimit))
    }

    private static func parseHunkHeader(_ header: String) -> (old: Int, new: Int) {
        let parts = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return (1, 1) }
        let oldPart = parts[1].hasPrefix("-") ? String(parts[1].dropFirst()) : parts[1]
        let newPart = parts[2].hasPrefix("+") ? String(parts[2].dropFirst()) : parts[2]
        let oldStart = Int(oldPart.split(separator: ",").first ?? "") ?? 1
        let newStart = Int(newPart.split(separator: ",").first ?? "") ?? 1
        return (oldStart, newStart)
    }
}

/// Compact diff card used for hover previews on edited-file chips.
public struct EditDiffHoverPreviewView: View {
    public let preview: String
    public let lineLimit: Int?
    public let isTruncated: Bool

    public init(
        preview: String,
        lineLimit: Int? = EditDiffHoverPreviewModel.defaultHoverLineLimit,
        isTruncated: Bool = false
    ) {
        self.preview = preview
        self.lineLimit = lineLimit
        self.isTruncated = isTruncated
    }

    private var lines: [EditDiffHoverPreviewDisplayLine] {
        EditDiffHoverPreviewModel.displayLines(from: preview, lineLimit: lineLimit)
    }

    private var isTruncatedByLineLimit: Bool {
        guard let lineLimit else { return false }
        return EditDiffHoverPreviewModel.displayLines(from: preview, lineLimit: nil).count > lineLimit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                hoverLine(line)
            }
            if isTruncated || isTruncatedByLineLimit {
                Text(isTruncated ? "preview truncated" : "show detailed density for full preview")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .editDiffHoverSelectableText()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hoverLine(_ line: EditDiffHoverPreviewDisplayLine) -> some View {
        switch line.kind {
        case .header:
            Text(line.text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.purple)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.08))
        case .noNewline:
            Text(line.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        default:
            HStack(spacing: 0) {
                lineNumberColumn(for: line)
                gutterBar(for: line.kind)
                codeTokens(for: line.text, kind: line.kind)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .padding(.vertical, 1)
            .background(background(for: line.kind))
        }
    }

    @ViewBuilder
    private func lineNumberColumn(for line: EditDiffHoverPreviewDisplayLine) -> some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 28, alignment: .trailing)
            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: 28, alignment: .trailing)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.leading, 6)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func gutterBar(for kind: EditDiffHoverPreviewDisplayLine.Kind) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(gutterColor(for: kind))
            .frame(width: 3)
            .padding(.vertical, 1)
            .padding(.trailing, 6)
    }

    @ViewBuilder
    private func codeTokens(for text: String, kind: EditDiffHoverPreviewDisplayLine.Kind) -> some View {
        HStack(spacing: 0) {
            ForEach(EditDiffHoverSyntaxTokenizer.tokens(for: text)) { token in
                Text(token.text)
                    .foregroundColor(token.color(for: kind))
            }
        }
    }

    private func background(for kind: EditDiffHoverPreviewDisplayLine.Kind) -> Color {
        switch kind {
        case .addition: return additionsColor.opacity(0.10)
        case .deletion: return deletionsColor.opacity(0.10)
        default: return .clear
        }
    }

    private func gutterColor(for kind: EditDiffHoverPreviewDisplayLine.Kind) -> Color {
        switch kind {
        case .addition: return additionsColor
        case .deletion: return deletionsColor
        default: return .clear
        }
    }

    private var additionsColor: Color {
        Color(red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0)
    }

    private var deletionsColor: Color {
        Color(red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0)
    }
}

private extension View {
    @ViewBuilder
    func editDiffHoverSelectableText() -> some View {
        #if os(watchOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

private enum EditDiffHoverSyntaxTokenizer {
    struct Token: Identifiable {
        let id = UUID()
        let text: String
        let color: Color

        func color(for kind: EditDiffHoverPreviewDisplayLine.Kind) -> Color {
            switch kind {
            case .addition, .deletion:
                return color
            default:
                return color
            }
        }
    }

    private static let keywords: Set<String> = [
        "actor", "async", "await", "case", "catch", "class", "do", "else",
        "enum", "false", "for", "func", "guard", "if", "import", "in",
        "let", "nil", "private", "public", "return", "self", "static",
        "struct", "switch", "throw", "throws", "true", "try", "var", "while"
    ]

    static func tokens(for line: String) -> [Token] {
        guard !line.isEmpty else { return [Token(text: " ", color: .primary)] }
        if let commentRange = line.range(of: "//") {
            let before = String(line[..<commentRange.lowerBound])
            let comment = String(line[commentRange.lowerBound...])
            return lexCode(before) + [Token(text: comment, color: .secondary)]
        }
        return lexCode(line)
    }

    private static func lexCode(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inString = false

        func flushNormal() {
            guard !current.isEmpty else { return }
            tokens.append(token(for: current))
            current = ""
        }

        for character in source {
            if character == "\"" {
                if inString {
                    current.append(character)
                    tokens.append(Token(text: current, color: .orange))
                    current = ""
                    inString = false
                } else {
                    flushNormal()
                    current.append(character)
                    inString = true
                }
                continue
            }
            if inString {
                current.append(character)
                continue
            }
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flushNormal()
                tokens.append(Token(text: String(character), color: .primary))
            }
        }
        if inString {
            tokens.append(Token(text: current, color: .orange))
        } else {
            flushNormal()
        }
        return tokens
    }

    private static func token(for text: String) -> Token {
        if keywords.contains(text) {
            return Token(text: text, color: .purple)
        }
        if text.allSatisfy(\.isNumber) {
            return Token(text: text, color: .blue)
        }
        return Token(text: text, color: .primary)
    }
}
#endif
