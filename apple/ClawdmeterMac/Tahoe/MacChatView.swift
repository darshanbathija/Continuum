import SwiftUI
import ClawdmeterShared

/// Mac Chat — the hero tab. Sidebar + 3-column compare (broadcast mode)
/// or single-column Solo mode. Ports `mac-chat.jsx`.
public struct MacChatView: View {
    @Environment(\.tahoe) private var t
    public enum Mode: String, CaseIterable, Hashable { case broadcast, solo }

    @State private var mode: Mode = .broadcast
    @State private var soloProvider: TahoeProvider = .claude

    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            TahoeGlass(radius: 20, tone: .panel) {
                ChatSidebar()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 248)

            VStack(spacing: 10) {
                ModeToggle(mode: $mode, soloProvider: $soloProvider)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 2)

                ChatColumnHeaders(mode: mode, soloProvider: soloProvider, thread: TahoeDemo.chatThread)

                TahoeGlass(radius: 20, tone: .panel) {
                    ChatStream(thread: TahoeDemo.chatThread, mode: mode, soloProvider: soloProvider)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                ChatComposer(mode: mode, soloProvider: soloProvider)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Mode toggle

private struct ModeToggle: View {
    @Environment(\.tahoe) private var t
    @Binding var mode: MacChatView.Mode
    @Binding var soloProvider: TahoeProvider

    var body: some View {
        HStack(spacing: 8) {
            Text("MODE")
                .font(TahoeFont.body(11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(t.fg3)

            segmented([
                (Self.broadcastKey, "Broadcast"),
                (Self.soloKey,      "Solo"),
            ], active: mode == .broadcast ? Self.broadcastKey : Self.soloKey) { k in
                mode = (k == Self.broadcastKey) ? .broadcast : .solo
            }

            if mode == .solo {
                segmentedProvider(active: soloProvider) { soloProvider = $0 }
            }
        }
    }

    private static let broadcastKey = "broadcast"
    private static let soloKey = "solo"

    private func segmented(_ items: [(String, String)], active: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { (key, label) in
                let isActive = key == active
                Button {
                    onSelect(key)
                } label: {
                    HStack(spacing: 5) {
                        if key == Self.broadcastKey {
                            CompareIconView(size: 10)
                        }
                        Text(label)
                    }
                    .font(TahoeFont.body(11.5, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? t.fg : t.fg3)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background {
                        if isActive {
                            Capsule(style: .continuous)
                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
        }
        .overlay {
            Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }

    private func segmentedProvider(active: TahoeProvider, onSelect: @escaping (TahoeProvider) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(TahoeProvider.allCases) { p in
                let isActive = p == active
                Button { onSelect(p) } label: {
                    HStack(spacing: 5) {
                        TahoeProviderGlyph(provider: p, size: 14)
                        Text(p.displayName)
                    }
                    .font(TahoeFont.body(11.5, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? t.fg : t.fg3)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background {
                        if isActive {
                            Capsule(style: .continuous)
                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
        }
        .overlay {
            Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }
}

/// Custom 3-vertical-bar compare glyph used by the Mode pill — matches the
/// JSX `CompareIcon` in `mac-chat.jsx::CompareIcon` (an SF Symbol equivalent
/// doesn't quite capture the spec, hence the inline Path).
private struct CompareIconView: View {
    var size: CGFloat
    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            // x=5 y=8..16, x=12 y=4..20, x=19 y=6..18 (24-viewbox)
            let s = size / 24
            for (x, y0, y1) in [(5.0, 8.0, 16.0), (12.0, 4.0, 20.0), (19.0, 6.0, 18.0)] {
                path.move(to: CGPoint(x: x * s, y: y0 * s))
                path.addLine(to: CGPoint(x: x * s, y: y1 * s))
            }
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sidebar

private struct ChatSidebar: View {
    @Environment(\.tahoe) private var t
    @State private var openSections: Set<String> = ["Pinned", "Today", "Earlier"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // New chat button
            TahoeAccentButton(size: .m) {
                HStack(spacing: 4) {
                    TahoeIcon("plus", size: 12, weight: .bold)
                    Text("New chat")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)

            // Search field
            HStack(spacing: 8) {
                TahoeIcon("search", size: 12).foregroundStyle(t.fg3)
                Text("Search chats")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            TahoeHair()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HistorySection(label: "Pinned",  rows: [TahoeDemo.chatHistory[5]],                                openSections: $openSections)
                    HistorySection(label: "Today",   rows: Array(TahoeDemo.chatHistory.prefix(2)),                    openSections: $openSections)
                    HistorySection(label: "Earlier", rows: Array(TahoeDemo.chatHistory[2..<5]) + Array(TahoeDemo.chatHistory[6...]), openSections: $openSections)
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
        }
    }
}

private struct HistorySection: View {
    @Environment(\.tahoe) private var t
    var label: String
    var rows: [TahoeDemo.ChatHistory]
    @Binding var openSections: Set<String>

    var body: some View {
        let open = openSections.contains(label)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { openSections.remove(label) } else { openSections.insert(label) }
            } label: {
                HStack(spacing: 6) {
                    TahoeIcon(open ? "chevD" : "chevR", size: 9).foregroundStyle(t.fg4)
                    Text(label.uppercased())
                        .font(TahoeFont.body(10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(t.fg4)
                    Spacer()
                    Text("\(rows.count)")
                        .font(TahoeFont.mono(10, weight: .semibold))
                        .foregroundStyle(t.fg4)
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            if open {
                ForEach(rows) { row in
                    HistoryRow(row: row)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    @Environment(\.tahoe) private var t
    var row: TahoeDemo.ChatHistory

    var body: some View {
        Button(action: {}) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(TahoeFont.body(12.5, weight: row.active ? .semibold : .medium))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    HStack(spacing: -6) {
                        ForEach(Array(row.winners.prefix(3).enumerated()), id: \.offset) { _, w in
                            TahoeProviderGlyph(provider: w, size: 14)
                        }
                    }
                    Text("\(row.turns) turn\(row.turns == 1 ? "" : "s")")
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                    Spacer()
                    Text(row.ago)
                        .font(TahoeFont.body(10.5))
                        .foregroundStyle(t.fg4)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if row.active {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Column headers

private struct ChatColumnHeaders: View {
    var mode: MacChatView.Mode
    var soloProvider: TahoeProvider
    var thread: TahoeDemo.ChatThread

    var providers: [TahoeProvider] {
        mode == .solo ? [soloProvider] : [.claude, .codex, .gemini]
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(providers) { p in
                ColumnHeader(provider: p, stats: totals(for: p))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    struct Stats { var tok: Int; var cost: Double; var wins: Int; var lastTime: Double; var model: String }

    private func totals(for p: TahoeProvider) -> Stats {
        let replies = thread.turns.compactMap { $0.replies[p] }
        let tok = replies.reduce(0) { $0 + $1.tokens }
        let cost = replies.reduce(0) { $0 + $1.cost }
        let wins = replies.filter { $0.starred }.count
        let lastTime = replies.last?.time ?? 0
        return Stats(tok: tok, cost: cost, wins: wins, lastTime: lastTime, model: replies.first?.model ?? "")
    }
}

private struct ColumnHeader: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var stats: ChatColumnHeaders.Stats

    var body: some View {
        TahoeGlass(radius: 14, tone: .raised) {
            VStack(spacing: 0) {
                // Brand rule on top
                LinearGradient(colors: [provider.glow.color, provider.base.color],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                    .shadow(color: provider.base.color(opacity: 0.55), radius: 6, x: 0, y: 0)

                HStack(spacing: 10) {
                    TahoeProviderGlyph(provider: provider, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(TahoeFont.body(13, weight: .bold))
                            .tracking(-0.1)
                            .foregroundStyle(t.fg)
                        Text(stats.model)
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg3)
                    }
                    Spacer(minLength: 4)
                    Stat(label: "tok",  value: tahoeFmtTok(stats.tok))
                    Stat(label: "cost", value: String(format: "$%.3f", stats.cost))
                    Stat(label: "last", value: String(format: "%.1fs", stats.lastTime))
                    Stat(label: "wins", value: "\(stats.wins)", highlight: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}

private struct Stat: View {
    @Environment(\.tahoe) private var t
    var label: String
    var value: String
    var highlight: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value)
                .font(TahoeFont.mono(13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(highlight ? t.accent : t.fg)
            Text(label.uppercased())
                .font(TahoeFont.body(9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(t.fg4)
        }
        .frame(minWidth: 38, alignment: .trailing)
    }
}

// MARK: - Stream

private struct ChatStream: View {
    @Environment(\.tahoe) private var t
    var thread: TahoeDemo.ChatThread
    var mode: MacChatView.Mode
    var soloProvider: TahoeProvider

    var providers: [TahoeProvider] {
        mode == .solo ? [soloProvider] : [.claude, .codex, .gemini]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text(thread.title.uppercased())
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(t.fg3)
                    TahoeHair(vertical: true).frame(height: 10)
                    Text("\(thread.turns.count) turn\(thread.turns.count == 1 ? "" : "s") · " +
                         (mode == .broadcast ? "broadcasting to 3 models" : "solo — \(soloProvider.displayName)"))
                        .font(TahoeFont.mono(11, weight: .semibold))
                        .foregroundStyle(t.fg4)
                }
                ForEach(Array(thread.turns.enumerated()), id: \.offset) { idx, turn in
                    Turn(turn: turn, providers: providers, index: idx)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
    }
}

private struct Turn: View {
    var turn: TahoeDemo.ChatTurn
    var providers: [TahoeProvider]
    var index: Int

    var body: some View {
        VStack(spacing: 10) {
            UserMessage(text: turn.user, attached: turn.attached, index: index)
            HStack(alignment: .top, spacing: 10) {
                ForEach(providers) { p in
                    if let reply = turn.replies[p] {
                        AssistantCard(provider: p, reply: reply, solo: providers.count == 1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct UserMessage: View {
    @Environment(\.tahoe) private var t
    var text: String
    var attached: [TahoeDemo.Attached]
    var index: Int

    var body: some View {
        TahoeGlass(radius: 14, tone: .chip) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : Color(.sRGB, white: 15.0/255, opacity: 0.08))
                    Text("\(index + 1)")
                        .font(TahoeFont.mono(11, weight: .bold))
                        .foregroundStyle(t.fg2)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text("YOU")
                        .font(TahoeFont.body(10.5, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(t.fg3)
                    Text(text)
                        .font(TahoeFont.body(13.5))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    if !attached.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(attached, id: \.name) { a in
                                HStack(spacing: 5) {
                                    TahoeIcon("doc", size: 10)
                                    Text(a.name)
                                    Text(a.range).foregroundStyle(t.fg4).padding(.leading, 4)
                                }
                                .font(TahoeFont.mono(11))
                                .foregroundStyle(t.fg2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

private struct AssistantCard: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var reply: TahoeDemo.ChatReply
    var solo: Bool

    var body: some View {
        TahoeGlass(radius: 14, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                LinearGradient(colors: [provider.glow.color, provider.base.color],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                    .opacity(0.85)
                HStack(spacing: 8) {
                    TahoeProviderGlyph(provider: provider, size: 20)
                    Text(provider.displayName)
                        .font(TahoeFont.body(12, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text(reply.model)
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg4)
                    Spacer()
                    StarButton(on: reply.starred)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                TahoeHair()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(reply.blocks.enumerated()), id: \.offset) { _, b in
                        switch b {
                        case .paragraph(let text):
                            Text(text)
                                .font(TahoeFont.body(solo ? 13.5 : 12.5))
                                .foregroundStyle(t.fg)
                                .fixedSize(horizontal: false, vertical: true)
                        case .code(let lang, let code):
                            CodeBlock(code: code, lang: lang)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                TahoeHair()
                HStack(spacing: 10) {
                    ReplyMeta(icon: "sparkles", value: tahoeFmtTok(reply.tokens), suffix: "tok")
                    ReplyMeta(icon: nil, value: String(format: "$%.3f", reply.cost), suffix: nil)
                    ReplyMeta(icon: nil, value: String(format: "%.1fs", reply.time), suffix: nil)
                    Spacer()
                    IconBtn(icon: "refresh")
                    IconBtn(icon: "doc")
                    IconBtn(icon: "arrowR")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

private struct CodeBlock: View {
    @Environment(\.tahoe) private var t
    var code: String
    var lang: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lang.uppercased())
                .font(TahoeFont.body(9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(t.fg4)
            ScrollView(.horizontal) {
                Text(code)
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(t.fg)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.dark ? Color.black.opacity(0.30) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }
}

private struct ReplyMeta: View {
    @Environment(\.tahoe) private var t
    var icon: String?
    var value: String
    var suffix: String?
    var body: some View {
        HStack(spacing: 4) {
            if let icon { TahoeIcon(icon, size: 10) }
            Text(value).foregroundStyle(t.fg2).fontWeight(.semibold)
            if let suffix { Text(suffix).foregroundStyle(t.fg4) }
        }
        .font(TahoeFont.mono(11))
        .foregroundStyle(t.fg3)
    }
}

private struct IconBtn: View {
    @Environment(\.tahoe) private var t
    var icon: String
    var body: some View {
        Button(action: {}) {
            TahoeIcon(icon, size: 12)
                .foregroundStyle(t.fg3)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
}

private struct StarButton: View {
    @Environment(\.tahoe) private var t
    var on: Bool
    var body: some View {
        Button(action: {}) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(on ? t.accent : t.fg4)
                .frame(width: 26, height: 22)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(t.accentAlpha(t.dark ? 0.22 : 0.14))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Composer

private struct ChatComposer: View {
    @Environment(\.tahoe) private var t
    var mode: MacChatView.Mode
    var soloProvider: TahoeProvider

    var body: some View {
        TahoeGlass(radius: 18, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(placeholder)
                        .font(TahoeFont.body(14))
                        .foregroundStyle(t.fg3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 50, alignment: .top)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

                HStack(spacing: 6) {
                    BroadcastChip(mode: mode, soloProvider: soloProvider)
                    TahoeComposerChip(icon: "paperclip")
                    TahoeComposerChip(icon: "code")
                    TahoeComposerChip(icon: "mic")
                    TahoeComposerChip(icon: "bolt", label: "auto", caret: true)
                    Spacer()
                    Text(mode == .broadcast ? "~$0.033 / send" : "~$0.011 / send")
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg4)
                        .padding(.trailing, 4)
                    SendButton()
                }
                .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
            }
        }
    }

    private var placeholder: String {
        if mode == .broadcast {
            return "Ask all three. Use / for skills, @ for files. Press ⏎ to send to Claude · Codex · Antigravity."
        }
        return "Ask \(soloProvider.displayName). Use / for skills, @ for files."
    }
}

private struct BroadcastChip: View {
    @Environment(\.tahoe) private var t
    var mode: MacChatView.Mode
    var soloProvider: TahoeProvider

    var providers: [TahoeProvider] {
        mode == .solo ? [soloProvider] : [.claude, .codex, .gemini]
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -5) {
                ForEach(providers) { p in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [p.glow.color, p.base.color],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 14, height: 14)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(t.dark ? Color(.sRGB, red: 13.0/255, green: 14.0/255, blue: 17.0/255) : Color.white, lineWidth: 1.5)
                        }
                }
            }
            Text(mode == .broadcast ? "Broadcast · 3 models" : "Solo · \(soloProvider.displayName)")
                .font(TahoeFont.body(11.5, weight: .semibold))
            TahoeIcon("chevD", size: 9).opacity(0.7)
        }
        .foregroundStyle(t.accent)
        .padding(.horizontal, 8).padding(.vertical, 0)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.accentAlpha(t.dark ? 0.16 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.accentAlpha(0.45), lineWidth: 0.5)
        }
    }
}

private struct SendButton: View {
    @Environment(\.tahoe) private var t
    var body: some View {
        Button(action: {}) {
            ZStack {
                Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                             startPoint: .top, endPoint: .bottom))
                TahoeIcon("arrowU", size: 15, weight: .bold)
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}
