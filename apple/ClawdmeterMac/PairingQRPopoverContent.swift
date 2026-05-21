import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// Compact pairing UI used by the dashboard's "Sync with iPhone"
/// toolbar button. Shows the QR code + a Copy URL CTA so users don't
/// have to dig into Settings → Sessions to pair a phone.
///
/// Mirrors the host/port/token wiring in `PairingSettingsView` but
/// strips the supervisor / security / scan-roots / plugins panes so
/// the popover stays the right size for a chrome dropdown. The
/// regenerate + revoke controls still live in Settings — keeping the
/// dashboard popover focused on the happy path makes "first-time
/// pair" feel like a one-click action.
struct PairingQRPopoverContent: View {

    @ObservedObject var runtime: AppRuntime
    @State private var qrImage: NSImage?
    @State private var tokenForDisplay: String = ""
    @State private var didCopy: Bool = false
    @State private var hostName: String = "127.0.0.1"
    @State private var hostKind: TailscaleHost.Resolved.Kind = .loopback

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair iPhone")
                .font(.system(size: 15, weight: .semibold))

            if let httpPort = runtime.agentControlServer.boundPort,
               let wsPort = runtime.agentControlServer.boundWsPort {
                VStack(spacing: 12) {
                    qrTile
                        .frame(maxWidth: .infinity)

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
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        labelRow("Host", value: hostName)
                        labelRow("Ports", value: "\(httpPort) / \(wsPort)")
                        labelRow("Token", value: String(tokenForDisplay.prefix(8)) + "…")
                    }
                    .padding(.top, 4)

                    hostWarning
                }
            } else {
                Label("Daemon not running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { refresh() }
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

    @ViewBuilder
    private var hostWarning: some View {
        switch hostKind {
        case .loopback:
            warningRow("No Tailscale address detected. Pairing will only work for the iOS simulator on this Mac. Install Tailscale and sign in to pair a real iPhone.")
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
                .font(.system(size: 11))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func labelRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
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
        guard let url = pairingURLString() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            didCopy = false
        }
    }

    // MARK: - Helpers

    private func refresh() {
        tokenForDisplay = PairingTokenStore.shared.currentToken()
        let resolved = TailscaleHost.resolve()
        hostName = resolved.host
        hostKind = resolved.kind
        qrImage = pairingURLString().flatMap { generateQR(from: $0) }
    }

    private func pairingURLString() -> String? {
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort else { return nil }
        var url = "clawdmeter://\(hostName):\(httpPort)?token=\(tokenForDisplay)&ws=\(wsPort)"
        // v0.14.0 (plan v2.1): include Design routing fields when the
        // daemon is ready. iOS older builds ignore unknown query keys.
        // Use the current bearer token as the pairing-id input. When the
        // user revokes / regenerates the pairing, currentToken() changes
        // and the derived designToken changes with it — automatic
        // rotation (v2.1 T19).
        if let designPort = runtime.openDesignDaemon.bridgePortAtomic.get(),
           let designToken = runtime.openDesignDaemon.deriveDesignToken(
               forPairingId: PairingTokenStore.shared.currentToken()
           ) {
            url += "&dp=\(designPort)&dt=\(designToken)"
        }
        return url
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
}

