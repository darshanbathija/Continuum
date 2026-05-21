import SwiftUI
import ClawdmeterShared

/// iOS Analytics tab. Period segmented + total card + mini chart + by-repo.
/// Ports `ios-other.jsx::IOSAnalytics`.
public struct IOSAnalyticsView: View {
    @Environment(\.tahoe) private var t
    @State private var window: String = "7d"

    public init() {}

    private var data: TahoeDemo.RangeData {
        switch window {
        case "1d":  return TahoeDemo.ranges["24h"]!
        case "7d":  return TahoeDemo.ranges["7d"]!
        case "30d": return TahoeDemo.ranges["30d"]!
        case "all": return TahoeDemo.ranges["all"]!
        default:    return TahoeDemo.ranges["7d"]!
        }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                IOSLargeTitle(title: "Analytics") {
                    IOSRoundIconBtn("sliders")
                }

                // Period segmented
                TahoeGlass(radius: 12, tone: .chip) {
                    HStack(spacing: 0) {
                        ForEach([("1d","Today"),("7d","7d"),("30d","30d"),("all","All")], id: \.0) { (k, label) in
                            let active = k == window
                            Button { window = k } label: {
                                Text(label)
                                    .font(TahoeFont.body(13, weight: .semibold))
                                    .foregroundStyle(active ? t.fg : t.fg2)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background {
                                        if active {
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.16) : .white)
                                                .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)

                // Total card
                TahoeGlass(radius: 22, tone: .raised) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("TOTAL · PAST 7D")
                            .font(TahoeFont.body(11, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(t.fg3)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(data.total.all)
                                .font(TahoeFont.rounded(42, weight: .heavy))
                                .monospacedDigit()
                                .tracking(-1)
                                .foregroundStyle(t.fg)
                            Text("\(data.total.delta) vs last week")
                                .font(TahoeFont.body(13, weight: .semibold))
                                .foregroundStyle(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                        }
                        .padding(.top, 6)

                        MiniSpendChart()
                            .padding(.top, 16)

                        HStack(spacing: 8) {
                            providerStat(.claude, data.total.c)
                            providerStat(.codex, data.total.x)
                            providerStat(.gemini, data.total.g)
                        }
                        .padding(.top, 16)
                    }
                    .padding(18)
                }
                .padding(.horizontal, 16)

                // By repo
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("BY REPO")
                            .font(TahoeFont.body(11, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(t.fg3)
                        Spacer()
                        Text("past 7d").font(TahoeFont.body(11)).foregroundStyle(t.fg3)
                    }
                    .padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 8)

                    TahoeGlass(radius: 22, tone: .raised) {
                        VStack(spacing: 0) {
                            let maxTotal = data.repos.map { $0.c + $0.x + $0.g }.max() ?? 1
                            ForEach(Array(data.repos.enumerated()), id: \.offset) { _, r in
                                let total = r.c + r.x + r.g
                                let width = total / maxTotal
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        HStack(spacing: 6) {
                                            TahoeIcon("folder", size: 12).foregroundStyle(t.fg3)
                                            Text(r.name).font(TahoeFont.body(13)).foregroundStyle(t.fg)
                                        }
                                        Spacer()
                                        Text(String(format: "$%.2f", total))
                                            .font(TahoeFont.mono(12))
                                            .monospacedDigit()
                                            .foregroundStyle(t.fg2)
                                    }
                                    GeometryReader { geo in
                                        HStack(spacing: 0) {
                                            Rectangle().fill(grad(.claude)).frame(width: geo.size.width * width * (r.c / total))
                                            Rectangle().fill(grad(.codex)).frame(width: geo.size.width * width * (r.x / total))
                                            Rectangle().fill(grad(.gemini)).frame(width: geo.size.width * width * (r.g / total))
                                            Spacer()
                                        }
                                    }
                                    .frame(height: 8)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                }
                                .padding(.horizontal, 4).padding(.vertical, 10)
                            }
                        }
                        .padding(14)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
    }

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.glow.color, p.base.color], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private func providerStat(_ p: TahoeProvider, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TahoeProviderGlyph(provider: p, size: 14)
                Text(p.displayName)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            Text(value)
                .font(TahoeFont.rounded(16, weight: .bold))
                .monospacedDigit()
                .tracking(-0.3)
                .foregroundStyle(t.fg)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.hair2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }
}

private struct MiniSpendChart: View {
    @Environment(\.tahoe) private var t
    private struct D { let d: String; let c: Double; let x: Double; let g: Double }
    private let data: [D] = [
        D(d: "Mon", c: 3.2, x: 1.4, g: 0.4),
        D(d: "Tue", c: 4.1, x: 2.2, g: 0.5),
        D(d: "Wed", c: 5.6, x: 1.8, g: 0.6),
        D(d: "Thu", c: 2.8, x: 0.9, g: 0.3),
        D(d: "Fri", c: 4.4, x: 2.6, g: 0.7),
        D(d: "Sat", c: 1.6, x: 0.8, g: 0.2),
        D(d: "Sun", c: 2.5, x: 2.2, g: 0.5),
    ]

    var body: some View {
        let maxV: Double = 9
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                let total = d.c + d.x + d.g
                let h = total / maxV * 70
                VStack(spacing: 4) {
                    VStack(spacing: 0) {
                        Rectangle().fill(grad(.gemini)).frame(height: d.g / total * h)
                        Rectangle().fill(grad(.codex)).frame(height: d.x / total * h)
                        Rectangle().fill(grad(.claude)).frame(height: d.c / total * h)
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(String(d.d.prefix(1)))
                        .font(TahoeFont.body(9))
                        .foregroundStyle(t.fg4)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 80)
    }

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.glow.color, p.base.color], startPoint: .top, endPoint: .bottom)
    }
}
