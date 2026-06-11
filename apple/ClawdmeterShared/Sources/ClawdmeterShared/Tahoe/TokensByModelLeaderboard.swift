#if canImport(SwiftUI)
import SwiftUI

// MARK: - Ranked tokens-by-model leaderboard (design handoff: option-a.jsx)

/// One row in the flat ranked leaderboard — keyed by the raw model id from
/// `UsageHistorySnapshot.tokensByModel`.
public struct TokensByModelEntry: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let totals: TokenTotals

    public init(id: String, displayName: String, totals: TokenTotals) {
        self.id = id
        self.displayName = displayName
        self.totals = totals
    }
}

/// Shared formatting + accent colors for the ranked leaderboard. Values mirror
/// the JSX handoff (`rgb(217,119,87)` Claude, `rgb(159,160,171)` Codex, …).
public enum TokensByModelLeaderboard {
    public static let primaryVisibleCount = 12
    /// Fixed model-name column width so the volume bars get the wide middle band.
    public static let modelColumnWidth: CGFloat = 200
    public static let rankColumnWidth: CGFloat = 28
    public static let tokensColumnWidth: CGFloat = 72
    public static let shareColumnWidth: CGFloat = 44

    /// Compact token count: 1.2K / 3.4M / 5.6B.
    public static func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    public static func rangeBlurb(_ range: String) -> String {
        switch range {
        case "today", "24h": return "today"
        case "7d":  return "in the past 7 days"
        case "30d": return "in the past 30 days"
        case "90d": return "in the past 90 days"
        case "all": return "all-time"
        default:     return "in the past 7 days"
        }
    }

    public static func rangeKey(for window: UsageHistorySnapshot.Window) -> String {
        switch window {
        case .today: return "today"
        case .past7d: return "7d"
        case .past30d: return "30d"
        case .allTime: return "all"
        }
    }

    public static func subtitle(total: Int, range: String, isEmpty: Bool) -> String {
        if isEmpty { return "No token activity \(rangeBlurb(range))." }
        return "\(fmt(total)) tokens \(rangeBlurb(range)) · ranked across all models"
    }

    public static func sharePct(_ tokens: Int, total: Int) -> String {
        guard total > 0, tokens > 0 else { return total > 0 ? "0%" : "" }
        let pct = Double(tokens) / Double(total) * 100
        if pct < 0.1 { return "<0.1%" }
        if pct >= 10 { return "\(Int(pct.rounded()))%" }
        if pct >= 1 { return "\(Int(pct.rounded()))%" }
        return String(format: "%.1f%%", pct)
    }

    /// Per-model accent — matches the design-canvas ranked leaderboard.
    public static func modelColor(for modelKey: String) -> Color {
        let m = modelKey.lowercased()
        if m.hasPrefix("claude") || m == "opus" || m == "sonnet" || m == "haiku" {
            return Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        }
        if m.contains("composer") {
            return Color(red: 70 / 255, green: 199 / 255, blue: 190 / 255)
        }
        if m.hasPrefix("gemini") || m.hasPrefix("gemma") {
            return Color(red: 99 / 255, green: 149 / 255, blue: 242 / 255)
        }
        if m.hasPrefix("gpt") || m.hasPrefix("chatgpt") || m.contains("codex")
            || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            return Color(red: 159 / 255, green: 160 / 255, blue: 171 / 255)
        }
        if let providerID = UsageHistorySnapshot.modelProviderID(forModelKey: modelKey) {
            switch providerID {
            case "claude": return Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
            case "codex":  return Color(red: 159 / 255, green: 160 / 255, blue: 171 / 255)
            case "gemini": return Color(red: 99 / 255, green: 149 / 255, blue: 242 / 255)
            case "grok":   return Color(red: 70 / 255, green: 199 / 255, blue: 190 / 255)
            default: break
            }
        }
        return Color(red: 159 / 255, green: 160 / 255, blue: 171 / 255)
    }

    public static func displayModel(_ modelKey: String) -> String {
        let stripped = UsageHistorySnapshot.displayModelName(forModelKey: modelKey)
        if stripped != modelKey { return stripped }
        if modelKey.lowercased().hasPrefix("cursor/") {
            return String(modelKey.dropFirst("cursor/".count))
        }
        return modelKey
    }

    public static func rankedEntries(from byModel: [String: TokenTotals]) -> [TokensByModelEntry] {
        byModel
            .filter { $0.value.totalTokens > 0 }
            .map { TokensByModelEntry(id: $0.key, displayName: displayModel($0.key), totals: $0.value) }
            .sorted { $0.totals.totalTokens > $1.totals.totalTokens }
    }

    /// Windowed per-model token totals — mirrors `AnalyticsRangeAdapter.tokensByModel`
    /// so Mac and iOS render identical numbers for each range pill.
    public static func tokensByModel(snapshot: UsageHistorySnapshot, range: String) -> [String: TokenTotals] {
        if range == "all" {
            if !snapshot.tokensByModel.isEmpty { return snapshot.tokensByModel }
            var out: [String: TokenTotals] = [:]
            for (_, modelMap) in snapshot.byDayByModel {
                for (model, totals) in modelMap { out[model, default: .zero] += totals }
            }
            return out
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startOffset: Int
        switch range {
        case "today", "24h": startOffset = 0
        case "7d":           startOffset = 6
        case "30d":          startOffset = 29
        case "90d":          startOffset = (7 * 11) + 6
        default:             startOffset = 6
        }
        let start = cal.date(byAdding: .day, value: -startOffset, to: today) ?? today
        var out: [String: TokenTotals] = [:]
        for (day, modelMap) in snapshot.byDayByModel where day >= start && day <= today {
            for (model, totals) in modelMap { out[model, default: .zero] += totals }
        }
        return out
    }
}

/// Range pills for the tokens leaderboard — Today | 7d | 30d | 90d | All time.
public struct TokensByModelRangeSelector: View {
    @Environment(\.theme) private var t
    @Binding var value: String
    private let items: [(String, String)] = [
        ("today", "Today"), ("7d", "7d"), ("30d", "30d"), ("90d", "90d"), ("all", "All time"),
    ]

    public init(value: Binding<String>) {
        self._value = value
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { (k, label) in
                let active = k == value
                Button { value = k } label: {
                    Text(label)
                        .font(ContinuumFont.mono(11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? t.primaryText : t.fg2)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if active {
                                Capsule(style: .continuous)
                                    .fill(t.segmentActiveFill)
                                    .overlay(Capsule(style: .continuous).strokeBorder(t.hair2, lineWidth: 0.5))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(t.surface1)
                .overlay(Capsule(style: .continuous).strokeBorder(t.hairline, lineWidth: 0.5))
        }
    }
}

/// Flat ranked leaderboard: rank · model · relative-volume bar · tokens · share.
public struct TokensByModelLeaderboardView<RangeControl: View>: View {
    @Environment(\.tahoe) private var t
    var entries: [TokensByModelEntry]
    var range: String
    @ViewBuilder var rangeControl: () -> RangeControl

    @State private var showHidden = false

    private var grandTotal: Int { entries.reduce(0) { $0 + $1.totals.totalTokens } }
    private var maxTokens: Int { entries.map(\.totals.totalTokens).max() ?? 0 }
    private var visible: [TokensByModelEntry] { Array(entries.prefix(TokensByModelLeaderboard.primaryVisibleCount)) }
    private var hidden: [TokensByModelEntry] { Array(entries.dropFirst(TokensByModelLeaderboard.primaryVisibleCount)) }
    private var hiddenTotal: Int { hidden.reduce(0) { $0 + $1.totals.totalTokens } }

    private var expandHint: String {
        #if os(macOS)
        return "* click to expand"
        #else
        return "* tap to expand"
        #endif
    }

    public init(
        entries: [TokensByModelEntry],
        range: String,
        @ViewBuilder rangeControl: @escaping () -> RangeControl
    ) {
        self.entries = entries
        self.range = range
        self.rangeControl = rangeControl
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            columnHeader
            VStack(alignment: .leading, spacing: 4) {
                if entries.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, entry in
                        modelRow(rank: idx + 1, entry: entry)
                    }
                    if !hidden.isEmpty {
                        hiddenFooter
                        if showHidden {
                            ForEach(Array(hidden.enumerated()), id: \.element.id) { idx, entry in
                                modelRow(rank: TokensByModelLeaderboard.primaryVisibleCount + idx + 1, entry: entry)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            t.surface2,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tokens by model")
                    .font(TahoeFont.body(16, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(t.fg)
                Text(TokensByModelLeaderboard.subtitle(total: grandTotal, range: range, isEmpty: entries.isEmpty))
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(t.fg.opacity(0.42))
            }
            Spacer()
            rangeControl()
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: TokensByModelLeaderboard.rankColumnWidth)
            Text("Model")
                .frame(width: TokensByModelLeaderboard.modelColumnWidth, alignment: .leading)
            Text("Relative volume")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Tokens")
                .frame(width: TokensByModelLeaderboard.tokensColumnWidth, alignment: .trailing)
            Text("Share")
                .frame(width: TokensByModelLeaderboard.shareColumnWidth, alignment: .trailing)
        }
        .font(TahoeFont.mono(10, weight: .medium))
        .textCase(.uppercase)
        .tracking(0.3)
        .foregroundStyle(t.fg.opacity(0.28))
    }

    private var emptyStateRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: TokensByModelLeaderboard.rankColumnWidth)
            Text("No models in this range")
                .font(TahoeFont.mono(11))
                .foregroundStyle(t.fg.opacity(0.34))
            Spacer()
        }
    }

    @ViewBuilder
    private func modelRow(rank: Int, entry: TokensByModelEntry) -> some View {
        let color = TokensByModelLeaderboard.modelColor(for: entry.id)
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(TahoeFont.mono(11.5))
                .foregroundStyle(t.fg.opacity(0.34))
                .frame(width: TokensByModelLeaderboard.rankColumnWidth, alignment: .trailing)

            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(entry.displayName)
                    .font(TahoeFont.mono(12.5))
                    .foregroundStyle(t.fg.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: TokensByModelLeaderboard.modelColumnWidth, alignment: .leading)

            RankedVolumeBar(
                fraction: maxTokens > 0 ? Double(entry.totals.totalTokens) / Double(maxTokens) : 0,
                color: color
            )
            .frame(maxWidth: .infinity)

            Text(TokensByModelLeaderboard.fmt(entry.totals.totalTokens))
                .font(TahoeFont.mono(12))
                .monospacedDigit()
                .foregroundStyle(t.fg.opacity(0.92))
                .frame(width: TokensByModelLeaderboard.tokensColumnWidth, alignment: .trailing)

            Text(TokensByModelLeaderboard.sharePct(entry.totals.totalTokens, total: grandTotal))
                .font(TahoeFont.mono(11))
                .monospacedDigit()
                .foregroundStyle(t.fg.opacity(0.34))
                .frame(width: TokensByModelLeaderboard.shareColumnWidth, alignment: .trailing)
        }
    }

    private var hiddenFooter: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showHidden.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text(showHidden ? "−" : "+")
                    .font(TahoeFont.mono(11.5))
                    .foregroundStyle(t.fg.opacity(0.34))
                    .frame(width: TokensByModelLeaderboard.rankColumnWidth, alignment: .trailing)

                Text("\(hidden.count) smaller model\(hidden.count == 1 ? "" : "s")")
                    .font(TahoeFont.mono(12.5))
                    .foregroundStyle(t.fg.opacity(0.34))
                    .frame(width: TokensByModelLeaderboard.modelColumnWidth, alignment: .leading)

                Group {
                    if showHidden {
                        RankedSegmentedVolumeBar(entries: hidden, maxTokens: maxTokens)
                    } else {
                        Text(expandHint)
                            .font(TahoeFont.mono(10))
                            .foregroundStyle(t.fg.opacity(0.34))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(TokensByModelLeaderboard.fmt(hiddenTotal))
                    .font(TahoeFont.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(t.fg.opacity(0.92))
                    .frame(width: TokensByModelLeaderboard.tokensColumnWidth, alignment: .trailing)

                Color.clear.frame(width: TokensByModelLeaderboard.shareColumnWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Multi-segment aggregate bar for the "+ N smaller models" footer row.
public struct RankedSegmentedVolumeBar: View {
    @Environment(\.tahoe) private var t
    var entries: [TokensByModelEntry]
    var maxTokens: Int

    public init(entries: [TokensByModelEntry], maxTokens: Int) {
        self.entries = entries
        self.maxTokens = maxTokens
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(t.dark ? Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
                                  : ContinuumTokens.ink(0.06))
                HStack(spacing: 0) {
                    ForEach(entries) { entry in
                        let clamped = maxTokens > 0
                            ? min(1, max(0, Double(entry.totals.totalTokens) / Double(maxTokens)))
                            : 0
                        let raw = geo.size.width * CGFloat(clamped)
                        let sliceWidth = clamped > 0 ? max(0.5, raw) : 0
                        if sliceWidth > 0 {
                            Rectangle()
                                .fill(TokensByModelLeaderboard.modelColor(for: entry.id))
                                .frame(width: sliceWidth)
                        }
                    }
                }
                .clipShape(Capsule(style: .continuous))
            }
        }
        .frame(height: 8)
    }
}

/// 8pt pill bar used by the ranked leaderboard (solid fill, no gradient).
public struct RankedVolumeBar: View {
    @Environment(\.tahoe) private var t
    var fraction: Double
    var color: Color

    public init(fraction: Double, color: Color) {
        self.fraction = fraction
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let clamped = min(1, max(0, fraction))
            let raw = geo.size.width * CGFloat(clamped)
            let fillWidth = fraction > 0 ? max(1, raw) : 0
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(t.dark ? Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
                                  : ContinuumTokens.ink(0.06))
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 8)
    }
}
#endif
