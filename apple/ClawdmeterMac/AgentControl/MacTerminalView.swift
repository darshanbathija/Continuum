import SwiftUI
import AppKit
import Network
import SwiftTerm
import ClawdmeterShared
import OSLog

private let macTermLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MacTerminalView")

/// SwiftUI wrapper for SwiftTerm's `TerminalView` on macOS. Connects to the
/// daemon's WS terminal channel for the given session and pipes bytes
/// bidirectionally:
/// - Bytes arriving over WS (tag=0x01 OUTPUT) → `feed(buffer:)` into SwiftTerm.
/// - Keystrokes from SwiftTerm → WS frame (tag=0x03 INPUT).
/// - Resize events → WS frame (tag=0x02 RESIZE, JSON body).
public struct MacTerminalView: NSViewRepresentable {

    public let sessionId: UUID
    public let host: String
    public let wsPort: Int
    public let token: String
    /// G12 multi-terminal: override the session's primary pane with a
    /// specific tmux pane id (e.g. "%9"). nil = use primary.
    public let paneId: String?

    public init(
        sessionId: UUID,
        host: String,
        wsPort: Int,
        token: String,
        paneId: String? = nil
    ) {
        self.sessionId = sessionId
        self.host = host
        self.wsPort = wsPort
        self.token = token
        self.paneId = paneId
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionId: sessionId,
            host: host,
            wsPort: wsPort,
            token: token,
            paneId: paneId
        )
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

    // MARK: - Coordinator: WS lifecycle + SwiftTerm delegate

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let sessionId: UUID
        let host: String
        let wsPort: Int
        let token: String
        let paneId: String?

        weak var terminalView: TerminalView?
        private var task: URLSessionWebSocketTask?
        // Reconnect state: `isStopped` is latched by disconnect() so a pending
        // backoff retry never revives a torn-down pane; `reconnectAttempts`
        // drives the exponential backoff and resets on a healthy receive.
        private var isStopped = false
        private var reconnectAttempts = 0

        init(sessionId: UUID, host: String, wsPort: Int, token: String, paneId: String?) {
            self.sessionId = sessionId
            self.host = host
            self.wsPort = wsPort
            self.token = token
            self.paneId = paneId
        }

        func connect() {
            // Use URLSessionWebSocketTask here too — server-side is via
            // Network.framework, but for the client we keep things simple.
            guard let url = URL(string: "ws://\(host):\(wsPort)/") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            // Send the subscription envelope. paneId is optional — the
            // server falls back to the session's primary pane when absent.
            var envelope: [String: Any] = [
                "op": "terminal",
                "token": token,
                "sessionId": sessionId.uuidString,
            ]
            if let paneId, !paneId.isEmpty {
                envelope["paneId"] = paneId
            }
            if let data = try? JSONSerialization.data(withJSONObject: envelope) {
                task.send(.data(data)) { error in
                    if let error {
                        macTermLogger.error("subscribe send: \(error.localizedDescription)")
                    }
                }
            }
            readLoop()
        }

        func disconnect() {
            isStopped = true
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }

        private func readLoop() {
            task?.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    macTermLogger.debug("read: \(error.localizedDescription)")
                    // Re-arm via bounded backoff instead of dying silently. A
                    // transient WS error (sleep/wake, Wi-Fi blip, daemon port
                    // flap) previously froze the terminal until the view was
                    // recreated, because only .success recursed readLoop().
                    Task { @MainActor [weak self] in self?.scheduleReconnect() }
                case .success(let message):
                    Task { @MainActor in
                        self.reconnectAttempts = 0
                        self.dispatch(message: message)
                        self.readLoop()
                    }
                }
            }
        }

        private func scheduleReconnect() {
            guard !isStopped else { return }
            let attempt = reconnectAttempts
            reconnectAttempts += 1
            // 1, 2, 4, 8, 16, capped 30s — mirrors the iOS chat-subscribe ladder.
            let delaySeconds = min(30.0, pow(2.0, Double(min(attempt, 5))))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard let self, !self.isStopped else { return }
                self.connect()
            }
        }

        private func dispatch(message: URLSessionWebSocketTask.Message) {
            let bytes: Data
            switch message {
            case .data(let d): bytes = d
            case .string(let s): bytes = Data(s.utf8)
            @unknown default: return
            }
            guard let first = bytes.first else { return }
            guard let tag = TerminalFrameTag(rawValue: first) else { return }
            let payload = bytes.dropFirst()
            switch tag {
            case .output:
                let arr = Array(payload)
                terminalView?.feed(byteArray: ArraySlice(arr))
            case .title:
                // Ignore: an embedded pane must not rename the host app window.
                // An OSC title escape (vim/tmux/echo -ne '\033]0;…') would
                // otherwise hijack the whole window's titlebar.
                break
            case .resize, .input:
                break
            }
        }

        // MARK: - TerminalViewDelegate (keystrokes + resize)

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var frame = Data([TerminalFrameTag.input.rawValue])
            frame.append(contentsOf: data)
            task?.send(.data(frame)) { _ in }
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let resize = TerminalResize(cols: newCols, rows: newRows)
            guard let body = try? JSONEncoder().encode(resize) else { return }
            var frame = Data([TerminalFrameTag.resize.rawValue])
            frame.append(body)
            task?.send(.data(frame)) { _ in }
        }

        public func setTerminalTitle(source: TerminalView, title: String) {
            // No-op: do not propagate the embedded terminal's title to the host
            // NSWindow (would hijack the app titlebar). See the `.title` case.
        }

        public func scrolled(source: TerminalView, position: Double) {}
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        public func clipboardCopy(source: TerminalView, content: Data) {
            #if os(macOS)
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
            #endif
        }
        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        public func bell(source: TerminalView) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Informational — could be surfaced as breadcrumb in the UI.
        }
    }
}
