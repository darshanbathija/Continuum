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
    /// T6 lazy markdown cache (codex A2' override): parse `split()` +
    /// `AttributedString(markdown:)` ONCE per visible message on first
    /// appear, then reuse. SwiftUI's LazyVStack only mounts ~30 messages
    /// at a time so this naturally bounds cache size to the visible
    /// window. Off-screen messages evict with the view; scrolling back
    /// re-parses (sub-millisecond per message).
    @State private var cachedChunks: [PreparedChunk]?

    /// A chunk with its AttributedString pre-parsed (for prose) so the
    /// view body doesn't call `AttributedString(markdown:)` on every render.
    private struct PreparedChunk: Identifiable {
        let id: Int
        let kind: Kind
        enum Kind {
            case prose(AttributedString, fallback: String)
            case code(language: String?, body: String)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cachedChunks ?? []) { chunk in
                switch chunk.kind {
                case .prose(let attr, _):
                    Text(attr)
                        .font(.system(size: 13, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let body):
                    codeBlock(language: language, body: body)
                }
            }
        }
        .onAppear {
            // First-attach parse runs OFF MAIN. For long assistant
            // messages (multi-KB body, several code fences) the markdown
            // parse can take 5–30ms per row; doing that synchronously
            // inside `.onAppear` on the main thread caused faulted-in
            // scroll hitches the perf overhaul was meant to eliminate.
            // We render the row immediately (chunks=nil → empty body)
            // and assign the parsed chunks back when ready. The visual
            // effect is "row appears, text fills in within ~1 frame".
            if cachedChunks == nil {
                let src = source
                Task.detached(priority: .userInitiated) {
                    let prepared = Self.prepare(source: src)
                    await MainActor.run {
                        // Only assign if the source the view holds is
                        // still the one we parsed — protects against
                        // LazyVStack rebinding during the parse.
                        if source == src {
                            cachedChunks = prepared
                        }
                    }
                }
            }
        }
        // SwiftUI's LazyVStack recycling means a row's @State can outlive
        // the original `source` (e.g., when the underlying message id
        // changes via diffing). Re-parse on source change so we don't
        // render stale markdown chunks for a different message body.
        .onChange(of: source) { _, newValue in
            let src = newValue
            // Clear the stale cache so the view doesn't render the
            // previous source's markdown for one frame.
            cachedChunks = nil
            Task.detached(priority: .userInitiated) {
                let prepared = Self.prepare(source: src)
                await MainActor.run {
                    if source == src {
                        cachedChunks = prepared
                    }
                }
            }
        }
    }

    private static func prepare(source: String) -> [PreparedChunk] {
        let chunks = Self.split(source)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return chunks.enumerated().map { idx, chunk in
            switch chunk {
            case .prose(let text):
                let attr = (try? AttributedString(markdown: text, options: options))
                    ?? AttributedString(text)
                return PreparedChunk(id: idx, kind: .prose(attr, fallback: text))
            case .code(let language, let body):
                return PreparedChunk(id: idx, kind: .code(language: language, body: body))
            }
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
