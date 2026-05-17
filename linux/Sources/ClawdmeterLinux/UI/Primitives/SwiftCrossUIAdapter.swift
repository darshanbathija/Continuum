// SwiftCrossUI-backed adapter for the LinuxUIWidget protocol layer (D14).
//
// Linux-only. On macOS / non-Linux dev builds this file is empty (the
// `#if os(Linux)` guard skips the body) and `LinuxUI.adapter` stays on
// `StubAdapter`. The Linux daemon's `main.swift` sets
//     LinuxUI.adapter = SwiftCrossUIAdapter()
// before constructing any widgets.

#if os(Linux)

import Foundation
// TODO(Phase 3.5 build-out): once linux/Package.swift adds the
// SwiftCrossUI dependency (https://github.com/stackotter/swift-cross-ui),
// uncomment the import + flesh out each `make*` to return a SwiftCrossUI
// view wrapped in a Linux* protocol conformer.
//
// import SwiftCrossUI
// import GtkBackend
//
// Until then, this Linux build also stubs out to give us a clean
// compile-on-Linux baseline. Swap in real implementations file by file.

public final class SwiftCrossUIAdapter: LinuxUIAdapter {
    public init() {}

    public func makeWindow(title: String) -> LinuxWindow {
        // TODO: SwiftCrossUI.Window(title) wrapped in a SwiftCrossUIWindow conformer
        return StubAdapter().makeWindow(title: title)
    }
    public func makeText(_ string: String, style: LinuxTextStyle) -> LinuxText {
        return StubAdapter().makeText(string, style: style)
    }
    public func makeButton(_ label: String, style: LinuxButtonStyle, onClick: (@Sendable () -> Void)?) -> LinuxButton {
        return StubAdapter().makeButton(label, style: style, onClick: onClick)
    }
    public func makeTextField(placeholder: String?, isMultiline: Bool, onChange: (@Sendable (String) -> Void)?) -> LinuxTextField {
        return StubAdapter().makeTextField(placeholder: placeholder, isMultiline: isMultiline, onChange: onChange)
    }
    public func makeImage(source: LinuxImageSource) -> LinuxImage {
        return StubAdapter().makeImage(source: source)
    }
    public func makeBox(orientation: LinuxBoxOrientation, spacing: Int, children: [LinuxUIWidget]) -> LinuxBox {
        return StubAdapter().makeBox(orientation: orientation, spacing: spacing, children: children)
    }
    public func makeList(itemCount: Int, rowBuilder: @escaping @Sendable (Int) -> LinuxUIWidget, onSelect: (@Sendable (Int) -> Void)?) -> LinuxList {
        return StubAdapter().makeList(itemCount: itemCount, rowBuilder: rowBuilder, onSelect: onSelect)
    }
    public func makePopover(content: LinuxUIWidget) -> LinuxPopover {
        return StubAdapter().makePopover(content: content)
    }
    public func makeAlertDialog(title: String, message: String, actions: [(label: String, isPrimary: Bool, handler: @Sendable () -> Void)]) -> LinuxAlertDialog {
        return StubAdapter().makeAlertDialog(title: title, message: message, actions: actions)
    }
    public func makeDrawingArea(draw: (@Sendable (Int, Int, OpaquePointer) -> Void)?) -> LinuxDrawingArea {
        return StubAdapter().makeDrawingArea(draw: draw)
    }
}

#endif
