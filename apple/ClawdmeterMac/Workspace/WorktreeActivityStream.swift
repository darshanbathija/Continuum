import SwiftUI
import Combine
import ClawdmeterShared

/// "Data stream" cable — a field of small packets flowing left→right *behind* a
/// worktree row's branch icon + name while that worktree's agent is mid-run.
///
/// Color is focus: the open/selected worktree streams in terra-cotta; a
/// worktree merely working in the background streams in a quiet white. One
/// color event on screen, and it always means "this is the worktree you're in."
/// When a worktree isn't working, the row draws no cable at all.
///
/// Faithful SwiftUI port of the standalone HTML `DataBus` design
/// (.context "Branch Tab · Data Stream"). The packet field is deterministic
/// (same seed + LCG as the source) so it reads identically across both color
/// treatments — only the tint and opacity band differ. Renders a single static
/// frame under Reduce Motion or while the window is inactive.
@available(macOS 14, *)
struct WorktreeActivityStream: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Mirror the sidebar's "pause cosmetic ticks while inactive" ethos — no
    // visible motion to drive when the user can't see the window.
    @Environment(\.controlActiveState) private var controlActiveState

    /// Packet tint — terra-cotta when the worktree is selected, white otherwise.
    let color: Color
    /// Opacity band. The same motif whispers behind text (mono) or glows a
    /// little warmer when focused (terra).
    let minOpacity: Double
    let maxOpacity: Double

    /// One packet on the bus. Geometry + timing are fixed at init; only the
    /// phase advances with the timeline clock.
    private struct Packet {
        let size: CGFloat      // square edge, px
        let opacity: Double    // within [minOpacity, maxOpacity]
        let period: Double     // seconds for one edge-to-edge pass
        let phase: Double      // 0..<1 starting offset (from the source's negative delay)
        let yFraction: CGFloat // vertical center as a fraction of height
    }
    private let packets: [Packet]

    /// Packets enter from x = -overscan and exit at x = width (CSS keyframe
    /// `translateX(-8px → var(--bw))` parity), so they slide in/out cleanly.
    private static let overscan: CGFloat = 8

    init(color: Color, minOpacity: Double, maxOpacity: Double) {
        self.color = color
        self.minOpacity = minOpacity
        self.maxOpacity = maxOpacity
        self.packets = Self.makePackets(count: 20, seed: 5, minOp: minOpacity, maxOp: maxOpacity)
    }

    /// Freeze the field to a single frame when motion is unwelcome.
    private var isStatic: Bool { reduceMotion || controlActiveState == .inactive }

    var body: some View {
        TimelineView(.animation(paused: isStatic)) { timeline in
            let time = isStatic ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(in: &ctx, size: size, time: time)
            }
        }
        // Edge mask so the cable dissolves at both ends instead of hard-cutting.
        .mask(edgeFade)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time: Double) {
        let travel = size.width + Self.overscan
        for p in packets {
            let frac: CGFloat
            if isStatic {
                frac = CGFloat(p.phase)
            } else {
                let raw = (time / p.period + p.phase).truncatingRemainder(dividingBy: 1)
                frac = CGFloat(raw < 0 ? raw + 1 : raw)
            }
            let x = -Self.overscan + frac * travel
            let y = p.yFraction * size.height - p.size / 2
            let rect = CGRect(x: x, y: y, width: p.size, height: p.size)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(color.opacity(p.opacity)))
        }
    }

    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.84),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Deterministic packet field

    /// Builds the packet field with the exact draw order + math of the HTML
    /// source's `DataBus` so the cable looks the same here as in the design
    /// mock. `seed` 5 + `speed` 2.2 + counts/sizes are the "behind" placement
    /// the design chose for the branch tab.
    private static func makePackets(count: Int, seed: UInt64, minOp: Double, maxOp: Double) -> [Packet] {
        var state = seed == 0 ? 1 : seed
        // glibc LCG masked to 31 bits — verbatim from the source's `rng()`.
        func next() -> Double {
            state = (state &* 1103515245 &+ 12345) & 0x7fffffff
            return Double(state) / Double(0x7fffffff)
        }
        let big: CGFloat = 6
        let small: CGFloat = 3.5
        let speed: Double = 2.2
        let band = maxOp - minOp

        var out: [Packet] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            // Draw order matters: isBig, opacity factor, period, delay, y.
            let isBig = next() > 0.66
            let size = isBig ? big : small
            let opacity = minOp + (isBig ? band : band * 0.45) * (0.7 + next() * 0.3)
            let period = (1.25 + next() * 1.5) * speed
            let delay = -next() * 2.7 * speed                 // negative animation-delay
            let yFraction = CGFloat(0.16 + next() * 0.68)
            // A negative start delay = already partway through one pass at t=0.
            var phase = ((-delay) / period).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            out.append(Packet(size: size, opacity: opacity, period: period, phase: phase, yFraction: yFraction))
        }
        return out
    }
}

/// Observes the live turn-state of a worktree's *active* sessions and exposes a
/// single `isStreaming` flag for the row's data-stream cable.
///
/// The cable should light for exactly as long as the model is working a turn —
/// input → cache → thinking → output — which is precisely
/// `TurnState.streaming` (set when the turn opens, cleared on
/// completed/interrupted/idle). We subscribe to each session's lightweight
/// `ChatLiveStatusSlice` (it invalidates on turn transitions, not on every
/// message), so this stays cheap even while tokens pour in.
///
/// Only sessions the caller already pre-filtered to "active" (running /
/// planning) are ever resolved to a store, so at most a handful of chat stores
/// are materialized — never one per sidebar row.
@MainActor
final class WorktreeStreamObserver: ObservableObject {
    @Published private(set) var isStreaming = false

    private var cancellables: Set<AnyCancellable> = []
    private var observedStoreKeys: [ObjectIdentifier] = []
    private var stores: [SessionChatStore] = []

    /// Resolve the active sessions to their live stores and (re)subscribe to
    /// each store's turn-state. Subscriptions are rebuilt only when the resolved
    /// store set actually changes, so steady-state syncs are O(stores). Resolving
    /// every call also re-touches the model's LRU, keeping active stores warm.
    func sync(activeSessions: [AgentSession], resolve: (AgentSession) -> SessionChatStore?) {
        let resolved = activeSessions.compactMap(resolve)
        let keys = resolved.map { ObjectIdentifier($0) }
        if keys != observedStoreKeys {
            observedStoreKeys = keys
            stores = resolved
            cancellables.removeAll()
            for store in resolved {
                store.liveStatusSlice.$currentTurnState
                    // Defer past the @Published willSet so `recompute` reads the
                    // already-committed value.
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.recompute() }
                    .store(in: &cancellables)
            }
        }
        recompute()
    }

    private func recompute() {
        let streaming = stores.contains { $0.liveStatusSlice.currentTurnState == .streaming }
        if streaming != isStreaming { isStreaming = streaming }
    }
}

/// Gates `WorktreeActivityStream` on live token streaming. Owns the per-row
/// `WorktreeStreamObserver` and shows the cable only while a turn is in flight,
/// fading it in/out at turn boundaries. Color is focus — terra-cotta for the
/// open worktree, a quiet white when it's working in the background.
@available(macOS 14, *)
struct WorktreeStreamCable: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sessions on this worktree the registry considers active (running /
    /// planning) — the bounded candidate set we observe for live streaming.
    let activeSessions: [AgentSession]
    /// The open/focused worktree streams terra-cotta; background work is white.
    let isOpen: Bool
    /// Resolves a session to its live, tailing chat store (`SessionsModel`).
    let resolveStore: (AgentSession) -> SessionChatStore?

    @StateObject private var observer = WorktreeStreamObserver()

    var body: some View {
        Group {
            if observer.isStreaming {
                WorktreeActivityStream(
                    color: isOpen ? t.accent : .white,
                    minOpacity: isOpen ? 0.26 : 0.12,
                    maxOpacity: isOpen ? 0.62 : 0.34
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: observer.isStreaming)
        .onAppear { observer.sync(activeSessions: activeSessions, resolve: resolveStore) }
        .onChange(of: activeSessions.map(\.id)) { _, _ in
            observer.sync(activeSessions: activeSessions, resolve: resolveStore)
        }
    }
}
