import SwiftUI
import AppKit
import SwiftTerm
import OSLog

private let inProcLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MacInProcessTerminalView")

/// SwiftUI wrapper around SwiftTerm `TerminalView` that pipes bytes
/// directly to/from a tmux pane via `TmuxControlClient` — no WebSocket
/// round-trip, no daemon-side proxy. Used by `OpencodeSetupSheet` to
/// host an interactive `opencode auth login` TUI inside the app.
///
/// Why a second wrapper vs `MacTerminalView`: the existing
/// `MacTerminalView` is coupled to the daemon's terminal WebSocket
/// (tagged frames + remote SwiftTerm coordinator). For the
/// OpencodeSetupSheet's one-shot auth pane we don't want to register
/// an AgentSession or open a WS — the pane is ephemeral and lives
/// only for the duration of the sheet. Talking directly to
/// `TmuxControlClient.subscribeToPane / sendKeys / pasteBytes /
/// resizePane` is ~80 LOC vs the ~200 LOC WS path.
///
/// **ESC-byte routing (O3 from /plan-eng-review):** the daemon's
/// `TerminalWebSocketChannel.swift:117-123` routes input bytes by
/// presence of `0x1B` — ESC-rich input (arrow keys, function keys,
/// any escape sequence) goes through `pasteBytes` (hex-encoded
/// literal), plain input goes through `sendKeys`. Skipping that
/// rule breaks the opencode provider-picker arrow keys silently.
/// We mirror the same rule here.
public struct MacInProcessTerminalView: NSViewRepresentable {

    public let tmuxClient: TmuxControlClient
    public let paneId: String

    public init(tmuxClient: TmuxControlClient, paneId: String) {
        self.tmuxClient = tmuxClient
        self.paneId = paneId
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(tmuxClient: tmuxClient, paneId: paneId)
    }

    public func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        context.coordinator.connect()
        return view
    }

    public func updateNSView(_ nsView: TerminalView, context: Context) {}

    public static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let tmuxClient: TmuxControlClient
        let paneId: String

        weak var terminalView: TerminalView?
        private var subscriptionTask: Task<Void, Never>?

        init(tmuxClient: TmuxControlClient, paneId: String) {
            self.tmuxClient = tmuxClient
            self.paneId = paneId
        }

        func connect() {
            let client = tmuxClient
            let paneId = self.paneId
            subscriptionTask = Task { [weak self] in
                let stream = await client.subscribeToPane(paneId)
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

        // MARK: - TerminalViewDelegate

        /// Forward keystrokes from SwiftTerm to tmux with ESC-aware
        /// routing — see top-of-file comment for the rule.
        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            let hasEscape = bytes.contains(0x1B)
            let paneId = self.paneId
            Task { [tmuxClient] in
                do {
                    if hasEscape {
                        try await tmuxClient.pasteBytes(paneId: paneId, bytes: bytes)
                    } else {
                        try await tmuxClient.sendKeys(paneId: paneId, bytes: bytes)
                    }
                } catch {
                    inProcLogger.debug("send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let paneId = self.paneId
            Task { [tmuxClient] in
                try? await tmuxClient.resizePane(paneId, cols: newCols, rows: newRows)
            }
        }

        public func setTerminalTitle(source: TerminalView, title: String) {
            source.window?.title = title
        }

        public func scrolled(source: TerminalView, position: Double) {}
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        public func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        public func bell(source: TerminalView) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
