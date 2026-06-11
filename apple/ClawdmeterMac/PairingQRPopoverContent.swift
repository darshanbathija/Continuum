import SwiftUI
import AppKit
import ClawdmeterShared

/// Compact pairing UI used by the dashboard toolbar's Pair with iPhone
/// affordance. Shows the QR code + a Copy URL CTA so users don't have
/// to dig into Settings → Sessions to pair a phone.
///
/// **E7 rewrite (Gate 3 GTM launch blocker).** Surfaces the relay
/// pairing bundle (sessionId + per-peer bearer tokens + Mac X25519
/// public key) instead of the Tailscale host/port/token URL. Falls
/// back to "Pair iPhone" CTA when no bundle exists.
///
/// The compact popover keeps the regenerate + revoke + advanced
/// controls in Settings — first-time pair stays a one-click action.
struct PairingQRPopoverContent: View {

    @ObservedObject var runtime: AppRuntime
    @ObservedObject var pairingService: RelayPairingService
    @State private var qrImage: NSImage?
    @State private var didCopy: Bool = false
    /// Step 1 of pairing: download QR before minting the relay auth bundle.
    @State private var confirmedAppInstall: Bool = ContinuumIOSAppStore.hasConfirmedInstall
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Active Tahoe accent (Halo blue by default; tracks the user's theme).
    /// All chrome inside this popover routes through this so the brackets,
    /// halo, and Copy URL CTA stay on-brand instead of leaking the legacy
    /// terra-cotta heritage color from SessionsV2Theme.accent.
    @Environment(\.tahoe) private var t
    /// #21: pause the 1Hz countdown re-render when the window is inactive.
    @Environment(\.controlActiveState) private var controlActiveState

    init(runtime: AppRuntime) {
        self.runtime = runtime
        self.pairingService = runtime.relayPairingService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with iPhone")
                .font(.system(size: 15, weight: .semibold))

            switch pairingService.phase {
            case .unpaired:
                if confirmedAppInstall {
                    unpairedContent
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
                bundleContent
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            confirmedAppInstall = ContinuumIOSAppStore.hasConfirmedInstall
            refreshQR()
        }
        .onChange(of: pairingService.bundleURL) { _, _ in refreshQR() }
        .onReceive(ticker) { if controlActiveState != .inactive { now = $0 } }
    }

    // MARK: - Empty / unpaired state

    private func confirmAppInstallAndBeginPairing() {
        ContinuumIOSAppStore.markInstallConfirmed()
        confirmedAppInstall = true
        Task { await pairingService.beginPairing() }
    }

    private var unpairedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate a one-time pairing bundle. The iPhone scans the QR and derives a shared key locally — no Tailscale or LAN setup required.")
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

    // MARK: - Bundle displayed

    @ViewBuilder
    private var bundleContent: some View {
        if let bundle = pairingService.bundle {
            VStack(spacing: 12) {
                qrTile.frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan with Continuum Console on your iPhone")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("or paste the URL after copying.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button(action: copyPairingURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text(didCopy ? "Copied ✓" : "Copy URL")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(terraCotta)
                    Button(action: { Task { await pairingService.beginPairing() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.large)
                    .help("Regenerate bundle")
                }

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

    // MARK: - Subviews

    private var qrTile: some View {
        // Per DESIGN.md: pairing QR is 280x280 with an accent halo (inset
        // -30, radius 50, blur 10px) and four corner brackets (32x32, 3px
        // solid accent, asymmetric radius). Inner QR image renders at 224.
        ZStack {
            // Glass tile
            Group {
                if let qr = qrImage {
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

            // Corner brackets — TL/BR get one asymmetric radius pattern,
            // TR/BL get the mirror. 3px stroke + accent glow shadow.
            ForEach(cornerSpecs, id: \.self) { spec in
                PairingQRCornerBracket(spec: spec, color: t.accent)
            }
        }
        .frame(width: 280, height: 280)
        .background(
            // Halo: inset -30 (so the gradient extends past the tile),
            // radius 50, blur 10px per DESIGN.md.
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

    /// Effective brand accent — routes through the active Tahoe accent
    /// (Halo blue by default; tracks the user's chosen theme) rather than
    /// the legacy terra-cotta heritage color. Per user feedback during
    /// live verification: orange isn't part of the modern brand.
    private var terraCotta: Color { t.accent }

    // MARK: - Actions

    private func copyPairingURL() {
        guard let url = pairingService.bundleURL else { return }
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

    private func formatTTLCountdown(ttl: UInt64) -> String {
        let remaining = Int(Int64(ttl) - Int64(now.timeIntervalSince1970))
        if remaining <= 0 { return "expired" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
