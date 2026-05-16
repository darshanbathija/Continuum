import SwiftUI
import AppKit

/// Render an assistant message as rich markdown — Codex-desktop parity G4.
///
/// We split the body on triple-backtick fences and render each chunk:
/// - Prose chunks → `AttributedString(markdown:)` (bold, italic, inline code,
///   links, headings up to ###). Native `AttributedString` markdown parses
///   inline tokens but ignores fenced code; that's why we pre-split.
/// - Fenced chunks → monospaced `Text` with a subtle background card. The
///   language tag (```swift) is shown as a chip above the block.
///
/// `Text(_:)` natively renders an `AttributedString`, so the prose chunks
/// participate in selection and line-wrapping like a normal `Text`. We don't
/// reach for a WebView — that would break selection and animate weirdly
/// inside a chat list.
struct MarkdownRenderer: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.split(source).enumerated()), id: \.offset) { _, chunk in
                switch chunk {
                case .prose(let text):
                    prose(text)
                case .code(let language, let body):
                    codeBlock(language: language, body: body)
                }
            }
        }
    }

    @ViewBuilder
    private func prose(_ text: String) -> some View {
        if let attr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attr)
                .font(.system(size: 13, design: .serif))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: 13, design: .serif))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlock(language: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
            Text(body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(codeBg, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var codeBg: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.05)
    }

    // MARK: - Chunking

    enum Chunk: Hashable {
        case prose(String)
        case code(language: String?, body: String)
    }

    /// Split a markdown source on triple-backtick code fences. Stable + simple:
    /// any line beginning with three+ backticks toggles fenced state.
    static func split(_ source: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var inCode = false
        var codeLanguage: String? = nil
        var buffer = ""

        func flushProse() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(.prose(buffer))
            }
            buffer = ""
        }
        func flushCode() {
            chunks.append(.code(language: codeLanguage, body: buffer))
            buffer = ""
            codeLanguage = nil
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let tag = s.drop(while: { $0 == "`" })
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = tag.isEmpty ? nil : tag
                }
                continue
            }
            if !buffer.isEmpty { buffer.append("\n") }
            buffer.append(s)
        }
        if inCode {
            // Unclosed fence — emit as prose so we don't lose content.
            chunks.append(.prose("```" + (codeLanguage.map { $0 + "\n" } ?? "") + buffer))
        } else {
            flushProse()
        }
        return chunks
    }
}
