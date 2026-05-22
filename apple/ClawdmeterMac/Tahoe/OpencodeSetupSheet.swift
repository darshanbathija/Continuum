import SwiftUI
import AppKit
import ClawdmeterShared
import OSLog

private let sheetLogger = Logger(subsystem: "com.clawdmeter.mac", category: "OpencodeSetupSheet")

/// Embedded interactive terminal sheet for OpenCode setup flows.
///
/// Hosts an `opencode auth login` / `auth logout` / diagnostic
/// session inside the Mac app — user never drops to a Terminal.
/// Uses `MacInProcessTerminalView` to pipe SwiftTerm I/O directly
/// to `TmuxControlClient`, with ESC-safe key routing per O3.
///
/// Lifecycle (on present):
///   1. Resolve `OpencodeProcessManager.shared.binaryPath` (preflight).
///   2. `await tmuxClient.start()` (idempotent).
///   3. Create a per-sheet exit-sentinel tempfile.
///   4. Spawn a tmux pane running
///      `bash -c '<opencode> <args>; echo $? > <sentinel>'`. The
///      sentinel carries the child exit code back (O2 — TmuxControlClient
///      windowClosed carries only the windowId, no exit status).
///   5. Wait on tmux lifecycle for `.windowClosed(windowId)` matching
///      the pane's window.
///   6. Read the sentinel → publish `exitCode`.
///   7. `await OpencodeProcessManager.shared.reprobe()` to trigger
///      O5 serve-restart-on-auth-change if needed.
///
/// Dismiss is BLOCKED while an OAuth URL is in-flight (A4): we scan
/// the visible pane buffer for `https://...?code=` or "paste this
/// URL" tokens. Done button becomes "Waiting for OAuth…" disabled,
/// explicit Cancel button kills the pane.
public struct OpencodeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    public enum Command: Identifiable, Equatable {
        case signIn
        case addProvider
        case signOut
        case diagnostic

        public var id: String {
            switch self {
            case .signIn: return "signIn"
            case .addProvider: return "addProvider"
            case .signOut: return "signOut"
            case .diagnostic: return "diagnostic"
            }
        }

        var title: String {
            switch self {
            case .signIn: return "Sign in to OpenCode"
            case .addProvider: return "Add OpenCode provider"
            case .signOut: return "Sign out of OpenCode"
            case .diagnostic: return "OpenCode diagnostic"
            }
        }

        /// Shell command suffix appended to the bundled opencode binary
        /// path. Composed with the sentinel-exit wrapper at runtime.
        func shellTail(binary: String) -> String {
            switch self {
            case .signIn, .addProvider:
                return "\(quoted(binary)) auth login"
            case .signOut:
                // O6: opencode auth logout takes no --provider arg,
                // signs out of all.
                return "\(quoted(binary)) auth logout || true"
            case .diagnostic:
                return "\(quoted(binary)) --version && echo '' && \(quoted(binary)) auth list"
            }
        }

        private func quoted(_ s: String) -> String {
            // Minimal shell-quoting for paths with spaces — wrap in
            // single quotes, escape inner single quotes.
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    let tmuxClient: TmuxControlClient
    let command: Command
    var onCompletion: () -> Void = {}

    @State private var paneId: String?
    @State private var exitFile: URL?
    @State private var exitCode: Int32?
    @State private var preflightError: String?
    @State private var oauthInFlight: Bool = false
    @State private var lifecycleTask: Task<Void, Never>?

    public init(
        tmuxClient: TmuxControlClient,
        command: Command,
        onCompletion: @escaping () -> Void = {}
    ) {
        self.tmuxClient = tmuxClient
        self.command = command
        self.onCompletion = onCompletion
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let preflightError {
                preflightFailure(preflightError)
            } else if let paneId {
                MacInProcessTerminalView(tmuxClient: tmuxClient, paneId: paneId)
                    .frame(minWidth: 720, minHeight: 480)
            } else {
                ProgressView("Starting…")
                    .frame(minWidth: 720, minHeight: 480)
            }

            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            await present()
        }
        .onDisappear {
            lifecycleTask?.cancel()
            if let paneId {
                let pid = paneId
                let client = tmuxClient
                Task { try? await client.killPane(pid) }
            }
            cleanupSentinel()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .semibold))
            Text(command.title)
                .font(.headline)
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(oauthInFlight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func preflightFailure(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't start setup")
                .font(.headline)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if oauthInFlight {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for OAuth — complete it in your browser")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let code = exitCode {
                Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(code == 0 ? .green : .red)
                Text(code == 0
                     ? "Done — exit 0"
                     : "Exited with code \(code)")
                    .font(.footnote)
                    .foregroundStyle(code == 0 ? Color.primary : Color.red)
            } else if paneId != nil {
                ProgressView()
                    .controlSize(.small)
                Text("Running…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if oauthInFlight {
                Button("Cancel") {
                    if let paneId {
                        let pid = paneId
                        let client = tmuxClient
                        Task { try? await client.killPane(pid) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Lifecycle

    @MainActor
    private func present() async {
        // Preflight 1: binary
        guard let binary = OpencodeProcessManager.shared.binaryPath ?? OpencodeProcessManager.shared.locateBinary() else {
            preflightError = "OpenCode binary not found. Reinstall the app or install opencode via brew."
            return
        }
        // Preflight 2: tmux up
        do {
            try await tmuxClient.start()
        } catch {
            preflightError = "Couldn't start tmux: \(error.localizedDescription)"
            return
        }

        // Sentinel file for O2 child-exit detection.
        let sentinel = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-opencode-\(UUID().uuidString).exit")
        exitFile = sentinel

        let escapedSentinel = sentinel.path
            .replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "\(command.shellTail(binary: binary)); echo $? > '\(escapedSentinel)'"

        // Spawn the pane.
        let window: TmuxControlClient.WindowRef
        do {
            window = try await tmuxClient.newWindow(
                cwd: NSHomeDirectory(),
                child: ["/bin/bash", "-c", shellCommand]
            )
        } catch {
            preflightError = "Couldn't spawn opencode pane: \(error.localizedDescription)"
            return
        }
        paneId = window.paneId
        sheetLogger.info("opencode setup pane=\(window.paneId, privacy: .public) cmd=\(command.id, privacy: .public)")

        // Listen for window-closed + scan for OAuth-URL token.
        lifecycleTask = Task { [windowId = window.windowId, sentinel] in
            await runLifecycle(windowId: windowId, sentinel: sentinel)
        }
    }

    @MainActor
    private func runLifecycle(windowId: String, sentinel: URL) async {
        // Lifecycle subscription: poll for windowClosed AND poll
        // pane scrollback for OAuth URL emission. Both are weak signals
        // — the tmux lifecycle stream isn't typed exhaustively here,
        // so we use a polling fallback.
        let pollInterval: UInt64 = 500_000_000  // 500ms
        var sawOAuthMarker = false

        while !Task.isCancelled {
            // Detect window closed → child exited.
            if !(await isWindowAlive(windowId: windowId)) {
                // Read sentinel for exit code.
                if let data = try? Data(contentsOf: sentinel),
                   let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let code = Int32(s) {
                    exitCode = code
                } else {
                    exitCode = -1
                }
                if exitCode == 0 {
                    onCompletion()
                }
                // Refresh provider manager state — triggers O5.
                await OpencodeProcessManager.shared.reprobe()
                oauthInFlight = false
                break
            }

            // OAuth-URL detection — scan the pane scrollback.
            if !sawOAuthMarker, let paneId, await scrollbackContainsOAuthURL(paneId: paneId) {
                sawOAuthMarker = true
                oauthInFlight = true
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func isWindowAlive(windowId: String) async -> Bool {
        // Use TmuxControlClient.listWindows to check if our window
        // still exists. Cheap (~5-10ms tmux RPC).
        do {
            let windows = try await tmuxClient.listWindows()
            return windows.contains { $0.windowId == windowId }
        } catch {
            // RPC error — assume still alive to avoid premature exit.
            return true
        }
    }

    private func scrollbackContainsOAuthURL(paneId: String) async -> Bool {
        // tmux capture-pane to grab recent scrollback. Cheap.
        do {
            let result = try await tmuxClient.command(["capture-pane", "-p", "-t", paneId, "-S", "-200"])
            let buffer = result.lines.joined(separator: "\n")
            if buffer.range(of: #"https://[^\s]+\?[^\s]*code="#, options: .regularExpression) != nil { return true }
            if buffer.range(of: "paste this URL", options: .caseInsensitive) != nil { return true }
            if buffer.range(of: "open this URL", options: .caseInsensitive) != nil { return true }
            return false
        } catch {
            return false
        }
    }

    private func cleanupSentinel() {
        if let exitFile {
            try? FileManager.default.removeItem(at: exitFile)
        }
    }
}
