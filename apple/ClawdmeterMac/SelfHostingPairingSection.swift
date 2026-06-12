import SwiftUI
import AppKit
import ClawdmeterShared

/// Settings → Pair iPhone → Self-hosting. Tailscale-direct pairing is the
/// primary self-hosted path; a custom relay grant token sits behind a nested
/// Advanced disclosure for operators running their own Cloudflare Worker.
struct SelfHostingPairingSection: View {

    @ObservedObject var runtime: AppRuntime
    @Environment(\.tahoe) private var t

    @State private var showSelfHosting = false
    @State private var showAdvanced = false

    @State private var tailscaleQRImage: NSImage?
    @State private var resolvedHost: TailscaleHost.Resolved = TailscaleHost.Resolved(host: "127.0.0.1", kind: .loopback)
    @State private var tokenForDisplay: String = ""
    @State private var didCopyTailscaleURL = false

    @AppStorage("clawdmeter.pairing.preferMagicDNS") private var preferMagicDNS = true
    @AppStorage("clawdmeter.pairing.preferTLS") private var preferTLS = false

    @State private var grantTokenInput: String = ""
    @State private var grantTokenIsStored: Bool = RelayGrantTokenStore.shared.isConfigured
    @State private var didSaveGrantToken: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { showSelfHosting.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: showSelfHosting ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Self-hosting")
                        .font(TahoeFont.body(12, weight: .semibold))
                }
                .foregroundStyle(t.fg3)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Expand for Tailscale-based self-hosted pairing")

            if showSelfHosting {
                tailscalePairingBlock
                nestedAdvancedBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshTailscalePairing()
            refreshGrantTokenState()
        }
        .onChange(of: preferMagicDNS) { _, _ in refreshTailscalePairing() }
        .onChange(of: preferTLS) { _, _ in refreshTailscalePairing() }
        .onChange(of: showSelfHosting) { _, expanded in
            if expanded { refreshTailscalePairing() }
        }
    }

    // MARK: - Tailscale pairing

    private var tailscalePairingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair over Tailscale instead of Continuum cloud relay. Both devices must be signed into the same tailnet.")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg4)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Prefer MagicDNS host in pairing QR", isOn: $preferMagicDNS)
                .font(TahoeFont.body(12))
            Toggle("Use TLS pairing URL (advanced)", isOn: $preferTLS)
                .font(TahoeFont.body(12))
                .disabled(!preferMagicDNS || !isMagicDNSHost(resolvedHost.kind))

            if PairingTokenStore.shared.isRevoked {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Pairing token revoked. Generate a new token to pair.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Generate token") {
                        _ = PairingTokenStore.shared.regenerate()
                        refreshTailscalePairing()
                    }
                    .controlSize(.small)
                }
            } else if let httpPort = runtime.agentControlServer.boundPort,
                      let wsPort = runtime.agentControlServer.boundWsPort {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
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
                        hostReachabilityNote
                        HStack(spacing: 8) {
                            Button("Copy Tailscale pairing URL", action: copyTailscalePairingURL)
                            if didCopyTailscaleURL {
                                Text("Copied ✓").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                            Button("Regenerate token") {
                                _ = PairingTokenStore.shared.regenerate()
                                refreshTailscalePairing()
                            }
                            .controlSize(.small)
                        }
                        Text("On iPhone: Pair → Self-hosting: Tailscale pairing, then scan this QR or paste the URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    tailscaleQRTile
                }
            } else {
                Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var hostReachabilityNote: some View {
        switch resolvedHost.kind {
        case .loopback:
            warningRow("No Tailscale address detected. Install Tailscale and sign in on both Mac and iPhone, or use the iOS Simulator on this Mac.")
        case .tailscaleDNSBackendDown(let state):
            warningRow("Tailscale is installed but not running (\(state)). Turn the tunnel on before pairing.")
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tailscaleQRTile: some View {
        Group {
            if let qr = tailscaleQRImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .accessibilityLabel("Tailscale pairing QR code")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 140, height: 140)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .padding(8)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }

    // MARK: - Nested Advanced (custom relay)

    private var nestedAdvancedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { showAdvanced.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Advanced")
                        .font(TahoeFont.body(11.5, weight: .semibold))
                }
                .foregroundStyle(t.fg4)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            if showAdvanced {
                Text("Fallback for your own Cloudflare relay Worker. Paste the operator grant token from your deployment if you are not using Continuum cloud relay.")
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SecureField(
                        grantTokenIsStored ? "Token saved — paste to replace" : "Relay grant token",
                        text: $grantTokenInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    Button("Save", action: saveGrantToken)
                        .disabled(grantTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if grantTokenIsStored {
                        Button("Remove", role: .destructive, action: clearGrantToken)
                    }
                }

                HStack(spacing: 6) {
                    relayGrantStatusRow
                }
                .font(.caption)
            }
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private var relayGrantStatusRow: some View {
        if didSaveGrantToken {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Saved").foregroundStyle(.green)
        } else if grantTokenIsStored {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(t.accent)
            Text("Custom relay token saved.").foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func refreshTailscalePairing() {
        tokenForDisplay = PairingTokenStore.shared.currentToken()
        resolvedHost = TailscaleHost.resolve()
        guard !PairingTokenStore.shared.isRevoked,
              let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort,
              let url = tailscalePairingURL(httpPort: Int(httpPort), wsPort: Int(wsPort))
        else {
            tailscaleQRImage = nil
            return
        }
        tailscaleQRImage = PairingQRGenerator.makeImage(from: url, side: 140)
    }

    private func tailscalePairingURL(httpPort: Int, wsPort: Int) -> String? {
        guard !tokenForDisplay.isEmpty else { return nil }
        let scheme = preferTLS && preferMagicDNS && isMagicDNSHost(resolvedHost.kind) ? "clawdmeters" : "clawdmeter"
        return "\(scheme)://\(resolvedHost.host):\(httpPort)?token=\(tokenForDisplay)&ws=\(wsPort)"
    }

    private func copyTailscalePairingURL() {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort,
              let url = tailscalePairingURL(httpPort: Int(httpPort), wsPort: Int(wsPort)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopyTailscaleURL = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didCopyTailscaleURL = false }
    }

    private func isMagicDNSHost(_ kind: TailscaleHost.Resolved.Kind) -> Bool {
        if case .tailscaleDNS = kind { return true }
        return false
    }

    private func refreshGrantTokenState() {
        grantTokenIsStored = RelayGrantTokenStore.shared.isConfigured
    }

    private func saveGrantToken() {
        let trimmed = grantTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if RelayGrantTokenStore.shared.setToken(trimmed) {
            grantTokenInput = ""
            grantTokenIsStored = true
            didSaveGrantToken = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didSaveGrantToken = false }
        }
    }

    private func clearGrantToken() {
        RelayGrantTokenStore.shared.clear()
        grantTokenInput = ""
        grantTokenIsStored = false
        didSaveGrantToken = false
    }
}
