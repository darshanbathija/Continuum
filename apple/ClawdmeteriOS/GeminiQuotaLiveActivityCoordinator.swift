import Foundation
import OSLog
import ClawdmeterShared
#if os(iOS)
import ActivityKit
#endif

private let geminiLiveActivityLogger = Logger(subsystem: "com.clawdmeter.ios", category: "GeminiLiveActivity")

/// Plan D5: dedicated Live Activity for Gemini quota. Lock Screen pill +
/// Dynamic Island compact/expanded + always-on dimmed glyph.
///
/// Gemini quota is a steady-state percent that's worth seeing without
/// unlocking, especially as the 5h window narrows toward exhaustion.
///
/// Updates are driven foreground-in-process by `UsageModel`'s
/// daemon-refresh path (`refresh(usage:)`); there is no background-push
/// path. The `pushType: .token` request below still asks ActivityKit for
/// a push token, but the token-registration plumbing is dormant (no
/// `client` is ever wired) — kept as forward-compat scaffolding for if a
/// dedicated Gemini-quota APNS push ever lands.
@MainActor
public final class GeminiQuotaLiveActivityCoordinator: ObservableObject {
    public static let shared = GeminiQuotaLiveActivityCoordinator()

    @Published public private(set) var latestContent: GeminiQuotaLiveActivityContentState?

    public weak var client: AgentControlClient?
    public var bundleId: String {
        Bundle.main.bundleIdentifier ?? "ai.continuum.ios"
    }

    public init() {}

    /// Update the Gemini quota Live Activity from the latest snapshot.
    /// No-op when iOS is older than 16.1, ActivityKit is unauthorized, or
    /// `usage` is absent / not-started (matches the "Connecting…" UI state).
    @discardableResult
    public func refresh(usage: UsageData?, stale: Bool = false) -> GeminiQuotaLiveActivityContentState? {
        guard let usage, usage.status != .notStarted else {
            latestContent = nil
            endCurrent()
            return nil
        }
        let content = GeminiQuotaLiveActivityContentState(
            sessionPct: usage.sessionPct,
            resetEpoch: usage.sessionEpoch,
            stale: stale
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
                for activity in Activity<GeminiQuotaLiveActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private func pushToActivityKit(content: GeminiQuotaLiveActivityContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            geminiLiveActivityLogger.debug("Live Activities not authorized — skipping Gemini push")
            return
        }
        let existing = Activity<GeminiQuotaLiveActivityAttributes>.activities.first
        if let activity = existing {
            if #available(iOS 16.2, *) {
                Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
            } else {
                Task { await activity.update(using: content) }
            }
        } else {
            do {
                let attrs = GeminiQuotaLiveActivityAttributes()
                if #available(iOS 16.2, *) {
                    let activity = try Activity.request(
                        attributes: attrs,
                        content: ActivityContent(state: content, staleDate: nil),
                        pushType: .token
                    )
                    geminiLiveActivityLogger.info("Started Gemini quota Live Activity")
                    observePushTokens(activity: activity)
                } else {
                    _ = try Activity.request(attributes: attrs, contentState: content)
                    geminiLiveActivityLogger.info("Started Gemini quota Live Activity (iOS 16.1, no push)")
                }
            } catch {
                geminiLiveActivityLogger.error("Failed to start Gemini Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @available(iOS 16.2, *)
    private func observePushTokens(activity: Activity<GeminiQuotaLiveActivityAttributes>) {
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await self?.registerToken(hex)
            }
            if let last = self?.lastSentToken {
                await self?.unregisterToken(last)
            }
        }
    }
    #endif

    private var lastSentToken: String?

    private func registerToken(_ token: String) async {
        guard let client else { return }
        guard let host = client.host, let bearer = client.token else { return }
        await postPushTokenJSON(
            host: host, port: client.httpPort, bearer: bearer,
            method: "POST",
            body: ["token": token, "bundleId": bundleId, "kind": "gemini-quota"]
        )
        lastSentToken = token
        geminiLiveActivityLogger.info("Registered Gemini quota push token with Mac")
    }

    private func unregisterToken(_ token: String) async {
        guard let client else { return }
        guard let host = client.host, let bearer = client.token else { return }
        await postPushTokenJSON(
            host: host, port: client.httpPort, bearer: bearer,
            method: "DELETE",
            body: ["token": token, "kind": "gemini-quota"]
        )
        if lastSentToken == token {
            lastSentToken = nil
        }
        geminiLiveActivityLogger.info("Unregistered Gemini quota push token")
    }

    private func postPushTokenJSON(
        host: String, port: Int, bearer: String, method: String, body: [String: String]
    ) async {
        // P1-Mac-19: bracket raw IPv6 literals (Tailscale pairing hands us
        // unbracketed addresses), otherwise URL(string:) returns nil and
        // we silently skip push-token registration.
        let safeHost = AgentControlClient.urlHostLiteral(host)
        guard let url = URL(string: "http://\(safeHost):\(port)/live-activities/push-token") else { return }
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
