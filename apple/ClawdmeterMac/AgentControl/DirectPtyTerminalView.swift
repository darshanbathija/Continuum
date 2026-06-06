import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm `TerminalView` that pipes bytes directly
/// to/from a `TerminalPtyHost`.
struct DirectPtyTerminalView: NSViewRepresentable {
    let host: TerminalPtyHost

    init(host: TerminalPtyHost) {
        self.host = host
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        context.coordinator.connect()
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let host: TerminalPtyHost
        weak var terminalView: TerminalView?
        private var subscriptionTask: Task<Void, Never>?

        init(host: TerminalPtyHost) {
            self.host = host
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
        }

        func disconnect() {
            subscriptionTask?.cancel()
            subscriptionTask = nil
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { [host] in await host.writeBytes(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { [host] in await host.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            source.window?.title = title
        }

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
        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
