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
@MainActor
public final class UsageHistoryStore: ObservableObject {

    @Published public private(set) var snapshot: UsageHistorySnapshot?
    @Published public private(set) var loading: Bool = false
    @Published public var activeWindow: UsageHistorySnapshot.Window = .past30d
    @Published public var providerFilter: ProviderFilter = .both

    public enum ProviderFilter: String, CaseIterable, Sendable {
        case both, claude, codex

        public var label: String {
            switch self {
            case .both: return "Both"
            case .claude: return "Claude"
            case .codex: return "Codex"
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
    }
}
