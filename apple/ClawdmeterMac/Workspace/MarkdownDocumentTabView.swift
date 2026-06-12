import SwiftUI
import AppKit
import WebKit
import Quartz
import ClawdmeterShared

/// Routes a workspace document tab to the right in-app preview surface for
/// Markdown, HTML, images, PDFs, Office docs, and other popular outputs.
struct WorkspaceDocumentTabView: View {
    let tab: WorkspaceDocumentTab

    @Environment(\.tahoe) private var t

    private var kind: TranscriptArtifactKind {
        TranscriptArtifactClassifier.kind(forPath: tab.path) ?? .markdown
    }

    var body: some View {
        switch kind {
        case .markdown:
            MarkdownDocumentTabView(tab: tab)
        case .html:
            HTMLDocumentTabView(tab: tab)
        case .image:
            ImageDocumentTabView(tab: tab)
        case .pdf, .document, .spreadsheet, .presentation, .media, .archive, .data:
            QuickLookDocumentTabView(tab: tab)
        }
    }
}

struct MarkdownDocumentTabView: View {
    let tab: WorkspaceDocumentTab

    @StateObject private var loader = MarkdownDocumentLoader()
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: tab.path) {
            await loader.load(path: tab.path)
        }
        .onDisappear {
            loader.cancel()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: TranscriptArtifactClassifier.systemImageName(forPath: tab.path))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                Text(tab.path)
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: ContinuumAnalytics.wrapButton(
                    "markdown_open_in_editor",
                    {

                NSWorkspace.shared.open(URL(fileURLWithPath: tab.path))
            
                    }
                )) {
                Image(systemName: "square.and.pencil")
            }
            .help("Open in Editor")
            Button(action: ContinuumAnalytics.wrapButton(
                    "markdown_reveal_in_finder",
                    {

                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.path)])
            
                    }
                )) {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            Button(action: ContinuumAnalytics.wrapButton(
                    "markdown_copy_path",
                    {

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path, forType: .string)
            
                    }
                )) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy Path")
            Button(action: ContinuumAnalytics.wrapButton(
                    "markdown_refresh",
                    {

                Task { await loader.load(path: tab.path, force: true) }
            
                    }
                )) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(t.dark ? Color.white.opacity(0.025) : Color.black.opacity(0.018))
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let document):
            ScrollView {
                MarkdownDocumentPage(document: document)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
            }
            .background(t.dark ? Color.black.opacity(0.18) : Color(nsColor: .windowBackgroundColor).opacity(0.72))
        case .failed(let error):
            ContentUnavailableView(
                error.title,
                systemImage: error.systemImage,
                description: Text(error.message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
final class MarkdownDocumentLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(MarkdownDocumentContent)
        case failed(MarkdownDocumentLoadError)
    }

    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?
    private var cache: [MarkdownDocumentCacheKey: MarkdownDocumentContent] = [:]

    func load(path: String, force: Bool = false) async {
        task?.cancel()
        state = .loading
        let task = Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    try MarkdownDocumentLoader.prepare(path: path)
                }.value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if !force, let cached = self.cache[prepared.key] {
                    self.state = .loaded(cached)
                    return
                }
                let document = prepared.document
                self.cache[prepared.key] = document
                self.state = .loaded(document)
            } catch is CancellationError {
                return
            } catch let error as MarkdownDocumentLoadError {
                self?.state = .failed(error)
            } catch {
                self?.state = .failed(.unsupportedContent("Could not load this Markdown document."))
            }
        }
        self.task = task
        await task.value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private nonisolated static func prepare(path: String) throws -> MarkdownDocumentPrepared {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw MarkdownDocumentLoadError.missing
        }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path)
        } catch {
            throw MarkdownDocumentLoadError.permissionDenied
        }
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            throw MarkdownDocumentLoadError.unsupportedContent("Only regular text files can be shown in a document tab.")
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= MarkdownDocumentPrepared.maxBytes else {
            throw MarkdownDocumentLoadError.tooLarge(size)
        }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw MarkdownDocumentLoadError.permissionDenied
        }
        if data.contains(0) {
            throw MarkdownDocumentLoadError.binary
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MarkdownDocumentLoadError.binary
        }
        let document = MarkdownDocumentContent.parse(text)
        if document.blocks.count == 1,
           case .unsupported = document.blocks[0] {
            throw MarkdownDocumentLoadError.unsupportedContent("This file is readable text, but its Markdown content is not supported by the native reader.")
        }
        return MarkdownDocumentPrepared(
            key: MarkdownDocumentCacheKey(path: url.standardizedFileURL.path, mtime: mtime, size: size),
            document: document
        )
    }
}

struct MarkdownDocumentCacheKey: Hashable {
    let path: String
    let mtime: Date
    let size: Int64
}

struct MarkdownDocumentPrepared {
    static let maxBytes: Int64 = 2 * 1024 * 1024

    let key: MarkdownDocumentCacheKey
    let document: MarkdownDocumentContent
}

enum MarkdownDocumentLoadError: Error, Equatable {
    case missing
    case permissionDenied
    case tooLarge(Int64)
    case binary
    case unsupportedContent(String)

    var title: String {
        switch self {
        case .missing: return "Document not found"
        case .permissionDenied: return "Permission denied"
        case .tooLarge: return "Document too large"
        case .binary: return "Not a text document"
        case .unsupportedContent: return "Unsupported Markdown"
        }
    }

    var message: String {
        switch self {
        case .missing:
            return "The file no longer exists at this path."
        case .permissionDenied:
            return "Clawdmeter could not read this file. Check file permissions or open it in your editor."
        case .tooLarge(let bytes):
            return "The reader supports Markdown files up to 2 MB. This file is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
        case .binary:
            return "The file is not readable UTF-8 text."
        case .unsupportedContent(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .missing: return "doc.badge.questionmark"
        case .permissionDenied: return "lock"
        case .tooLarge: return "doc.zipper"
        case .binary: return "exclamationmark.triangle"
        case .unsupportedContent: return "doc.plaintext"
        }
    }
}

private struct MarkdownDocumentPage: View {
    let document: MarkdownDocumentContent

    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
        .padding(.horizontal, 54)
        .padding(.vertical, 48)
        .background(t.dark ? Color.white.opacity(0.06) : Color.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(t.hairline, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(t.dark ? 0.18 : 0.08), radius: 18, x: 0, y: 10)
        .frame(maxWidth: .infinity)
    }

    private func blockView(_ block: MarkdownDocumentBlock) -> AnyView {
        switch block {
        case .heading(let level, let text):
            return AnyView(Text(text)
                .font(headingFont(level))
                .foregroundStyle(t.fg)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 8 : 2))
        case .paragraph(let text):
            return AnyView(Text(text)
                .font(TahoeFont.body(14.5))
                .lineSpacing(5)
                .foregroundStyle(t.fg)
                .textSelection(.enabled))
        case .list(let ordered, let items):
            return AnyView(VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listItem(item, marker: ordered ? "\(index + 1)." : nil)
                }
            })
        case .codeBlock(let language, let code):
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    if let language, !language.isEmpty {
                        Text(language)
                            .font(TahoeFont.mono(10, weight: .semibold))
                            .foregroundStyle(t.fg3)
                    }
                    Text(code)
                        .font(TahoeFont.mono(12))
                        .foregroundStyle(t.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(t.dark ? Color.black.opacity(0.22) : Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t.hairline, lineWidth: 0.7)
                        )
                }
            )
        case .blockQuote(let blocks):
            return AnyView(
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        blockView(child)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(t.accent.opacity(0.5))
                        .frame(width: 3)
                }
            )
        case .thematicBreak:
            return AnyView(Rectangle()
                .fill(t.hairline)
                .frame(height: 1)
                .padding(.vertical, 4))
        case .unsupported(let message):
            return AnyView(Label(message, systemImage: "exclamationmark.triangle")
                .font(TahoeFont.body(13))
                .foregroundStyle(SessionsV2Theme.warn))
        }
    }

    private func listItem(_ item: MarkdownDocumentListItem, marker: String?) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if item.isTask {
                    Image(systemName: item.isComplete ? "checkmark.square" : "square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.isComplete ? t.accent : t.fg3)
                        .frame(width: 18)
                } else if let marker {
                    Text(marker)
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg3)
                        .frame(width: 24, alignment: .trailing)
                } else {
                    Text("•")
                        .font(TahoeFont.body(15, weight: .semibold))
                        .foregroundStyle(t.fg3)
                        .frame(width: 18)
                }
                Text(item.text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            if !item.children.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        blockView(child)
                    }
                }
                .padding(.leading, 28)
            }
        })
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return TahoeFont.body(25, weight: .bold)
        case 2: return TahoeFont.body(20, weight: .semibold)
        case 3: return TahoeFont.body(17, weight: .semibold)
        default: return TahoeFont.body(15.5, weight: .semibold)
        }
    }
}

// MARK: - Shared document tab chrome

private struct WorkspaceDocumentTabToolbar: View {
    let tab: WorkspaceDocumentTab
    let onRefresh: (() -> Void)?

    @Environment(\.tahoe) private var t

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: TranscriptArtifactClassifier.systemImageName(forPath: tab.path))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                Text(tab.path)
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: ContinuumAnalytics.wrapButton(
                    "markdown_open_in_editor",
                    {

                NSWorkspace.shared.open(URL(fileURLWithPath: tab.path))
            
                    }
                )) {
                Image(systemName: "square.and.pencil")
            }
            .help("Open in Editor")
            Button(action: ContinuumAnalytics.wrapButton(
                    "markdown_reveal_in_finder",
                    {

                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.path)])
            
                    }
                )) {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            Button(action: ContinuumAnalytics.wrapButton(
                    "markdown_copy_path",
                    {

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path, forType: .string)
            
                    }
                )) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy Path")
            if let onRefresh {
                Button(action: ContinuumAnalytics.wrapButton("markdown_refresh", onRefresh)) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(t.dark ? Color.white.opacity(0.025) : Color.black.opacity(0.018))
    }
}

// MARK: - HTML preview

private struct HTMLDocumentTabView: View {
    let tab: WorkspaceDocumentTab

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDocumentTabToolbar(tab: tab, onRefresh: nil)
            Divider()
            LocalHTMLPreview(url: URL(fileURLWithPath: tab.path))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LocalHTMLPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

// MARK: - Image preview

private struct ImageDocumentTabView: View {
    let tab: WorkspaceDocumentTab
    @State private var image: NSImage?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDocumentTabToolbar(tab: tab, onRefresh: { loadImage() })
            Divider()
            Group {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(24)
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Could not load image",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: tab.path) {
            loadImage()
        }
    }

    private func loadImage() {
        image = nil
        errorMessage = nil
        let path = tab.path
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = "The file no longer exists at this path."
            return
        }
        guard let loaded = NSImage(contentsOfFile: path) else {
            errorMessage = "Clawdmeter could not decode this image."
            return
        }
        image = loaded
    }
}

// MARK: - QuickLook preview (PDF, Office, media, archives, …)

private struct QuickLookDocumentTabView: View {
    let tab: WorkspaceDocumentTab

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDocumentTabToolbar(tab: tab, onRefresh: nil)
            Divider()
            WorkspaceQuickLookPreview(url: URL(fileURLWithPath: tab.path))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WorkspaceQuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}
