import SwiftUI
import ClawdmeterShared

/// Reusable side-by-side "Scan QR" + "Paste URL" CTA used by every iOS
/// empty state that needs the user to pair with a Mac: Sessions tab,
/// Analytics tab, and the Codex card on the Live tab. Each tap opens the
/// Tahoe `IOSPairingView` sheet — D3 retired the legacy `PairingFlow`,
/// so both buttons present the same sheet (the segmented picker is gone,
/// the new view exposes both Scan + Paste from one screen).
struct PairingCTAButtons: View {
    @ObservedObject var client: AgentControlClient

    /// Lets the caller pick a more compact button style when space is
    /// tight (Codex card on the Live tab). Default is the prominent
    /// terra-cotta pill the Sessions empty state uses.
    var compact: Bool = false

    @State private var showingPairing: Bool = false

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                showingPairing = true
            } label: {
                Label("Scan QR", systemImage: "qrcode.viewfinder")
                    .font(compact ? .subheadline.bold() : .headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 8 : 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(terraCotta)

            Button {
                showingPairing = true
            } label: {
                Label("Paste URL", systemImage: "doc.on.clipboard")
                    .font(compact ? .subheadline.bold() : .headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 8 : 10)
            }
            .buttonStyle(.bordered)
            .tint(terraCotta)
        }
        .sheet(isPresented: $showingPairing) {
            // D3: present the full-screen IOSPairingView. The sheet's
            // onClose dismisses both the pairing screen + the sheet
            // wrapper. The TahoeWallpaperView background ensures the
            // sheet renders correctly outside the IOSRootView ZStack.
            ZStack {
                TahoeWallpaperView()
                IOSPairingView(
                    client: client,
                    onClose: { showingPairing = false }
                )
            }
            .background(Color.black.opacity(0.001))
        }
    }
}
