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

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            TahoeHairline()
            terminal
        }
        .background(t.surfaceSolid)
        .onChange(of: selectedSecondaryId) { _, _ in
            sawOutput = false
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            tabButton(id: nil, title: primaryTabTitle, isPrimary: true)
            ForEach(session.terminalPanes) { ref in
                tabButton(id: ref.id, title: ref.title, isPrimary: false, paneRef: ref)
            }
            Button(action: {
                Task {
                    if let _ = await model.addTerminalPane(sessionId: session.id) {
                        // Switch to the new tab — pick the last added.
                        if let last = model.registry.session(id: session.id)?.terminalPanes.last {
                            selectedSecondaryId = last.id
                        }
                    }
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(t.fg3)
                    .background(t.surfaceSolid2.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(PressableButtonStyle())
            .help("New terminal pane")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(t.surfaceSolid2.opacity(0.45))
    }

    private var primaryTabTitle: String {
        // Agent pane gets a nicer label than just the tmux id.
        "\(session.agent.rawValue.capitalized)"
    }

    private func tabButton(
        id: UUID?,
        title: String,
        isPrimary: Bool,
        paneRef: TerminalPaneRef? = nil
    ) -> some View {
        let isSelected = (id == selectedSecondaryId)
        return HStack(spacing: 4) {
            Button(action: { selectedSecondaryId = id }) {
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
            if let paneRef, !isPrimary {
                Button(action: {
                    Task {
                        await model.closeTerminalPane(sessionId: session.id, paneRef: paneRef)
                        if selectedSecondaryId == paneRef.id {
                            selectedSecondaryId = nil
                        }
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(t.fg4)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Close pane")
            }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        let targetPaneId: String? = {
            guard let sid = selectedSecondaryId,
                  let ref = session.terminalPanes.first(where: { $0.id == sid })
            else { return nil }
            return ref.paneId
        }()
        // SwiftUI re-creates the view (and the WS connection) when the
        // .id() changes. That's what we want: switching tabs hangs up the
        // previous WS and opens one for the new pane.
        ZStack {
            Color.black
            MacTerminalView(
                sessionId: session.id,
                host: "127.0.0.1",
                wsPort: wsPort,
                token: token,
                paneId: targetPaneId,
                onFirstOutput: { sawOutput = true }
            )
            .id(targetPaneId ?? "primary")
            if !sawOutput {
                terminalPendingOverlay
            }
        }
        .overlay(alignment: .topLeading) {
            terminalStatusBadge
        }
    }

    private var terminalPendingOverlay: some View {
        TahoeGlass(radius: 14, tone: .raised, shadow: .subtle) {
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
                    Text("Connecting to raw terminal")
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

    private var activePaneTitle: String {
        guard let selectedSecondaryId,
              let pane = session.terminalPanes.first(where: { $0.id == selectedSecondaryId })
        else { return primaryTabTitle }
        return pane.title
    }

    private var terminalCwdLabel: String {
        let last = (session.effectiveCwd as NSString).lastPathComponent
        return last.isEmpty ? session.repoDisplayName : last
    }
}
