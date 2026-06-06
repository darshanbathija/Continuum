import Foundation

/// No-op widget adapter for development on macOS / non-Linux platforms.
///
/// Lets `swift build` of `linux/` work on a Mac dev machine — useful for
/// running pure-Swift logic tests (LinuxUsageStore, LinuxConfigPaths,
/// terminal-submission helpers from shared, etc.) without installing GTK4. Throws no
/// errors at construction; widgets are inert.
///
/// On Linux: `main.swift` sets `LinuxUI.adapter = SwiftCrossUIAdapter()`
/// before any UI code runs.
public final class StubAdapter: LinuxUIAdapter {
    public init() {}

    public func makeWindow(title: String) -> LinuxWindow { StubWindow(title: title) }
    public func makeText(_ string: String, style: LinuxTextStyle) -> LinuxText { StubText(text: string, style: style) }
    public func makeButton(_ label: String, style: LinuxButtonStyle, onClick: (@Sendable () -> Void)?) -> LinuxButton {
        StubButton(label: label, style: style, onClick: onClick)
    }
    public func makeTextField(placeholder: String?, isMultiline: Bool, onChange: (@Sendable (String) -> Void)?) -> LinuxTextField {
        StubTextField(placeholder: placeholder, isMultiline: isMultiline, onChange: onChange)
    }
    public func makeImage(source: LinuxImageSource) -> LinuxImage { StubImage(source: source) }
    public func makeBox(orientation: LinuxBoxOrientation, spacing: Int, children: [LinuxUIWidget]) -> LinuxBox {
        StubBox(orientation: orientation, spacing: spacing, children: children)
    }
    public func makeList(itemCount: Int, rowBuilder: @escaping @Sendable (Int) -> LinuxUIWidget, onSelect: (@Sendable (Int) -> Void)?) -> LinuxList {
        StubList(itemCount: itemCount, rowBuilder: rowBuilder, onSelect: onSelect)
    }
    public func makePopover(content: LinuxUIWidget) -> LinuxPopover { StubPopover(content: content) }
    public func makeAlertDialog(title: String, message: String, actions: [(label: String, isPrimary: Bool, handler: @Sendable () -> Void)]) -> LinuxAlertDialog {
        StubAlertDialog(title: title, message: message, actions: actions)
    }
    public func makeDrawingArea(draw: (@Sendable (Int, Int, OpaquePointer) -> Void)?) -> LinuxDrawingArea {
        StubDrawingArea(draw: draw)
    }
}

// MARK: - Stub implementations

final class StubWindow: LinuxWindow {
    let widgetID = "stub.window"
    var title: String
    var size: (width: Int, height: Int) = (980, 1100)
    var content: LinuxUIWidget?
    init(title: String) { self.title = title }
    func present() {}
    func close() {}
}

final class StubText: LinuxText {
    let widgetID = "stub.text"
    var text: String
    var style: LinuxTextStyle
    init(text: String, style: LinuxTextStyle) { self.text = text; self.style = style }
}

final class StubButton: LinuxButton {
    let widgetID = "stub.button"
    var label: String
    var isEnabled = true
    var onClick: (@Sendable () -> Void)?
    var style: LinuxButtonStyle
    init(label: String, style: LinuxButtonStyle, onClick: (@Sendable () -> Void)?) {
        self.label = label
        self.style = style
        self.onClick = onClick
    }
}

final class StubTextField: LinuxTextField {
    let widgetID = "stub.textfield"
    var text = ""
    var placeholder: String?
    var onChange: (@Sendable (String) -> Void)?
    var isMultiline: Bool
    init(placeholder: String?, isMultiline: Bool, onChange: (@Sendable (String) -> Void)?) {
        self.placeholder = placeholder
        self.isMultiline = isMultiline
        self.onChange = onChange
    }
}

final class StubImage: LinuxImage {
    let widgetID = "stub.image"
    var source: LinuxImageSource
    init(source: LinuxImageSource) { self.source = source }
}

final class StubBox: LinuxBox {
    let widgetID = "stub.box"
    let orientation: LinuxBoxOrientation
    var spacing: Int
    var children: [LinuxUIWidget]
    init(orientation: LinuxBoxOrientation, spacing: Int, children: [LinuxUIWidget]) {
        self.orientation = orientation
        self.spacing = spacing
        self.children = children
    }
}

final class StubList: LinuxList {
    let widgetID = "stub.list"
    var itemCount: Int
    var rowBuilder: (@Sendable (Int) -> LinuxUIWidget)?
    var onSelect: (@Sendable (Int) -> Void)?
    init(itemCount: Int, rowBuilder: @escaping @Sendable (Int) -> LinuxUIWidget, onSelect: (@Sendable (Int) -> Void)?) {
        self.itemCount = itemCount
        self.rowBuilder = rowBuilder
        self.onSelect = onSelect
    }
}

final class StubPopover: LinuxPopover {
    let widgetID = "stub.popover"
    let content: LinuxUIWidget
    init(content: LinuxUIWidget) { self.content = content }
    func present(relativeTo anchor: LinuxUIWidget) {}
    func dismiss() {}
}

final class StubAlertDialog: LinuxAlertDialog {
    let widgetID = "stub.alert"
    let title: String
    let message: String
    let actions: [(label: String, isPrimary: Bool, handler: @Sendable () -> Void)]
    init(title: String, message: String, actions: [(label: String, isPrimary: Bool, handler: @Sendable () -> Void)]) {
        self.title = title; self.message = message; self.actions = actions
    }
    func present(over parent: LinuxWindow?) {}
}

final class StubDrawingArea: LinuxDrawingArea {
    let widgetID = "stub.drawingarea"
    var draw: (@Sendable (Int, Int, OpaquePointer) -> Void)?
    init(draw: (@Sendable (Int, Int, OpaquePointer) -> Void)?) { self.draw = draw }
    func setNeedsDisplay() {}
}
