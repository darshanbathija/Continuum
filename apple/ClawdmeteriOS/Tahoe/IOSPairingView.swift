import SwiftUI
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// iOS Pairing flow — QR viewport with halo brackets + paste URL row +
/// Scan QR button. Ports `ios-other.jsx::IOSPairing`. Renders a real QR
/// via CoreImage (vs the JSX FakeQR).
///
/// D3 (v1.0 polish, 2026-05-22): replaces the legacy `PairingFlow`
/// surface. Buttons now wire to `AgentControlClient.setPairing(...)`
/// — Scan QR presents `PairingScannerView` as a sheet, Paste URL
/// presents a paste sheet that parses the clawdmeter:// URL via
/// `PairingScannerView.parse(urlString:)`. Either path lands on
/// `applyChallenge(...)` which mirrors `PairingFlow`'s wire (so
/// behavior is preserved exactly while the visual chrome upgrades to
/// Tahoe).
public struct IOSPairingView: View {
    @Environment(\.tahoe) private var t
    var onClose: () -> Void

    /// Daemon client — used to commit the pairing once a QR scans or a
    /// pasted URL parses. The wire is `setPairing(host:httpPort:wsPort:token:)`
    /// followed by `refreshAll()` (identical to the legacy PairingFlow).
    @ObservedObject private var client: AgentControlClient

    @State private var scannerPresented: Bool = false
    @State private var pasteSheetPresented: Bool = false

    public init(client: AgentControlClient, onClose: @escaping () -> Void) {
        self.client = client
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onClose) {
                    TahoeIcon("x", size: 15).foregroundStyle(t.fg)
                        .frame(width: 40, height: 38)
                        .background { Capsule().fill(t.glassTintHi) }
                        .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Pair to Mac")
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                Spacer()
                Color.clear.frame(width: 40, height: 38)
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)

            ZStack {
                RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .fill(RadialGradient(colors: [t.accentGlow.color(opacity: 0.30), .clear],
                                         center: .center, startRadius: 0, endRadius: 220))
                    .blur(radius: 10).padding(-30).allowsHitTesting(false)

                TahoeGlass(radius: 28, tone: .raised) {
                    QRView(content: "clwd://100.42.7.18:7019/v1/pair")
                        .padding(28)
                }
                .frame(width: 280, height: 280)

                bracket(.topLeading)
                bracket(.topTrailing)
                bracket(.bottomLeading)
                bracket(.bottomTrailing)
            }
            .frame(width: 280, height: 280)
            .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Point your camera at the QR")
                    .font(TahoeFont.rounded(18, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(t.fg)
                Text("Open Clawdmeter on your Mac → Sync with iPhone. Both devices need to be on the same Tailnet.")
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    pasteSheetPresented = true
                } label: {
                    TahoeGlass(radius: 14, tone: .chip) {
                        HStack(spacing: 10) {
                            TahoeIcon("link", size: 15).foregroundStyle(t.fg3)
                            Text("clwd://100.42\u{2026}")
                                .font(TahoeFont.mono(13))
                                .foregroundStyle(t.fg3)
                                .lineLimit(1)
                            Spacer()
                            Text("Paste URL")
                                .font(TahoeFont.body(12.5, weight: .bold))
                                .foregroundStyle(t.accent)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste pairing URL")

                Button {
                    scannerPresented = true
                } label: {
                    TahoeAccentButton(size: .l) {
                        HStack(spacing: 6) {
                            TahoeIcon("qr", size: 14)
                            Text("Scan QR")
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Scan pairing QR")
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .sheet(isPresented: $scannerPresented) {
            // D3: present the existing PairingScannerView and pipe its
            // detected challenge through applyChallenge. The scanner
            // emits a callback once per successful scan.
            NavigationStack {
                PairingScannerView { challenge in
                    applyChallenge(challenge)
                    scannerPresented = false
                }
                .navigationTitle("Scan pairing QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { scannerPresented = false }
                    }
                }
            }
        }
        .sheet(isPresented: $pasteSheetPresented) {
            PasteURLSheet(
                isPresented: $pasteSheetPresented,
                onAccept: { challenge in applyChallenge(challenge) }
            )
        }
    }

    /// D3: commit a parsed challenge through the client. Mirrors
    /// `PairingFlow.applyChallenge` so behavior is byte-for-byte
    /// identical to the retired surface.
    private func applyChallenge(_ challenge: PairingChallenge) {
        client.setPairing(
            host: challenge.host,
            httpPort: challenge.port,
            wsPort: challenge.wsPort,
            token: challenge.token
        )
        Task { @MainActor in
            await client.refreshAll()
        }
        onClose()
    }

    @ViewBuilder
    private func bracket(_ corner: UnitPoint) -> some View {
        let top = corner.y < 0.5
        let leading = corner.x < 0.5
        Path { p in
            let s: CGFloat = 32
            p.move(to: CGPoint(x: leading ? 0 : s, y: top ? s : 0))
            p.addLine(to: CGPoint(x: leading ? 0 : s, y: top ? 0 : s))
            p.addLine(to: CGPoint(x: leading ? s : 0, y: top ? 0 : s))
        }
        .stroke(t.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .frame(width: 32, height: 32)
        .shadow(color: t.accent.opacity(0.5), radius: 5, x: 0, y: 0)
        .offset(
            x: leading ? -6 : 286 + 6 - 32,
            y: top    ? -6 : 286 + 6 - 32
        )
        .position(x: 140 + (leading ? -150 : 150), y: 140 + (top ? -150 : 150))
    }
}

// MARK: - Paste URL sheet (D3)

/// D3 (v1.0 polish): paste-URL form lifted out of the legacy PairingFlow
/// so it can stand alone behind IOSPairingView's "Paste URL" affordance.
/// Parses the clawdmeter:// URL via PairingScannerView.parse and surfaces
/// errors inline.
private struct PasteURLSheet: View {
    @Binding var isPresented: Bool
    var onAccept: (PairingChallenge) -> Void

    @State private var pastedURL: String = ""
    @State private var pasteError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open Clawdmeter on your Mac → Settings → Sessions → Copy pairing URL. Then paste it below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(
                    "clawdmeter://host:21731?token=...&ws=21732",
                    text: $pastedURL,
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                if let error = pasteError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button("Pair") {
                    let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let challenge = PairingScannerView.parse(urlString: trimmed) else {
                        pasteError = "Not a valid clawdmeter:// URL"
                        return
                    }
                    onAccept(challenge)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Paste pairing URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - QR rendering

private struct QRView: View {
    @Environment(\.tahoe) private var t
    var content: String

    var body: some View {
        if let image = generateQR(content: content) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray
        }
    }

    private func generateQR(content: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(content.data(using: .utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let ctx = CIContext()
        return ctx.createCGImage(scaled, from: scaled.extent)
    }
}
