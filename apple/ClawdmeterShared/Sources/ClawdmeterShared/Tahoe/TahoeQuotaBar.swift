#if canImport(SwiftUI)
import SwiftUI

/// Pill-bar gauge — replaces the original "QuotaOrb" ring (the chat history
/// explicitly pivoted to bars in chat2). JSX: `mac-dashboard.jsx::QuotaOrb`
/// with `dense` variant for menu-bar contexts.
public struct TahoeQuotaBar: View {
    @Environment(\.tahoe) private var t
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

    public var body: some View {
        if dense {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(percent))")
                        .font(TahoeFont.rounded(22, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(t.fg)
                    Text("%")
                        .font(TahoeFont.body(11, weight: .semibold))
                        .foregroundStyle(t.fg3)
                }
                TahoePillBar(percent: percent, provider: provider, height: 6)
            }
            .frame(width: size, alignment: .leading)
        } else {
            let numSize = size * 0.36
            VStack(alignment: .leading, spacing: size * 0.08) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(percent))")
                            .font(TahoeFont.rounded(numSize, weight: .bold))
                            .monospacedDigit()
                            .tracking(-1.5)
                            .foregroundStyle(t.fg)
                        Text("%")
                            .font(TahoeFont.body(numSize * 0.42, weight: .semibold))
                            .foregroundStyle(t.fg3)
                    }
                    Spacer(minLength: 8)
                    if let label {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(label.uppercased())
                                .font(TahoeFont.body(10.5, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(t.fg3)
                            if let sublabel {
                                Text(sublabel)
                                    .font(TahoeFont.body(10.5))
                                    .foregroundStyle(t.fg4)
                            }
                        }
                    }
                }
                TahoePillBar(percent: percent, provider: provider, height: 6)
            }
            .frame(maxWidth: size * 1.6, alignment: .leading)
        }
    }
}

/// Single horizontal pill bar — matches the weekly bar geometry.
public struct TahoePillBar: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public var percent: Double
    public var provider: TahoeProvider
    public var height: CGFloat

    public init(percent: Double, provider: TahoeProvider, height: CGFloat = 6) {
        self.percent = max(0, min(100, percent))
        self.provider = provider
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.12)
                                 : Color(.sRGB, white: 15.0/255, opacity: 0.08))
                Capsule(style: .continuous)
                    // v0.22.16: was `[glow, base]` which for Codex
                    // resolved to `[gray, near-black]` — invisible
                    // against the dark popover background. Now uses
                    // the vivid `halo` color (the same color used for
                    // each provider's outer-glow accent) as the
                    // gradient anchor so every provider's fill is
                    // legible even at 6pt height. Claude → bright
                    // orange, Codex → OpenAI cool blue, Antigravity →
                    // vivid violet, OpenCode → magenta-violet.
                    .fill(LinearGradient(
                        colors: [provider.halo.color, provider.glow.color],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.width * percent / 100,
                                      percent > 0 ? max(height, 4) : 0))
                    .shadow(color: provider.halo.color(opacity: 0.45), radius: 5, x: 0, y: 0)
                    // Motion polish: smooth fill-in when percent changes.
                    // Respects `accessibilityReduceMotion` so users who
                    // have asked the system to dampen animation get an
                    // instant jump-cut instead of the 0.45s easeInOut.
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45),
                               value: percent)
            }
        }
        .frame(height: height)
    }
}

/// Menu bar popover meter — label + percent + bar + hint, all stacked.
public struct TahoeMenuBarMeter: View {
    @Environment(\.tahoe) private var t
    public var label: String
    public var percent: Double
    public var hint: String?
    public var provider: TahoeProvider
    /// v0.22.18: true when the underlying data is from a fallback /
    /// cached source instead of a live poll. Triggers a small "Stale"
    /// pill next to the percent so the user knows the value may not
    /// match what each provider's own desktop app shows in real time.
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
                Text(label)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg2)
                if stale {
                    Text("STALE")
                        .font(TahoeFont.body(8.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color(.sRGB, red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color(.sRGB, red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0, opacity: 0.14))
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(Color(.sRGB, red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0, opacity: 0.40), lineWidth: 0.5)
                        }
                        .help("Underlying source is using cached / fallback data — value may not match the provider's live count.")
                }
                Spacer()
                Text("\(Int(percent))%")
                    .font(TahoeFont.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(t.fg2)
            }
            TahoePillBar(percent: percent, provider: provider, height: 6)
            if let hint {
                Text(hint)
                    .font(TahoeFont.mono(10))
                    .foregroundStyle(t.fg3)
                    .padding(.top, 2)
            }
        }
    }
}
#endif
