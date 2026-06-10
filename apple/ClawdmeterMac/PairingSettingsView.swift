import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// Mac Settings → Pair iPhone. One QR the iPhone scans (relay-based): the Mac
/// mints a session ID + per-peer bearer tokens + an X25519 public key, encodes
/// them into a `clawdmeter-pair://v1/<base64url>` URL, and renders a QR. The
/// iPhone scans, derives the shared key locally via HKDF-SHA256
/// (`RelayPairingCrypto`) and persists. No Tailscale or LAN required.
///
/// Stripped to the basics per user feedback: the legacy Tailscale pairing,
/// allowed-roots, plugins inventory, verbose detail rows, and the security
/// blurb were removed. The pane is now just "scan one QR" + Forget pairing.
struct PairingSettingsView: View {

    @ObservedObject var runtime: AppRuntime
    @ObservedObject var pairingService: RelayPairingService
    @State private var qrImage: NSImage?
    @State private var didCopyRelay: Bool = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            relayPairSection
            if pairingService.phase != .unpaired {
                TahoeHair()
                HStack {
                    Button("Forget pairing", role: .destructive) { pairingService.reset() }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshRelayQR() }
        .onReceive(ticker) { if controlActiveState != .inactive { now = $0 } }
        .onChange(of: pairingService.bundleURL) { _, _ in refreshRelayQR() }
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

    private var relayPairSection: some View {
        tahoeSection("Pair with iPhone", footer: "Open Clawdmeter on your iPhone and scan the QR. The code expires after 15 minutes.") {
            switch pairingService.phase {
            case .unpaired:
                relayUnpairedRow
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
    }

    @ViewBuilder
    private var relayUnpairedRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not yet paired")
                    .font(.headline)
                Text("Generate a one-time QR your iPhone scans to pair.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Pair iPhone") {
                Task { await pairingService.beginPairing() }
            }
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
                    Label("Scan with your iPhone's camera", systemImage: "iphone.gen3")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                        Button("Regenerate", action: { Task { await pairingService.beginPairing() } })
                    }
                    .padding(.top, 4)
                    // Hidden in production builds — only shows when a dev wants
                    // to copy the raw URL into the iOS simulator (clipboard
                    // sharing doesn't auto-flow QRs).
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
        // Match the pairing-popover spec from DESIGN.md: 280x280 outer with
        // glass tile + 224 inner image. Settings + popover share dimensions so
        // users see one consistent surface.
        Group {
            if let qr = qrImage {
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
        // Relay bundle URLs are ~280 chars — error correction "M" gives ~15%
        // recovery which is enough at the screen sizes the iPhone scanner sees.
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaleFactor: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 224, height: 224))
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
