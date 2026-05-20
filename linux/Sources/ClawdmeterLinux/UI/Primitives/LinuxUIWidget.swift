import Foundation

/// Insurance protocol layer over the chosen GTK4 Swift binding (D3 + D14).
///
/// **Why this exists.** The Linux UI is built on SwiftCrossUI (per D14;
/// adwaita-swift was demoted at codex outside-voice). SwiftCrossUI is
/// solid but still 0.x; if a release breaks the GtkBackend, we don't want
/// to touch 50 dashboard/sessions files to recover. The 12 primitives
/// below cover the simple ~70% of surfaces (dashboard cards, settings
/// forms, tray menus, popovers); changing the adapter swaps the binding
/// without touching feature code.
///
/// **What this doesn't insure.** The complex stateful 30% — the Sessions
/// IDE chat workspace with nav-split + drag/drop + clipboard image paste
/// + WebKit embed + VTE multi-pane — calls SwiftCrossUI / direct CGtk4
/// directly. Codex's "fake insurance" critique applies there; we accept it.
///
/// **Two-binding-future.** If SwiftCrossUI breaks, the planned fallback is
/// swift-cross-ui's older release pinned or a hand-rolled CGtk4 adapter
/// against the same protocols. Estimated swap cost: ~1 week.

// MARK: - Core widget protocol

public protocol LinuxUIWidget: AnyObject {
    /// The widget identifier — debug-only, e.g. "DashboardWindow.totalsGrid".
    var widgetID: String { get }
}

// MARK: - Application & windows

public protocol LinuxApp {
    associatedtype Body: LinuxUIWidget
    /// Build the initial widget tree. Called once at AdwApplication "activate".
    func body() -> Body
}

public protocol LinuxWindow: LinuxUIWidget {
    var title: String { get set }
    var size: (width: Int, height: Int) { get set }
    var content: LinuxUIWidget? { get set }
    func present()
    func close()
}

public protocol LinuxAlertDialog: LinuxUIWidget {
    var title: String { get }
    var message: String { get }
    var actions: [(label: String, isPrimary: Bool, handler: @Sendable () -> Void)] { get }
    func present(over parent: LinuxWindow?)
}

public protocol LinuxPopover: LinuxUIWidget {
    var content: LinuxUIWidget { get }
    func present(relativeTo anchor: LinuxUIWidget)
    func dismiss()
}

// MARK: - Layout

public protocol LinuxBox: LinuxUIWidget {
    /// .horizontal == HStack, .vertical == VStack.
    var orientation: LinuxBoxOrientation { get }
    var spacing: Int { get set }
    var children: [LinuxUIWidget] { get set }
}

public enum LinuxBoxOrientation: Sendable {
    case horizontal
    case vertical
}

// MARK: - Atoms

public protocol LinuxText: LinuxUIWidget {
    var text: String { get set }
    /// Style token from ThemeTokens (Phase 1 split).
    var style: LinuxTextStyle { get set }
}

public enum LinuxTextStyle: Sendable {
    case body
    case caption
    case headline
    case title
    case monospace
}

public protocol LinuxButton: LinuxUIWidget {
    var label: String { get set }
    var isEnabled: Bool { get set }
    var onClick: (@Sendable () -> Void)? { get set }
    var style: LinuxButtonStyle { get set }
}

public enum LinuxButtonStyle: Sendable {
    case standard
    case suggested     // Adwaita .suggested-action (primary)
    case destructive   // Adwaita .destructive-action
    case flat
}

public protocol LinuxTextField: LinuxUIWidget {
    var text: String { get set }
    var placeholder: String? { get set }
    var onChange: (@Sendable (String) -> Void)? { get set }
    var isMultiline: Bool { get set }
}

public protocol LinuxImage: LinuxUIWidget {
    /// Either a system icon name (Adwaita icon theme), a file URL, or
    /// raw bytes (Cairo-rendered PNG, e.g. the live gauge).
    var source: LinuxImageSource { get set }
}

public enum LinuxImageSource: Sendable {
    case iconName(String)
    case fileURL(URL)
    case bytes(Data)
}

public protocol LinuxList: LinuxUIWidget {
    /// Item count + per-row builder + per-row click handler. The list
    /// owns selection state; the adapter implements virtualization.
    var itemCount: Int { get set }
    var rowBuilder: (@Sendable (Int) -> LinuxUIWidget)? { get set }
    var onSelect: (@Sendable (Int) -> Void)? { get set }
}

// MARK: - Cairo escape hatch

/// For the live menu-bar gauge + analytics charts + sparkline. The adapter
/// wraps a `GtkDrawingArea` and invokes the draw closure each time the
/// widget needs repaint. The drawer gets a Cairo context (`OpaquePointer`
/// to `cairo_t`) which the Cairo Swift wrapper consumes on Linux.
public protocol LinuxDrawingArea: LinuxUIWidget {
    /// (width, height, cairo_t pointer) → draw side effects.
    var draw: (@Sendable (Int, Int, OpaquePointer) -> Void)? { get set }
    func setNeedsDisplay()
}

// MARK: - Adapter factory

/// Single source of truth for constructing widgets. Feature code does:
///
/// ```swift
/// let label = LinuxUI.text("Hello", style: .body)
/// let button = LinuxUI.button("Open Dashboard", style: .suggested) { ... }
/// let row = LinuxUI.box(.horizontal, spacing: 8, children: [label, button])
/// ```
///
/// On Linux: backed by `SwiftCrossUIAdapter` (or alternate adapter).
/// On macOS dev: backed by `MacStubAdapter` so `swift build` works for
/// pure-Swift correctness checks without GTK installed.
public enum LinuxUI {
    /// Globally selected adapter. Configure exactly once at app entry
    /// (`main.swift`) via `configure(adapter:)`. After that it's a frozen
    /// reference — reads are lock-free.
    ///
    /// P1-Linux-6: previously declared as `nonisolated(unsafe) public static var`,
    /// which allowed unsynchronized writes from any thread. Background
    /// tasks (tray poll loop, HTTP server) read it concurrently with the
    /// main thread's initial assignment. Now there's a tiny lock guarding
    /// the install path and reads only happen after install, so the
    /// `nonisolated(unsafe)` escape hatch is unnecessary.
    private static let adapterLock = NSLock()
    private static var _adapter: LinuxUIAdapter = StubAdapter()

    public static var adapter: LinuxUIAdapter {
        adapterLock.lock()
        defer { adapterLock.unlock() }
        return _adapter
    }

    /// Install the production adapter exactly once. Subsequent calls log
    /// and ignore — flipping the adapter mid-run was never supported and
    /// almost certainly indicates a bug.
    public static func configure(adapter: LinuxUIAdapter) {
        adapterLock.lock()
        defer { adapterLock.unlock() }
        _adapter = adapter
    }

    public static func window(title: String) -> LinuxWindow {
        adapter.makeWindow(title: title)
    }

    public static func text(_ string: String, style: LinuxTextStyle = .body) -> LinuxText {
        adapter.makeText(string, style: style)
    }

    public static func button(
        _ label: String,
        style: LinuxButtonStyle = .standard,
        onClick: (@Sendable () -> Void)? = nil
    ) -> LinuxButton {
        adapter.makeButton(label, style: style, onClick: onClick)
    }

    public static func textField(
        placeholder: String? = nil,
        isMultiline: Bool = false,
        onChange: (@Sendable (String) -> Void)? = nil
    ) -> LinuxTextField {
        adapter.makeTextField(placeholder: placeholder, isMultiline: isMultiline, onChange: onChange)
    }

    public static func image(_ source: LinuxImageSource) -> LinuxImage {
        adapter.makeImage(source: source)
    }

    public static func box(
        _ orientation: LinuxBoxOrientation,
        spacing: Int = 0,
        children: [LinuxUIWidget] = []
    ) -> LinuxBox {
        adapter.makeBox(orientation: orientation, spacing: spacing, children: children)
    }

    public static func list(
        itemCount: Int,
        rowBuilder: @escaping @Sendable (Int) -> LinuxUIWidget,
        onSelect: (@Sendable (Int) -> Void)? = nil
    ) -> LinuxList {
        adapter.makeList(itemCount: itemCount, rowBuilder: rowBuilder, onSelect: onSelect)
    }

    public static func popover(content: LinuxUIWidget) -> LinuxPopover {
        adapter.makePopover(content: content)
    }

    public static func alertDialog(
        title: String,
        message: String,
        actions: [(label: String, isPrimary: Bool, handler: @Sendable () -> Void)]
    ) -> LinuxAlertDialog {
        adapter.makeAlertDialog(title: title, message: message, actions: actions)
    }

    public static func drawingArea(
        draw: (@Sendable (Int, Int, OpaquePointer) -> Void)? = nil
    ) -> LinuxDrawingArea {
        adapter.makeDrawingArea(draw: draw)
    }
}

// MARK: - Adapter protocol

public protocol LinuxUIAdapter {
    func makeWindow(title: String) -> LinuxWindow
    func makeText(_ string: String, style: LinuxTextStyle) -> LinuxText
    func makeButton(_ label: String, style: LinuxButtonStyle, onClick: (@Sendable () -> Void)?) -> LinuxButton
    func makeTextField(placeholder: String?, isMultiline: Bool, onChange: (@Sendable (String) -> Void)?) -> LinuxTextField
    func makeImage(source: LinuxImageSource) -> LinuxImage
    func makeBox(orientation: LinuxBoxOrientation, spacing: Int, children: [LinuxUIWidget]) -> LinuxBox
    func makeList(itemCount: Int, rowBuilder: @escaping @Sendable (Int) -> LinuxUIWidget, onSelect: (@Sendable (Int) -> Void)?) -> LinuxList
    func makePopover(content: LinuxUIWidget) -> LinuxPopover
    func makeAlertDialog(title: String, message: String, actions: [(label: String, isPrimary: Bool, handler: @Sendable () -> Void)]) -> LinuxAlertDialog
    func makeDrawingArea(draw: (@Sendable (Int, Int, OpaquePointer) -> Void)?) -> LinuxDrawingArea
}
