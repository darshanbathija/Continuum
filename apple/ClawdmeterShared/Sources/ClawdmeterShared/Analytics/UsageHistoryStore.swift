import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(OSLog)
import OSLog
#endif

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// `@MainActor` ObservableObject bridge between the analytics loader actor
/// and SwiftUI. Apps construct one of these at startup and pass it down via
/// `@EnvironmentObject`.
///
/// Plan A8: refreshes on app-foreground via `NotificationCenter` + every
/// 60s via a `Timer`. Both invalidations are cheap because the cache makes
/// warm-load near-zero.
/// PR #31: OpencodeSSEAdapter posts this when an opencode `usage`
/// event arrives + maps through OpencodeUsageMapper. UsageHistoryStore
/// subscribes and folds the record into `opencodeLiveRecords` for the
/// menu-bar dollar gauge and Analytics. `userInfo["record"]` carries
/// the `UsageRecord`.
public extension Notification.Name {
    static let opencodeUsageRecorded = Notification.Name("clawdmeter.opencode.usage.recorded")
}

@MainActor
public final class UsageHistoryStore: ObservableObject {

    @Published public private(set) var snapshot: UsageHistorySnapshot?
    @Published public private(set) var loading: Bool = false
    @Published public var activeWindow: UsageHistorySnapshot.Window = .past30d
    @Published public var providerFilter: ProviderFilter = .both

    /// PR #31 chunk 3: live opencode usage events recorded since app
    /// launch. Driven by the `opencodeUsageRecorded` notification the
    /// SSE adapter posts; rolled into `opencodeTodayCostUSD` /
    /// `opencodeWeekCostUSD` for the menu-bar dollar gauge (A2).
    /// Bounded to the last 5000 events to keep memory bounded for
    /// long-running sessions; older events are dropped FIFO.
    @Published public private(set) var opencodeLiveRecords: [UsageRecord] = []
    private static let maxLiveRecords = 5000

    public enum ProviderFilter: String, CaseIterable, Sendable {
        /// All providers visible (replaces `.both` for the N-provider world
        /// per X3-C). `.both` retained for back-compat with persisted user
        /// pref values; treated as a synonym for `.all`.
        case all
        case both
        case claude
        case codex
        case gemini
        /// v0.22.8: OpenCode disk-parsed analytics (separate from the
        /// SSE live-records bucket used for the menu-bar dollar gauge).
        case opencode
        case cursor

        public var label: String {
            switch self {
            case .all, .both: return "All"
            case .claude:     return "Claude"
            case .codex:      return "Codex"
            case .gemini:     return "Gemini"
            case .opencode:   return "OpenCode"
            case .cursor:     return "Cursor"
            }
        }

        /// True when this filter includes the given provider in rendering.
        /// `.all` and `.both` include everyone; per-provider filters
        /// include only that provider.
        public func includes(_ provider: UsageRecord.Provider) -> Bool {
            switch self {
            case .all, .both: return true
            case .claude:     return provider == .claude
            case .codex:      return provider == .codex
            case .gemini:     return provider == .gemini
            case .opencode:   return provider == .opencode
            case .cursor:     return provider == .cursor
            }
        }
    }

    private let loader: UsageHistoryLoader
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "Analytics")
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    // MARK: - B2 mtime probe + idle backoff
    //
    // Pre-B2: refresh ran every 60s unconditionally. Even with the loader's
    // per-file mtime cache (which skips re-parsing unchanged files),
    // walking every JSONL on disk per tick burns CPU on machines with
    // hundreds of session files. B2 short-circuits via a single stat-only
    // probe, and slides the timer to a longer interval after consecutive
    // no-change ticks.
    //
    // States:
    //   - **active**  (just saw a change) → 60s interval
    //   - **idle**    (≥1 consecutive no-change tick) → 300s interval
    //
    // App foreground always resets to active + force-refreshes once.
    /// Highest source mtime observed at the end of the last refresh.
    /// Set on every successful refresh (mtime-probe or full load); used
    /// to detect "nothing changed since last refresh" so the next tick
    /// can short-circuit.
    private var lastSeenMaxMtime: Date?
    /// Consecutive ticks where the mtime probe found no change. Drives
    /// the slide from `baseInterval` to `idleInterval`.
    private var consecutiveIdleTicks: Int = 0
    private static let baseInterval: TimeInterval = 60     // active
    private static let idleInterval: TimeInterval = 300    // backoff cap (5 min)
    /// After this many no-change ticks at base interval, slide to idle.
    private static let idleThreshold = 2

    /// Whether snapshot has ever been populated. Drives the cold-load
    /// skeleton in the UI.
    public var hasInitialSnapshot: Bool {
        snapshot != nil
    }

    public init(loader: UsageHistoryLoader = UsageHistoryLoader()) {
        self.loader = loader
        installLifecycleObservers()
        // Kick the initial load asynchronously so the constructor returns
        // immediately and the UI can render its skeleton. force:true on
        // the first refresh so the probe doesn't short-circuit before
        // lastSeenMaxMtime is initialized.
        Task { await self.refresh(force: true) }
    }

    deinit {
        // Note: refreshTimer and observers can't be touched here because of
        // @MainActor isolation. They're owned by NotificationCenter / RunLoop
        // and clean themselves up when the store is released — fine for an
        // app-lifetime singleton.
    }

    // MARK: - Refresh

    /// B2: refresh that short-circuits when no source mtime changed and
    /// applies idle-backoff to the timer interval. Pass `force: true`
    /// to bypass the probe — used by `forceRefresh()` / `invalidate()`
    /// / app-foreground notifications, which want to skip the probe so
    /// the UI updates immediately.
    ///
    /// Mtime capture rule: we probe BEFORE `loadAll()` and save that
    /// pre-load mtime as `lastSeenMaxMtime`. Capturing a post-load
    /// mtime would silently mark files written *during* the load as
    /// "already seen" without their content being reflected in the
    /// published snapshot — the next probe would short-circuit and the
    /// data would not surface until something else forced a refresh
    /// (PR #137 review P1 #2). Pre-load capture means concurrent writes
    /// bump the mtime above what we saved, triggering a re-load on the
    /// next tick.
    public func refresh(force: Bool = false) async {
        // Probe mtime up front regardless of `force` so we have a
        // pre-load baseline to save. On non-force paths the probe also
        // gates short-circuiting; on force paths it just primes
        // `lastSeenMaxMtime` and resets idle backoff.
        let probedMtime = await loader.mostRecentSourceMtime()

        if !force {
            // mtime probe — single stat per source dir (no parsing).
            // Skip the full loadAll() if nothing changed.
            if let last = lastSeenMaxMtime, let probed = probedMtime, probed <= last {
                // No change → bump idle counter + maybe slide timer.
                consecutiveIdleTicks += 1
                if consecutiveIdleTicks == Self.idleThreshold {
                    rescheduleTimer(interval: Self.idleInterval)
                }
                return
            }
        }

        // Reaching here means we're going to call loadAll(). Reset the
        // idle-backoff state so the timer goes back to the active
        // interval — covers both "unforced refresh detected activity"
        // and "foreground / forceRefresh / invalidate kicked us out of
        // backoff". Previously the force path skipped this branch and
        // left the timer stuck at idleInterval (PR #137 review P1 #1).
        if consecutiveIdleTicks > 0 {
            consecutiveIdleTicks = 0
            rescheduleTimer(interval: Self.baseInterval)
        }
        // Save the PRE-load probe so writes that race with loadAll()
        // get re-detected on the next tick instead of being marked
        // already-seen (see method-level doc).
        if let probed = probedMtime { lastSeenMaxMtime = probed }

        loading = true
        let result = await loader.loadAll()
        snapshot = result
        loading = false
    }

    public func forceRefresh() {
        Task { await refresh(force: true) }
    }

    public func invalidate() async {
        await loader.invalidate()
        await refresh(force: true)
    }

    /// Reschedule the periodic timer at a new interval. Invalidates the
    /// old timer and registers a fresh one on the main run loop.
    private func rescheduleTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer
        logger.debug("B2 idle backoff: rescheduled refresh timer to \(interval, privacy: .public)s")
    }

    // MARK: - Lifecycle

    private func installLifecycleObservers() {
        let center = NotificationCenter.default

        // B2: schedule the periodic refresh via rescheduleTimer() so the
        // idle-backoff path can later swap the interval. Initial: base
        // (60s); slides to idle (300s) after consecutive no-change ticks.
        rescheduleTimer(interval: Self.baseInterval)

#if canImport(UIKit) && !os(watchOS)
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // App foreground: force-refresh so the UI reflects any
            // changes that landed while the app was backgrounded and so
            // we exit idle-backoff (`refresh(force:)` resets the
            // idle-tick counter + slides the timer back to baseInterval).
            Task { @MainActor in await self?.refresh(force: true) }
        })
#elseif canImport(AppKit)
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        })
#endif
        // PR #31 chunk 3: subscribe to opencode usage events so the
        // menu-bar dollar gauge + Analytics fold opencode costs in
        // alongside the loader-sourced providers.
        observers.append(center.addObserver(
            forName: .opencodeUsageRecorded,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let record = note.userInfo?["record"] as? UsageRecord else { return }
            Task { @MainActor in
                self?.appendOpencodeRecord(record)
                self?.scheduleOpencodeMirrorRefresh()
            }
        })
    }

    /// v0.23.3 T9 — debounced trigger that asks the analytics loader to
    /// rebuild the snapshot soon after a live opencode usage event lands.
    /// The loader reads opencode's SQLite database (which opencode itself
    /// wrote when the LLM completion finished), folds the new rows into
    /// `byProvider[.opencode]`, publishes a fresh snapshot, and AppRuntime
    /// mirrors it into iCloud KV via `UsageCloudMirror.writeAnalyticsSnapshot`.
    ///
    /// Result: a paired iPhone sees the new opencode dollar values via
    /// iCloud within seconds of the Mac processing the SSE `usage` event,
    /// instead of waiting up to 60s for the next periodic refresh tick.
    ///
    /// Debounce: 10s minimum gap between refreshes triggered by opencode
    /// events. A long opencode session can fire many `usage` events in
    /// quick succession (one per LLM completion); coalescing them into a
    /// single refresh per 10s window keeps the SQLite-read + iCloud-write
    /// cost bounded.
    @MainActor
    private func scheduleOpencodeMirrorRefresh() {
        let now = Date()
        let cooldown: TimeInterval = 10
        if let last = lastOpencodeMirrorRefreshAt,
           now.timeIntervalSince(last) < cooldown {
            return
        }
        lastOpencodeMirrorRefreshAt = now
        Task { @MainActor in
            await refresh()
        }
    }

    /// Timestamp of the last opencode-event-triggered refresh. Drives the
    /// 10s debounce in `scheduleOpencodeMirrorRefresh`.
    private var lastOpencodeMirrorRefreshAt: Date?

    /// Append a live opencode UsageRecord. Trims to the 5000-item
    /// retention cap so memory stays bounded over a long-running day.
    /// Called from the .opencodeUsageRecorded observer; exposed
    /// `internal` so tests can drive it directly without dispatching
    /// a real Notification.
    internal func appendOpencodeRecord(_ record: UsageRecord) {
        opencodeLiveRecords.append(record)
        if opencodeLiveRecords.count > Self.maxLiveRecords {
            opencodeLiveRecords.removeFirst(opencodeLiveRecords.count - Self.maxLiveRecords)
        }
    }

    /// PR #31 chunk 3 (A2): sum of opencode cost recorded since 00:00
    /// of the user's local day. Drives the menu-bar dollar gauge's
    /// "$X today" label.
    public var opencodeTodayCostUSD: Decimal {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return opencodeLiveRecords
            .lazy
            .filter { $0.timestamp >= startOfDay }
            .map { $0.tokens.costUSD }
            .reduce(Decimal(0), +)
    }

    /// PR #31 chunk 3 (A2): sum of opencode cost over the trailing
    /// 7 days (rolling — NOT a calendar week). Drives the "$Y this
    /// week" sub-label on the dollar gauge.
    public var opencodeWeekCostUSD: Decimal {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return opencodeLiveRecords
            .lazy
            .filter { $0.timestamp >= cutoff }
            .map { $0.tokens.costUSD }
            .reduce(Decimal(0), +)
    }
}
