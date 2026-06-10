import SwiftUI
import AppKit
import ClawdmeterShared

struct WorkspaceTerminalPane: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    let terminalTab: WorkspaceTerminalTab
    let wsPort: Int
    let token: String

    @State private var sawOutput = false
    @State private var connectionState: TerminalConnectionState = .connecting

    var body: some View {
        ZStack {
            Color.black
            if terminalTab.isPendingDirectShell && terminalTab.paneRefId == nil {
                terminalPendingOverlay
                    .accessibilityIdentifier("code.workspace.terminal.pending")
            } else if terminalTab.paneRefId == nil || paneId != nil {
                MacTerminalView(
                    sessionId: session.id,
                    host: "127.0.0.1",
                    wsPort: wsPort,
                    token: token,
                    paneId: paneId,
                    onFirstOutput: { sawOutput = true },
                    onConnectionStateChange: { connectionState = $0 }
                )
                .id(paneId ?? "primary-\(session.id.uuidString)")
                if !sawOutput || connectionState.isAttentionState {
                    terminalPendingOverlay
                }
            } else {
                ContentUnavailableView(
                    "Terminal pane unavailable",
                    systemImage: "terminal",
                    description: Text("This pane no longer exists on the Mac.")
                )
                .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            // Visible "Terminal connected · <pane> · in <cwd>" strip removed per
            // user feedback; the 1pt invisible marker stays for automation.
            terminalStatusAccessibilityMarker
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.workspace.terminal.surface")
        .onChange(of: terminalTab.id) { _, _ in
            sawOutput = false
            connectionState = .connecting
        }
        .onChange(of: paneId ?? "primary-\(session.id.uuidString)") { _, _ in
            sawOutput = false
            connectionState = .connecting
        }
    }

    private var paneId: String? {
        guard let paneRefId = terminalTab.paneRefId,
              let pane = session.terminalPanes.first(where: { $0.id == paneRefId })
        else { return nil }
        return pane.paneId
    }

    private var activePaneTitle: String {
        if let pendingTitle = terminalTab.pendingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pendingTitle.isEmpty {
            return pendingTitle
        }
        guard let paneRefId = terminalTab.paneRefId,
              let pane = session.terminalPanes.first(where: { $0.id == paneRefId })
        else { return "\(session.agent.rawValue.capitalized)" }
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Terminal" : title
    }

    private var terminalCwdLabel: String {
        let last = (session.effectiveCwd as NSString).lastPathComponent
        return last.isEmpty ? session.repoDisplayName : last
    }

    private var terminalPendingOverlay: some View {
        TahoeGlass(radius: 6, tone: .raised, shadow: .subtle) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(t.accentAlpha(t.dark ? 0.20 : 0.12))
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .frame(width: 44, height: 44)

                VStack(spacing: 4) {
                    Text(connectionState.pendingTitle)
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Opening \(activePaneTitle) in \(terminalCwdLabel).")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(t.accent)
                    Text(connectionState.pendingStatusText)
                        .font(TahoeFont.body(10.5, weight: .medium))
                        .foregroundStyle(t.fg3)
                }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private var terminalStatusAccessibilityMarker: some View {
        Text(connectionState.statusText(hasVisibleOutput: sawOutput))
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .accessibilityIdentifier("code.workspace.terminal.status.state")
    }
}
