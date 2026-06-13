import SwiftUI
import ClawdmeterShared

// MARK: - Surfaces

/// Flat Continuum panel — matches design `surface-1` / `surface-2` cards (no glass).
struct ContinuumSurface<Content: View>: View {
    @Environment(\.theme) private var theme
    enum Level { case one, two }
    var level: Level
    var padding: CGFloat
    @ViewBuilder var content: () -> Content

    init(level: Level = .one, padding: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.level = level
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(level == .one ? theme.surface1 : theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous)
                    .strokeBorder(level == .two ? theme.hair2 : theme.hairline, lineWidth: 0.5)
            }
    }
}

struct ContinuumEtchedLabel: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(ContinuumFont.etched(10.5))
            .tracking(0.95)
            .foregroundStyle(theme.fg3)
    }
}

/// Design large title — 26px display weight.
struct ContinuumLargeTitle: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text)
            .font(ContinuumFont.display(26, weight: .heavy))
            .tracking(-0.5)
            .foregroundStyle(theme.fg)
    }
}

/// Screen header with etched Continuum breadcrumb + tab title.
struct ContinuumScreenHeader: View {
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ContinuumEtchedLabel(text: "Continuum")
            ContinuumLargeTitle(text: title)
        }
    }
}

// MARK: - Home session state

enum IOSContinuumHomeState: String, Sendable {
    case planning
    case needsApproval
    case executing
    case review
    case blocked
    case done
    case idle

    var label: String {
        switch self {
        case .planning: return "Planning"
        case .needsApproval: return "Needs approval"
        case .executing: return "Executing"
        case .review: return "Review"
        case .blocked: return "Blocked"
        case .done: return "Merged"
        case .idle: return "Idle"
        }
    }

    func resolvedColor(theme: TahoeTokens) -> Color {
        switch self {
        case .planning: return theme.fg3
        case .needsApproval, .review: return theme.warn
        case .executing, .done: return theme.live
        case .blocked: return theme.error
        case .idle: return theme.fg4
        }
    }

    func dotColor(theme: TahoeTokens) -> Color {
        switch self {
        case .planning: return theme.fg3
        case .needsApproval, .review: return theme.warn
        case .executing: return theme.live
        case .blocked: return theme.error
        case .done, .idle: return theme.paused
        }
    }

    var pulses: Bool {
        switch self {
        case .planning, .executing: return true
        default: return false
        }
    }

    var needsAction: Bool {
        switch self {
        case .needsApproval, .review, .blocked: return true
        default: return false
        }
    }

    var priority: Int {
        switch self {
        case .blocked: return 0
        case .needsApproval: return 1
        case .review: return 2
        case .executing: return 8
        case .planning: return 9
        case .done: return 20
        case .idle: return 21
        }
    }

    static func from(_ session: AgentSession) -> IOSContinuumHomeState {
        if session.status == .done { return .done }
        if session.status == .degraded { return .blocked }

        let reasons = AttentionReasonResolver.reasons(for: session)
        if reasons.contains(.planReady), session.status == .planning { return .needsApproval }
        if reasons.contains(.checksFailed) || reasons.contains(.providerBlocked) { return .blocked }
        if reasons.contains(.pullRequest) { return .review }
        if session.status == .planning { return .planning }
        if session.status == .running { return .executing }
        if session.status == .paused { return .idle }
        return .idle
    }
}

struct IOSContinuumStateChip: View {
    @Environment(\.theme) private var theme
    var state: IOSContinuumHomeState

    var body: some View {
        HStack(spacing: 6) {
            if state.pulses {
                Circle()
                    .fill(state.resolvedColor(theme: theme))
                    .frame(width: 6, height: 6)
                    .modifier(ContinuumPulseModifier(active: true))
            } else {
                Circle()
                    .fill(state.dotColor(theme: theme))
                    .frame(width: 6, height: 6)
            }
            Text(state.label)
                .font(ContinuumFont.body(12, weight: .semibold))
                .foregroundStyle(state.resolvedColor(theme: theme))
        }
    }
}

private struct ContinuumPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(active && pulse ? 0.45 : 1)
            .onAppear {
                guard active, let anim = ContinuumMotion.heartbeat(reduceMotion: reduceMotion) else { return }
                withAnimation(anim) { pulse = true }
            }
    }
}

struct IOSContinuumRepoTag: View {
    @Environment(\.theme) private var theme
    var repo: String
    var compact: Bool

    init(_ repo: String, compact: Bool = false) {
        self.repo = repo
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed")
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(theme.fg3)
            Text(repo)
                .font(ContinuumFont.mono(compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(theme.fg2)
                .lineLimit(1)
        }
    }
}

struct IOSContinuumSessionProgressRail: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var provider: TahoeProvider
    var state: IOSContinuumHomeState
    var completed: Int
    var total: Int
    var height: CGFloat

    private var fraction: Double {
        if state == .planning { return 0 }
        if total > 0 { return min(Double(completed) / Double(total), 1) }
        return state == .done ? 1 : 0
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(w * fraction, fraction > 0 ? max(height, 4) : 0)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous)
                    .fill(theme.railTrack)
                if state == .planning {
                    planningSweep(width: w)
                } else if fillW > 0 {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous)
                        .fill(ProviderFill.gradient(for: provider))
                        .frame(width: fillW)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(theme.railLitEdge)
                                .frame(width: fillW, height: 1)
                        }
                    if state == .blocked, fillW > 0 {
                        Rectangle()
                            .fill(theme.error)
                            .frame(width: 2.5)
                            .shadow(color: theme.error.opacity(0.8), radius: 3)
                            .offset(x: max(0, fillW - 1))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous)
                    .strokeBorder(theme.railTrackInset, lineWidth: 0.5)
            }
        }
        .frame(height: height)
        .animation(ContinuumMotion.settle(reduceMotion: reduceMotion), value: fraction)
    }

    @ViewBuilder
    private func planningSweep(width: CGFloat) -> some View {
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: 1.5)) / 1.5
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.16), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.34)
                    .offset(x: (width * 1.34 - width * 0.34) * phase - width * 0.34)
            }
        }
    }
}

struct IOSContinuumProviderRow: View {
    @Environment(\.theme) private var theme
    var provider: TahoeProvider
    var model: String

    var body: some View {
        HStack(spacing: 8) {
            TahoeProviderGlyph(provider: provider, size: 15)
            Text(model)
                .font(ContinuumFont.body(12, weight: .semibold))
                .foregroundStyle(theme.fg2)
                .lineLimit(1)
        }
    }
}
