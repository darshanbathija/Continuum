import SwiftUI
import ClawdmeterShared

/// iOS Chat tab — broadcast strip + per-turn model pills + active reply card.
/// Ports `ios-chat.jsx`.
public struct IOSChatView: View {
    @Environment(\.tahoe) private var t
    @State private var activeByTurn: [Int: TahoeProvider] = [:]
    @State private var broadcast: Bool = true

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            IOSLargeTitle(title: "Chat", subtitle: "Clawdmeter") {
                HStack(spacing: 10) {
                    IOSRoundIconBtn("archive")
                    IOSRoundIconBtn("plus")
                }
            }

            // Broadcast strip
            TahoeGlass(radius: 14, tone: .chip) {
                HStack(spacing: 10) {
                    HStack(spacing: -6) {
                        ForEach(TahoeProvider.allCases) { p in
                            TahoeProviderGlyph(provider: p, size: 22)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Broadcast to all three")
                            .font(TahoeFont.body(12.5, weight: .bold))
                            .foregroundStyle(t.fg)
                        Text("Compare answers · tap a model to read its reply")
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                    }
                    Spacer()
                    TahoeToggleView(on: $broadcast)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(TahoeDemo.chatThread.title.uppercased()) · \(TahoeDemo.chatThread.turns.count) TURNS")
                        .font(TahoeFont.body(10.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(t.fg4)
                        .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 10)
                    ForEach(Array(TahoeDemo.chatThread.turns.enumerated()), id: \.offset) { idx, turn in
                        IOSTurnRow(
                            turn: turn, index: idx,
                            activeProvider: Binding(
                                get: { activeByTurn[idx] ?? defaultStarred(turn) ?? .claude },
                                set: { activeByTurn[idx] = $0 }
                            )
                        )
                        .padding(.bottom, 18)
                    }
                    Spacer().frame(height: 12)
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            .frame(maxHeight: .infinity)

            // Floating composer above the tab bar — JSX positions this at
            // bottom: 92 inside the iPhone frame; in our SwiftUI shell we
            // put it after the scroll view so it stays glued to the bottom
            // of the content area, just above the floating tab bar.
            IOSChatComposer()
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
    }

    private func defaultStarred(_ turn: TahoeDemo.ChatTurn) -> TahoeProvider? {
        turn.replies.first { _, r in r.starred }?.key
    }
}

// MARK: - Turn

private struct IOSTurnRow: View {
    @Environment(\.tahoe) private var t
    var turn: TahoeDemo.ChatTurn
    var index: Int
    @Binding var activeProvider: TahoeProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSUserBubble(text: turn.user, attached: turn.attached, index: index)
            HStack(spacing: 6) {
                ForEach(TahoeProvider.allCases) { p in
                    if let reply = turn.replies[p] {
                        ModelPill(provider: p, reply: reply, active: p == activeProvider) {
                            activeProvider = p
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 10).padding(.bottom, 8)

            if let reply = turn.replies[activeProvider] {
                IOSReplyCard(provider: activeProvider, reply: reply)
            }
        }
    }
}

private struct IOSUserBubble: View {
    @Environment(\.tahoe) private var t
    var text: String
    var attached: [TahoeDemo.Attached]
    var index: Int

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !attached.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attached, id: \.name) { a in
                            HStack(spacing: 4) {
                                TahoeIcon("doc", size: 10).foregroundStyle(.white)
                                Text(a.name).foregroundStyle(.white)
                                Text(a.range).foregroundStyle(Color.white.opacity(0.7))
                            }
                            .font(TahoeFont.mono(11))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.16))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 18,
                    bottomTrailingRadius: 18, topTrailingRadius: 6
                )
                .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                     startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 7, x: 0, y: 4)
            .frame(maxWidth: .infinity * 0.88, alignment: .trailing)
        }
    }
}

private struct ModelPill: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var reply: TahoeDemo.ChatReply
    var active: Bool
    var onSelect: () -> Void

    private var tintMul: Double { provider == .codex ? 2.4 : 1.0 }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    TahoeProviderGlyph(provider: provider, size: 22)
                    if reply.starred {
                        ZStack {
                            Circle().fill(t.accent)
                            Image(systemName: "star.fill")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 13, height: 13)
                        .overlay { Circle().stroke(t.dark ? Color(.sRGB, red: 13.0/255, green: 14.0/255, blue: 17.0/255) : .white, lineWidth: 1.5) }
                        .offset(x: 6, y: -6)
                    }
                }
                Text(provider.displayName)
                    .font(TahoeFont.body(10.5, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? t.fg : t.fg2)
                    .lineLimit(1)
                Text("\(String(format: "%.1f", reply.time))s · \(tahoeFmtTok(reply.tokens))")
                    .font(TahoeFont.mono(9.5))
                    .monospacedDigit()
                    .foregroundStyle(t.fg4)
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active
                          ? provider.base.color(opacity: (t.dark ? 0.32 : 0.18) * tintMul)
                          : (t.dark ? Color(.sRGB, white: 1, opacity: 0.04) : Color(.sRGB, white: 15.0/255, opacity: 0.03)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? provider.base.color(opacity: 0.55) : t.hairline, lineWidth: active ? 1 : 0.5)
            }
            .shadow(color: active ? provider.base.color(opacity: 0.25) : .clear, radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct IOSReplyCard: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var reply: TahoeDemo.ChatReply

    var body: some View {
        TahoeGlass(radius: 18, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                LinearGradient(colors: [provider.glow.color, provider.base.color],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(reply.blocks.enumerated()), id: \.offset) { _, b in
                        switch b {
                        case .paragraph(let text):
                            Text(text)
                                .font(TahoeFont.body(13.5))
                                .foregroundStyle(t.fg)
                                .fixedSize(horizontal: false, vertical: true)
                        case .code(_, let code):
                            ScrollView(.horizontal) {
                                Text(code)
                                    .font(TahoeFont.mono(11))
                                    .foregroundStyle(t.fg)
                                    .padding(10)
                            }
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(t.dark ? Color.black.opacity(0.32) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                TahoeHair()

                HStack(spacing: 8) {
                    Text("\(tahoeFmtTok(reply.tokens)) tok · $\(String(format: "%.3f", reply.cost)) · \(String(format: "%.1f", reply.time))s")
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                    Spacer()
                    IOSReplyAction(icon: "refresh")
                    IOSReplyAction(icon: "doc")
                    PickWinnerButton(starred: reply.starred)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

private struct IOSReplyAction: View {
    @Environment(\.tahoe) private var t
    var icon: String
    var body: some View {
        Button(action: {}) {
            TahoeIcon(icon, size: 12)
                .foregroundStyle(t.fg2)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
                }
        }
        .buttonStyle(.plain)
    }
}

private struct PickWinnerButton: View {
    @Environment(\.tahoe) private var t
    var starred: Bool
    var body: some View {
        Button(action: {}) {
            HStack(spacing: 4) {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .bold))
                Text(starred ? "Winner" : "Pick")
            }
            .font(TahoeFont.body(11, weight: .bold))
            .foregroundStyle(starred ? t.accent : t.fg2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                Capsule(style: .continuous)
                    .fill(starred ? t.accentAlpha(t.dark ? 0.22 : 0.14)
                                  : (t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05)))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Composer

private struct IOSChatComposer: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        TahoeGlass(radius: 26, tone: .raised) {
            HStack(spacing: 8) {
                TahoeIcon("plus", size: 18).foregroundStyle(t.fg3)
                Text("Ask all three…")
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg3)
                Spacer()
                TahoeIcon("mic", size: 16).foregroundStyle(t.fg3)
                Button(action: {}) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                     startPoint: .top, endPoint: .bottom))
                        TahoeIcon("arrowU", size: 14, weight: .bold).foregroundStyle(.white)
                    }
                    .frame(width: 32, height: 32)
                    .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
    }
}
