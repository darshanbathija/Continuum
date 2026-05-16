import Foundation
import OSLog
import ClawdmeterShared
#if os(iOS)
import ActivityKit
import UIKit
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

    /// Reference to the AgentControlClient set by the iOS app. We need
    /// this to POST push tokens to the paired Mac as ActivityKit hands
    /// them to us. Optional so tests / preview environments don't have
    /// to wire a paired client.
    public weak var client: AgentControlClient?

    /// Bundle id we report to the Mac when registering a push token.
    /// Defaults to the running app's main-bundle id, which is the value
    /// Apple expects in `apns-topic` (suffix appended Mac-side).
    public var bundleId: String {
        Bundle.main.bundleIdentifier ?? "com.clawdmeter.iOS"
    }

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
                if #available(iOS 16.2, *) {
                    let activity = try Activity.request(
                        attributes: attrs,
                        content: ActivityContent(state: content, staleDate: nil),
                        pushType: .token
                    )
                    liveActivityLogger.info("Started aggregate Live Activity with push token")
                    observePushTokens(activity: activity)
                } else {
                    _ = try Activity.request(attributes: attrs, contentState: content)
                    liveActivityLogger.info("Started aggregate Live Activity (iOS 16.1, no push)")
                }
            } catch {
                liveActivityLogger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Phase 10 / D9 narrow scope: ActivityKit hands us a per-activity
    /// push token; ship it to the paired Mac so MacAPNSPusher can
    /// deliver background updates. Tokens rotate — we forward every
    /// new one and unregister when the activity ends.
    @available(iOS 16.2, *)
    private func observePushTokens(activity: Activity<SessionLiveActivityAttributes>) {
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await self?.registerToken(hex)
            }
            // Stream ends when the activity does — unregister the last
            // known token so the Mac doesn't keep pushing into the void.
            if let last = await self?.lastSentToken {
                await self?.unregisterToken(last)
            }
        }
    }
    #endif

    /// Cache of the most recent token we shipped to the Mac so we can
    /// unregister it cleanly when the activity ends.
    private var lastSentToken: String?

    private func registerToken(_ token: String) async {
        guard let client else { return }
        guard let host = client.host, let bearer = client.token else { return }
        await postPushTokenJSON(
            host: host, port: client.httpPort, bearer: bearer,
            method: "POST",
            body: ["token": token, "bundleId": bundleId]
        )
        lastSentToken = token
        liveActivityLogger.info("Registered Live Activity push token with paired Mac")
    }

    private func unregisterToken(_ token: String) async {
        guard let client else { return }
        guard let host = client.host, let bearer = client.token else { return }
        await postPushTokenJSON(
            host: host, port: client.httpPort, bearer: bearer,
            method: "DELETE",
            body: ["token": token]
        )
        if lastSentToken == token {
            lastSentToken = nil
        }
        liveActivityLogger.info("Unregistered Live Activity push token")
    }

    private func postPushTokenJSON(
        host: String, port: Int, bearer: String, method: String, body: [String: String]
    ) async {
        guard let url = URL(string: "http://\(host):\(port)/live-activities/push-token") else { return }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 8
        _ = try? await URLSession.shared.data(for: req)
    }
}
