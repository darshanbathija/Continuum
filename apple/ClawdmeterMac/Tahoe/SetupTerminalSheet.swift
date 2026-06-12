import SwiftUI
import ClawdmeterShared

/// One embedded setup-terminal run (a login / install command hosted in
/// a `TerminalPtyHost`). Shared between first-run onboarding and
/// Settings → Providers → Add account.
struct SetupTerminalSession: Identifiable {
    let id: String
    let title: String
    let host: TerminalPtyHost

    /// Single launcher for every embedded setup-terminal command (CLI
    /// installs + logins). Onboarding, Settings → Providers, and the
    /// spawn-mode config sheet all wrap commands identically — the
    /// "Press Done" suffix and session construction live here so the
    /// call sites can't drift. Throws when the PTY can't spawn; callers
    /// decide the fallback (AppleScript Terminal vs inline error).
    @MainActor
    static func launch(
        title: String,
        command: String,
        cwd: String = ClawdmeterRealHome.path()
    ) async throws -> SetupTerminalSession {
        let wrapped = "\(command); echo ''; echo 'Press Done when finished.'"
        let host = try await TerminalPtyRegistry.shared.spawnCommand(
            wrapped,
            cwd: cwd,
            title: title
        )
        return SetupTerminalSession(id: host.id.uuidString, title: title, host: host)
    }
}

/// Sheet chrome around `DirectPtyTerminalView` for setup commands
/// (`codex login`, CLI installs). Extracted from the onboarding sheet
/// (PR #301) into its own file; onboarding is the only consumer today —
/// the multi-account add-account flow embeds `DirectPtyTerminalView` in
/// its own stepped sheet because it also hosts the paste-token fallback
/// and completion state.
struct SetupTerminalSheet: View {
    @Environment(\.tahoe) private var t
    let terminal: SetupTerminalSession
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
                Button("Done", action: ContinuumAnalytics.wrapButton("setup_terminal_done", onClose))
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
            Task { await terminal.host.kill() }
        }
    }
}
