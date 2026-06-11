#if canImport(SwiftUI)
import SwiftUI

/// The signature **rail meter** card — a big SF Pro Rounded `%`, an etched
/// label, and the horizontal rail. Length is the signal; hue never carries the
/// reading. (Was the ring "QuotaOrb"; the chat history pivoted to bars and this
/// is now the canonical rail.)
public struct TahoeQuotaBar: View {
    @Environment(\.theme) private var t
    public var percent: Double  // 0..100
    public var size: CGFloat
    public var label: String?
    public var sublabel: String?
    public var provider: TahoeProvider
    public var dense: Bool

    public init(
        provider: TahoeProvider,
        percent: Double,
        size: CGFloat = 260,
        label: String? = nil,
        sublabel: String? = nil,
        dense: Bool = false
    ) {
        self.provider = provider
        self.percent = max(0, min(100, percent))
        self.size = size
        self.label = label
        self.sublabel = sublabel
        self.dense = dense
    }

    /// The current `%` is the loudest element on the card; it adopts warn/error
    /// past the thresholds.
    private var metricColor: Color { ContinuumTokens.metricColor(percent: percent) }

    public var body: some View {
        if dense {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(percent))")
                        .font(ContinuumFont.display(22, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(metricColor)
                    Text("%")
                        .font(ContinuumFont.body(11, weight: .semibold))
                        .foregroundStyle(ContinuumTokens.fg3)
                }
                TahoeRailMeter(percent: percent, provider: provider)
            }
            .frame(width: size, alignment: .leading)
        } else {
            let numSize = size * 0.36
            VStack(alignment: .leading, spacing: size * 0.08) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(percent))")
                            .font(ContinuumFont.display(numSize, weight: .bold))
                            .monospacedDigit()
                            .tracking(-1.5)
                            .foregroundStyle(metricColor)
                        Text("%")
                            .font(ContinuumFont.display(numSize * 0.5, weight: .semibold))
                            .foregroundStyle(ContinuumTokens.fg3)
                    }
                    Spacer(minLength: 8)
                    if let label {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(label.uppercased())
                                .font(ContinuumFont.etched(10.5))
                                .tracking(0.95)               // ~0.09em at 10.5px
                                .foregroundStyle(ContinuumTokens.fg3)
                            if let sublabel {
                                Text(sublabel)
                                    .font(ContinuumFont.mono(10.5))
                                    .foregroundStyle(ContinuumTokens.fg4)
                            }
                        }
                    }
                }
                TahoeRailMeter(percent: percent, provider: provider)
            }
            // Fill the parent column so rail width stays consistent when
            // sublabels differ ("resets in 3h 31m" vs "usage limit").
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The rail meter (treatment **T2**). Track 7px `#202126` + 0.5px inset
/// hairline; provider gradient fill (radius 3) with a 1px lit top edge; an 80%
/// limit tick; the portion past the tick caps to warn (then error). Secondary
/// (weekly) variant uses the same fill at half opacity with no tick. Length is
/// the signal; the fill before the tick never recolors. Settles like a
/// galvanometer needle.
public struct TahoeRailMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public var percent: Double
    public var provider: TahoeProvider
    public var height: CGFloat
    /// Weekly / secondary meter — same fill @0.5 opacity, no limit tick.
    public var secondary: Bool

    public init(percent: Double, provider: TahoeProvider, height: CGFloat = 7, secondary: Bool = false) {
        self.percent = max(0, min(100, percent))
        self.provider = provider
        self.height = height
        self.secondary = secondary
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let tickX = w * ContinuumTokens.warnTickFraction
            // Provider fill never recolors past the tick: it runs to min(pct,80%).
            let providerPct = min(percent, ContinuumTokens.warnTickFraction * 100)
            let providerW = fillWidth(providerPct, w)
            // Cap segment for the region beyond the 80% tick.
            let capEndPct = min(percent, 100)
            let capStartX = tickX
            let capEndX = w * capEndPct / 100
            let capW = max(0, capEndX - capStartX)
            let capGradient: LinearGradient = percent > 100 ? ProviderFill.error : ProviderFill.warn
            let filledW = max(providerW, percent > ContinuumTokens.warnTickFraction * 100 ? capEndX : providerW)

            ZStack(alignment: .leading) {
                Rectangle().fill(ContinuumTokens.railTrack)
                Rectangle()
                    .fill(ProviderFill.gradient(for: provider))
                    .opacity(secondary ? 0.5 : 1)
                    .frame(width: providerW)
                if !secondary, capW > 0 {
                    Rectangle()
                        .fill(capGradient)
                        .frame(width: capW)
                        .offset(x: capStartX)
                }
                // 1px lit top edge over the filled region.
                if filledW > 0 {
                    Rectangle()
                        .fill(ContinuumTokens.railLitEdge)
                        .frame(width: filledW, height: 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                // 80% limit tick.
                if !secondary {
                    Rectangle()
                        .fill(ContinuumTokens.fg3)
                        .frame(width: 1)
                        .offset(x: tickX)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous)
                    .strokeBorder(ContinuumTokens.railTrackInset, lineWidth: 0.5)
            )
            .animation(ContinuumMotion.settle(reduceMotion: reduceMotion), value: percent)
        }
        .frame(height: height)
    }

    private func fillWidth(_ pct: Double, _ w: CGFloat) -> CGFloat {
        guard pct > 0 else { return 0 }
        return max(w * pct / 100, max(height, 4))
    }
}

/// Back-compat alias — older call sites construct `TahoePillBar`. It is now the
/// rail meter. (Default height bumped 6 → 7 per DESIGN.md.)
public struct TahoePillBar: View {
    public var percent: Double
    public var provider: TahoeProvider
    public var height: CGFloat
    public var secondary: Bool

    public init(percent: Double, provider: TahoeProvider, height: CGFloat = 7, secondary: Bool = false) {
        self.percent = percent
        self.provider = provider
        self.height = height
        self.secondary = secondary
    }

    public var body: some View {
        TahoeRailMeter(percent: percent, provider: provider, height: height, secondary: secondary)
    }
}

/// Menu-bar popover meter — label + percent + rail + hint, stacked. Dense mono
/// numerics on the compact operational surface.
public struct TahoeMenuBarMeter: View {
    @Environment(\.theme) private var t
    public var label: String
    public var percent: Double
    public var hint: String?
    public var provider: TahoeProvider
    public var stale: Bool

    public init(
        label: String,
        percent: Double,
        hint: String? = nil,
        provider: TahoeProvider,
        stale: Bool = false
    ) {
        self.label = label
        self.percent = percent
        self.hint = hint
        self.provider = provider
        self.stale = stale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProviderDot(provider, size: 6)
                Text(label)
                    .font(ContinuumFont.body(11, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg2)
                if stale {
                    Text("STALE")
                        .font(ContinuumFont.etched(8.5))
                        .tracking(0.6)
                        .foregroundStyle(ContinuumTokens.warn)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(ContinuumTokens.warn.opacity(0.40), lineWidth: 0.5)
                        }
                        .help("Underlying source is using cached / fallback data — value may not match the provider's live count.")
                }
                Spacer()
                Text("\(Int(percent))%")
                    .font(ContinuumFont.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(ContinuumTokens.metricColor(percent: percent))
            }
            TahoeRailMeter(percent: percent, provider: provider, height: 7)
            if let hint {
                Text(hint)
                    .font(ContinuumFont.mono(10))
                    .foregroundStyle(ContinuumTokens.fg3)
                    .padding(.top, 2)
            }
        }
    }
}
#endif
