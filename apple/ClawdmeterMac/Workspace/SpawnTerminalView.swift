import SwiftUI
import AppKit
import SwiftTerm

/// SwiftTerm terminal for a spawn-grid tile. Same byte plumbing as
/// `DirectPtyTerminalView`, plus the two focus hooks the grid needs:
/// - clicking into the terminal reports via `onDidFocus` so the tile's
///   selection border follows the actual typing target, and
/// - bumping `focusToken` (tile header tap / programmatic select) makes
///   this terminal first responder so typing lands here immediately.
///
/// Click detection uses a local mouseDown event monitor — SwiftTerm's
/// `TerminalView.becomeFirstResponder` is `public` (not `open`), so a
/// subclass override can't observe focus directly.
struct SpawnTerminalView: NSViewRepresentable {
    let host: TerminalPtyHost
    let focusToken: Int
    let onDidFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host, onDidFocus: onDidFocus)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.connect()
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Refresh the focus callback every update: the Coordinator caches the
        // closure from makeCoordinator, but `onDidFocus` closes over the tile
        // for THIS render. After a grid reflow (tile closed → grid reindexed)
        // a stale closure would make the click monitor select the wrong tile.
        context.coordinator.onDidFocus = onDidFocus
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        // Deferred: makeFirstResponder mid-view-update triggers AppKit
        // reentrancy warnings, and the view may not be in a window yet.
        context.coordinator.requestKeyboardFocus()
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let host: TerminalPtyHost
        // var (not let): refreshed each updateNSView so a grid reflow can't
        // leave the click monitor reporting focus for a stale tile.
        var onDidFocus: () -> Void
        weak var terminalView: TerminalView?
        var lastFocusToken: Int = 0
        private var subscriptionTask: Task<Void, Never>?
        private var clickMonitor: Any?

        init(host: TerminalPtyHost, onDidFocus: @escaping () -> Void) {
            self.host = host
            self.onDidFocus = onDidFocus
        }

        /// Make the terminal first responder, retrying briefly when the
        /// view hasn't been attached to a window yet (the initial focus
        /// handoff fires from `updateNSView` before insertion completes —
        /// consuming the token there would silently drop the request).
        func requestKeyboardFocus(attempt: Int = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
                guard let self, let view = self.terminalView else { return }
                if let window = view.window {
                    // Token bumps fire on grid-open and on store-driven
                    // selection changes (e.g. closeTile falling back to the
                    // first tile). Don't yank the keyboard out of a sibling
                    // text editor (sidebar search, rename field) the user is
                    // mid-type in. The click-to-focus path is unaffected.
                    if let current = window.firstResponder, current !== view, current is NSText {
                        return
                    }
                    window.makeFirstResponder(view)
                } else if attempt < 5 {
                    self.requestKeyboardFocus(attempt: attempt + 1)
                }
            }
        }

        func connect() {
            let host = self.host
            subscriptionTask = Task { [weak self] in
                let stream = await host.outputStream()
                for await chunk in stream {
                    if Task.isCancelled { break }
                    let arr = Array(chunk)
                    await MainActor.run {
                        self?.terminalView?.feed(byteArray: ArraySlice(arr))
                    }
                }
            }
            // Click-into-terminal moves the tile selection. The monitor passes
            // the event through untouched — AppKit still delivers it to the
            // terminal for caret/selection handling.
            //
            // We decide "did THIS tile get the click?" from the window's actual
            // first responder AFTER the click is dispatched, not from geometric
            // hitTest. AppKit makes the clicked terminal first responder during
            // event dispatch, so on the next runloop tick exactly one tile's
            // view owns it — unambiguous. hitTest, by contrast, returned the
            // wrong tile whenever an intervening hittable view sat at the click
            // point (the TahoeGlass material, the SwiftUI selection-border
            // overlay) or sibling AppKit z-order drifted from the visual grid
            // after a reflow — which is what left the highlight on the wrong
            // tile. First-responder is also the right gate for the opacity-0
            // inactive-tab case: a non-hittable cached grid never takes focus.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self,
                      let view = self.terminalView,
                      let window = view.window,
                      event.window === window
                else { return event }
                // Deferred: first responder only updates once this click
                // finishes dispatching, and this publishes selection outside
                // event handling.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          let view = self.terminalView,
                          let window = view.window,
                          let responder = window.firstResponder as? NSView,
                          responder === view || responder.isDescendant(of: view)
                    else { return }
                    self.onDidFocus()
                }
                return event
            }
        }

        func disconnect() {
            subscriptionTask?.cancel()
            subscriptionTask = nil
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { [host] in await host.writeBytes(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { [host] in await host.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func bell(source: TerminalView) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // Agent output is untrusted; an OSC-8 hyperlink can carry
            // file:// or arbitrary app schemes. Only open web links.
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            NSWorkspace.shared.open(url)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
