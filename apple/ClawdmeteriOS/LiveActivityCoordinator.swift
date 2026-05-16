import Foundation
import OSLog
import ClawdmeterShared
#if os(iOS)
import ActivityKit
#endif

private let liveActivityLogger = Logger(subsystem: "com.clawdmeter.ios", category: "LiveActivity")

/// Aggregate iOS Live Activity coordinator. Sessions v2 Phase 10 / E6.
///
/// One activity for the whole app — shows "N active sessions" + the
/// most-urgent item on the Lock Screen + Dynamic Island. Codex's
/// outside-voice review correctly flagged per-session activities as
/// product-incoherent at scale; the user picked aggregate (D7 eng).
///
/// Phase 10 v2.0 ships the attribute shape + coordinator + foreground
/// in-process update wiring. The widget extension + APNS push token
/// wiring (D9 narrow scope) land in the v2.0.1 follow-up — at which
/// point the `Activity.request(...)` call here starts producing real
/// Lock Screen pills.
@MainActor
public final class LiveActivityCoordinator: ObservableObject {
    public static let shared = LiveActivityCoordinator()

    /// Latest content state — published so iOS UI (e.g., the new-session
    /// sheet) can mirror what the Lock Screen would show.
    @Published public private(set) var latestContent: SessionLiveActivityContentState?

    public init() {}

    /// Refresh the live activity from the current sessions list. Computes
    /// the aggregate content state and pushes it to ActivityKit when
    /// available. Returns the content state for inspection.
    @discardableResult
    public func refresh(from sessions: [AgentSession], cityNamer: CityNamer? = nil) -> SessionLiveActivityContentState? {
        let active = sessions.filter { $0.archivedAt == nil && $0.status != .done }
        guard !active.isEmpty else {
            latestContent = nil
            endCurrent()
            return nil
        }
        let mostRecent = active.max(by: { $0.lastEventAt < $1.lastEventAt }) ?? active[0]
        let cityLabel = cityNamer?.cityName(for: mostRecent.id) ?? CityPool.cityName(for: mostRecent.id)
        let needsAttention = active.contains { $0.planText != nil && $0.status == .planning }
        let content = SessionLiveActivityContentState(
            activeSessionCount: active.count,
            latestCity: cityLabel,
            latestAgentKind: mostRecent.agent,
            latestState: mostRecent.status.rawValue,
            needsAttention: needsAttention
        )
        latestContent = content

        #if os(iOS)
        if #available(iOS 16.1, *) {
            pushToActivityKit(content: content)
        }
        #endif
        return content
    }

    public func endCurrent() {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            Task {
                for activity in Activity<SessionLiveActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private func pushToActivityKit(content: SessionLiveActivityContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityLogger.debug("Live Activities not authorized — skipping push")
            return
        }
        let existing = Activity<SessionLiveActivityAttributes>.activities.first
        if let activity = existing {
            Task { await activity.update(using: content) }
        } else {
            do {
                let attrs = SessionLiveActivityAttributes()
                _ = try Activity.request(attributes: attrs, contentState: content)
                liveActivityLogger.info("Started aggregate Live Activity")
            } catch {
                liveActivityLogger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    #endif
}
