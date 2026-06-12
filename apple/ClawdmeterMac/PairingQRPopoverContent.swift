import SwiftUI
import AppKit
import ClawdmeterShared

/// Compact pairing UI used by the dashboard toolbar's Pair with iPhone
/// affordance. Users choose Cloud or Tailscale, install the iPhone app,
/// then scan the transport-specific pairing QR.
struct PairingQRPopoverContent: View {

    @ObservedObject var runtime: AppRuntime
    @ObservedObject var pairingService: RelayPairingService
    @AppStorage(PairingMode.storageKey) private var pairingModeRaw: String = PairingMode.cloud.rawValue
    @State private var qrImage: NSImage?
    @State private var tailscaleQRImage: NSImage?
    @State private var didCopy: Bool = false
    @State private var tokenForDisplay: String = ""
    @State private var resolvedHost: TailscaleHost.Resolved = TailscaleHost.Resolved(host: "127.0.0.1", kind: .loopback)
    /// Step 1 of pairing: download QR before minting the pairing QR.
    @State private var confirmedAppInstall: Bool = ContinuumIOSAppStore.hasConfirmedInstall
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @Environment(\.tahoe) private var t
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with iPhone")
                .font(.system(size: 15, weight: .semibold))

            if confirmedAppInstall {
                PairingModePicker(mode: pairingMode, layout: .compact)
            }

            switch pairingMode.wrappedValue {
            case .cloud:
                cloudContent
            case .tailscale:
                tailscaleContent
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            confirmedAppInstall = ContinuumIOSAppStore.hasConfirmedInstall
            refreshTailscaleState()
            refreshQR()
        }
        .onChange(of: pairingService.bundleURL) { _, _ in refreshQR() }
        .onChange(of: pairingModeRaw) { _, _ in
            if pairingMode.wrappedValue == .tailscale {
                refreshTailscaleState()
            }
        }
        .onReceive(ticker) { if controlActiveState != .inactive { now = $0 } }
    }

    // MARK: - Cloud

    @ViewBuilder
    private var cloudContent: some View {
        switch pairingService.phase {
        case .unpaired:
            if confirmedAppInstall {
                cloudUnpairedContent
            } else {
                PairingDownloadAppStep(layout: .popover, onConfirmInstall: confirmAppInstallAndBeginPairing)
            }
        case .generatingBundle:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating bundle…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        case .scanning, .keyExchanged, .readyButNotConnected:
            cloudBundleContent
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

    private var cloudUnpairedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate a one-time Cloud pairing bundle. The iPhone scans the QR and derives a shared key locally — no Tailscale or LAN setup required.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { Task { await pairingService.beginPairing() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                    Text("Pair iPhone")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(terraCotta)
            if let lastError = pairingService.lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var cloudBundleContent: some View {
        if let bundle = pairingService.bundle {
            VStack(spacing: 12) {
                qrTile(image: qrImage).frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan with Continuum Console on your iPhone")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("or paste the URL after copying.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                pairingActionRow(copyAction: copyPairingURL, regenerateAction: {
                    Task { await pairingService.beginPairing() }
                })

                VStack(alignment: .leading, spacing: 3) {
                    labelRow("Session", value: String(bundle.sid.prefix(12)) + "…")
                    labelRow("Mac key", value: String(bundle.ecdhPub.prefix(12)) + "…")
                    labelRow("Expires", value: formatTTLCountdown(ttl: bundle.ttl))
                }
                .padding(.top, 4)
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Tailscale

    @ViewBuilder
    private var tailscaleContent: some View {
        if confirmedAppInstall {
            tailscaleBundleContent
        } else {
            PairingDownloadAppStep(layout: .popover, onConfirmInstall: confirmAppInstallAndBeginPairing)
        }
    }

    @ViewBuilder
    private var tailscaleBundleContent: some View {
        if let httpPort = runtime.agentControlServer.boundPort,
           let wsPort = runtime.agentControlServer.boundWsPort,
           tailscalePairingURL(httpPort: httpPort, wsPort: wsPort) != nil {
            VStack(spacing: 12) {
                qrTile(image: tailscaleQRImage).frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan with Continuum Console on your iPhone")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Both devices must be on the same Tailnet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                pairingActionRow(copyAction: copyTailscaleURL, regenerateAction: refreshTailscaleState)

                VStack(alignment: .leading, spacing: 3) {
                    labelRow("Host", value: resolvedHost.host)
                    labelRow("Token", value: String(tokenForDisplay.prefix(8)) + "…")
                }
                .padding(.top, 4)

                tailscaleReachabilityNote
            }
        } else {
            Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var tailscaleReachabilityNote: some View {
        switch resolvedHost.kind {
        case .loopback:
            Text("No Tailscale address detected. Install and run Tailscale on this Mac first.")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .tailscaleDNSBackendDown(let state):
            Text("Tailscale is installed but not running (\(state)).")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .tailscaleIPv4, .tailscaleIPv6, .tailscaleDNS:
            EmptyView()
        }
    }

    // MARK: - Subviews

    private func qrTile(image: NSImage?) -> some View {
        ZStack {
            Group {
                if let qr = image {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 224, height: 224)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(width: 224, height: 224)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .padding(28)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: 280, height: 280)
            .accessibilityLabel("Pairing QR code")
            .accessibilityHint("Scan with your iPhone's camera to pair this Mac.")

            ForEach(cornerSpecs, id: \.self) { spec in
                PairingQRCornerBracket(spec: spec, color: t.accent)
            }
        }
        .frame(width: 280, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [.clear, .clear],
                        center: .center, startRadius: 0, endRadius: 200
                    )
                )
                .blur(radius: 10)
                .padding(-30)
                .allowsHitTesting(false)
        )
    }

    private func pairingActionRow(copyAction: @escaping () -> Void, regenerateAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: copyAction) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text(didCopy ? "Copied ✓" : "Copy URL")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(terraCotta)
            Button(action: regenerateAction) {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.large)
            .help("Regenerate pairing QR")
        }
    }

    private var cornerSpecs: [QRCornerBracketSpec] {
        [
            .init(corner: .topLeft),
            .init(corner: .topRight),
            .init(corner: .bottomLeft),
            .init(corner: .bottomRight),
        ]
    }

    private func labelRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var terraCotta: Color { t.accent }

    // MARK: - Actions

    private func copyPairingURL() {
        guard let url = pairingService.bundleURL else { return }
        copyToPasteboard(url)
    }

    private func copyTailscaleURL() {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort,
              let url = tailscalePairingURL(httpPort: httpPort, wsPort: wsPort) else { return }
        copyToPasteboard(url)
    }

    private func copyToPasteboard(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            didCopy = false
        }
    }

    // MARK: - Helpers

    private func refreshQR() {
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
            token: tokenForDisplay
        )
    }

    private func formatTTLCountdown(ttl: UInt64) -> String {
        let remaining = Int(Int64(ttl) - Int64(now.timeIntervalSince1970))
        if remaining <= 0 { return "expired" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
