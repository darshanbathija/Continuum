import SwiftUI
import ClawdmeterShared

/// Continuum mark — three stacked arcs from the design `AppMark`.
struct ContinuumAppMark: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 58

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .trim(from: 0.08, to: 0.92)
                    .stroke(theme.fg.opacity(0.92 - Double(i) * 0.18), style: StrokeStyle(lineWidth: max(2.5, size * 0.045), lineCap: .round))
                    .rotationEffect(.degrees(Double(i) * 38 - 18))
                    .frame(width: size - CGFloat(i) * size * 0.14, height: size - CGFloat(i) * size * 0.14)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Post-scan pairing progress — mirrors design `Handshake`.
struct ContinuumPairingHandshakeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Transport { case cloud, tailscale }

    var transport: Transport
    var hostLabel: String
    var onEnter: () -> Void

    @State private var step = 0
    @State private var done = false

    private var steps: [String] {
        switch transport {
        case .cloud:
            return [
                "Opening relay session",
                "ECDH key exchange (X25519)",
                "Verifying Mac fingerprint",
                "Subscribing to live streams"
            ]
        case .tailscale:
            return [
                "Resolving Tailscale host",
                "Challenge–response over LAN",
                "Verifying pairing key",
                "Subscribing to live streams"
            ]
        }
    }

    private var transportLabel: String {
        transport == .cloud ? "Continuum Cloud" : "Tailscale"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ContinuumAppMark(size: 58)
            Text(done ? "Paired" : "Pairing…")
                .font(ContinuumFont.display(22, weight: .heavy))
                .tracking(-0.3)
                .foregroundStyle(theme.fg)
                .padding(.top, 22)
            HStack(spacing: 7) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.live)
                }
                Text(done ? "\(hostLabel) · \(transport == .cloud ? "relay" : "tailscale")" : "via \(transportLabel)")
                    .font(ContinuumFont.mono(11.5))
                    .foregroundStyle(theme.fg3)
            }
            .padding(.top, 7)

            VStack(alignment: .leading, spacing: 11) {
                ContinuumHandshakeProgressRail(fraction: done ? 1 : Double(step) / Double(max(steps.count, 1)))
                    .padding(.top, 26)

                ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                    let state: StepState = done || index < step ? .done : (index == step ? .active : .idle)
                    HStack(spacing: 10) {
                        stepIndicator(state)
                        Text(label)
                            .font(ContinuumFont.mono(12))
                            .foregroundStyle(state == .idle ? theme.fg4 : (state == .active ? theme.fg : theme.fg3))
                    }
                }
            }
            .frame(maxWidth: 290)
            .padding(.top, 8)

            if done {
                Button(action: ContinuumAnalytics.wrapButton("pairing_enter_continuum", onEnter)) {
                    Text("Enter Continuum")
                        .font(ContinuumFont.body(15.5, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(theme.primaryFill)
                        .clipShape(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 290)
                .padding(.top, 26)
            } else {
                Color.clear.frame(height: 76).padding(.top, 26)
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .onAppear { runSteps() }
    }

    private enum StepState { case done, active, idle }

    @ViewBuilder
    private func stepIndicator(_ state: StepState) -> some View {
        ZStack {
            if state == .done {
                Circle()
                    .fill(theme.live)
                    .frame(width: 16, height: 16)
                Text("✓")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.05))
            } else {
                Circle()
                    .strokeBorder(theme.hair2, lineWidth: 0.5)
                    .frame(width: 16, height: 16)
                if state == .active {
                    Circle()
                        .fill(theme.fg)
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    private func runSteps() {
        let stepDuration: UInt64 = reduceMotion ? 80_000_000 : 620_000_000
        Task { @MainActor in
            for i in 1...steps.count {
                try? await Task.sleep(nanoseconds: stepDuration)
                step = i
            }
            try? await Task.sleep(nanoseconds: reduceMotion ? 80_000_000 : 260_000_000)
            done = true
        }
    }
}

private struct ContinuumHandshakeProgressRail: View {
    @Environment(\.theme) private var theme
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(w * min(max(fraction, 0), 1), fraction > 0 ? 4 : 0)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous)
                    .fill(theme.railTrack)
                if fillW > 0 {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.55), Color.white.opacity(0.92)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillW)
                }
            }
        }
        .frame(height: 6)
    }
}
