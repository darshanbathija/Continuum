import SwiftUI
import AppKit
import ClawdmeterShared

/// Step 1 of Mac → iPhone pairing: choose Cloud or Tailscale, scan a QR to
/// download Continuum Console from the App Store, then continue to the
/// transport-specific pairing QR.
struct PairingDownloadAppStep: View {

    enum Layout {
        case settings
        case popover
    }

    let layout: Layout
    let onConfirmInstall: () -> Void

    @AppStorage(PairingMode.storageKey) private var pairingModeRaw: String = PairingMode.cloud.rawValue
    @State private var downloadQR: NSImage?
    @Environment(\.tahoe) private var t

    private var pairingMode: Binding<PairingMode> {
        Binding(
            get: { PairingMode(rawValue: pairingModeRaw) ?? .cloud },
            set: { pairingModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        switch layout {
        case .settings:
            settingsLayout
        case .popover:
            popoverLayout
        }
    }

    private var settingsLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            PairingModePicker(mode: pairingMode, layout: .settings)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install Continuum Console")
                        .font(.headline)
                    Text(downloadStepCopy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    confirmButton
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                downloadQRTile(showCornerBrackets: false)
            }
        }
        .onAppear { refreshDownloadQR() }
    }

    private var popoverLayout: some View {
        VStack(spacing: 12) {
            PairingModePicker(mode: pairingMode, layout: .compact)
            downloadQRTile(showCornerBrackets: true)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("Scan to download Continuum Console")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(downloadStepCopy)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            confirmButton
        }
        .onAppear { refreshDownloadQR() }
    }

    private var downloadStepCopy: String {
        switch pairingMode.wrappedValue {
        case .cloud:
            return "Install the iPhone app from the App Store, then scan the Continuum Cloud pairing QR."
        case .tailscale:
            return "Install the iPhone app from the App Store, then scan the Tailscale pairing QR."
        }
    }

    private var confirmButton: some View {
        Button(action: ContinuumAnalytics.wrapButton("pairing_confirm_app_installed", onConfirmInstall)) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                Text("I've installed the app")
            }
            .frame(maxWidth: layout == .popover ? .infinity : nil)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(t.accent)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private func downloadQRTile(showCornerBrackets: Bool) -> some View {
        if showCornerBrackets {
            ZStack {
                qrImageTile
                ForEach(cornerSpecs, id: \.self) { spec in
                    PairingQRCornerBracket(spec: spec, color: t.accent)
                }
            }
            .frame(width: 280, height: 280)
        } else {
            qrImageTile
                .frame(width: 280, height: 280)
        }
    }

    private var qrImageTile: some View {
        Group {
            if let qr = downloadQR {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 224, height: 224)
                    .accessibilityLabel("App Store download QR code")
                    .accessibilityHint("Scan with your iPhone camera to download Continuum Console.")
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
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

    private func refreshDownloadQR() {
        downloadQR = PairingQRGenerator.makeImage(from: ContinuumIOSAppStore.downloadURL)
    }
}
