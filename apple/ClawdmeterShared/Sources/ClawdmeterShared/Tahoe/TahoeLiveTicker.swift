#if canImport(SwiftUI)
import SwiftUI

/// Composer running-state pill. While a session runs, the Send button becomes
/// this LiveTicker: a `surface-2` pill with a 1Hz `live` heartbeat dot, a mono
/// `$x.xxx · live` line, an optional `<tok/s> · <elapsed>` second line, and a
/// Stop control inside. (DESIGN.md "Composer" → LiveTicker.)
public struct TahoeLiveTicker: View {
    public var costText: String
    public var rateText: String?
    public var onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(costText: String, rateText: String? = nil, onStop: @escaping () -> Void) {
        self.costText = costText
        self.rateText = rateText
        self.onStop = onStop
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ContinuumTokens.live)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(costText) · live")
                    .font(ContinuumFont.mono(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(ContinuumTokens.fg)
                if let rateText {
                    Text(rateText)
                        .font(ContinuumFont.mono(9))
                        .monospacedDigit()
                        .foregroundStyle(ContinuumTokens.fg3)
                }
            }
            Button(action: ContinuumAnalytics.wrapButton("live_ticker_stop", onStop)) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ContinuumTokens.error)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(ContinuumTokens.error.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(ContinuumTokens.surface2)
                .overlay(Capsule(style: .continuous).strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5))
        }
        .onAppear {
            guard let anim = ContinuumMotion.heartbeat(reduceMotion: reduceMotion) else { return }
            withAnimation(anim) { pulse = true }
        }
    }
}

/// Mono digit-roll counter — signals live measurement. The caller drives value
/// changes inside `withAnimation`; under Reduce Motion it falls back to a plain
/// text set (no roll).
public struct TahoeOdometer: View {
    public var text: String
    public var size: CGFloat
    public var weight: Font.Weight
    public var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String, size: CGFloat = 12, weight: Font.Weight = .medium, color: Color = ContinuumTokens.fg) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(ContinuumFont.mono(size, weight: weight))
            .monospacedDigit()
            .foregroundStyle(color)
            .modifier(OdometerRoll(enabled: !reduceMotion))
    }
}

private struct OdometerRoll: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.contentTransition(.numericText())
        } else {
            content
        }
    }
}
#endif
