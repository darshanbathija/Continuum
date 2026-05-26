import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
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
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                unpairedContent
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
        .onAppear { refreshQR() }
        .onChange(of: pairingService.bundleURL) { _, _ in refreshQR() }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Empty / unpaired state

    private var unpairedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate a one-time pairing bundle. The iPhone scans the QR and derives a shared key locally — no Tailscale or LAN setup required.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { pairingService.beginPairing() }) {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                    Text("Pair iPhone")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(terraCotta)
        }
    }

    // MARK: - Bundle displayed

    @ViewBuilder
    private var bundleContent: some View {
        if let bundle = pairingService.bundle {
            VStack(spacing: 12) {
                qrTile.frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan with Clawdmeter on your iPhone")
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
                    Button(action: { pairingService.beginPairing() }) {
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
        Group {
            if let qr = qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 200, height: 200)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
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

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

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
        qrImage = generateQR(from: urlString)
    }

    private func generateQR(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaleFactor: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
    }

    private func formatTTLCountdown(ttl: UInt64) -> String {
        let remaining = Int(Int64(ttl) - Int64(now.timeIntervalSince1970))
        if remaining <= 0 { return "expired" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
