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
    @State private var resolvedHost: TailscaleHost.Resolved = TailscaleHost.Resolved(host: "127.0.0.1", kind: .loopback)
    // Loaded once on appear — PluginRegistry.discover() is a disk scan and must
    // not run inside the Form body (it re-ran on every settings re-render).
    @State private var plugins: [PluginInfo] = []

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    @AppStorage("clawdmeter.pairing.preferMagicDNS") private var preferMagicDNS: Bool = true
    @AppStorage("clawdmeter.pairing.preferTLS") private var preferTLS: Bool = false

    var body: some View {
        Form {
            pairSection
            connectivitySection
            scanRootsSection
            supervisorSection
            securitySection
            pluginsSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .onAppear {
            refreshQR()
            plugins = PluginRegistry.discover()
        }
    }

    private func isMagicDNSHost(_ kind: TailscaleHost.Resolved.Kind) -> Bool {
        // TailscaleHost.Resolved.Kind has an associated value on
        // `.tailscaleDNSBackendDown(state:)` — Equatable isn't
        // synthesized. Pattern-match directly.
        if case .tailscaleDNS = kind { return true }
        return false
    }

    private var connectivitySection: some View {
        Section {
            Toggle("Prefer MagicDNS host in pairing QR", isOn: $preferMagicDNS)
                .onChange(of: preferMagicDNS) { _, _ in refreshQR() }
            Toggle("Use TLS for pairing (advanced)", isOn: $preferTLS)
                .onChange(of: preferTLS) { _, _ in refreshQR() }
                .disabled(!preferMagicDNS || !isMagicDNSHost(resolvedHost.kind))
        } header: {
            Text("Connectivity")
        } footer: {
            Text("MagicDNS uses the Tailscale-issued `*.ts.net` hostname so pairing survives IP changes (sleep/wake, switching Wi-Fi). TLS pairing wraps the pairing URL in `clawdmeters://` for future server-side TLS — requires `tailscale cert` and a Running MagicDNS backend. The daemon itself still listens on plain HTTP today; this toggle ships the URL plumbing so iOS is ready when server TLS lands.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sections

    private var pairSection: some View {
        Section {
            if let httpPort = runtime.agentControlServer.boundPort,
               let wsPort = runtime.agentControlServer.boundWsPort {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Host") {
                            Text(resolvedHost.host)
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
                        hostReachabilityNote
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    qrTile
                }
            } else {
                Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Pair with iPhone")
        } footer: {
            Text("Scan the QR with Clawdmeter on your iPhone, or paste the URL after tapping **Copy pairing URL**.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var hostReachabilityNote: some View {
        switch resolvedHost.kind {
        case .loopback:
            warningRow("No Tailscale address detected. Pairing only works for the iOS simulator on this Mac. Install Tailscale and sign in to pair a real iPhone.")
        case .tailscaleDNSBackendDown(let state):
            warningRow("Tailscale is installed but not running (\(state)). Open the Tailscale menu bar and turn the tunnel on — the iPhone can't reach this Mac until it's up.")
        case .tailscaleIPv4, .tailscaleIPv6, .tailscaleDNS:
            EmptyView()
        }
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
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
            // Inventory comes from the `plugins` @State loaded in onAppear —
            // calling PluginRegistry.discover() here ran a disk scan per render.
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
        // v0.27.0: Design routing fields (`&dp=` and `&dt=`) dropped from
        // the pairing URL along with the Design tab + DesignPortForwarder.
        let url = "clawdmeter://\(resolvedHost.host):\(httpPort)?token=\(tokenForDisplay)&ws=\(wsPort)"
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
        resolvedHost = TailscaleHost.resolve()
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort
        else {
            qrImage = nil
            return
        }
        // v0.27.0: Design routing fields dropped from the pairing URL.
        let urlString = "clawdmeter://\(resolvedHost.host):\(httpPort)?token=\(tokenForDisplay)&ws=\(wsPort)"
        qrImage = generateQR(from: urlString)
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
