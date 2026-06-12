import SwiftUI
import AppKit
import ClawdmeterShared
import OSLog

private let sheetLogger = Logger(subsystem: "com.clawdmeter.mac", category: "OpencodeSetupSheet")

/// Embedded interactive terminal sheet for OpenCode setup flows.
///
/// Hosts an `opencode auth login` / `auth logout` / diagnostic
/// session inside the Mac app — user never drops to a Terminal.
/// Uses `DirectPtyTerminalView` to pipe SwiftTerm I/O directly to a
/// per-sheet PTY host.
///
/// Lifecycle (on present):
///   1. Resolve `OpencodeProcessManager.shared.binaryPath` (preflight).
///   2. Create a per-sheet exit-sentinel tempfile.
///   3. Spawn a direct PTY running
///      `bash -c '<opencode> <args>; echo $? > <sentinel>'`.
///   4. Read the sentinel → publish `exitCode`.
///   5. `await OpencodeProcessManager.shared.reprobe()` to trigger
///      O5 serve-restart-on-auth-change if needed.
///
/// Dismiss is BLOCKED while an OAuth URL is in-flight (A4): we scan
/// the visible terminal buffer for `https://...?code=` or "paste this
/// URL" tokens. Done button becomes "Waiting for OAuth…" disabled,
/// explicit Cancel button kills the pane.
public struct OpencodeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    public enum Command: Identifiable, Equatable {
        case signIn
        case addProvider
        case loginProvider(String)
        case signOut
        case diagnostic

        public var id: String {
            switch self {
            case .signIn: return "signIn"
            case .addProvider: return "addProvider"
            case .loginProvider(let providerID): return "loginProvider:\(providerID)"
            case .signOut: return "signOut"
            case .diagnostic: return "diagnostic"
            }
        }

        var title: String {
            switch self {
            case .signIn: return "Sign in to OpenCode"
            case .addProvider: return "Add OpenCode provider"
            case .loginProvider(let providerID):
                return "Sign in to \(OpencodeAuthFile.defaultDisplayName(for: providerID))"
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
            case .loginProvider(let providerID):
                let escaped = providerID.replacingOccurrences(of: "'", with: "'\\''")
                return "\(quoted(binary)) auth login --provider '\(escaped)'"
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

    let command: Command
    var onCompletion: () -> Void = {}

    @State private var host: TerminalPtyHost?
    @State private var exitFile: URL?
    @State private var exitCode: Int32?
    @State private var preflightError: String?
    @State private var oauthInFlight: Bool = false
    @State private var lifecycleTask: Task<Void, Never>?

    public init(
        command: Command,
        onCompletion: @escaping () -> Void = {}
    ) {
        self.command = command
        self.onCompletion = onCompletion
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let preflightError {
                preflightFailure(preflightError)
            } else if let host {
                DirectPtyTerminalView(host: host)
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
            if let host {
                Task { await host.kill() }
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
            } else if host != nil {
                ProgressView()
                    .controlSize(.small)
                Text("Running…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if oauthInFlight {
                Button("Cancel") {
                    if let host {
                        Task { await host.kill() }
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
        // Sentinel file for O2 child-exit detection.
        let sentinel = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-opencode-\(UUID().uuidString).exit")
        exitFile = sentinel

        let escapedSentinel = sentinel.path
            .replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "\(command.shellTail(binary: binary)); echo $? > '\(escapedSentinel)'"

        do {
            let spawned = try await TerminalPtyRegistry.shared.spawnCommand(
                shellCommand,
                cwd: NSHomeDirectory(),
                title: command.title
            )
            host = spawned
        } catch {
            preflightError = "Couldn't spawn opencode setup terminal: \(error.localizedDescription)"
            return
        }
        sheetLogger.info("opencode setup terminal cmd=\(command.id, privacy: .public)")

        lifecycleTask = Task { [sentinel] in
            await runLifecycle(sentinel: sentinel)
        }
    }

    @MainActor
    private func runLifecycle(sentinel: URL) async {
        let pollInterval: UInt64 = 500_000_000  // 500ms
        var sawOAuthMarker = false

        while !Task.isCancelled {
            if let data = try? Data(contentsOf: sentinel),
               let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let code = Int32(s) {
                exitCode = code
                if exitCode == 0 {
                    onCompletion()
                    NotificationCenter.default.post(name: .opencodeAuthChanged, object: nil)
                }
                // Refresh provider manager state — triggers O5.
                await OpencodeProcessManager.shared.reprobe()
                oauthInFlight = false
                break
            }

            // OAuth-URL detection — scan the PTY output ring.
            if !sawOAuthMarker, await scrollbackContainsOAuthURL() {
                sawOAuthMarker = true
                oauthInFlight = true
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func scrollbackContainsOAuthURL() async -> Bool {
        guard let host else { return false }
        let buffer = String(decoding: await host.snapshot(), as: UTF8.self)
        if buffer.range(of: #"https://[^\s]+\?[^\s]*code="#, options: .regularExpression) != nil { return true }
        if buffer.range(of: "paste this URL", options: .caseInsensitive) != nil { return true }
        if buffer.range(of: "open this URL", options: .caseInsensitive) != nil { return true }
        return false
    }

    private func cleanupSentinel() {
        if let exitFile {
            try? FileManager.default.removeItem(at: exitFile)
        }
    }
}

extension Notification.Name {
    static let opencodeAuthChanged = Notification.Name("clawdmeter.opencodeAuth.changed")
}
