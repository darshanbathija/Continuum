import SwiftUI
import AppKit
import ClawdmeterShared

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
    var syntaxTheme: CodeSyntaxTheme = .tahoe

    @Environment(\.colorScheme) private var colorScheme
    /// T6 lazy markdown cache (codex A2' override): parse `split()` +
    /// `AttributedString(markdown:)` ONCE per visible message on first
    /// appear, then reuse. SwiftUI's LazyVStack only mounts ~30 messages
    /// at a time so this naturally bounds cache size to the visible
    /// window. Off-screen messages evict with the view; scrolling back
    /// re-parses (sub-millisecond per message).
    ///
    /// P1-Mac-12: pair the cached chunks with the source they were parsed
    /// from. The previous form had a `if source == src` guard inside the
    /// detached Task closure, but `source` was captured by value at
    /// closure creation — so the comparison was always `src == src` and
    /// older slow parses could clobber fresh chunks during LazyVStack
    /// recycling. We now compare the parsed source against the View's
    /// current `source` on every render and on assignment.
    @State private var cache: CacheEntry?
    /// audit/desktop-surfaces-v2: the latest source a parse was kicked for.
    /// `kickParseIfNeeded`'s detached closure captures the View struct by
    /// value, so the struct's `source` is FROZEN to the instance that kicked
    /// the parse — on an `.onChange` recycle from A→B the closure that
    /// started for A still sees `source == A`, so the staleness guard never
    /// trips. `@State` storage is shared across struct re-creations, so
    /// comparing against `pendingSource` reads the LIVE requested source.
    @State private var pendingSource: String?

    private struct CacheEntry: Equatable {
        let source: String
        let chunks: [PreparedChunk]
    }

    /// A chunk with its AttributedString pre-parsed (for prose) so the
    /// view body doesn't call `AttributedString(markdown:)` on every render.
    private struct PreparedChunk: Identifiable, Equatable {
        let id: Int
        let kind: Kind
        enum Kind: Equatable {
            case prose(AttributedString, fallback: String)
            case code(language: String?, body: String)
        }
    }

    var body: some View {
        // Only render chunks whose parse source matches the current view
        // source — protects against stale slow parses clobbering fresh
        // ones when LazyVStack recycles a row to a different message.
        let liveChunks: [PreparedChunk] = (cache?.source == source) ? (cache?.chunks ?? []) : []
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(liveChunks) { chunk in
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
            // and assign the parsed chunks back when ready.
            kickParseIfNeeded(for: source)
        }
        // SwiftUI's LazyVStack recycling means a row's @State can outlive
        // the original `source` (e.g., when the underlying message id
        // changes via diffing). Re-parse on source change so we don't
        // render stale markdown chunks for a different message body.
        .onChange(of: source) { _, newValue in
            kickParseIfNeeded(for: newValue)
        }
    }

    private func kickParseIfNeeded(for src: String) {
        // Skip if we already have chunks for this exact source.
        if cache?.source == src { return }
        // Record the live requested source in shared @State so the detached
        // closure below can compare against it (not the frozen captured
        // `source`) when it completes.
        pendingSource = src
        Task.detached(priority: .userInitiated) {
            let prepared = Self.prepare(source: src)
            await MainActor.run {
                // Codex fix: an older parse can complete AFTER a newer
                // one when SwiftUI recycles the row from source A to
                // source B and B parses faster. If we unconditionally
                // stored `(A, parsed_A)` here, body's `cache.source !=
                // source` filter would render nothing AND no
                // onChange/onAppear would fire again for B (the source
                // already changed) — that message stays blank
                // indefinitely. Only commit the result when it matches
                // the LIVE pending source (`source` is frozen in this
                // captured-by-value closure); otherwise re-kick a parse
                // for the live source so the row renders.
                let live = pendingSource ?? source
                guard live == src else {
                    kickParseIfNeeded(for: live)
                    return
                }
                cache = CacheEntry(source: src, chunks: prepared)
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
                .foregroundStyle(codeForeground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(codeBg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(codeBorder, lineWidth: 0.5)
                )
        }
    }

    private var codeBg: Color {
        switch syntaxTheme {
        case .tahoe:
            return colorScheme == .dark
                ? Color(.sRGB, red: 0.06, green: 0.10, blue: 0.12, opacity: 0.92)
                : Color(.sRGB, red: 0.90, green: 0.97, blue: 0.98, opacity: 0.92)
        case .graphite:
            return colorScheme == .dark
                ? Color(.sRGB, red: 0.10, green: 0.10, blue: 0.11, opacity: 0.92)
                : Color(.sRGB, red: 0.94, green: 0.94, blue: 0.95, opacity: 0.92)
        case .xcode:
            return colorScheme == .dark
                ? Color(.sRGB, red: 0.08, green: 0.09, blue: 0.13, opacity: 0.95)
                : Color(.sRGB, red: 0.96, green: 0.98, blue: 1.0, opacity: 0.95)
        }
    }

    private var codeForeground: Color {
        switch syntaxTheme {
        case .tahoe: return colorScheme == .dark ? Color(.sRGB, red: 0.82, green: 0.94, blue: 0.93) : Color(.sRGB, red: 0.06, green: 0.22, blue: 0.24)
        case .graphite: return colorScheme == .dark ? Color(.sRGB, red: 0.90, green: 0.90, blue: 0.92) : Color(.sRGB, red: 0.16, green: 0.16, blue: 0.18)
        case .xcode: return colorScheme == .dark ? Color(.sRGB, red: 0.78, green: 0.86, blue: 1.0) : Color(.sRGB, red: 0.05, green: 0.20, blue: 0.45)
        }
    }

    private var codeBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
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
