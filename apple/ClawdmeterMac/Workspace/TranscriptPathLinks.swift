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

    var body: some View {
        if !links.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(links) { link in
                        TranscriptPathLinkButton(link: link, presentationStore: presentationStore)
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

    private var exists: Bool {
        FileManager.default.fileExists(atPath: link.absolutePath)
    }

    private var lineLabel: String {
        if let end = link.lineEnd, end != link.lineStart {
            return "\(link.lineStart)-\(end)"
        }
        return "\(link.lineStart)"
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
        .buttonStyle(.plain)
        .disabled(!exists)
        .help(exists ? "Open \(link.path) at line \(lineLabel)" : "File not found: \(link.path)")
        .accessibilityLabel(exists ? "Open \(link.path) line \(lineLabel)" : "File not found \(link.path)")
        .contextMenu {
            Button("Copy Relative Path") { copy(link.path) }
            Button("Copy Absolute Path") { copy(link.absolutePath) }
            Button("Reveal in Finder") { reveal() }
                .disabled(!exists)
        }
    }

    private func open() {
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
}
