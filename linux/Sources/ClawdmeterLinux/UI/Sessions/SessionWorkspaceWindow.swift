import Foundation
import ClawdmeterShared

/// Linux port of `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`.
///
/// Phase 6 scaffolding only. Per **D14 hybrid pick**, this surface uses
/// direct CGtk4 (`GtkPaned`) for the 3-way split rather than the
/// `LinuxUIWidget` protocol — too much custom state (drag/drop, clipboard
/// image paste, sub-pane focus management) to route through 12 primitives.
///
/// Architectural shape:
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │ [sessions sidebar] │ [chat thread + composer] │ [review panes]   │
/// │ (Cgtk4 GtkListBox) │ (Cgtk4 GtkTextView)      │ (LinuxUI VStack) │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// The review panes (right column) use LinuxUI primitives since they're
/// mostly read-only. The chat thread + composer call CGtk4 directly for
/// VTE-style scrolling, clipboard image paste, drag-drop, etc.
public final class SessionWorkspaceWindow {

    public let window: LinuxWindow

    public init() {
        let win = LinuxUI.window(title: "Sessions — Clawdmeter")
        win.size = (width: 1280, height: 800)
        self.window = win
        // TODO(Phase 6): construct GtkPaned + sidebar + thread + review
        win.content = LinuxUI.text("Sessions chat IDE — Phase 6 scaffold", style: .title)
    }

    public func present() {
        window.present()
    }
}
