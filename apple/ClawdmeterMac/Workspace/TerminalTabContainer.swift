import SwiftUI
import AppKit
import ClawdmeterShared

struct TerminalTabContainer: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    let wsPort: Int
    let token: String

    /// nil = primary pane. Non-nil = a TerminalPaneRef.id from session.terminalPanes.
    @State private var selectedSecondaryId: UUID? = nil
    @State private var sawOutput = false
    @State private var connectionState: TerminalConnectionState = .connecting

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            TahoeHairline()
            terminal
        }
        .background(t.surfaceSolid)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.terminal.surface")
        .onChange(of: session.terminalPanes) { _, _ in
            if selectedSecondaryPane == nil {
                selectedSecondaryId = nil
            }
        }
        .onChange(of: selectedSecondaryId) { _, _ in
            sawOutput = false
            connectionState = .connecting
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            tabButton(id: nil, title: primaryTabTitle, isPrimary: true)
            ForEach(secondaryPanes) { ref in
                tabButton(id: ref.id, title: ref.title, isPrimary: ref.isPrimary, paneRef: ref)
            }
            Button(action: ContinuumAnalytics.wrapButton(
                    "terminal_add_pane",
                    {
                Task {
                    if let pane = await model.addTerminalPane(sessionId: session.id) {
                        selectedSecondaryId = pane.id
                    }
                }
            
                    }
                )) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(t.fg3)
                    .background(t.surfaceSolid2.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(PressableButtonStyle())
            .help("New terminal pane")
            .accessibilityIdentifier("code.terminal.new-pane")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(t.surfaceSolid2.opacity(0.45))
    }

    private var primaryTabTitle: String {
        "\(session.agent.rawValue.capitalized)"
    }

    private func tabButton(
        id: UUID?,
        title: String,
        isPrimary: Bool,
        paneRef: TerminalPaneRef? = nil
    ) -> some View {
        let isSelected = isPrimary ? selectedSecondaryPane == nil : (id == selectedSecondaryId)
        return HStack(spacing: 4) {
            Button(action: ContinuumAnalytics.wrapButton(
                    "terminal_tab_select",
                    {
 selectedSecondaryId = id 
                    }
                )) {
                HStack(spacing: 4) {
                    Image(systemName: isPrimary ? "sparkle" : "terminal")
                        .font(.system(size: 9))
                    Text(title)
                        .font(TahoeFont.body(11, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? t.fg : t.fg3)
                .background(
                    isSelected
                        ? t.accentAlpha(t.dark ? 0.18 : 0.12)
                        : t.surfaceSolid2.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? t.accentAlpha(0.45) : t.hairline, lineWidth: 0.5)
                )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier(isPrimary ? "code.terminal.tab.primary" : "code.terminal.tab.secondary")
            if let paneRef, !paneRef.isPrimary {
                Button(action: ContinuumAnalytics.wrapButton(
                        "terminal_tab_close",
                        {
                    Task {
                        await model.closeTerminalPane(sessionId: session.id, paneRef: paneRef)
                        if selectedSecondaryId == paneRef.id {
                            selectedSecondaryId = nil
                        }
                    }
                
                        }
                    )) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(t.fg4)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Close pane")
                .accessibilityIdentifier("code.terminal.tab.close")
            }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        let targetPaneId = selectedSecondaryPane?.paneId
        // SwiftUI re-creates the view (and the WS connection) when the .id()
        // changes. Switching tabs hangs up the previous WS and opens one for
        // the selected terminal instance.
        ZStack {
            Color.black
            MacTerminalView(
                sessionId: session.id,
                host: "127.0.0.1",
                wsPort: wsPort,
                token: token,
                paneId: targetPaneId,
                onFirstOutput: { sawOutput = true },
                onConnectionStateChange: { connectionState = $0 }
            )
            .id(targetPaneId ?? "primary-\(session.id.uuidString)")
            if !sawOutput || connectionState.isAttentionState {
                terminalPendingOverlay
            }
        }
        .overlay(alignment: .topLeading) {
            // The visible "Terminal connected · <pane> · in <cwd>" strip was
            // removed per user feedback (no real value). Only the 1pt invisible
            // marker remains so automation can still observe connection state.
            terminalStatusAccessibilityMarker
        }
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
            .accessibilityIdentifier("code.terminal.status.state")
    }

    private var activePaneTitle: String {
        guard let pane = selectedSecondaryPane else { return primaryTabTitle }
        return pane.title
    }

    private var secondaryPanes: [TerminalPaneRef] {
        session.terminalPanes.filter { !$0.isPrimary }
    }

    private var selectedSecondaryPane: TerminalPaneRef? {
        guard let selectedSecondaryId else { return nil }
        return secondaryPanes.first { $0.id == selectedSecondaryId }
    }

    private var terminalCwdLabel: String {
        let last = (session.effectiveCwd as NSString).lastPathComponent
        return last.isEmpty ? session.repoDisplayName : last
    }
}
