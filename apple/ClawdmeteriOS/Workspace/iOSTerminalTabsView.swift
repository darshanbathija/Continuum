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
    @State private var addDraft: String = ""
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
            TextField("Pane title (optional)", text: $addDraft)
            Button("Cancel", role: .cancel) { addDraft = "" }
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
            Button("Save") { Task { await applyRename() } }
        } message: {
            Text("Saved on the Mac and kept after the session list reloads.")
        }
    }

    private func applyRename() async {
        defer {
            renameTarget = nil
            renameDraft = ""
        }
        guard let target = renameTarget else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let renamed = await client.renameTerminal(
            sessionId: session.id,
            terminalRefId: target.id,
            title: trimmed
        ), let idx = panes.firstIndex(where: { $0.id == target.id }) {
            panes[idx] = renamed
        } else {
            await reload()
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
                    .accessibilityHidden(true)
                Text(label)
                    .font(.caption.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? SessionsV2Theme.accent.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? SessionsV2Theme.accent : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pane.isPrimary ? "Primary pane" : "Pane") \(label)")
        .accessibilityHint(pane.isPrimary
            ? "Double-tap to view the agent's main terminal."
            : "Double-tap to switch panes. Long-press for rename or delete."
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if !pane.isPrimary {
                Button(role: .destructive) {
                    Task { await deletePane(pane) }
                } label: {
                    Label("Delete pane", systemImage: "trash")
                }
            }
            if !pane.isPrimary {
                Button {
                    renameTarget = pane
                    renameDraft = pane.title
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
        }
    }

    private var addButton: some View {
        Button {
            addDraft = ""
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
        let title = addDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        addDraft = ""
        if let added = await client.addTerminal(sessionId: session.id, title: title) {
            panes.append(added)
            selectedPaneId = added.paneId
        }
    }

    private func deletePane(_ pane: TerminalPaneRef) async {
        // Daemon's DELETE handler matches on TerminalPaneRef.id (a UUID),
        // NOT the tmux pane id (e.g. "%14"). The two collided in the v2
        // ship — sending pane.paneId here always 404s. Send the ref UUID;
        // local panes/selectedPaneId still key off the tmux paneId since
        // that's what the WS envelope expects.
        await client.deleteTerminal(sessionId: session.id, terminalRefId: pane.id)
        panes.removeAll { $0.paneId == pane.paneId }
        if selectedPaneId == pane.paneId {
            selectedPaneId = panes.first?.paneId
        }
    }
}
