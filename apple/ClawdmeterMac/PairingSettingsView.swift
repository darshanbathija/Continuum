import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// Mac Settings pane for the Sessions feature. Shows the pairing QR
/// (host + ports + token), supervisor health, scan-roots editor, and
/// explicit regenerate/revoke buttons for the bearer token.
///
/// Per Codex Round 1 reviewer concern #6 (lost-phone story): regenerate
/// invalidates the iPhone's stored token. Revoke removes the token
/// entirely; the daemon refuses every connection until next launch
/// auto-generates a fresh one.
///
/// Layout note: this view uses `Form { Section { } header: { } }` like
/// the General preferences tab so the rendering matches macOS Settings
/// chrome. The previous implementation used raw `VStack`s inside a
/// `ScrollView` which gave inconsistent rendering — section headers,
/// labels, and descriptions were technically present but rendered in
/// system-default styling that blended into the Settings background.
struct PairingSettingsView: View {

    @ObservedObject var runtime: AppRuntime
    @AppStorage(RepoIndex.scanRootsKey) private var scanRoots: String = ""
    @State private var qrImage: NSImage?
    @State private var tokenForDisplay: String = ""
    @State private var didCopy: Bool = false

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    var body: some View {
        Form {
            pairSection
            scanRootsSection
            supervisorSection
            securitySection
            pluginsSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .onAppear { refreshQR() }
    }

    // MARK: - Sections

    private var pairSection: some View {
        Section {
            if let httpPort = runtime.agentControlServer.boundPort,
               let wsPort = runtime.agentControlServer.boundWsPort {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Host") {
                            Text(macHost())
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("HTTP port") {
                            Text("\(httpPort)")
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("WS port") {
                            Text("\(wsPort)")
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("Token") {
                            Text(String(tokenForDisplay.prefix(8)) + "…")
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 8) {
                            Button("Copy pairing URL", action: copyPairingURL)
                            if didCopy {
                                Text("Copied ✓")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    qrTile
                }
            } else {
                Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Pair iPhone")
        } footer: {
            Text("Scan the QR with Clawdmeter on your iPhone, or paste the URL after tapping **Copy pairing URL**.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var qrTile: some View {
        Group {
            if let qr = qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 140, height: 140)
                    .overlay(
                        ProgressView().controlSize(.small)
                    )
            }
        }
        .padding(8)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var scanRootsSection: some View {
        Section {
            TextField(
                "e.g. ~/Downloads, ~/code",
                text: $scanRoots,
                axis: .vertical
            )
            .lineLimit(1...3)
            .onChange(of: scanRoots) { _, newValue in
                let roots = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                UserDefaults.standard.set(roots, forKey: RepoIndex.scanRootsKey)
                Task { await runtime.repoIndex.refresh() }
            }
        } header: {
            Text("Scan roots")
        } footer: {
            Text("Comma-separated directories to scan for `.git` repos beyond `~/.claude/projects/` and `~/.codex/sessions/`. Empty by default; common picks: `~/Downloads`, `~/Desktop`, `~/code`.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var supervisorSection: some View {
        Section {
            LabeledContent("Status") {
                if runtime.tmuxSupervisor.isRecoveryBlocked {
                    HStack(spacing: 8) {
                        Label("Unrecoverable", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Recover") {
                            Task { await runtime.tmuxSupervisor.userInitiatedRecovery() }
                        }
                        .controlSize(.small)
                    }
                } else {
                    Label("tmux server is healthy", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            LabeledContent("Restart count") {
                Text("\(runtime.tmuxSupervisor.restartCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Supervisor")
        }
    }

    private var securitySection: some View {
        Section {
            HStack(spacing: 12) {
                Button("Regenerate token") {
                    _ = PairingTokenStore.shared.regenerate()
                    refreshQR()
                }
                Button("Revoke token", role: .destructive) {
                    PairingTokenStore.shared.revoke()
                    refreshQR()
                }
                Spacer()
            }
        } header: {
            Text("Security")
        } footer: {
            Text("Regenerating the token invalidates every paired device — you'll need to scan the QR again on each iPhone. Revoking removes the token entirely; the daemon refuses every connection until you relaunch Clawdmeter.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var pluginsSection: some View {
        Section {
            let plugins = PluginRegistry.discover()
            if plugins.isEmpty {
                Text("No MCP servers or plugins detected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugins) { plugin in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: plugin.kind))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(plugin.name)
                            .font(.system(size: 12, design: .monospaced))
                        Text(label(for: plugin.kind))
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(plugin.source)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } header: {
            Text("Plugins")
        } footer: {
            Text("Read-only inventory of MCP servers and plugins from `~/.codex/config.toml` and `~/.claude/settings.json`. Enable or disable from the CLI configs.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func icon(for kind: PluginInfo.Kind) -> String {
        switch kind {
        case .codexMCP, .claudeMCP: return "plug"
        case .claudePlugin: return "puzzlepiece.extension"
        }
    }

    private func label(for kind: PluginInfo.Kind) -> String {
        switch kind {
        case .codexMCP: return "Codex MCP"
        case .claudeMCP: return "Claude MCP"
        case .claudePlugin: return "Claude plugin"
        }
    }

    // MARK: - Actions

    private func copyPairingURL() {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort else { return }
        let url = "clawdmeter://\(macHost()):\(httpPort)?token=\(tokenForDisplay)&ws=\(wsPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            didCopy = false
        }
    }

    // MARK: - Helpers

    private func refreshQR() {
        tokenForDisplay = PairingTokenStore.shared.currentToken()
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort
        else {
            qrImage = nil
            return
        }
        let challenge = PairingChallenge(
            host: macHost(),
            port: Int(httpPort),
            wsPort: Int(wsPort),
            token: tokenForDisplay
        )
        let urlString = "clawdmeter://\(challenge.host):\(challenge.port)?token=\(challenge.token)&ws=\(challenge.wsPort)"
        qrImage = generateQR(from: urlString)
    }

    /// Best-effort: read the Tailscale MagicDNS name from `tailscale status`.
    /// Falls back to `127.0.0.1` (works from iOS Simulator on the same Mac;
    /// real iPhones reach the Mac via the MagicDNS name over Tailscale).
    private func macHost() -> String {
        if let result = try? Process.runAndCapture(
            "/opt/homebrew/bin/tailscale", ["status", "--json"]
        ),
           let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
           let selfNode = json["Self"] as? [String: Any],
           let dnsName = selfNode["DNSName"] as? String,
           !dnsName.isEmpty {
            return dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return "127.0.0.1"
    }

    private func generateQR(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        // Scale up so the QR is crisp at the rendered size.
        let scaleFactor: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 140, height: 140))
    }
}

/// Process helper for the host-name lookup. Throwing variant that returns
/// stdout Data.
private extension Process {
    static func runAndCapture(_ executable: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}
