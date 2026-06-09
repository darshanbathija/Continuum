import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeSourcesPreviewPane: View {
    @Environment(\.tahoe) private var t
    let chatStore: SessionChatStore?
    @State private var lastOpenedSourceValue: String?

    static let maxVisibleEntries = 14
    static let paneAccessibilityIdentifier = "code.sources.pane"
    static let emptyAccessibilityIdentifier = "code.sources.empty"
    static let rowAccessibilityIdentifier = "code.sources.row"

    struct SourceRowDescriptor: Identifiable, Equatable {
        let id: String
        let kind: SourceEntry.Kind
        let label: String
        let payload: String
        let count: Int
        let icon: String
        let subtitle: String
        let counterText: String?
        let accessibilityIdentifier: String
        let accessibilityValue: String

        init(entry: SourceEntry) {
            id = entry.id
            kind = entry.kind
            label = entry.label
            payload = entry.payload
            count = entry.count
            icon = entry.kind == .url ? "link" : "doc"
            subtitle = entry.kind == .url ? "Fetched URL" : "Referenced \(entry.count)x"
            counterText = entry.count > 1 ? "×\(entry.count)" : nil
            accessibilityIdentifier = TahoeSourcesPreviewPane.rowAccessibilityIdentifier
            accessibilityValue = "\(entry.kind.rawValue): \(entry.payload)"
        }
    }

    static func sourceRowDescriptors(from entries: [SourceEntry]) -> [SourceRowDescriptor] {
        entries.prefix(maxVisibleEntries).map(SourceRowDescriptor.init(entry:))
    }

    private var entries: [SourceRowDescriptor] {
        Self.sourceRowDescriptors(from: chatStore?.snapshot.sourceEntries ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    TahoeEmptyReviewState(icon: "search", title: "No sources yet", body: "Files and URLs referenced by tools will appear here.")
                        .padding(16)
                        .accessibilityIdentifier(Self.emptyAccessibilityIdentifier)
                } else {
                    ForEach(entries) { entry in
                        Button(action: { open(entry) }) {
                            HStack(alignment: .top, spacing: 10) {
                                TahoeIcon(entry.icon, size: 13)
                                    .foregroundStyle(t.accent)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .font(TahoeFont.mono(11.5))
                                        .foregroundStyle(t.fg)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(entry.subtitle)
                                        .font(TahoeFont.body(11))
                                        .foregroundStyle(t.fg3)
                                }
                                Spacer(minLength: 6)
                                if let counterText = entry.counterText {
                                    Text(counterText)
                                        .font(TahoeFont.mono(10.5, weight: .bold))
                                        .foregroundStyle(t.fg3)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityIdentifier(entry.accessibilityIdentifier)
                        .accessibilityLabel(Text(entry.label))
                        .accessibilityValue(Text(entry.accessibilityValue))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier(Self.paneAccessibilityIdentifier)
        .accessibilityValue(Text(lastOpenedSourceValue ?? ""))
    }

    private func open(_ entry: SourceRowDescriptor) {
        lastOpenedSourceValue = entry.accessibilityValue
        if Self.suppressesExternalOpenForUITesting {
            return
        }
        switch entry.kind {
        case .url:
            if let url = URL(string: entry.payload) {
                NSWorkspace.shared.open(url)
            }
        case .file:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.payload)])
        }
    }

    private static var suppressesExternalOpenForUITesting: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CLAWDMETER_UI_TESTING"] == "1"
            && environment["CLAWDMETER_ALLOW_EXTERNAL_OPEN_IN_UI_TESTS"] != "1"
    }
}
