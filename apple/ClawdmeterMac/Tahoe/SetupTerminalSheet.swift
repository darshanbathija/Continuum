import SwiftUI
import ClawdmeterShared

/// One embedded setup-terminal run (a login / install command hosted in
/// a `TerminalPtyHost`). Shared between first-run onboarding and
/// Settings → Providers → Add account.
struct SetupTerminalSession: Identifiable {
    let id: String
    let title: String
    let host: TerminalPtyHost
}

/// Sheet chrome around `DirectPtyTerminalView` for setup commands
/// (`codex login`, `claude setup-token`, CLI installs). Extracted from
/// the onboarding sheet so the multi-account add-account flow reuses
/// the identical surface.
///
/// `killOnDisappear: false` lets a caller that observes the host's
/// output (token capture) own the kill instead — closing the sheet
/// early must not tear the PTY out from under the observer's final
/// reads.
struct SetupTerminalSheet: View {
    @Environment(\.tahoe) private var t
    let terminal: SetupTerminalSession
    var killOnDisappear: Bool = true
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TahoeIcon("terminal", size: 14, weight: .bold)
                    .foregroundStyle(t.accent)
                Text(terminal.title)
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer(minLength: 0)
                Button("Done", action: onClose)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            TahoeHair()
            DirectPtyTerminalView(host: terminal.host)
                .frame(minWidth: 640, minHeight: 360)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onDisappear {
            if killOnDisappear {
                Task { await terminal.host.kill() }
            }
        }
    }
}
