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

/// Prominent Tahoe-style desktop pairing/sync CTA for mobile tabs that
/// depend on the Mac daemon. The action always opens the real pairing flow:
/// when already paired it acts as a manage/repair affordance instead of a
/// passive status badge.
struct IOSDesktopPairingCTA: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    var compact: Bool = false
    var onPair: () -> Void

    private var connected: Bool { client.isDesktopEventSyncConnected }
    private var configured: Bool { client.isConfigured }

    var body: some View {
        Button(action: onPair) {
            TahoeGlass(radius: compact ? 16 : 20, tone: .raised) {
                HStack(spacing: compact ? 10 : 12) {
                    ZStack {
                        Circle()
                            .fill(statusFill)
                        TahoeIcon(connected ? "check" : "qr", size: compact ? 13 : 16, weight: .bold)
                            .foregroundStyle(.white)
                    }
                    .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(TahoeFont.body(compact ? 12.5 : 14, weight: .bold))
                            .foregroundStyle(t.fg)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(TahoeFont.body(compact ? 10.5 : 11.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(compact ? 1 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        Text(actionTitle)
                            .font(TahoeFont.body(compact ? 11 : 12, weight: .bold))
                        TahoeIcon("chevR", size: 10, weight: .bold)
                    }
                    .foregroundStyle(connected ? t.fg2 : .white)
                    .padding(.horizontal, compact ? 9 : 11)
                    .frame(height: compact ? 28 : 32)
                    .background(
                        connected ? AnyShapeStyle(t.glassTintHi) : AnyShapeStyle(LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom)),
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(connected ? t.hairline : Color.clear, lineWidth: 0.5)
                    }
                }
                .padding(.horizontal, compact ? 12 : 14)
                .padding(.vertical, compact ? 10 : 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Opens the Mac pairing screen.")
    }

    private var title: String {
        if connected { return "Desktop sync live" }
        if configured { return "Repair desktop sync" }
        return "Pair with desktop"
    }

    private var subtitle: String {
        if connected {
            return "Sessions, analytics, run preview, and terminal are streaming from your Mac."
        }
        if configured {
            return client.desktopEventSyncLastError ?? "Tap to re-pair or refresh the Mac connection."
        }
        return "Scan the Mac QR to unlock sessions, analytics, run preview, and terminal."
    }

    private var actionTitle: String {
        if connected { return "Manage" }
        if configured { return "Repair" }
        return "Pair now"
    }

    private var statusFill: AnyShapeStyle {
        if connected {
            return AnyShapeStyle(Color.green)
        }
        if configured {
            return AnyShapeStyle(Color.orange)
        }
        return AnyShapeStyle(LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom))
    }
}
