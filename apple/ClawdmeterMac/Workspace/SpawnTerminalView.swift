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
        let onDidFocus: () -> Void
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
            // Click-into-terminal moves the tile selection. The monitor
            // passes the event through untouched — AppKit still delivers
            // it to the terminal for caret/selection handling. hitTest (not
            // bounds.contains) so clicks on overlays stacked above the
            // terminal — or on the ACTIVE tab while this grid sits in
            // MacRootView's opacity-0 inactive-tab cache — don't silently
            // steal the typing target.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self,
                      let view = self.terminalView,
                      let window = view.window,
                      event.window === window,
                      let contentView = window.contentView
                else { return event }
                let pointInContent = contentView.convert(event.locationInWindow, from: nil)
                if let hit = contentView.hitTest(pointInContent),
                   hit === view || hit.isDescendant(of: view) {
                    // Deferred so selection publishes outside event dispatch.
                    DispatchQueue.main.async { [onDidFocus = self.onDidFocus] in
                        onDidFocus()
                    }
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
