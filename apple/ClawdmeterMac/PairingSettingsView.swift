import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// Mac Settings pane for the Sessions feature.
///
/// **E7 rewrite (Gate 3 GTM launch blocker).** The primary pairing flow
/// is now relay-based: Mac mints a session ID + bearer tokens + ECDH
/// public key, encodes them into a `clawdmeter-pair://v1/<base64url>`
/// URL, and renders a QR. The iPhone scans, derives the shared key
/// locally via HKDF-SHA256 (see `RelayPairingCrypto`), and persists.
///
/// E7 stops at "bundle generated + iPhone-side key derived". E3/E4 will
/// actually open the WebSocket against the relay Worker.
///
/// The old Tailscale-config-as-pairing-mechanism (host + ports + token
/// URL) is preserved behind a collapsed "Advanced: legacy Tailscale
/// pairing" disclosure so users who already paired on a Tailnet aren't
/// broken. The relay path is the default.
///
/// Layout note: this view uses `Form { Section { } header: { } }` so
/// it renders with native macOS Settings chrome.
struct PairingSettingsView: View {

    @ObservedObject var runtime: AppRuntime
    @ObservedObject var pairingService: RelayPairingService
    @AppStorage(RepoIndex.scanRootsKey) private var scanRoots: String = ""
    @State private var qrImage: NSImage?
    @State private var tokenForDisplay: String = ""
    @State private var didCopyRelay: Bool = false
    @State private var didCopyLegacy: Bool = false
    @State private var resolvedHost: TailscaleHost.Resolved = TailscaleHost.Resolved(host: "127.0.0.1", kind: .loopback)
    @State private var showLegacyTailscaleAdvanced: Bool = false
    /// Live ticker so the "expires in N:NN" label re-renders without a
    /// state change from the pairing service.
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(runtime: AppRuntime) {
        self.runtime = runtime
        self.pairingService = runtime.relayPairingService
    }

    @AppStorage("clawdmeter.pairing.preferMagicDNS") private var preferMagicDNS: Bool = true
    @AppStorage("clawdmeter.pairing.preferTLS") private var preferTLS: Bool = false

    var body: some View {
        Form {
            relayPairSection
            scanRootsSection
            supervisorSection
            relaySecuritySection
            legacyTailscaleSection
            pluginsSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .onAppear {
            tokenForDisplay = PairingTokenStore.shared.currentToken()
            resolvedHost = TailscaleHost.resolve()
            refreshRelayQR()
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: pairingService.bundleURL) { _, _ in refreshRelayQR() }
    }

    private func isMagicDNSHost(_ kind: TailscaleHost.Resolved.Kind) -> Bool {
        if case .tailscaleDNS = kind { return true }
        return false
    }

    // MARK: - Relay pair section (E7 primary)

    private var relayPairSection: some View {
        Section {
            switch pairingService.phase {
            case .unpaired:
                relayUnpairedRow
            case .generatingBundle:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating pairing bundle…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .scanning, .keyExchanged, .readyButNotConnected:
                relayBundleRow
            }
        } header: {
            Text("Pair with iPhone")
        } footer: {
            Text("Open Clawdmeter on your iPhone and scan the QR. The pairing bundle includes a relay session ID + per-peer bearer tokens + an X25519 public key — no Tailscale or LAN required. The bundle expires after 15 minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var relayUnpairedRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not yet paired")
                    .font(.headline)
                Text("Generate a one-time bundle the iPhone scans. Bundle includes a relay session ID, per-peer bearer tokens, and the Mac's X25519 public key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Pair iPhone") {
                pairingService.beginPairing()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var relayBundleRow: some View {
        if let bundle = pairingService.bundle, let urlString = pairingService.bundleURL {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Relay") {
                        Text(bundle.relayUrl)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Session ID") {
                        Text(String(bundle.sid.prefix(12)) + "…")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Mac key") {
                        Text(String(bundle.ecdhPub.prefix(12)) + "…")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Expires in") {
                        Text(formatTTLCountdown(ttl: bundle.ttl))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ttlColor(ttl: bundle.ttl))
                    }
                    HStack(spacing: 8) {
                        Button("Copy pairing URL", action: copyRelayURL)
                        if didCopyRelay {
                            Text("Copied ✓")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button("Regenerate", action: { pairingService.beginPairing() })
                    }
                    .padding(.top, 4)
                    if pairingService.phase == .readyButNotConnected {
                        Label("Waiting for iPhone scan", systemImage: "iphone.gen3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    // Hidden in production builds — only shows when a dev
                    // wants to copy the raw URL into the iOS simulator
                    // (clipboard sharing doesn't auto-flow QRs).
                    if ProcessInfo.processInfo.environment["CLAWDMETER_DEBUG_PAIRING"] != nil {
                        Text(urlString)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                relayQRTile
            }
        } else {
            EmptyView()
        }
    }

    private var relayQRTile: some View {
        // Match the pairing-popover spec from DESIGN.md: 280x280 outer
        // with halo + glass tile + 224 inner image. Settings + popover
        // share the same dimensions so users see one consistent surface.
        Group {
            if let qr = qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 224, height: 224)
                    .accessibilityLabel("Pairing QR code")
                    .accessibilityHint("Scan with your iPhone's camera to pair this Mac.")
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(width: 224, height: 224)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .padding(28)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .frame(width: 280, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [SessionsV2Theme.accent.opacity(0.30), .clear],
                        center: .center, startRadius: 0, endRadius: 200
                    )
                )
                .blur(radius: 10)
                .padding(-30)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Relay security section

    private var relaySecuritySection: some View {
        Section {
            HStack(spacing: 12) {
                Button("Forget pairing", role: .destructive) {
                    pairingService.reset()
                }
                .disabled(pairingService.phase == .unpaired)
                Spacer()
            }
        } header: {
            Text("Pairing security")
        } footer: {
            Text("Forget pairing wipes the in-memory keypair and bundle on this Mac. The iPhone keeps its derived key until it scans a fresh QR or the bundle TTL expires. Relaunching Clawdmeter also invalidates the bundle by design — keys are ephemeral per pairing.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Legacy Tailscale section (collapsed by default)

    private var legacyTailscaleSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showLegacyTailscaleAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    legacyTailscaleConnectivityToggles
                    Divider()
                    legacyTailscalePairRow
                    Divider()
                    HStack(spacing: 12) {
                        Button("Regenerate token") {
                            _ = PairingTokenStore.shared.regenerate()
                            tokenForDisplay = PairingTokenStore.shared.currentToken()
                        }
                        Button("Revoke token", role: .destructive) {
                            PairingTokenStore.shared.revoke()
                            tokenForDisplay = PairingTokenStore.shared.currentToken()
                        }
                        Spacer()
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    Text("Advanced: legacy Tailscale pairing")
                        .font(.callout)
                    Spacer()
                    Text("Fallback")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        } header: {
            Text("Legacy transport")
        } footer: {
            Text("Pre-E7 Tailscale-based pairing — bundles host + ports + bearer token into a `clawdmeter://` URL. Kept for users who explicitly want LAN-only / no-relay operation. The relay flow above is the recommended default and survives IP changes, NAT, and not having Tailscale installed at all.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var legacyTailscaleConnectivityToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Prefer MagicDNS host in legacy QR", isOn: $preferMagicDNS)
            Toggle("Use TLS for legacy pairing (advanced)", isOn: $preferTLS)
                .disabled(!preferMagicDNS || !isMagicDNSHost(resolvedHost.kind))
            Text("MagicDNS uses the Tailscale `*.ts.net` hostname so legacy pairing survives IP changes. TLS toggle wraps the URL in `clawdmeters://` for future server-side TLS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var legacyTailscalePairRow: some View {
        Group {
            if let httpPort = runtime.agentControlServer.boundPort,
               let wsPort = runtime.agentControlServer.boundWsPort {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Host") {
                        Text(resolvedHost.host)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("HTTP port") {
                        Text("\(httpPort)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    LabeledContent("WS port") {
                        Text("\(wsPort)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    LabeledContent("Token") {
                        Text(String(tokenForDisplay.prefix(8)) + "…")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Copy legacy URL", action: copyLegacyURL)
                        if didCopyLegacy {
                            Text("Copied ✓")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.top, 4)
                    hostReachabilityNote
                }
            } else {
                Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var hostReachabilityNote: some View {
        switch resolvedHost.kind {
        case .loopback:
            warningRow("No Tailscale address detected. Legacy pairing only works for the iOS simulator on this Mac. The relay flow above does not require Tailscale.")
        case .tailscaleDNSBackendDown(let state):
            warningRow("Tailscale is installed but not running (\(state)). Use the relay flow above, or open the Tailscale menu bar and turn the tunnel on.")
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

    // MARK: - Scan roots section (unchanged from pre-E7)

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

    private func copyRelayURL() {
        guard let urlString = pairingService.bundleURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        didCopyRelay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didCopyRelay = false }
    }

    private func copyLegacyURL() {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort else { return }
        let url = "clawdmeter://\(resolvedHost.host):\(httpPort)?token=\(tokenForDisplay)&ws=\(wsPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopyLegacy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didCopyLegacy = false }
    }

    // MARK: - QR rendering

    private func refreshRelayQR() {
        guard let urlString = pairingService.bundleURL else {
            qrImage = nil
            return
        }
        qrImage = generateQR(from: urlString)
    }

    private func generateQR(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Relay bundle URLs are ~280 chars — error correction "M" gives
        // ~15% recovery which is enough at the printed/screen sizes
        // the iPhone scanner sees from camera distance.
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaleFactor: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 160, height: 160))
    }

    // MARK: - TTL helpers

    private func formatTTLCountdown(ttl: UInt64) -> String {
        let remaining = Int(Int64(ttl) - Int64(now.timeIntervalSince1970))
        if remaining <= 0 { return "expired" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func ttlColor(ttl: UInt64) -> Color {
        let remaining = Int(Int64(ttl) - Int64(now.timeIntervalSince1970))
        if remaining <= 0 { return .red }
        if remaining < 60 { return .orange }
        return .secondary
    }
}
