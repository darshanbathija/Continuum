#if (os(iOS) || os(watchOS)) && canImport(WatchConnectivity)
import Foundation
import WatchConnectivity
#if canImport(OSLog)
import OSLog
#endif
#if canImport(Combine)
import Combine
#endif

/// Cross-process bridge that delivers the Anthropic OAuth token AND the
/// latest polled `UsageData` from the iPhone to its paired Apple Watch.
///
/// Why this exists: iCloud Keychain sync between Mac and iPhone works on
/// real devices, but the Apple Watch frequently can't read iCloud-synced
/// Keychain entries — paired-watch simulators have no iCloud account at all,
/// and even on a real watch the sync is best-effort. The user reported the
/// watch app stuck on "Waiting for iPhone" while the iPhone had a working
/// token; this bridge unblocks that.
///
/// What it sends, in `WCSession.updateApplicationContext`:
///   - `token`: the bare `sk-ant-…` OAuth token (or `""` to clear)
///   - `tokenPushedAt`: epoch seconds
///   - `usage`: JSON-encoded `UsageData` from the iPhone's most recent poll
///   - `usagePushedAt`: epoch seconds
///
/// Application-context delivery is "latest-wins, best-effort, replayed on
/// reconnect," which is exactly what we want — there's nothing time-critical,
/// just the current state.
public final class WatchTokenBridge: NSObject, WCSessionDelegate, @unchecked Sendable {

    public static let shared = WatchTokenBridge()

    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "WatchTokenBridge")

    /// Fires on the receiving side when a new token lands. iOS publishes,
    /// watchOS subscribes.
    public let didReceiveToken = PassthroughSubject<String?, Never>()

    /// Fires on the receiving side when a new usage snapshot lands. Same
    /// direction.
    public let didReceiveUsage = PassthroughSubject<UsageData, Never>()

    /// Fires on the receiving side when a multi-provider usage payload
    /// lands. The dict is keyed by `providerID` (e.g. "claude", "codex",
    /// "gemini"). Watch subscribes to populate per-provider meters. The
    /// legacy `didReceiveUsage` publisher continues to fire for the
    /// "claude" entry so existing single-provider watch code keeps
    /// working without changes.
    public let didReceiveUsageByProvider = PassthroughSubject<[String: UsageData], Never>()

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// Cached last-pushed context. We hold onto it so we can replay through
    /// the bridge once `WCSession` finishes activating (the iPhone often
    /// calls `pushToken` during app init, BEFORE the session is up).
    private let queueLock = NSLock()
    private var pendingToken: String?
    private var pendingTokenSeen = false
    private var pendingUsage: UsageData?
    /// Pending multi-provider usage snapshots, keyed by providerID. Sent
    /// alongside the legacy single `usage` field so v5 watches keep
    /// reading the Claude snapshot through the old path.
    private var pendingUsageByProvider: [String: UsageData] = [:]

    private override init() {
        super.init()
        if let s = session {
            s.delegate = self
            s.activate()
        }
    }

    // MARK: - Sender (iPhone-side)

    /// Push the token to the paired watch. No-op when the watch isn't
    /// installed / paired / reachable. Pass `nil` to clear.
    /// If WCSession isn't activated yet, the call is queued and replayed
    /// from `activationDidCompleteWith`.
    public func pushToken(_ token: String?) {
#if os(iOS)
        queueLock.lock()
        pendingToken = token
        pendingTokenSeen = true
        queueLock.unlock()
        sendPending()
#endif
    }

    /// Push a `UsageData` snapshot to the paired watch. Same queueing
    /// semantics as `pushToken`.
    public func pushUsage(_ usage: UsageData) {
#if os(iOS)
        queueLock.lock()
        pendingUsage = usage
        // Also surface in the by-provider dict so the watch's per-provider
        // path receives Claude updates without a separate iOS-side call.
        pendingUsageByProvider["claude"] = usage
        queueLock.unlock()
        sendPending()
#endif
    }

    /// Push a per-provider `UsageData` snapshot to the paired watch.
    /// Multiple providers can be staged and shipped together by calling
    /// this once per provider before the next flush. Pass `providerID =
    /// "claude"` to also drive the legacy single-provider path.
    public func pushUsage(providerID: String, _ usage: UsageData) {
#if os(iOS)
        queueLock.lock()
        pendingUsageByProvider[providerID] = usage
        if providerID == "claude" {
            // Keep the legacy single-field path warm for older watches.
            pendingUsage = usage
        }
        queueLock.unlock()
        sendPending()
#endif
    }

#if os(iOS)
    /// Flush whatever's queued. Tries `updateApplicationContext` first
    /// (overwriting latest-wins) and falls back to `transferUserInfo` when
    /// the context API refuses (the simulator path returns
    /// `WCErrorCodeWatchAppNotInstalled` even when the watch app IS
    /// installed via `simctl install` because the iPhone-mediated
    /// companion-install bookkeeping isn't populated).
    private func sendPending() {
        queueLock.lock()
        let token = pendingToken
        let tokenSeen = pendingTokenSeen
        let usage = pendingUsage
        let byProvider = pendingUsageByProvider
        queueLock.unlock()

        guard let session, session.activationState == .activated else {
            logger.debug("sendPending: session not activated yet, will retry on activationDidComplete")
            return
        }
        guard session.isPaired else {
            logger.debug("sendPending skipped: not paired")
            return
        }

        var payload: [String: Any] = [:]
        if tokenSeen {
            payload["token"] = token ?? ""
            payload["tokenPushedAt"] = Date().timeIntervalSince1970
        }
        if let usage, let encoded = try? JSONEncoder().encode(usage) {
            payload["usage"] = encoded
            payload["usagePushedAt"] = Date().timeIntervalSince1970
        }
        // Encode each provider snapshot as its own Data field. Picking a
        // [String: Data] dict over a single encoded blob keeps the
        // WCSession context flat (no nested NSCoding) and lets v5
        // watches happily ignore unknown keys.
        if !byProvider.isEmpty {
            let encoder = JSONEncoder()
            var encodedByProvider: [String: Data] = [:]
            for (id, snap) in byProvider {
                if let data = try? encoder.encode(snap) {
                    encodedByProvider[id] = data
                }
            }
            if !encodedByProvider.isEmpty {
                payload["usageByProvider"] = encodedByProvider
                payload["usageByProviderPushedAt"] = Date().timeIntervalSince1970
            }
        }
        guard !payload.isEmpty else { return }

        // Try latest-wins context first.
        var ctx = session.applicationContext
        for (k, v) in payload { ctx[k] = v }

        do {
            try session.updateApplicationContext(ctx)
            logger.info("sendPending ok via updateApplicationContext (token=\(tokenSeen, privacy: .public) usage=\(usage != nil, privacy: .public))")
            return
        } catch {
            logger.notice("updateApplicationContext refused (\(String(describing: error), privacy: .public)); falling back to transferUserInfo")
        }

        // Fallback: queued delivery. On real devices this is overkill, but
        // it survives the simulator's missing-companion-install bookkeeping
        // and also makes us robust against transient WC errors.
        _ = session.transferUserInfo(payload)
        logger.info("sendPending queued via transferUserInfo")
    }
#endif

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            logger.error("activation error: \(String(describing: error), privacy: .public)")
            return
        }
        logger.info("activation complete state=\(activationState.rawValue, privacy: .public)")
#if os(iOS)
        // Flush whatever the iPhone had queued during init (token + usage).
        // pushToken/pushUsage often fire before WCSession's first activation
        // completes; the queue is the cure.
        if activationState == .activated {
            sendPending()
        }
#endif
#if os(watchOS)
        // Replay any context the iPhone already shipped so cold launch
        // isn't blocked waiting for the next push.
        if activationState == .activated {
            handleContext(session.receivedApplicationContext)
        }
#endif
    }

#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so we can pair a different watch if the user swaps.
        session.activate()
    }
#endif

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
#if os(watchOS)
        handleContext(applicationContext)
#endif
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
#if os(watchOS)
        handleContext(userInfo)
#endif
    }

    // MARK: - Receiver (Watch-side)

#if os(watchOS)
    public func receive(context: [String: Any]) {
        handleContext(context)
    }

    private func handleContext(_ ctx: [String: Any]) {
        if let token = ctx["token"] as? String {
            let payload: String? = token.isEmpty ? nil : token
            logger.info("rx token len=\(token.count, privacy: .public)")
            DispatchQueue.main.async { self.didReceiveToken.send(payload) }
        }
        if let usageData = ctx["usage"] as? Data,
           let usage = try? JSONDecoder().decode(UsageData.self, from: usageData) {
            logger.info("rx usage session=\(usage.sessionPct, privacy: .public)% weekly=\(usage.weeklyPct, privacy: .public)%")
            DispatchQueue.main.async { self.didReceiveUsage.send(usage) }
        }
        if let dict = ctx["usageByProvider"] as? [String: Data] {
            let decoder = JSONDecoder()
            var byProvider: [String: UsageData] = [:]
            for (id, data) in dict {
                if let snap = try? decoder.decode(UsageData.self, from: data) {
                    byProvider[id] = snap
                }
            }
            if !byProvider.isEmpty {
                logger.info("rx usageByProvider providers=\(byProvider.keys.joined(separator: ","), privacy: .public)")
                DispatchQueue.main.async { self.didReceiveUsageByProvider.send(byProvider) }
            }
        }
    }
#endif
}
#endif
