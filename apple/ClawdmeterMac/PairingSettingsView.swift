import SwiftUI
import AppKit
import ClawdmeterShared

/// Mac Settings → Pair iPhone. Users choose Continuum Cloud or Tailscale,
/// install Continuum Console on the iPhone, then scan the transport-specific
/// pairing QR.
struct PairingSettingsView: View {

    @ObservedObject var runtime: AppRuntime
    @ObservedObject var pairingService: RelayPairingService
    @AppStorage(PairingMode.storageKey) private var pairingModeRaw: String = PairingMode.cloud.rawValue
    @AppStorage("clawdmeter.pairing.preferMagicDNS") private var preferMagicDNS: Bool = true
    @AppStorage("clawdmeter.pairing.preferTLS") private var preferTLS: Bool = false
    @State private var qrImage: NSImage?
    @State private var tailscaleQRImage: NSImage?
    @State private var didCopyRelay: Bool = false
    @State private var didCopyTailscale: Bool = false
    @State private var tokenForDisplay: String = ""
    @State private var resolvedHost: TailscaleHost.Resolved = TailscaleHost.Resolved(host: "127.0.0.1", kind: .loopback)
    /// Relay creation-grant token entry. Empty after save; we never echo the
    /// stored value back into the field (it lives in the Keychain).
    @State private var grantTokenInput: String = ""
    @State private var grantTokenIsStored: Bool = RelayGrantTokenStore.shared.isConfigured
    @State private var didSaveGrantToken: Bool = false
    @State private var isProvisioningGrantToken: Bool = false
    @State private var grantProvisionFailed: Bool = false
    /// Step 1 of pairing: download QR before minting the pairing QR.
    @State private var confirmedAppInstall: Bool = ContinuumIOSAppStore.hasConfirmedInstall
    /// Live ticker so the "expires in N:NN" label re-renders without a state
    /// change from the pairing service.
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Active Tahoe accent (Halo blue by default; tracks the user's theme).
    @Environment(\.tahoe) private var t
    /// #21: pause the 1Hz TTL-countdown re-render when the window is inactive.
    @Environment(\.controlActiveState) private var controlActiveState

    init(runtime: AppRuntime) {
        self.runtime = runtime
        self.pairingService = runtime.relayPairingService
    }

    private var pairingMode: Binding<PairingMode> {
        Binding(
            get: { PairingMode(rawValue: pairingModeRaw) ?? .cloud },
            set: { pairingModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            pairSection
            if pairingMode.wrappedValue == .cloud, pairingService.phase != .unpaired {
                TahoeHair()
                HStack {
                    Button("Forget pairing", role: .destructive, action: ContinuumAnalytics.wrapButton("pairing_forget", { pairingService.reset() }))
                    Spacer()
                }
            }
            if pairingMode.wrappedValue == .cloud {
                TahoeHair()
                relayGrantTokenSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            confirmedAppInstall = ContinuumIOSAppStore.hasConfirmedInstall
            refreshTailscaleState()
            refreshRelayQR()
            refreshGrantTokenState()
            Task { await autoProvisionGrantTokenIfNeeded() }
        }
        .onReceive(ticker) { if controlActiveState != .inactive { now = $0 } }
        .onChange(of: pairingService.bundleURL) { _, _ in refreshRelayQR() }
        .onChange(of: pairingModeRaw) { _, _ in
            if pairingMode.wrappedValue == .tailscale {
                refreshTailscaleState()
            }
        }
        .onChange(of: preferMagicDNS) { _, _ in refreshTailscaleState() }
        .onChange(of: preferTLS) { _, _ in refreshTailscaleQR() }
    }

    /// Uppercased header + content + optional muted footer, matching the rest
    /// of MacSettingsView.
    @ViewBuilder
    private func tahoeSection<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(TahoeFont.body(11.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(t.fg3)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let footer {
                Text(LocalizedStringKey(footer))
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pair section

    private var pairSectionFooter: String {
        if !confirmedAppInstall {
            return "Choose Cloud or Tailscale, install Continuum Console on your iPhone, then scan the pairing QR to connect."
        }
        switch pairingMode.wrappedValue {
        case .cloud:
            return "Open Continuum Console on your iPhone and scan the Cloud QR. The code is valid for 30 days; regenerate any time to rotate the keys."
        case .tailscale:
            return "Open Continuum Console on your iPhone and scan the Tailscale QR. Both devices must be on the same Tailnet with Tailscale running."
        }
    }

    private func confirmAppInstallAndBeginPairing() {
        ContinuumIOSAppStore.markInstallConfirmed()
        confirmedAppInstall = true
        beginPairingForSelectedMode()
    }

    private func beginPairingForSelectedMode() {
        switch pairingMode.wrappedValue {
        case .cloud:
            Task { await pairingService.beginPairing() }
        case .tailscale:
            refreshTailscaleState()
        }
    }

    private var pairSection: some View {
        tahoeSection("Pair with iPhone", footer: pairSectionFooter) {
            VStack(alignment: .leading, spacing: 14) {
                if confirmedAppInstall {
                    PairingModePicker(mode: pairingMode, layout: .settings)
                }
                switch pairingMode.wrappedValue {
                case .cloud:
                    cloudPairContent
                case .tailscale:
                    tailscalePairContent
                }
            }
        }
    }

    @ViewBuilder
    private var cloudPairContent: some View {
        switch pairingService.phase {
        case .unpaired:
            if confirmedAppInstall {
                relayUnpairedRow
            } else {
                PairingDownloadAppStep(layout: .settings, onConfirmInstall: confirmAppInstallAndBeginPairing)
            }
        case .generatingBundle:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating QR…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .scanning, .keyExchanged, .readyButNotConnected:
            relayBundleRow
        }
    }

    @ViewBuilder
    private var tailscalePairContent: some View {
        if confirmedAppInstall {
            tailscalePairingRow
        } else {
            PairingDownloadAppStep(layout: .settings, onConfirmInstall: confirmAppInstallAndBeginPairing)
        }
    }

    // MARK: - Relay grant token

    /// Advanced override for operator/dev grant tokens. Normal installs auto-
    /// provision a per-Mac token in the background on first launch.
    private var relayGrantTokenSection: some View {
        tahoeSection(
            "Relay access token",
            footer: "Clawdmeter auto-provisions a relay grant token for this Mac. Paste a custom token only if you run your own relay or need to replace the auto-provisioned one."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SecureField(grantTokenIsStored ? "Token saved — paste to replace" : "Relay grant token (optional override)", text: $grantTokenInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Button("Save", action: ContinuumAnalytics.wrapButton("pairing_grant_token_save", saveGrantToken))
                        .disabled(grantTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if grantTokenIsStored {
                        Button("Remove", role: .destructive, action: ContinuumAnalytics.wrapButton("pairing_grant_token_remove", clearGrantToken))
                    }
                }
                HStack(spacing: 6) {
                    if isProvisioningGrantToken {
                        ProgressView().controlSize(.small)
                        Text("Provisioning relay access…").foregroundStyle(.secondary)
                    } else if didSaveGrantToken {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Saved").foregroundStyle(.green)
                    } else if grantTokenIsStored {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(t.accent)
                        Text("Relay access is ready for pairing.").foregroundStyle(.secondary)
                    } else if grantProvisionFailed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Auto-provision failed — paste a relay grant token or retry Pair iPhone.").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "clock.fill").foregroundStyle(.secondary)
                        Text("Setting up relay access…").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func refreshGrantTokenState() {
        grantTokenIsStored = RelayGrantTokenStore.shared.isConfigured
    }

    private func autoProvisionGrantTokenIfNeeded() async {
        guard !RelayGrantTokenStore.shared.isConfigured else {
            grantProvisionFailed = false
            return
        }
        isProvisioningGrantToken = true
        defer { isProvisioningGrantToken = false }
        let ok = await RelayGrantProvisioner().ensureConfigured()
        grantTokenIsStored = ok
        grantProvisionFailed = !ok
    }

    private func saveGrantToken() {
        let trimmed = grantTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if RelayGrantTokenStore.shared.setToken(trimmed) {
            grantTokenInput = ""
            grantTokenIsStored = true
            grantProvisionFailed = false
            didSaveGrantToken = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didSaveGrantToken = false }
        }
    }

    private func clearGrantToken() {
        RelayGrantTokenStore.shared.clear()
        grantTokenInput = ""
        grantTokenIsStored = false
        didSaveGrantToken = false
        grantProvisionFailed = false
    }

    @ViewBuilder
    private var relayUnpairedRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not yet paired")
                    .font(.headline)
                Text("Generate a one-time Cloud QR your iPhone scans to pair.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Pair iPhone", action: ContinuumAnalytics.wrapButton("pairing_begin_cloud", {
                Task { await pairingService.beginPairing() }
            }))
            .keyboardShortcut(.defaultAction)
        }
        if let lastError = pairingService.lastError {
            Text(lastError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var relayBundleRow: some View {
        if let bundle = pairingService.bundle, let urlString = pairingService.bundleURL {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Scan with Continuum Console on your iPhone", systemImage: "iphone.gen3")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent("Expires in") {
                        Text(formatTTLCountdown(ttl: bundle.ttl))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ttlColor(ttl: bundle.ttl))
                    }
                    HStack(spacing: 8) {
                        Button("Copy pairing URL", action: ContinuumAnalytics.wrapButton("pairing_copy_relay_url", copyRelayURL))
                        if didCopyRelay {
                            Text("Copied ✓")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button("Regenerate", action: ContinuumAnalytics.wrapButton("pairing_regenerate_relay", { Task { await pairingService.beginPairing() } }))
                    }
                    .padding(.top, 4)
                    if ProcessInfo.processInfo.environment["CLAWDMETER_DEBUG_PAIRING"] != nil {
                        Text(urlString)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                relayQRTile(image: qrImage)
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var tailscalePairingRow: some View {
        if let httpPort = runtime.agentControlServer.boundPort,
           let wsPort = runtime.agentControlServer.boundWsPort,
           let urlString = tailscalePairingURL(httpPort: httpPort, wsPort: wsPort) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Scan with Continuum Console on your iPhone", systemImage: "iphone.gen3")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    tailscaleConnectivityToggles
                    LabeledContent("Host") {
                        Text(resolvedHost.host)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Token") {
                        Text(String(tokenForDisplay.prefix(8)) + "…")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    hostReachabilityNote
                    HStack(spacing: 8) {
                        Button("Copy pairing URL", action: ContinuumAnalytics.wrapButton("pairing_copy_tailscale_url", copyTailscaleURL))
                        if didCopyTailscale {
                            Text("Copied ✓")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button("Refresh QR", action: ContinuumAnalytics.wrapButton("pairing_refresh_tailscale_qr", refreshTailscaleState))
                        Button("Regenerate token", action: ContinuumAnalytics.wrapButton("pairing_regenerate_tailscale_token", {
                            _ = PairingTokenStore.shared.regenerate()
                            refreshTailscaleState()
                        }))
                    }
                    .padding(.top, 4)
                    if ProcessInfo.processInfo.environment["CLAWDMETER_DEBUG_PAIRING"] != nil {
                        Text(urlString)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                relayQRTile(image: tailscaleQRImage)
            }
        } else {
            Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var tailscaleConnectivityToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Prefer MagicDNS host in QR", isOn: $preferMagicDNS)
            Toggle("Use TLS pairing URL (advanced)", isOn: $preferTLS)
                .disabled(!preferMagicDNS || !isMagicDNSHost(resolvedHost.kind))
            Text("MagicDNS uses your `*.ts.net` hostname so pairing survives IP changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func isMagicDNSHost(_ kind: TailscaleHost.Resolved.Kind) -> Bool {
        if case .tailscaleDNS = kind { return true }
        return false
    }

    @ViewBuilder
    private var hostReachabilityNote: some View {
        switch resolvedHost.kind {
        case .loopback:
            warningRow("No Tailscale address detected. Tailscale pairing only works for the iOS simulator on this Mac, or after Tailscale is installed and running.")
        case .tailscaleDNSBackendDown(let state):
            warningRow("Tailscale is installed but not running (\(state)). Open the Tailscale menu bar app and turn the tunnel on.")
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

    private func relayQRTile(image: NSImage?) -> some View {
        Group {
            if let qr = image {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 224, height: 224)
                    .accessibilityLabel("Pairing QR code")
                    .accessibilityHint("Scan with your iPhone's camera to pair this Mac.")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 224, height: 224)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .padding(28)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 280, height: 280)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func copyRelayURL() {
        guard let urlString = pairingService.bundleURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        didCopyRelay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didCopyRelay = false }
    }

    private func copyTailscaleURL() {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort,
              let url = tailscalePairingURL(httpPort: httpPort, wsPort: wsPort) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopyTailscale = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didCopyTailscale = false }
    }

    // MARK: - QR rendering

    private func refreshRelayQR() {
        guard let urlString = pairingService.bundleURL else {
            qrImage = nil
            return
        }
        qrImage = PairingQRGenerator.makeImage(from: urlString)
    }

    private func refreshTailscaleState() {
        tokenForDisplay = PairingTokenStore.shared.currentToken()
        resolvedHost = TailscaleHost.resolve()
        refreshTailscaleQR()
    }

    private func refreshTailscaleQR() {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort,
              let urlString = tailscalePairingURL(httpPort: httpPort, wsPort: wsPort) else {
            tailscaleQRImage = nil
            return
        }
        tailscaleQRImage = PairingQRGenerator.makeImage(from: urlString)
    }

    private func tailscalePairingURL(httpPort: UInt16, wsPort: UInt16) -> String? {
        guard !tokenForDisplay.isEmpty else { return nil }
        return TailscalePairingURLBuilder.buildURL(
            host: resolvedHost.host,
            httpPort: httpPort,
            wsPort: wsPort,
            token: tokenForDisplay,
            preferTLS: preferTLS
        )
    }

    // MARK: - TTL helpers

    private func formatTTLCountdown(ttl: UInt64) -> String {
        let remaining = Int(Int64(ttl) - Int64(now.timeIntervalSince1970))
        if remaining <= 0 { return "expired" }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func ttlColor(ttl: UInt64) -> Color {
        let remaining = Int(Int64(ttl) - Int64(now.timeIntervalSince1970))
        if remaining <= 0 { return .red }
        if remaining < 3_600 { return .orange }
        return .secondary
    }
}
