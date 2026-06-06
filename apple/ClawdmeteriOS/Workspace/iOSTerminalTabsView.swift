import SwiftUI
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif

/// Sessions v2 T33. Multi-pane terminal container for iOS. Wraps
/// `iOSTerminalView` in a TabView so the user can spawn additional direct PTY
/// terminals per session. Mirrors the Mac's `TerminalTabContainer`. Each tab
/// carries its own WebSocket; the primary terminal is always present and can't
/// be deleted.
struct iOSTerminalTabsView: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    let session: AgentSession
    @ObservedObject var chatStore: iOSChatStore

    @State private var panes: [TerminalPaneRef] = []
    @State private var selectedPaneId: String? = nil
    @State private var isAdding = false
    @State private var addDraft: String = ""
    @State private var renameTarget: TerminalPaneRef? = nil
    @State private var renameDraft: String = ""
    @State private var commandDraft: String = ""
    @State private var terminalCommand: IOSTerminalCommand?
    @State private var connectionState: IOSTerminalConnectionState = .idle

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if hasLiveTerminal {
                commandBar
            }
            TahoeHair()
            paneContent
        }
        .task(id: session.id) {
            if hasLiveTerminal { await reload() }
        }
        .onChange(of: selectedPaneId) { _, _ in
            connectionState = client.isConfigured ? .connecting : .idle
        }
        .alert("New terminal", isPresented: $isAdding) {
            TextField("Pane title (optional)", text: $addDraft)
            Button("Cancel", role: .cancel) { addDraft = "" }
            Button("Create") { Task { await addPane() } }
        } message: {
            Text("Spawns a new terminal in this session.")
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

    private var commandBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                TextField("Send command to selected pane", text: $commandDraft)
                    .font(TahoeFont.mono(11.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(sendCommandDraft)
                Button {
                    sendCommandDraft()
                } label: {
                    Label("Send", systemImage: "return")
                        .labelStyle(.iconOnly)
                }
                .disabled(commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    controlButton("Ctrl-C", bytes: [0x03])
                    controlButton("Ctrl-D", bytes: [0x04])
                    controlButton("Esc", bytes: [0x1B])
                    controlButton("Tab", bytes: [0x09])
                    controlButton("Clear", bytes: [0x0C])
                    Button {
                        terminalCommand = .reconnect(UUID())
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    #if canImport(UIKit)
                    Button {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            terminalCommand = .send(UUID(), pasted)
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    #endif
                }
                .font(TahoeFont.body(11, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            terminalStatusRow
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var terminalStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionStateColor)
                .frame(width: 7, height: 7)
            Text(connectionStateLabel)
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
            Spacer(minLength: 0)
            if client.isConfigured {
                Text("Mac tunnel")
                    .font(TahoeFont.mono(10))
                    .foregroundStyle(t.fg4)
            }
        }
    }

    private var connectionStateColor: Color {
        switch connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        case .idle, .disconnected:
            return t.fg4
        }
    }

    private var connectionStateLabel: String {
        if !client.isConfigured {
            return "Not paired"
        }
        switch connectionState {
        case .idle:
            return "Terminal idle"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Live terminal"
        case .disconnected:
            return "Disconnected"
        case .failed(let message):
            return message.isEmpty ? "Tunnel failed" : message
        }
    }

    private func controlButton(_ title: String, bytes: [UInt8]) -> some View {
        Button {
            terminalCommand = .raw(UUID(), bytes)
        } label: {
            Text(title)
        }
    }

    private func sendCommandDraft() {
        let trimmed = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        terminalCommand = .send(UUID(), trimmed + "\n")
        commandDraft = ""
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
        if !hasLiveTerminal {
            HStack {
                TahoeIcon("terminal", size: 12)
                    .foregroundStyle(t.fg3)
                Text("Recent shell history")
                    .font(TahoeFont.body(11.5, weight: .bold))
                    .foregroundStyle(t.fg3)
                Spacer()
                Text("\(historyEntries.count)")
                    .font(TahoeFont.mono(10.5, weight: .bold))
                    .foregroundStyle(t.fg4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(displayPanes) { pane in
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
        let selected = pane.isPrimary ? selectedPaneId == nil : pane.paneId == selectedPaneId
        let label = pane.title.isEmpty
            ? (pane.isPrimary ? "Primary" : pane.paneId)
            : pane.title
        return Button {
            selectedPaneId = pane.isPrimary ? nil : pane.paneId
        } label: {
            HStack(spacing: 6) {
                TahoeIcon(pane.isPrimary ? "sparkles" : "terminal", size: 11)
                    .accessibilityHidden(true)
                Text(label)
                    .font(TahoeFont.body(11.5, weight: selected ? .bold : .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? t.accentAlpha(0.18) : t.glassTintHi)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(selected ? t.accentAlpha(0.55) : t.hairline, lineWidth: 0.5)
            )
            .foregroundStyle(selected ? t.accent : t.fg2)
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
            TahoeIcon("plus", size: 13, weight: .bold)
                .foregroundStyle(t.accent)
                .frame(width: 30, height: 30)
                .background(t.glassTintHi, in: Circle())
                .overlay { Circle().stroke(t.hairline, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add terminal pane")
    }

    @ViewBuilder
    private var paneContent: some View {
        if !hasLiveTerminal {
            historyContent
        } else if let host = client.host, let token = client.token {
            // The TerminalView is wrapped in a stable identifier so SwiftUI
            // tears down + recreates the WebSocket when the user switches
            // panes (vs reusing the old socket with a now-wrong paneId).
            iOSTerminalView(
                sessionId: session.id,
                host: host,
                wsPort: client.wsPort,
                token: token,
                paneId: selectedPaneId,
                command: $terminalCommand,
                onConnectionStateChange: { state in
                    connectionState = state
                }
            )
            .id(selectedPaneId ?? "primary")
        } else {
            VStack(spacing: 8) {
                TahoeIcon("terminal", size: 24)
                    .foregroundStyle(t.fg4)
                Text("Not paired")
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("Pair this iPhone with the Mac to open the live terminal.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hasLiveTerminal: Bool {
        return session.tmuxPaneId == nil && session.tmuxWindowId == nil
    }

    private var displayPanes: [TerminalPaneRef] {
        guard hasLiveTerminal else { return [] }
        let primary = panes.first(where: { $0.isPrimary }) ?? TerminalPaneRef(
            id: session.id,
            paneId: "",
            title: "\(session.agent.rawValue.capitalized)",
            isPrimary: true,
            createdAt: session.createdAt
        )
        return [primary] + panes.filter { !$0.isPrimary }
    }

    private struct ShellEntry: Identifiable {
        let id: String
        let command: String
        let output: String
        let isError: Bool
    }

    private var historyEntries: [ShellEntry] {
        chatStore.snapshot.items.flatMap { item -> [ShellEntry] in
            guard case let .toolRun(_, pairs) = item else { return [] }
            return pairs.compactMap { pair in
                guard Self.isShellTool(pair.call.title) else { return nil }
                let command = (pair.call.detail?.isEmpty == false ? pair.call.detail! : pair.call.body)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let output = pair.result.map { Self.stripNoise($0.body) } ?? ""
                return ShellEntry(
                    id: pair.id,
                    command: command.isEmpty ? pair.call.title : command,
                    output: output,
                    isError: pair.result?.isError ?? pair.call.isError
                )
            }
        }
        .suffix(24)
        .map { $0 }
    }

    @ViewBuilder
    private var historyContent: some View {
        let entries = historyEntries
        if entries.isEmpty {
            VStack(spacing: 8) {
                TahoeIcon("terminal", size: 24)
                    .foregroundStyle(t.fg4)
                Text("No shell activity")
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("The transcript has not published any Bash or shell tool calls yet.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 6) {
                                Text("$")
                                    .font(TahoeFont.mono(11.5, weight: .bold))
                                    .foregroundStyle(t.accent)
                                Text(entry.command)
                                    .font(TahoeFont.mono(11.5, weight: .semibold))
                                    .foregroundStyle(t.fg)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !entry.output.isEmpty {
                                Text(entry.output)
                                    .font(TahoeFont.mono(11))
                                    .foregroundStyle(entry.isError ? .red : t.fg2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 12)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        TahoeHair()
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(t.dark
                              ? Color(.sRGB, white: 0, opacity: 0.18)
                              : Color(.sRGB, white: 0.96, opacity: 0.6))
                }
                .padding(10)
            }
        }
    }

    private static func isShellTool(_ title: String) -> Bool {
        let shellTools: Set<String> = ["bash", "shell", "exec", "exec_command", "sh", "zsh", "pwsh", "run", "execute"]
        return shellTools.contains(title.lowercased())
    }

    private static func stripNoise(_ raw: String) -> String {
        let prefixes = ["Chunk ID:", "Wall time:", "Process exited", "Original token count:", "Output:", "Total output lines:"]
        let kept = raw.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            for marker in prefixes where trimmed.hasPrefix(marker) { return false }
            return true
        }
        return kept.joined(separator: "\n")
    }

    private func reload() async {
        guard hasLiveTerminal else { return }
        let fetched = await client.fetchTerminals(sessionId: session.id)
        panes = fetched
        if let selectedPaneId, !fetched.contains(where: { !$0.isPrimary && $0.paneId == selectedPaneId }) {
            self.selectedPaneId = nil
        }
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
        // not the direct PTY instance id. Send the ref UUID; local
        // panes/selectedPaneId still key off pane.paneId because that is what
        // the WS envelope expects.
        await client.deleteTerminal(sessionId: session.id, terminalRefId: pane.id)
        panes.removeAll { $0.paneId == pane.paneId }
        if selectedPaneId == pane.paneId {
            selectedPaneId = nil
        }
    }
}
