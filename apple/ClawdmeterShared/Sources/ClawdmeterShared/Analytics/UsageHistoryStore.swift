import Foundation
import Combine
import OSLog

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

        public var label: String {
            switch self {
            case .all, .both: return "All"
            case .claude:     return "Claude"
            case .codex:      return "Codex"
            case .gemini:     return "Gemini"
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
            }
        }
    }

    private let loader: UsageHistoryLoader
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "Analytics")
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Whether snapshot has ever been populated. Drives the cold-load
    /// skeleton in the UI.
    public var hasInitialSnapshot: Bool {
        snapshot != nil
    }

    public init(loader: UsageHistoryLoader = UsageHistoryLoader()) {
        self.loader = loader
        installLifecycleObservers()
        // Kick the initial load asynchronously so the constructor returns
        // immediately and the UI can render its skeleton.
        Task { await self.refresh() }
    }

    deinit {
        // Note: refreshTimer and observers can't be touched here because of
        // @MainActor isolation. They're owned by NotificationCenter / RunLoop
        // and clean themselves up when the store is released — fine for an
        // app-lifetime singleton.
    }

    // MARK: - Refresh

    public func refresh() async {
        loading = true
        let result = await loader.loadAll()
        snapshot = result
        loading = false
    }

    public func forceRefresh() {
        Task { await refresh() }
    }

    public func invalidate() async {
        await loader.invalidate()
        await refresh()
    }

    // MARK: - Lifecycle

    private func installLifecycleObservers() {
        let center = NotificationCenter.default

        // Periodic 60s refresh while the app is running.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer

#if canImport(UIKit) && !os(watchOS)
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })
#elseif canImport(AppKit)
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
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
            Task { @MainActor in self?.appendOpencodeRecord(record) }
        })
    }

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
