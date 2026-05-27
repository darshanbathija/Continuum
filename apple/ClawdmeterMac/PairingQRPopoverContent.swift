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
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .frame(width: 280, height: 280)
            .accessibilityLabel("Pairing QR code")
            .accessibilityHint("Scan with your iPhone's camera to pair this Mac.")

            // Corner brackets — TL/BR get one asymmetric radius pattern,
            // TR/BL get the mirror. 3px stroke + accent glow shadow.
            ForEach(cornerSpecs, id: \.self) { spec in
                CornerBracket(spec: spec, color: SessionsV2Theme.accent)
            }
        }
        .frame(width: 280, height: 280)
        .background(
            // Halo: inset -30 (so the gradient extends past the tile),
            // radius 50, blur 10px per DESIGN.md.
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

    private var terraCotta: Color { SessionsV2Theme.accent }

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

// MARK: - QR corner bracket

/// Four L-shaped accent brackets that frame the QR tile, mirroring the
/// iOS `IOSPairingView` spec. Each bracket is 32×32, 3px stroke, with an
/// asymmetric corner radius that bends inward toward the QR.
struct QRCornerBracketSpec: Hashable {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    let corner: Corner
}

private struct CornerBracket: View {
    let spec: QRCornerBracketSpec
    let color: Color

    var body: some View {
        let s: CGFloat = 32
        let stroke: CGFloat = 3
        let r: CGFloat = 10
        Path { p in
            switch spec.corner {
            case .topLeft:
                p.move(to: CGPoint(x: s, y: 0))
                p.addLine(to: CGPoint(x: r, y: 0))
                p.addArc(center: CGPoint(x: r, y: r), radius: r,
                         startAngle: .degrees(-90), endAngle: .degrees(180),
                         clockwise: true)
                p.addLine(to: CGPoint(x: 0, y: s))
            case .topRight:
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: s - r, y: 0))
                p.addArc(center: CGPoint(x: s - r, y: r), radius: r,
                         startAngle: .degrees(-90), endAngle: .degrees(0),
                         clockwise: false)
                p.addLine(to: CGPoint(x: s, y: s))
            case .bottomLeft:
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: s - r))
                p.addArc(center: CGPoint(x: r, y: s - r), radius: r,
                         startAngle: .degrees(180), endAngle: .degrees(90),
                         clockwise: true)
                p.addLine(to: CGPoint(x: s, y: s))
            case .bottomRight:
                p.move(to: CGPoint(x: s, y: 0))
                p.addLine(to: CGPoint(x: s, y: s - r))
                p.addArc(center: CGPoint(x: s - r, y: s - r), radius: r,
                         startAngle: .degrees(0), endAngle: .degrees(90),
                         clockwise: false)
                p.addLine(to: CGPoint(x: 0, y: s))
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        .frame(width: s, height: s)
        .shadow(color: color.opacity(0.5), radius: 5)
        .offset(offset(for: spec.corner))
        .accessibilityHidden(true)
    }

    private func offset(for corner: QRCornerBracketSpec.Corner) -> CGSize {
        let inset: CGFloat = 280 / 2 - 16 + 6  // tile half - bracket half + 6 outward
        switch corner {
        case .topLeft:     return CGSize(width: -inset, height: -inset)
        case .topRight:    return CGSize(width: inset,  height: -inset)
        case .bottomLeft:  return CGSize(width: -inset, height: inset)
        case .bottomRight: return CGSize(width: inset,  height: inset)
        }
    }
}
