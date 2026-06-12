import SwiftUI
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// iOS Pairing flow — QR viewport with halo brackets + paste URL row +
/// Scan QR button. Ports `ios-other.jsx::IOSPairing`.
///
/// Users choose Continuum Cloud or Tailscale to match the pairing QR shown
/// on the Mac, then scan or paste the transport-specific URL.
///
/// Success states:
///   - relay path lands the user in `.readyButNotConnected` (E4 brings
///     the actual WS open)
///   - legacy path lands the user in the existing AgentControlClient
///     `setPairing(...)` configured state (Tailscale-direct)
public struct IOSPairingView: View {
    @Environment(\.tahoe) private var t
    var onClose: () -> Void

    /// Daemon client — used by the Tailscale path. The Cloud relay
    /// path persists into `RelayPairingStore` directly.
    @ObservedObject private var client: AgentControlClient

    @ObservedObject private var relayService: IOSRelayPairingService

    @AppStorage(PairingMode.storageKey) private var pairingModeRaw: String = PairingMode.cloud.rawValue
    @State private var relayScanPresented: Bool = false
    @State private var relayPastePresented: Bool = false
    @State private var legacyScanPresented: Bool = false
    @State private var legacyPastePresented: Bool = false

    private var pairingMode: Binding<PairingMode> {
        Binding(
            get: { PairingMode(rawValue: pairingModeRaw) ?? .cloud },
            set: { pairingModeRaw = $0.rawValue }
        )
    }

    public init(client: AgentControlClient, onClose: @escaping () -> Void) {
        self.client = client
        self.onClose = onClose
        self.relayService = .shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            scrim
            Spacer(minLength: 0)
            ctaSection
        }
        // Relay scan (primary).
        .fullScreenCover(isPresented: $relayScanPresented) {
            PairingScanView(service: relayService) { result in
                relayScanPresented = false
                if case .success = result {
                    applyTransportPreference(for: .cloud)
                    onClose()
                }
            }
        }
        // Relay paste (accessibility / simulator fallback).
        .sheet(isPresented: $relayPastePresented) {
            PairingPasteURLSheet(
                isPresented: $relayPastePresented,
                onAccept: { url in
                    let ok = relayService.handleScannedURL(url)
                    if ok {
                        applyTransportPreference(for: .cloud)
                        onClose()
                    }
                }
            )
        }
        // Legacy Tailscale scan.
        .sheet(isPresented: $legacyScanPresented) {
            NavigationStack {
                PairingScannerView { challenge in
                    applyLegacyChallenge(challenge)
                    legacyScanPresented = false
                }
                .navigationTitle("Scan Tailscale QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel", action: ContinuumAnalytics.wrapButton(
                                "cancel",
                                {
 legacyScanPresented = false 
                                }
                            ))
                    }
                }
            }
        }
        // Legacy Tailscale paste.
        .sheet(isPresented: $legacyPastePresented) {
            LegacyPasteURLSheet(
                isPresented: $legacyPastePresented,
                onAccept: { challenge in applyLegacyChallenge(challenge) }
            )
        }
        .onChange(of: pairingModeRaw) { _, newValue in
            let mode = PairingMode(rawValue: newValue) ?? .cloud
            applyTransportPreference(for: mode)
        }
        .onAppear {
            applyTransportPreference(for: pairingMode.wrappedValue)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: ContinuumAnalytics.wrapButton("pairing_close", onClose)) {
                TahoeIcon("x", size: 15).foregroundStyle(t.fg)
                    .frame(width: 44, height: 44)
                    .background { Capsule().fill(t.glassTintHi) }
                    .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel pairing")
            Spacer()
            Text("Pair to Mac")
                .font(TahoeFont.body(15, weight: .bold))
                .foregroundStyle(t.fg)
            Spacer()
            Color.clear.frame(width: 40, height: 38)
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
    }

    // MARK: - Scrim (the always-visible viewfinder hint)

    private var scrim: some View {
        VStack(spacing: 14) {
            iosPairingModePicker
            ZStack {
                RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .fill(RadialGradient(colors: [.clear, .clear],
                                         center: .center, startRadius: 0, endRadius: 220))
                    .blur(radius: 10).padding(-30).allowsHitTesting(false)

                TahoeGlass(radius: 8, tone: .raised) {
                    VStack(spacing: 10) {
                        TahoeIcon("qr", size: 54).foregroundStyle(t.fg4)
                        Text("Scan the live QR")
                            .font(TahoeFont.body(14, weight: .bold))
                            .foregroundStyle(t.fg2)
                        Text(scrimSubtitle)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 200)
                    }
                    .padding(28)
                }
                .frame(width: 280, height: 280)

                bracket(.topLeading)
                bracket(.topTrailing)
                bracket(.bottomLeading)
                bracket(.bottomTrailing)
            }
            .frame(width: 280, height: 280)
        }
        .padding(.top, 12)
    }

    private var scrimSubtitle: String {
        switch pairingMode.wrappedValue {
        case .cloud:
            return relayService.hasActivePairing
                ? "Already paired. Scan again to re-pair with a different Mac."
                : "Scan the Continuum Cloud QR shown by Clawdmeter on your Mac."
        case .tailscale:
            return client.isConfigured
                ? "Already paired. Scan again to re-pair with a different Mac."
                : "Scan the Tailscale QR shown by Clawdmeter on your Mac."
        }
    }

    private var iosPairingModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Pairing method", selection: pairingMode) {
                ForEach(PairingMode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Pairing method")

            Text(pairingMode.wrappedValue.subtitle)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - CTAs

    private var ctaSection: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Text("Point your camera at the QR")
                    .font(TahoeFont.rounded(18, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(t.fg)
                Text(ctaInstructions)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)

            VStack(spacing: 10) {
                switch pairingMode.wrappedValue {
                case .cloud:
                    cloudCTAs
                case .tailscale:
                    tailscaleCTAs
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
    }

    private var ctaInstructions: String {
        switch pairingMode.wrappedValue {
        case .cloud:
            return "Open Clawdmeter on your Mac → Settings → Devices → Pair iPhone, choose Continuum Cloud, then scan the pairing QR."
        case .tailscale:
            return "Open Clawdmeter on your Mac → Settings → Devices → Pair iPhone, choose Tailscale, then scan the pairing QR. Both devices must be on the same Tailnet."
        }
    }

    private var cloudCTAs: some View {
        Group {
            Button(action: ContinuumAnalytics.wrapButton("cloud_paste_url", { relayPastePresented = true })) {
                TahoeGlass(radius: 6, tone: .chip) {
                    HStack(spacing: 10) {
                        TahoeIcon("link", size: 15).foregroundStyle(t.fg3)
                        Text("clawdmeter-pair://v1/…")
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
            .accessibilityLabel("Paste Cloud pairing URL")

            Button(action: ContinuumAnalytics.wrapButton("cloud_scan_qr", { relayScanPresented = true })) {
                TahoeAccentButton(size: .l) {
                    HStack(spacing: 6) {
                        TahoeIcon("qr", size: 14)
                        Text("Scan QR")
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Scan Cloud pairing QR")
        }
    }

    private var tailscaleCTAs: some View {
        Group {
            Button(action: ContinuumAnalytics.wrapButton("tailscale_paste_url", { legacyPastePresented = true })) {
                TahoeGlass(radius: 6, tone: .chip) {
                    HStack(spacing: 10) {
                        TahoeIcon("link", size: 15).foregroundStyle(t.fg3)
                        Text("clawdmeter://host:port?…")
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
            .accessibilityLabel("Paste Tailscale pairing URL")

            Button(action: ContinuumAnalytics.wrapButton("tailscale_scan_qr", { legacyScanPresented = true })) {
                TahoeAccentButton(size: .l) {
                    HStack(spacing: 6) {
                        TahoeIcon("qr", size: 14)
                        Text("Scan QR")
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Scan Tailscale pairing QR")
        }
    }

    // MARK: - Tailscale apply

    private func applyLegacyChallenge(_ challenge: PairingChallenge) {
        applyTransportPreference(for: .tailscale)
        client.setPairing(
            host: challenge.host,
            httpPort: challenge.port,
            wsPort: challenge.wsPort,
            token: challenge.token
        )
        PostHogIdentity.onDirectPairingCompleted()
        Task { @MainActor in
            await client.refreshAll()
        }
        onClose()
    }

    private func applyTransportPreference(for mode: PairingMode) {
        RelayTransportFlag.setRelayDefault(mode.prefersRelayTransport)
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

// MARK: - Tailscale paste sheet

private struct LegacyPasteURLSheet: View {
    @Binding var isPresented: Bool
    var onAccept: (PairingChallenge) -> Void

    @State private var pastedURL: String = ""
    @State private var pasteError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tailscale pairing — paste the `clawdmeter://` URL shown on your Mac.")
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
                .accessibilityLabel("Legacy pairing URL")
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                if let error = pasteError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button("Pair", action: ContinuumAnalytics.wrapButton(
                        "pair",
                        {
                    let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let challenge = PairingScannerView.parse(urlString: trimmed) else {
                        pasteError = "Not a valid clawdmeter:// URL"
                        return
                    }
                    onAccept(challenge)
                    isPresented = false
                
                        }
                    ))
                .buttonStyle(.borderedProminent)
                .tint(SessionsV2Theme.accent)
                .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Paste Tailscale URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel", action: ContinuumAnalytics.wrapButton(
                            "cancel",
                            {
 isPresented = false 
                            }
                        ))
                }
            }
        }
    }
}
