import AppKit
import SwiftUI
import Combine
import OSLog
import ClawdmeterShared

/// Owns the menu bar `NSStatusItem`s directly, instead of going through SwiftUI's
/// `MenuBarExtra`. We need this for two reasons:
///   1. `MenuBarExtra(isInserted:)` on macOS Tahoe enters a self-perpetuating
///      KVO loop that pegs the main thread at 100% CPU — see PopoverView.
///   2. The user wants per-provider toggles for "show in menu bar". `NSStatusItem`
///      has `isVisible` plus `NSStatusBar.system.removeStatusItem(_:)`, both of
///      which work as expected without any Tahoe quirks.
///
/// One `ProviderStatusController` per provider — Claude and Codex. The
/// controller owns its `NSStatusItem` and `NSPopover`, subscribes to the
/// `AppModel`'s `objectWillChange` to refresh the button image on each poll,
/// and hides itself when the user toggles its preference off.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "AppDelegate")

    /// Set by `ClawdmeterMacApp` before `applicationDidFinishLaunching` is
    /// invoked, so we have access to the polled models. Marked `unowned`
    /// because runtime is owned by the App's `@StateObject` and outlives us.
    static weak var runtime: AppRuntime?

    private var claudeController: ProviderStatusController?
    private var codexController: ProviderStatusController?
    private var geminiController: ProviderStatusController?
    /// PR #32 (A2): OpenCode menu-bar item renders `$X.XX` (today's
    /// cost) instead of a quota gauge — OpenCode doesn't have a
    /// rolling 5h window. Reads UsageHistoryStore.opencodeTodayCostUSD.
    private var opencodeController: OpencodeStatusController?

    private var prefsObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    private var showDashboardObserver: NSObjectProtocol?

    /// Perf: `UserDefaults.didChangeNotification` (object:nil) fires on EVERY
    /// app-wide defaults write, so `applyVisibilityFromPrefs` must filter to
    /// the 4 `menuBarShown` keys it cares about — otherwise unrelated pref
    /// writes thrash `setVisible(_:)` across all controllers. `nil` means
    /// "not yet applied" so the first call always runs.
    private var lastAppliedVisibility: (claude: Bool, codex: Bool, gemini: Bool, opencode: Bool)?

    /// Notification posted by the menu bar popover's "Show dashboard" button.
    /// Handled here so the AppDelegate can flip the activation policy and
    /// surface the SwiftUI window.
    static let showDashboardNotification = Notification.Name("clawdmeter.showDashboard")

    /// Title set on the SwiftUI `Window("Continuum", id: "dashboard")` —
    /// matched when the user closes that window so we can drop the Dock icon.
    /// `nonisolated` so the notification observer's @Sendable closure can read
    /// it; the value is an immutable string literal and trivially thread-safe.
    nonisolated private static let dashboardWindowTitle = "Continuum"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = AppDelegate.runtime else {
            logger.warning("AppDelegate: runtime not ready at launch; waiting for SwiftUI binding.")
            return
        }
        configure(runtime: runtime)
        // v0.27.0: installFileMenuExtensions() (the "Open Folder in
        // Design…" File-menu item) was removed along with the Design
        // tab + AppRuntime.openFolderInDesign(baseDir:).
    }

    func configure(runtime: AppRuntime) {
        AppDelegate.runtime = runtime
        if claudeController == nil {
            claudeController = ProviderStatusController(model: runtime.claudeModel, runtime: runtime)
        }
        if codexController == nil {
            codexController = ProviderStatusController(model: runtime.codexModel, runtime: runtime)
        }
        if geminiController == nil {
            geminiController = ProviderStatusController(model: runtime.geminiModel, runtime: runtime)
        }
        if opencodeController == nil {
            opencodeController = OpencodeStatusController(runtime: runtime)
        }
        installObserversIfNeeded()
        applyVisibilityFromPrefs()
        Task(priority: .utility) { @MainActor in
            OpencodeProcessManager.shared.prepareRuntimeHost()
        }

        // PR #24a critical-gap fix: surface loopback-port-bind failure
        // explicitly. If `loopbackClient == nil` the agent control server
        // exhausted its port range — Mac Code IDE actions (approve plan,
        // refine, send prompt, stop) won't reach the daemon. Silent
        // failure is the worst outcome; show the user once at launch.
        if runtime.agentControlServer.boundPort == nil {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Continuum couldn't start its agent server"
                alert.informativeText = """
                Ports 21731–21741 are all in use. Sessions, chat, and \
                pairing will not work until you free a port or restart \
                your Mac.
                """
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Continue anyway")
                alert.runModal()
            }
        }
    }

    private func installObserversIfNeeded() {
        guard prefsObserver == nil else { return }

        // Re-evaluate which items are visible whenever the user toggles a
        // pref from the dashboard. `UserDefaults.didChangeNotification` is
        // posted on every set; we filter inside `applyVisibilityFromPrefs`.
        prefsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyVisibilityFromPrefs()
            }
        }

        // Hide the Dock icon when the dashboard window closes — the app keeps
        // running with the menu bar items as its only visible surface.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow,
                  win.title == AppDelegate.dashboardWindowTitle
            else { return }
            Task { @MainActor in
                self?.didCloseDashboard()
            }
        }

        // The menu bar popover's "Show dashboard" button posts this so we
        // can resurface the window from anywhere in the app.
        showDashboardObserver = NotificationCenter.default.addObserver(
            forName: AppDelegate.showDashboardNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showDashboard()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in [prefsObserver, windowCloseObserver, showDashboardObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        // F2-wire: opportunistic WAL checkpoint on normal exit so the
        // orchestration log's sidecar files (`-wal`/`-shm`) don't accrete
        // unbounded across reboots, and so a normal exit gives the next
        // cold start a single-file open. Privacy-deletion paths still
        // checkpoint inline; this catches the steady-state shutdown.
        //
        // We use `Task` rather than awaiting synchronously — Apple won't
        // wait on us past a few hundred ms during termination, and a
        // best-effort fire-and-let-the-OS-eventually-flush is correct:
        // the next launch's `OrchestrationEventStore.init` rebuilds from
        // the WAL anyway. Synchronous semaphore wait here would risk
        // blocking the AppKit terminate path.
        if let registry = AppDelegate.runtime?.agentSessionRegistry {
            Task.detached {
                await registry.checkpointEventStore()
            }
        }
    }

    /// Keep the app alive when the dashboard window is closed — the menu bar
    /// items are the persistent surface. User quits via Cmd+Q or
    /// Right-click on Dock icon → Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// When the user re-launches Clawdmeter (from /Applications, Spotlight,
    /// or by clicking the Dock icon) while it's running, re-show the
    /// dashboard. The Dock icon comes back as a side-effect of switching
    /// activation policy to `.regular`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDashboard() }
        return true
    }

    /// v0.7.7: NSUserActivity Handoff receiver. iOS advertises
    /// `com.clawdmeter.continue-codex-thread` with userInfo[threadId];
    /// macOS receives it here, focuses the dashboard, and broadcasts a
    /// notification SessionsView observes to highlight the matching
    /// thread.
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        // v0.7.7 — codex thread (deep-link to a specific JSONL thread).
        if userActivity.activityType == "com.clawdmeter.continue-codex-thread",
           let threadId = userActivity.userInfo?["threadId"] as? String,
           !threadId.isEmpty {
            showDashboard()
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: AppDelegate.continueCodexThreadFromHandoff,
                object: nil,
                userInfo: ["threadId": threadId]
            )
            return true
        }
        // v0.9.x — chat thread Handoff (NEW-E6 from v0.8 plan). iOS
        // advertises `com.clawdmeter.continue-chat-thread` with the
        // chat session UUID; we focus the dashboard + broadcast a
        // notification the Chat tab observer listens for to select
        // the matching session.
        if userActivity.activityType == "com.clawdmeter.continue-chat-thread",
           let sessionIdString = userActivity.userInfo?["sessionId"] as? String,
           !sessionIdString.isEmpty {
            showDashboard()
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: AppDelegate.continueChatSessionFromHandoff,
                object: nil,
                userInfo: ["sessionId": sessionIdString]
            )
            return true
        }
        return false
    }

    /// Called when the dashboard window has just been closed (X button or
    /// Cmd+W). Drops the app to `.accessory` so the Dock icon disappears,
    /// leaving the menu bar items as the only visible surface.
    private func didCloseDashboard() {
        // A tiny delay lets SwiftUI finish tearing down the window before
        // we change the activation policy — avoids visual flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Re-surface the dashboard window. Restores the Dock icon (`.regular`)
    /// and asks SwiftUI to (re)open the `Window(id: "dashboard")` scene
    /// via a posted notification the `DashboardOpenerScene` listens to.
    fileprivate func showDashboard() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Look for an existing dashboard NSWindow first — SwiftUI keeps the
        // scene alive after close, so the NSWindow often still exists.
        if let existing = NSApp.windows.first(where: { $0.title == AppDelegate.dashboardWindowTitle && $0.contentViewController != nil }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // No live window — ask SwiftUI to create one. The dashboard scene
        // observes `openDashboardRequest` and calls `openWindow(id:)` when
        // it ticks.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AppDelegate.openDashboardRequest, object: nil)
        }
    }

    /// Internal — only used to bridge `showDashboard()` into the SwiftUI
    /// hierarchy so we can call `openWindow(id:)`.
    static let openDashboardRequest = Notification.Name("clawdmeter.openDashboardRequest")

    /// v0.7.7: posted when an NSUserActivity Handoff from iOS lands.
    /// `userInfo["threadId"]` carries the Codex SDK threadId; the
    /// SessionsView observer focuses the matching thread.
    static let continueCodexThreadFromHandoff =
        Notification.Name("clawdmeter.continueCodexThreadFromHandoff")

    /// v0.9.x: posted when a chat-tab Handoff from iOS lands.
    /// `userInfo["sessionId"]` carries the chat AgentSession.id; the
    /// Chat workspace observer focuses the matching pane.
    static let continueChatSessionFromHandoff =
        Notification.Name("clawdmeter.continueChatSessionFromHandoff")

    private func applyVisibilityFromPrefs() {
        let defaults = UserDefaults.standard
        // v0.29.32: providers are opt-in — a disabled provider must NOT show an
        // (empty) menu-bar gauge, so AND each shown-pref with its enabled flag.
        // setProviderEnabled writes both in lockstep + this observer re-applies.
        let claudeShown = (defaults.object(forKey: ProviderStatusController.prefKey("claude")) as? Bool ?? true)
            && ProviderEnablement.isEnabled("claude")
        let codexShown = (defaults.object(forKey: ProviderStatusController.prefKey("codex")) as? Bool ?? true)
            && ProviderEnablement.isEnabled("codex")
        let geminiShown = (defaults.object(forKey: ProviderStatusController.prefKey("gemini")) as? Bool ?? true)
            && ProviderEnablement.isEnabled("gemini")
        // PR #32: OpenCode menu-bar item default OFF — opencode is opt-
        // in and many users won't have it installed. The Settings →
        // Providers panel shows the install state; toggling on the
        // menu-bar item is a separate explicit step (matches how iOS
        // Live tab toggle behaves).
        let opencodeShown = (defaults.object(forKey: ProviderStatusController.prefKey("opencode")) as? Bool ?? false)
            && ProviderEnablement.isEnabled("opencode")
        // Perf: this fires on every app-wide defaults write via
        // `didChangeNotification`; bail unless one of the 4 menu-bar keys
        // actually moved so we don't re-toggle every NSStatusItem on
        // unrelated pref changes.
        let next = (claude: claudeShown, codex: codexShown, gemini: geminiShown, opencode: opencodeShown)
        guard lastAppliedVisibility == nil || lastAppliedVisibility! != next else { return }
        lastAppliedVisibility = next
        claudeController?.setVisible(claudeShown)
        codexController?.setVisible(codexShown)
        geminiController?.setVisible(geminiShown)
        opencodeController?.setVisible(opencodeShown)
    }
}

// MARK: - Per-provider controller

@MainActor
final class ProviderStatusController: NSObject {
    private let model: AppModel
    private weak var runtime: AppRuntime?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    /// This controller's provider, derived from the AppModel config.
    private var providerCase: TahoeProvider {
        switch model.config.id {
        case "claude": return .claude
        case "codex":  return .codex
        case "gemini": return .gemini
        case "cursor": return .cursor
        default:       return .claude
        }
    }
    /// #38: controller-owned selection driver so each open re-targets the
    /// (cached) popover's tab to THIS provider, instead of leaving whatever
    /// tab the user last switched to inside the popover.
    private lazy var selection = MenuBarPopoverSelection(initial: providerCase)

    init(model: AppModel, runtime: AppRuntime) {
        self.model = model
        self.runtime = runtime
        super.init()
        // Mirror the model's @Published changes onto the status item button.
        // `objectWillChange` fires before `usage` is updated, so hop one
        // runloop tick later via `Task { @MainActor in ... }` to read the
        // new value.
        model.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshImage() }
            }
            .store(in: &cancellables)
    }

    static func prefKey(_ providerID: String) -> String {
        "clawdmeter.\(providerID).menuBarShown"
    }

    func setVisible(_ visible: Bool) {
        if visible {
            ensureStatusItem()
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.image = currentImage()
        statusItem = item

        // Eagerly build the popover so the first click renders without delay.
        let pop = NSPopover()
        pop.behavior = .transient
        // Initial size — NSHostingController.sizingOptions = .preferredContentSize
        // (macOS 13+) makes the popover re-size to whatever SwiftUI's intrinsic
        // content height ends up being. The collapsed/expanded Advanced section
        // (and any future surface tweaks) no longer need hand-tuned heights.
        pop.contentSize = NSSize(width: 380, height: 600)
        // Tahoe 26 redesign: swap the legacy `PopoverView` for the new
        // `MacMenubarPopover` glass card. Each menu-bar item opens the
        // same popover (all three providers via segmented control); the
        // segmented control defaults to whichever provider's status
        // item was clicked.
        //
        // v0.22.4 fix: pass the per-provider AppModels directly so the
        // popover observes them via @ObservedObject (through a
        // MenuBarLiveSource wrapper). The previous wiring captured a
        // value-typed TahoeLiveBindings snapshot at status-item
        // construction time — which was often `.demo` because pollers
        // hadn't completed when the status item was eagerly built at
        // launch. NSPopover never re-rendered the SwiftUI content, so
        // the demo data stuck around forever.
        let popoverView: MacMenubarPopover
        if let runtime {
            popoverView = MacMenubarPopover(
                initialProvider: providerCase,
                onOpenDashboard: { [weak self] in
                    guard let self else { return }
                    self.popover?.performClose(nil)
                    NotificationCenter.default.post(name: AppDelegate.openDashboardRequest, object: nil)
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                },
                onSyncIPhone: { [weak self] in
                    self?.showPairingPopover()
                },
                claudeModel: runtime.claudeModel,
                codexModel: runtime.codexModel,
                geminiModel: runtime.geminiModel,
                // Thread the live Cursor poller so the Cursor popover tab shows
                // real usage instead of the hardcoded stale 0% row.
                cursorModel: runtime.cursorModel,
                // #38: controller-owned driver re-targets the tab on each open.
                selectionDriver: selection,
                // v0.22.30: thread the usage history store so the
                // OpenCode tab renders Today + This-week dollar tiles.
                usageHistoryStore: runtime.usageHistoryStore
            )
        } else {
            // Test / preview safety net — no live runtime, no live data.
            popoverView = MacMenubarPopover(
                initialProvider: providerCase,
                onOpenDashboard: {},
                onSyncIPhone: {}
            )
        }
        // Apply chrome modifiers outside the if-else so both branches
        // get the same theme + width framing.
        let themedPopover = popoverView
            .tahoeTheme(TahoeThemeStore.loaded())
            .frame(width: 388)
        let host = NSHostingController(rootView: themedPopover)
        host.sizingOptions = NSHostingSizingOptions.preferredContentSize
        pop.contentViewController = host
        popover = pop
    }

    /// Pairing QR popover — anchored to the same menu-bar button so users
    /// don't have to dig into Settings → Sessions to pair an iPhone. Closes
    /// the parent dashboard popover first so the user only sees one popover
    /// at a time.
    private var pairingPopover: NSPopover?

    private func showPairingPopover() {
        popover?.performClose(nil)
        guard let runtime, let button = statusItem?.button else { return }
        let pop = pairingPopover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.contentSize = NSSize(width: 340, height: 460)
            let view = PairingQRPopoverContent(runtime: runtime)
                .tahoeTheme(TahoeThemeStore.loaded())
                .padding(16)
                .frame(width: 340)
            let host = NSHostingController(rootView: view)
            host.sizingOptions = NSHostingSizingOptions.preferredContentSize
            p.contentViewController = host
            pairingPopover = p
            return p
        }()
        // Tiny delay so the dashboard popover's dismiss animation can
        // complete before the new popover takes the same anchor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func refreshImage() {
        statusItem?.button?.image = currentImage()
    }

    private func currentImage() -> NSImage {
        let template = MenuBarGaugeView.isTemplateAsset(model.config.logoAssetName)
        if model.needsReauth {
            let img = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "reconnect")
                ?? NSImage()
            img.isTemplate = template
            return img
        }
        if let usage = model.usage {
            return MenuBarGaugeView.renderLabel(
                for: usage,
                assetName: model.config.logoAssetName,
                template: template,
                hasWeekly: model.config.hasWeeklyWindow
            )
        }
        return MenuBarGaugeView.renderEmptyLabel(
            assetName: model.config.logoAssetName,
            template: template
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // v0.22.10: kick a forcePoll on every provider before
            // showing the popover so the gauges reflect the latest
            // state — particularly important after a long idle when
            // the cached UsageData may be tens of minutes stale. The
            // forcePoll is fire-and-forget; the @ObservedObject
            // MenuBarLiveSource catches the resulting `usage` mutation
            // and the popover re-renders.
            if let runtime {
                runtime.claudeModel.forcePoll()
                runtime.codexModel.forcePoll()
                runtime.geminiModel.forcePoll()
            }
            // #38: re-target the cached popover to this provider's tab so
            // re-opening always lands on the clicked provider, not the last
            // tab the user manually switched to inside the popover.
            selection.request(providerCase)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Keep the popover keyed to the active window so menu bar
            // interaction doesn't immediately dismiss it.
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}

// MARK: - OpenCode menu-bar controller (PR #32, A2)

/// Per-A2 menu-bar variant for OpenCode: renders today's dollar cost
/// (`$X.XX`) as the status item text instead of a quota gauge.
/// OpenCode doesn't have a rolling 5h window — it's pay-as-you-go
/// through whichever underlying provider the user authenticated with.
/// Reads `UsageHistoryStore.opencodeTodayCostUSD`; refreshes on every
/// `opencodeLiveRecords` mutation.
///
/// Lifecycle mirrors `ProviderStatusController` but skips the AppModel
/// + popover surface — clicking the dollar item opens the dashboard's
/// Usage tab (where the full OpencodeDollarRow lives).
@MainActor
final class OpencodeStatusController: NSObject {
    private weak var runtime: AppRuntime?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
        // Re-render the dollar amount whenever the usage store's
        // opencode bag mutates. Single observer covers both the
        // initial ingest + every subsequent SSE usage event.
        //
        // C2 — was `$opencodeLiveRecords` pre-C2. With UsageHistoryStore
        // migrated to `@Observable`, the daemon-side Combine bridge is
        // `opencodeLiveRecordsPublisher` (a `PassthroughSubject` pushed
        // inside `appendOpencodeRecord(_:)`).
        runtime.usageHistoryStore.opencodeLiveRecordsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            ensureStatusItem()
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.image = nil  // text-only; A2 dollar variant
        item.button?.title = formattedToday()
        item.button?.toolTip = "OpenCode usage today — click to open the dashboard"
        statusItem = item
    }

    private func refresh() {
        statusItem?.button?.title = formattedToday()
    }

    private func formattedToday() -> String {
        guard let runtime else { return "$—.——" }
        let value = runtime.usageHistoryStore.opencodeTodayCostUSD
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
    }

    @objc private func handleClick(_ sender: Any?) {
        // Reuse the existing "show dashboard" plumbing — opens the
        // SwiftUI window and switches activation policy. The user
        // lands on whichever tab was last selected; we don't force
        // .usage because that'd surprise users who left it on another
        // tab.
        NotificationCenter.default.post(name: AppDelegate.showDashboardNotification, object: nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
