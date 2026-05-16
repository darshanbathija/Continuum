import SwiftUI
import ClawdmeterShared

/// Sessions v2 T33. Multi-pane terminal container for iOS — wraps
/// `iOSTerminalView` in a TabView so the user can spawn additional tmux
/// panes per session. Mirrors the Mac's `TerminalTabContainer`. Each tab
/// carries its own WebSocket; the primary pane is always present and
/// can't be deleted.
struct iOSTerminalTabsView: View {
    @ObservedObject var client: AgentControlClient
    let session: AgentSession

    @State private var panes: [TerminalPaneRef] = []
    @State private var selectedPaneId: String? = nil
    @State private var isAdding = false
    @State private var renameTarget: TerminalPaneRef? = nil
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            paneContent
        }
        .task(id: session.id) { await reload() }
        .alert("New terminal", isPresented: $isAdding) {
            TextField("Pane title (optional)", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameDraft = "" }
            Button("Create") { Task { await addPane() } }
        } message: {
            Text("Spawns a new tmux pane in this session.")
        }
        .alert("Rename pane", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil; renameDraft = "" }
            Button("Save") { renameTarget = nil; renameDraft = "" }
        } message: {
            Text("Renaming is local-only in v2.0; persisted in v2.0.1.")
        }
    }

    @ViewBuilder
    private var tabStrip: some View {
        if panes.isEmpty {
            HStack {
                Text("Loading panes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                addButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(panes) { pane in
                        paneChip(pane)
                    }
                    addButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func paneChip(_ pane: TerminalPaneRef) -> some View {
        let selected = pane.paneId == selectedPaneId
        let label = pane.title.isEmpty
            ? (pane.isPrimary ? "Primary" : pane.paneId)
            : pane.title
        return Button {
            selectedPaneId = pane.paneId
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pane.isPrimary ? "rectangle.inset.filled" : "rectangle")
                    .font(.caption)
                Text(label)
                    .font(.caption.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? SessionsV2Theme.accent.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? SessionsV2Theme.accent : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !pane.isPrimary {
                Button(role: .destructive) {
                    Task { await deletePane(pane) }
                } label: {
                    Label("Delete pane", systemImage: "trash")
                }
            }
            Button {
                renameTarget = pane
                renameDraft = pane.title
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
    }

    private var addButton: some View {
        Button {
            renameDraft = ""
            isAdding = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(SessionsV2Theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add terminal pane")
    }

    @ViewBuilder
    private var paneContent: some View {
        if let host = client.host, let token = client.token {
            // The TerminalView is wrapped in a stable identifier so SwiftUI
            // tears down + recreates the WebSocket when the user switches
            // panes (vs reusing the old socket with a now-wrong paneId).
            iOSTerminalView(
                sessionId: session.id,
                host: host,
                wsPort: client.wsPort,
                token: token,
                paneId: selectedPaneId
            )
            .id(selectedPaneId ?? "primary")
        } else {
            ContentUnavailableView("Not paired", systemImage: "wifi.exclamationmark")
        }
    }

    private func reload() async {
        let fetched = await client.fetchTerminals(sessionId: session.id)
        // Daemon endpoint may return an empty list when only the primary
        // pane exists; synthesize a primary tab so the UI is never empty.
        var seeded = fetched
        if seeded.isEmpty || seeded.allSatisfy({ !$0.isPrimary }) {
            if let primaryPaneId = session.tmuxPaneId ?? session.tmuxWindowId {
                seeded.insert(
                    TerminalPaneRef(paneId: primaryPaneId, title: "Primary", isPrimary: true),
                    at: 0
                )
            }
        }
        panes = seeded
        if selectedPaneId == nil { selectedPaneId = seeded.first?.paneId }
    }

    private func addPane() async {
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renameDraft = ""
        if let added = await client.addTerminal(sessionId: session.id, title: title) {
            panes.append(added)
            selectedPaneId = added.paneId
        }
    }

    private func deletePane(_ pane: TerminalPaneRef) async {
        await client.deleteTerminal(sessionId: session.id, paneId: pane.paneId)
        panes.removeAll { $0.paneId == pane.paneId }
        if selectedPaneId == pane.paneId {
            selectedPaneId = panes.first?.paneId
        }
    }
}
