import Foundation
import ClawdmeterShared

/// Wraps libayatana-appindicator3 to put a live gauge in the GNOME top bar.
///
/// Lifecycle: `start(provider:)` creates the indicator with a placeholder
/// icon, registers the menu (Open Dashboard / Force poll / Settings / Quit),
/// then `TrayPollLoop` drives `setIcon(path:)` calls at the 60s poll
/// cadence.
///
/// Phase 4 build-out: actual `app_indicator_*` calls under `#if os(Linux)`.
public final class AppIndicatorTray {
    public enum MenuAction: Sendable {
        case openDashboard
        case forcePollClaude
        case forcePollCodex
        case openSettings
        case quit
    }

    public typealias MenuHandler = @Sendable (MenuAction) -> Void

    public let provider: CairoGaugeRenderer.Provider
    private let handler: MenuHandler

    /// On Linux holds the AppIndicator* pointer; on macOS dev it's nil.
    private var indicatorPtr: OpaquePointer?

    public init(provider: CairoGaugeRenderer.Provider, handler: @escaping MenuHandler) {
        self.provider = provider
        self.handler = handler
    }

    /// Construct + show the indicator. Idempotent.
    public func start(initialIcon: URL? = nil) throws {
        #if os(Linux)
        // TODO(Phase 4):
        //   let id = "com.clawdmeter.linux.\(provider.rawValue)"
        //   let title = provider == .claude ? "Clawd Claude" : "Clawd Codex"
        //   indicatorPtr = OpaquePointer(app_indicator_new(id, "clawdmeter", APP_INDICATOR_CATEGORY_APPLICATION_STATUS))
        //   app_indicator_set_status(indicatorPtr, APP_INDICATOR_STATUS_ACTIVE)
        //   if let initialIcon { app_indicator_set_icon_full(indicatorPtr, initialIcon.path, title) }
        //   buildMenu()
        #else
        _ = initialIcon  // unused on macOS dev
        #endif
    }

    /// Update the icon. Called by TrayPollLoop after each Cairo render.
    public func setIcon(at path: URL, label: String) {
        #if os(Linux)
        // TODO(Phase 4):
        //   app_indicator_set_icon_full(indicatorPtr, path.path, label)
        //   app_indicator_set_label(indicatorPtr, label, "")
        #else
        _ = (path, label)
        #endif
    }

    /// Tear down the indicator (called on app quit).
    public func stop() {
        #if os(Linux)
        // TODO(Phase 4):
        //   if let indicatorPtr {
        //       app_indicator_set_status(indicatorPtr, APP_INDICATOR_STATUS_PASSIVE)
        //       g_object_unref(indicatorPtr)
        //   }
        //   indicatorPtr = nil
        #endif
    }

    /// Construct the GtkMenu attached to the indicator. Each item wires
    /// to a MenuAction case which the AppDelegate-equivalent dispatcher
    /// translates into shared daemon calls (Force poll) or UI events
    /// (Open Dashboard).
    private func buildMenu() {
        #if os(Linux)
        // TODO(Phase 4):
        //   let menu = gtk_menu_new()
        //   addItem(menu, "Open dashboard") { self.handler(.openDashboard) }
        //   addItem(menu, "Force poll Claude") { self.handler(.forcePollClaude) }
        //   addItem(menu, "Force poll Codex") { self.handler(.forcePollCodex) }
        //   addSeparator(menu)
        //   addItem(menu, "Settings…") { self.handler(.openSettings) }
        //   addItem(menu, "Quit") { self.handler(.quit) }
        //   app_indicator_set_menu(indicatorPtr, menu)
        #endif
    }
}
