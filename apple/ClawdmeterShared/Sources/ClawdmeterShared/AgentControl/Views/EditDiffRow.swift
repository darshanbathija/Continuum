#if canImport(SwiftUI)
import SwiftUI

/// v0.5.5 chat row for an `Edit` / `MultiEdit` / `Write` tool call.
///
/// Replaces the generic "Ran 1 command" grouping for file-edit tool
/// uses — matches Claude Code's own CLI rendering: `Edited <basename>
/// +N -M ›`. For `Write` we render `Wrote <basename> +N` (no `-M` part,
/// since the prior content isn't known at parse time so deletions are
/// always reported as zero).
///
/// Tap → toggles a disclosure that surfaces the full file path, the
/// capped edit preview/diff payload when available, and the matched
/// tool_result body.
///
/// v0.29.4: removed the hover-to-peek behavior. Users reported diffs
/// auto-opening when scrolling past them was disorienting — the disclosure
/// would flash open and closed as the pointer crossed each row. The
/// state is now click-only.
public struct EditDiffRow: View {
    /// Structured summary parsed at ingest time from the tool_use input.
    public let stats: EditStats
    /// Richer edit payload parsed from provider input. Carries a capped
    /// preview or patch body when the provider exposed one.
    public let editDiff: EditDiff?
    /// Companion result (if it's already landed) — its body becomes the
    /// inline "result" view when the row is expanded. May be nil while
    /// the agent is still applying the edit.
    public let resultBody: String?
    public let density: TranscriptDensity

    @State private var isExpanded: Bool = false

    public init(
        stats: EditStats,
        editDiff: EditDiff? = nil,
        resultBody: String?,
        density: TranscriptDensity = .balanced
    ) {
        self.stats = stats
        self.editDiff = editDiff
        self.resultBody = resultBody
        self.density = density
    }

    public var body: some View {
        #if os(watchOS)
        // watchOS has no DisclosureGroup; the chat thread doesn't render
        // on Watch today, so a compact summary line is enough here as a
        // future-proof placeholder if a Watch chat tab ever lands.
        HStack(spacing: 6) {
            ToolIconView(toolName: stats.kind == .write ? "Write" : "Edit", size: 12)
            Text(verb)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            FilePathChip(path: stats.filePath)
            if stats.additions > 0 {
                Text("+\(stats.additions)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(additionsColor)
            }
            if stats.deletions > 0 {
                Text("-\(stats.deletions)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(deletionsColor)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        #else
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(stats.filePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let preview = editDiff?.preview, !preview.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(previewTitle)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if editDiff?.isTruncated == true {
                                Text("truncated")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        EditDiffPreviewPane(
                            preview: preview,
                            lineLimit: previewLineLimit
                        )
                    }
                    .padding(8)
                    .background(
                        Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                if let resultBody, !resultBody.isEmpty {
                    Text(resultBody)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(resultLineLimit)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                ToolIconView(toolName: stats.kind == .write ? "Write" : "Edit", size: 12)
                Text(verb)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                FilePathChip(path: stats.filePath)
                if stats.additions > 0 {
                    Text("+\(stats.additions)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(additionsColor)
                        .monospacedDigit()
                }
                if stats.deletions > 0 {
                    Text("-\(stats.deletions)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(deletionsColor)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        #endif
    }

    private var previewTitle: String {
        switch editDiff?.kind {
        case .applyPatch: return "patch"
        case .write: return "content"
        case .multiEdit: return "edits"
        case .edit: return "edit"
        case nil: return "preview"
        }
    }

    private var previewLineLimit: Int? {
        switch density {
        case .compact: return 12
        case .balanced: return 24
        case .detailed: return nil
        }
    }

    private var resultLineLimit: Int? {
        switch density {
        case .compact: return 4
        case .balanced: return 8
        case .detailed: return nil
        }
    }

    private var verb: String {
        switch stats.kind {
        case .edit, .multiEdit: return "Edited"
        case .write:            return "Wrote"
        }
    }

    private var additionsColor: Color {
        // Matches the green/red Claude Code's CLI uses for unified diffs.
        Color(red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0)
    }

    private var deletionsColor: Color {
        Color(red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0)
    }
}

public struct EditDiffPreviewLine: Identifiable, Equatable {
    public enum Kind: Equatable {
        case context
        case addition
        case deletion
        case header
    }

    public let id: Int
    public let oldText: String?
    public let newText: String?
    public let kind: Kind
}

public enum EditDiffPreviewModel {
    public static func lines(from preview: String) -> [EditDiffPreviewLine] {
        var rows: [EditDiffPreviewLine] = []
        var index = 0
        for raw in preview.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let row: EditDiffPreviewLine
            if raw.hasPrefix("@@") || raw.hasPrefix("*** ") || raw.hasPrefix("diff --git") {
                row = EditDiffPreviewLine(id: index, oldText: raw, newText: raw, kind: .header)
            } else if raw.hasPrefix("+"), !raw.hasPrefix("+++") {
                row = EditDiffPreviewLine(id: index, oldText: nil, newText: String(raw.dropFirst()), kind: .addition)
            } else if raw.hasPrefix("-"), !raw.hasPrefix("---") {
                row = EditDiffPreviewLine(id: index, oldText: String(raw.dropFirst()), newText: nil, kind: .deletion)
            } else if raw.hasPrefix(" ") {
                let text = String(raw.dropFirst())
                row = EditDiffPreviewLine(id: index, oldText: text, newText: text, kind: .context)
            } else {
                row = EditDiffPreviewLine(id: index, oldText: raw, newText: raw, kind: .context)
            }
            rows.append(row)
            index += 1
        }
        return rows
    }

    public static func hasSideBySideChanges(_ lines: [EditDiffPreviewLine]) -> Bool {
        lines.contains { $0.kind == .addition || $0.kind == .deletion }
    }
}

private struct EditDiffPreviewPane: View {
    let preview: String
    let lineLimit: Int?

    private var lines: [EditDiffPreviewLine] {
        let parsed = EditDiffPreviewModel.lines(from: preview)
        guard let lineLimit else { return parsed }
        return Array(parsed.prefix(lineLimit))
    }

    private var isTruncatedByDensity: Bool {
        guard let lineLimit else { return false }
        return EditDiffPreviewModel.lines(from: preview).count > lineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if EditDiffPreviewModel.hasSideBySideChanges(lines) {
                ViewThatFits(in: .horizontal) {
                    sideBySide.frame(minWidth: 620)
                    unified
                }
            } else {
                unified
            }
            if isTruncatedByDensity {
                Text("show detailed density for full preview")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .editDiffSelectableText()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 0) {
            diffColumn(title: "Before", side: .old)
            Divider()
            diffColumn(title: "After", side: .new)
        }
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.10), lineWidth: 0.5))
    }

    private var unified: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(lines) { line in
                DiffCodeLine(
                    text: unifiedText(for: line),
                    kind: line.kind,
                    prefix: unifiedPrefix(for: line)
                )
            }
        }
    }

    private enum DiffSide {
        case old
        case new
    }

    private func diffColumn(title: String, side: DiffSide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines) { line in
                    let text = side == .old ? line.oldText : line.newText
                    DiffCodeLine(
                        text: text ?? "",
                        kind: columnKind(for: line, side: side),
                        prefix: nil
                    )
                    .opacity(text == nil ? 0.25 : 1.0)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func unifiedText(for line: EditDiffPreviewLine) -> String {
        line.newText ?? line.oldText ?? ""
    }

    private func unifiedPrefix(for line: EditDiffPreviewLine) -> String? {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context:  return " "
        case .header:   return nil
        }
    }

    private func columnKind(for line: EditDiffPreviewLine, side: DiffSide) -> EditDiffPreviewLine.Kind {
        switch (line.kind, side) {
        case (.addition, .new): return .addition
        case (.deletion, .old): return .deletion
        case (.header, _):      return .header
        default:                return .context
        }
    }
}

private extension View {
    @ViewBuilder
    func editDiffSelectableText() -> some View {
        #if os(watchOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

private struct DiffCodeLine: View {
    let text: String
    let kind: EditDiffPreviewLine.Kind
    let prefix: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let prefix {
                Text(prefix)
                    .font(.caption.monospaced())
                    .foregroundStyle(prefixColor)
                    .frame(width: 14, alignment: .center)
            }
            HStack(spacing: 0) {
                ForEach(DiffSyntaxTokenizer.tokens(for: text)) { token in
                    Text(token.text)
                        .foregroundColor(token.color)
                }
            }
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(lineBackground)
    }

    private var prefixColor: Color {
        switch kind {
        case .addition: return additionsColor
        case .deletion: return deletionsColor
        case .header:   return .purple
        case .context:  return .secondary
        }
    }

    private var lineBackground: Color {
        switch kind {
        case .addition: return additionsColor.opacity(0.10)
        case .deletion: return deletionsColor.opacity(0.10)
        case .header:   return Color.purple.opacity(0.09)
        case .context:  return Color.clear
        }
    }

    private var additionsColor: Color {
        Color(red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0)
    }

    private var deletionsColor: Color {
        Color(red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0)
    }
}

private enum DiffSyntaxTokenizer {
    struct Token: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
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
