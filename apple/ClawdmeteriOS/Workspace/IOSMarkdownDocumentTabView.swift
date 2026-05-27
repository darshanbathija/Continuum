import SwiftUI
import QuickLook
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif

struct IOSMarkdownDocumentTabView: View {
    let tab: IOSWorkspaceDocumentTab
    let sessionId: UUID
    @ObservedObject var client: AgentControlClient

    @Environment(\.tahoe) private var t
    @StateObject private var loader = IOSMarkdownDocumentLoader()
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: tab.path) {
            await loader.load(client: client, sessionId: sessionId, path: tab.path)
        }
        .onDisappear {
            loader.cancel()
        }
        .quickLookPreview($previewURL)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t.accent)
                .accessibilityHidden(true)
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
            }
            Spacer()
            Button {
                previewURL = loader.loadedURL
            } label: {
                Image(systemName: "doc.viewfinder")
            }
            .disabled(loader.loadedURL == nil)
            .accessibilityLabel("Preview file")
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = tab.path
                #endif
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy path")
            Button {
                Task {
                    await loader.load(client: client, sessionId: sessionId, path: tab.path, force: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh document")
        }
        .buttonStyle(.plain)
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
        case .loaded(let result):
            ScrollView {
                IOSMarkdownDocumentPage(document: result.document)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            }
            .background(t.dark ? Color.black.opacity(0.18) : Color(uiColor: .systemGroupedBackground))
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
final class IOSMarkdownDocumentLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(IOSMarkdownDocumentLoadResult)
        case failed(IOSMarkdownDocumentLoadError)
    }

    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?
    private var cache: [IOSMarkdownDocumentCacheKey: IOSMarkdownDocumentLoadResult] = [:]
    private var loadGeneration: UInt64 = 0

    var loadedURL: URL? {
        guard case .loaded(let result) = state else { return nil }
        return result.localURL
    }

    func load(client: AgentControlClient, sessionId: UUID, path: String, force: Bool = false) async {
        task?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        let task = Task { [weak self, weak client] in
            guard let client else {
                self?.publish(.failed(.downloadFailed("Not paired to a Mac.")), generation: generation)
                return
            }
            guard PathValidator.isSafeArtifactPath(path) else {
                self?.publish(.failed(.unsupportedContent("This document path is not safe to request from the paired Mac.")), generation: generation)
                return
            }
            do {
                let localURL = try await client.downloadMarkdownDocument(
                    sessionId: sessionId,
                    remotePath: path,
                    forceRefresh: force
                )
                let prepared = try await Task.detached(priority: .utility) {
                    try IOSMarkdownDocumentLoader.prepare(localURL: localURL, remotePath: path)
                }.value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if !force, let cached = self.cache[prepared.key] {
                    self.publish(.loaded(cached), generation: generation)
                    return
                }
                let result = prepared.result
                self.cache[prepared.key] = result
                self.publish(.loaded(result), generation: generation)
            } catch is CancellationError {
                return
            } catch let error as IOSMarkdownDocumentLoadError {
                self?.publish(.failed(error), generation: generation)
            } catch let error as AgentControlClient.ArtifactError {
                self?.publish(.failed(.downloadFailed(error.localizedDescription)), generation: generation)
            } catch {
                self?.publish(.failed(.downloadFailed("Could not download this Markdown document from the paired Mac.")), generation: generation)
            }
        }
        self.task = task
        await task.value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func publish(_ newState: State, generation: UInt64) {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        state = newState
    }

    nonisolated static func prepare(localURL: URL, remotePath: String) throws -> IOSMarkdownDocumentPrepared {
        let path = localURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw IOSMarkdownDocumentLoadError.missing
        }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path)
        } catch {
            throw IOSMarkdownDocumentLoadError.permissionDenied
        }
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            throw IOSMarkdownDocumentLoadError.unsupportedContent("Only regular text files can be shown in a document tab.")
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= IOSMarkdownDocumentPrepared.maxBytes else {
            throw IOSMarkdownDocumentLoadError.tooLarge(size)
        }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let data: Data
        do {
            data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        } catch {
            throw IOSMarkdownDocumentLoadError.permissionDenied
        }
        if data.contains(0) {
            throw IOSMarkdownDocumentLoadError.binary
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw IOSMarkdownDocumentLoadError.binary
        }
        let document = MarkdownDocumentContent.parse(text)
        if document.blocks.count == 1,
           case .unsupported = document.blocks[0] {
            throw IOSMarkdownDocumentLoadError.unsupportedContent("This file is readable text, but its Markdown content is not supported by the native reader.")
        }
        return IOSMarkdownDocumentPrepared(
            key: IOSMarkdownDocumentCacheKey(
                remotePath: remotePath,
                localPath: localURL.standardizedFileURL.path,
                mtime: mtime,
                size: size
            ),
            result: IOSMarkdownDocumentLoadResult(document: document, localURL: localURL)
        )
    }
}

struct IOSMarkdownDocumentLoadResult: Equatable {
    let document: MarkdownDocumentContent
    let localURL: URL
}

struct IOSMarkdownDocumentCacheKey: Hashable {
    let remotePath: String
    let localPath: String
    let mtime: Date
    let size: Int64
}

struct IOSMarkdownDocumentPrepared {
    static let maxBytes: Int64 = 2 * 1024 * 1024

    let key: IOSMarkdownDocumentCacheKey
    let result: IOSMarkdownDocumentLoadResult
}

enum IOSMarkdownDocumentLoadError: Error, Equatable {
    case missing
    case permissionDenied
    case tooLarge(Int64)
    case binary
    case unsupportedContent(String)
    case downloadFailed(String)

    var title: String {
        switch self {
        case .missing: return "Document not found"
        case .permissionDenied: return "Permission denied"
        case .tooLarge: return "Document too large"
        case .binary: return "Not a text document"
        case .unsupportedContent: return "Unsupported Markdown"
        case .downloadFailed: return "Could not load document"
        }
    }

    var message: String {
        switch self {
        case .missing:
            return "The downloaded file no longer exists on this iPhone."
        case .permissionDenied:
            return "Clawdmeter could not read the downloaded file."
        case .tooLarge(let bytes):
            return "The reader supports Markdown files up to 2 MB. This file is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
        case .binary:
            return "The file is not readable UTF-8 text."
        case .unsupportedContent(let message):
            return message
        case .downloadFailed(let message):
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
        case .downloadFailed: return "icloud.and.arrow.down"
        }
    }
}

private struct IOSMarkdownDocumentPage: View {
    let document: MarkdownDocumentContent

    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .background(t.dark ? Color.white.opacity(0.06) : Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.7)
        }
        .shadow(color: Color.black.opacity(t.dark ? 0.18 : 0.07), radius: 16, x: 0, y: 8)
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
                .font(TahoeFont.body(15))
                .lineSpacing(5)
                .foregroundStyle(t.fg)
                .textSelection(.enabled))
        case .list(let ordered, let items):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
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
                        .background(t.dark ? Color.black.opacity(0.22) : Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(t.hairline, lineWidth: 0.7)
                        }
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
                    Text("-")
                        .font(TahoeFont.body(15, weight: .semibold))
                        .foregroundStyle(t.fg3)
                        .frame(width: 18)
                }
                Text(item.text)
                    .font(TahoeFont.body(14.5))
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
        case 1: return TahoeFont.body(26, weight: .bold)
        case 2: return TahoeFont.body(21, weight: .semibold)
        case 3: return TahoeFont.body(17.5, weight: .semibold)
        default: return TahoeFont.body(15.5, weight: .semibold)
        }
    }
}
