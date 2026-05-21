import SwiftUI
import ClawdmeterShared

/// iOS Session Detail — pushed from the Code list. Nav bar chip + thread +
/// PlanHaloMini + composer. Ports `ios-other.jsx::IOSSessionDetail`.
public struct IOSSessionDetailView: View {
    @Environment(\.tahoe) private var t
    var onBack: () -> Void

    public init(onBack: @escaping () -> Void) { self.onBack = onBack }

    public var body: some View {
        VStack(spacing: 0) {
            // Custom nav bar
            HStack(spacing: 10) {
                Button(action: onBack) {
                    TahoeIcon("chevL", size: 16).foregroundStyle(t.fg)
                        .frame(width: 40, height: 38)
                        .background { Capsule().fill(t.glassTintHi) }
                        .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
                }
                .buttonStyle(.plain)

                TahoeGlass(radius: 14, tone: .chip) {
                    HStack(spacing: 9) {
                        TahoeProviderGlyph(provider: .claude, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Refactor settlement store dedupe")
                                .font(TahoeFont.body(12.5, weight: .bold))
                                .foregroundStyle(t.fg)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Circle().fill(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                                    .frame(width: 7, height: 7)
                                    .shadow(color: Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), radius: 3, x: 0, y: 0)
                                Text("running · Sonnet 4.5 · plan")
                                    .font(TahoeFont.body(10.5))
                                    .foregroundStyle(t.fg3)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)

                IOSRoundIconBtn("sliders")
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

            // Thread
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(TahoeDemo.thread.enumerated()), id: \.offset) { _, msg in
                        IOSThreadMsg(msg: msg)
                    }
                    IOSPlanHaloMini()
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            // Composer
            TahoeGlass(radius: 22, tone: .raised) {
                HStack(spacing: 8) {
                    TahoeIcon("plus", size: 18).foregroundStyle(t.fg3)
                    Text("Refine the plan…")
                        .font(TahoeFont.body(14))
                        .foregroundStyle(t.fg3)
                    Spacer()
                    TahoeIcon("mic", size: 16).foregroundStyle(t.fg3)
                    Button(action: {}) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                         startPoint: .top, endPoint: .bottom))
                            TahoeIcon("arrowU", size: 16, weight: .bold).foregroundStyle(.white)
                        }
                        .frame(width: 38, height: 38)
                        .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 10)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 14)
        }
    }
}

private struct IOSThreadMsg: View {
    @Environment(\.tahoe) private var t
    var msg: TahoeDemo.DemoThreadMsg

    var body: some View {
        switch msg {
        case .user(let text):
            HStack {
                Spacer()
                TahoeGlass(radius: 20, tone: .raised) {
                    Text(text)
                        .font(TahoeFont.body(13))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity * 0.82, alignment: .trailing)
            }
        case .tool(let tool, let target, _):
            HStack(spacing: 8) {
                TahoeIcon(tool == "grep" ? "search" : "doc", size: 11).foregroundStyle(t.fg3)
                Text(tool).font(TahoeFont.body(11.5, weight: .semibold)).foregroundStyle(t.fg2)
                Text(target).font(TahoeFont.mono(11)).foregroundStyle(t.fg3).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        case .assistant(let text):
            HStack(alignment: .top, spacing: 9) {
                TahoeProviderGlyph(provider: .claude, size: 24)
                Text(text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }
}

private struct IOSPlanHaloMini: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(RadialGradient(
                    colors: [t.accentGlow.color(opacity: 0.30), .clear],
                    center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 400))
                .blur(radius: 6).padding(-20).allowsHitTesting(false)

            TahoeGlass(radius: 20, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 26, height: 26)
                            .overlay { TahoeIcon("sparkles", size: 13).foregroundStyle(.white) }
                            .shadow(color: t.accentDeep.color(opacity: 0.35), radius: 6, x: 0, y: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("PLAN READY")
                                .font(TahoeFont.body(11, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(t.fg3)
                            Text("5 steps · ~$0.18")
                                .font(TahoeFont.body(13, weight: .bold))
                                .foregroundStyle(t.fg)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(TahoeDemo.plan.prefix(3).enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 9) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(t.hair2)
                                    Text("\(i+1)").font(TahoeFont.mono(10, weight: .bold)).foregroundStyle(t.fg2)
                                }
                                .frame(width: 18, height: 18)
                                Text(step)
                                    .font(TahoeFont.body(12.5))
                                    .foregroundStyle(t.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("+ 2 more steps…")
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                            .padding(.leading, 27)
                    }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

                    TahoeHair()

                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .l) { Text("Refine") }
                            .frame(maxWidth: .infinity)
                        TahoeAccentButton(size: .l) { Text("Approve & run") }
                            .frame(maxWidth: .infinity * 2)
                    }
                    .padding(10)
                }
            }
        }
        .padding(.top, 4)
    }
}
