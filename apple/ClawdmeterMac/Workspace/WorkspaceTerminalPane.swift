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

    var body: some View {
        ZStack {
            Color.black
            if terminalTab.paneRefId == nil || paneId != nil {
                MacTerminalView(
                    sessionId: session.id,
                    host: "127.0.0.1",
                    wsPort: wsPort,
                    token: token,
                    paneId: paneId,
                    onFirstOutput: { sawOutput = true }
                )
                // Include the session's primary pane id so a revive (which
                // respawns into a NEW pane and updates tmuxPaneId) changes the
                // view identity → SwiftUI tears down the dead-pane WS and opens
                // a fresh subscription to the live pane.
                .id(paneId ?? session.tmuxPaneId ?? "primary")
                if !sawOutput {
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
            terminalStatusBadge
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: terminalTab.id) { _, _ in
            sawOutput = false
        }
        // A revive respawns into a NEW pane (session.tmuxPaneId changes) and
        // recreates MacTerminalView via .id; reset sawOutput so the "starting"
        // overlay tracks the fresh reconnect instead of lying from the dead pane.
        .onChange(of: paneId ?? session.tmuxPaneId ?? "primary") { _, _ in
            sawOutput = false
        }
    }

    private var paneId: String? {
        guard let paneRefId = terminalTab.paneRefId,
              let pane = session.terminalPanes.first(where: { $0.id == paneRefId })
        else { return nil }
        return pane.paneId
    }

    private var activePaneTitle: String {
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
                    Text("Connecting to terminal")
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
                    Text("Waiting for visible shell output")
                        .font(TahoeFont.body(10.5, weight: .medium))
                        .foregroundStyle(t.fg3)
                }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private var terminalStatusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sawOutput ? Color.green.opacity(0.85) : t.accent)
                .frame(width: 7, height: 7)
            Text(sawOutput ? "Terminal connected" : "Terminal starting")
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(t.fg)
            TahoeHair(vertical: true).frame(height: 12)
            Text(activePaneTitle)
                .font(TahoeFont.mono(10.5, weight: .semibold))
                .foregroundStyle(t.fg2)
                .lineLimit(1)
            Text("in \(terminalCwdLabel)")
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(t.surfaceSolid2.opacity(0.94), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.75)
        )
        .padding(10)
        .help("\(activePaneTitle)\n\(session.effectiveCwd)")
    }
}
