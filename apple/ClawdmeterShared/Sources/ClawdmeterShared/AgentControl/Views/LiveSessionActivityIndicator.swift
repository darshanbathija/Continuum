#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// "Session is still working" footer for the live chat list. Shows when
/// the current turn is streaming and the session's JSONL has been touched
/// within the activity window —
/// drives off `SessionChatStore.snapshot.lastEventAt` on Mac and
/// `iOSChatStore.snapshot.lastEventAt` on iOS.
///
/// Renders the shared `SteadyTenthsStream`: a faint left→right data-packet
/// stream flowing into a live `m, ss.s` elapsed-time readout. The packets
/// take the session's provider tint (the focused-session "one color event");
/// the readout digits stay near-foreground. Replaces the old per-agent
/// rotating-asterisk / pulsing-dots spinners.
///
/// The elapsed counter anchors to `activityStartedAt` (the current turn's
/// start) when the caller knows it; otherwise the stream counts from when the
/// indicator first appeared. The user feedback that triggered this: "there's
/// no way to know that the session is still moving forward and claude/codex
/// is working."
public struct LiveSessionActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timelineVisible = false
    /// Provider drives the accent + symbol.
    public let agent: AgentKind
    /// Most-recent observed event on the JSONL. nil → hide.
    public let lastEventAt: Date?
    /// When the agent started this turn — drives the elapsed readout. When
    /// `nil`, the stream counts from when the indicator first appeared.
    public let activityStartedAt: Date?
    /// Explicit per-turn lifecycle. When supplied, only `.streaming` keeps
    /// the animation mounted; completion/interruption hides it immediately.
    public let turnState: TurnState?
    /// How long after `lastEventAt` we consider the agent still working.
    /// 30 seconds matches the Mac chat-thread "thinking" window
    /// documented in `SessionChatStore.lastEventAt`.
    public let activityWindow: TimeInterval

    public init(
        agent: AgentKind,
        lastEventAt: Date?,
        activityStartedAt: Date? = nil,
        turnState: TurnState? = nil,
        activityWindow: TimeInterval = 30
    ) {
        self.agent = agent
        self.lastEventAt = lastEventAt
        self.activityStartedAt = activityStartedAt
        self.turnState = turnState
        self.activityWindow = activityWindow
        self._timelineVisible = State(initialValue: Self.shouldShowTimeline(
            lastEventAt: lastEventAt,
            activityWindow: activityWindow,
            now: Date(),
            turnState: turnState
        ))
    }

    public var body: some View {
        let visible = timelineVisible && Self.turnStateAllowsTimeline(turnState)
        // Mounted only while the last event is inside the activity window —
        // otherwise hidden/cached transcripts would keep the animation alive
        // forever. `SteadyTenthsStream` owns its own 10 Hz readout clock and
        // frame-rate packet motion, so there's no per-tick `@State` here to
        // invalidate the surrounding view tree.
        Group {
            if visible {
                SteadyTenthsStream(
                    color: agent.tahoeProvider.dot,
                    startedAt: activityStartedAt
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(ContinuumTokens.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visible)
            }
        }
        .task(id: activityScheduleKey) {
            await updateTimelineVisibility()
        }
    }

    // MARK: - Derived

    private var activityScheduleKey: String {
        "\(lastEventAt?.timeIntervalSinceReferenceDate ?? -1):\(activityWindow):\(turnState?.rawValue ?? "ungated")"
    }

    private var activityExpiry: Date? {
        lastEventAt?.addingTimeInterval(activityWindow)
    }

    @MainActor
    private func updateTimelineVisibility() async {
        guard Self.shouldShowTimeline(
            lastEventAt: lastEventAt,
            activityWindow: activityWindow,
            now: Date(),
            turnState: turnState
        ) else {
            timelineVisible = false
            return
        }

        guard let activityExpiry else {
            timelineVisible = false
            return
        }

        let remaining = activityExpiry.timeIntervalSinceNow
        guard remaining > 0 else {
            timelineVisible = false
            return
        }

        timelineVisible = true
        let cappedRemaining = min(remaining, activityWindow)
        try? await Task.sleep(nanoseconds: UInt64(cappedRemaining * 1_000_000_000))
        if !Task.isCancelled {
            timelineVisible = false
        }
    }

    static func shouldShowTimeline(
        lastEventAt: Date?,
        activityWindow: TimeInterval,
        now: Date,
        turnState: TurnState?
    ) -> Bool {
        guard turnStateAllowsTimeline(turnState) else { return false }
        guard let lastEventAt else { return false }
        return now.timeIntervalSince(lastEventAt) < activityWindow
    }

    private static func turnStateAllowsTimeline(_ turnState: TurnState?) -> Bool {
        turnState.map { $0 == .streaming } ?? true
    }

}
#endif
