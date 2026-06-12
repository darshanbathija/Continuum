import SwiftUI
import AppKit
import ClawdmeterShared

/// Horizontal strip of clickable file:line chips that surface every
/// resolvable path link mentioned in the chat transcript. Used by the
/// chat thread to give the user one-click jumps to source.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Reads
/// `presentationStore` for the user's external-editor preference; the
/// link list itself is a value type passed in at init. Independent of
/// the parent workspace's @State.
struct TranscriptPathLinkStrip: View {
    @Environment(\.tahoe) private var t

    let links: [ResolvablePathLink]
    @ObservedObject var presentationStore: SessionPresentationStore
    let onOpenMarkdownDocument: ((String) -> Void)?

    init(
        links: [ResolvablePathLink],
        presentationStore: SessionPresentationStore,
        onOpenMarkdownDocument: ((String) -> Void)? = nil
    ) {
        self.links = links
        self.presentationStore = presentationStore
        self.onOpenMarkdownDocument = onOpenMarkdownDocument
    }

    var body: some View {
        if !links.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(links) { link in
                        TranscriptPathLinkButton(
                            link: link,
                            presentationStore: presentationStore,
                            onOpenMarkdownDocument: onOpenMarkdownDocument
                        )
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Referenced files")
        }
    }
}

/// A single file:line button. Opens via `xed`, Finder, or the system
/// default editor depending on the user's external-editor preference,
/// recorded back to `presentationStore` so repeated clicks dedupe.
struct TranscriptPathLinkButton: View {
    @Environment(\.tahoe) private var t

    let link: ResolvablePathLink
    @ObservedObject var presentationStore: SessionPresentationStore
    let onOpenMarkdownDocument: ((String) -> Void)?

    private var exists: Bool {
        FileManager.default.fileExists(atPath: link.absolutePath)
    }

    private var lineLabel: String {
        if let end = link.lineEnd, end != link.lineStart {
            return "\(link.lineStart)-\(end)"
        }
        return "\(link.lineStart)"
    }

    private var opensInDocumentTab: Bool {
        TranscriptArtifactClassifier.opensInDocumentTab(forPath: link.absolutePath)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: exists ? "doc.text.magnifyingglass" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                Text("\((link.path as NSString).lastPathComponent):\(lineLabel)")
                    .font(TahoeFont.mono(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(exists ? t.fg2 : t.fg3)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(t.dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.7)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!exists)
        .help(exists ? helpText : "File not found: \(link.path)")
        .accessibilityLabel(exists ? "Open \(link.path) line \(lineLabel)" : "File not found \(link.path)")
        .contextMenu {
            if opensInDocumentTab, let onOpenMarkdownDocument {
                Button("Open in Code Tab") { onOpenMarkdownDocument(link.absolutePath) }
                    .disabled(!exists)
                Button("Open External Editor") { openExternal() }
                    .disabled(!exists)
            }
            Button("Copy Relative Path") { copy(link.path) }
            Button("Copy Absolute Path") { copy(link.absolutePath) }
            Button("Reveal in Finder") { reveal() }
                .disabled(!exists)
        }
    }

    private func open() {
        guard exists else { return }
        if opensInDocumentTab, let onOpenMarkdownDocument {
            try? presentationStore.recordPathAction(link.path)
            onOpenMarkdownDocument(link.absolutePath)
            return
        }
        openExternal()
    }

    private func openExternal() {
        guard exists else { return }
        try? presentationStore.recordPathAction(link.path)
        let preference = presentationStore.snapshot.externalEditorIdentifier ?? "xed"
        if preference == "finder" {
            reveal()
            return
        }
        if preference == "default" {
            NSWorkspace.shared.open(URL(fileURLWithPath: link.absolutePath))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xed", "-l", "\(link.lineStart)", link.absolutePath]
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: link.absolutePath))
            }
        }
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: link.absolutePath))
        }
    }

    private func reveal() {
        guard exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: link.absolutePath)])
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var helpText: String {
        if opensInDocumentTab, onOpenMarkdownDocument != nil {
            return "Open \(link.path) in Code tab"
        }
        return "Open \(link.path) at line \(lineLabel)"
    }
}
