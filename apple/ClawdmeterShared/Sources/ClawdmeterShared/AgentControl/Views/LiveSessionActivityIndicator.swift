#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// "Session is still working" footer for the live chat list. Shows when
/// the session's JSONL has been touched within the activity window —
/// drives off `SessionChatStore.snapshot.lastEventAt` on Mac and
/// `iOSChatStore.snapshot.lastEventAt` on iOS.
///
/// Renders the shared `SteadyTenthsStream`: a faint left→right data-packet
/// stream flowing into a live `m, ss.s` elapsed-time readout. The packets use
/// the canonical orange working accent; provider-gray variants are deliberately
/// not used here. Replaces the old per-agent rotating-asterisk / pulsing-dots
/// spinners.
///
/// The elapsed counter anchors to `activityStartedAt` (the current turn's
/// start) when the caller knows it; otherwise the stream counts from when the
/// indicator first appeared. The user feedback that triggered this: "there's
/// no way to know that the session is still moving forward and claude/codex
/// is working."
public struct LiveSessionActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timelineVisible = false
    /// Provider is retained for call-site/session context; the stream color is
    /// the shared working accent rather than the provider identity color.
    public let agent: AgentKind
    /// Most-recent observed event on the JSONL. nil → hide.
    public let lastEventAt: Date?
    /// When the agent started this turn — drives the elapsed readout. When
    /// `nil`, the stream counts from when the indicator first appeared.
    public let activityStartedAt: Date?
    /// How long after `lastEventAt` we consider the agent still working.
    /// 30 seconds matches the Mac chat-thread "thinking" window
    /// documented in `SessionChatStore.lastEventAt`.
    public let activityWindow: TimeInterval

    public init(
        agent: AgentKind,
        lastEventAt: Date?,
        activityStartedAt: Date? = nil,
        activityWindow: TimeInterval = 30
    ) {
        self.agent = agent
        self.lastEventAt = lastEventAt
        self.activityStartedAt = activityStartedAt
        self.activityWindow = activityWindow
        self._timelineVisible = State(initialValue: lastEventAt.map {
            Date().timeIntervalSince($0) < activityWindow
        } ?? false)
    }

    public var body: some View {
        // Mounted only while the last event is inside the activity window —
        // otherwise hidden/cached transcripts would keep the animation alive
        // forever. `SteadyTenthsStream` owns its own 10 Hz readout clock and
        // frame-rate packet motion, so there's no per-tick `@State` here to
        // invalidate the surrounding view tree.
        Group {
            if timelineVisible {
                SteadyTenthsStream(
                    color: Self.packetColor,
                    startedAt: activityStartedAt
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: timelineVisible)
            }
        }
        .task(id: activityScheduleKey) {
            await updateTimelineVisibility()
        }
    }

    // MARK: - Derived

    private var activityScheduleKey: String {
        "\(lastEventAt?.timeIntervalSinceReferenceDate ?? -1):\(activityWindow)"
    }

    private var activityExpiry: Date? {
        lastEventAt?.addingTimeInterval(activityWindow)
    }

    @MainActor
    private func updateTimelineVisibility() async {
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

    static var packetColor: Color { SessionsV2Theme.accent }

}
#endif
