import SwiftUI
import AppKit
import Network
import SwiftTerm
import ClawdmeterShared
import OSLog

private let macTermLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MacTerminalView")

public enum TerminalConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed
    case disconnected

    public func statusText(hasVisibleOutput: Bool) -> String {
        switch self {
        case .connected where hasVisibleOutput:
            return "Terminal connected"
        case .reconnecting:
            return "Terminal reconnecting"
        case .failed:
            return "Terminal connection failed"
        case .disconnected where hasVisibleOutput:
            return "Terminal disconnected"
        default:
            return "Terminal starting"
        }
    }

    public var pendingTitle: String {
        switch self {
        case .reconnecting:
            return "Reconnecting to terminal"
        case .failed:
            return "Terminal connection failed"
        default:
            return "Connecting to terminal"
        }
    }

    public var pendingStatusText: String {
        switch self {
        case .reconnecting:
            return "Restoring terminal stream"
        case .failed:
            return "Try reopening the terminal tab"
        default:
            return "Waiting for visible shell output"
        }
    }

    public var isAttentionState: Bool {
        switch self {
        case .reconnecting, .failed, .disconnected:
            return true
        case .connecting, .connected:
            return false
        }
    }
}

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
    /// G12 multi-terminal: override the session's primary terminal with a
    /// specific direct PTY instance id. nil = use primary.
    public let paneId: String?
    public let onFirstOutput: (() -> Void)?
    public let onConnectionStateChange: ((TerminalConnectionState) -> Void)?

    public init(
        sessionId: UUID,
        host: String,
        wsPort: Int,
        token: String,
        paneId: String? = nil,
        onFirstOutput: (() -> Void)? = nil,
        onConnectionStateChange: ((TerminalConnectionState) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.host = host
        self.wsPort = wsPort
        self.token = token
        self.paneId = paneId
        self.onFirstOutput = onFirstOutput
        self.onConnectionStateChange = onConnectionStateChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionId: sessionId,
            host: host,
            wsPort: wsPort,
            token: token,
            paneId: paneId,
            onFirstOutput: onFirstOutput,
            onConnectionStateChange: onConnectionStateChange
        )
    }

    public func makeNSView(context: Context) -> TerminalView {
        let view = SizeSyncingTerminalView()
        view.terminalDelegate = context.coordinator
        // Re-assert the PTY winsize over the WS resize frame on every laid-out
        // frame change. SwiftTerm's `sizeChanged` delegate only fires on a
        // col/row CHANGE and doesn't reliably re-fire when the review pane is
        // dragged wider/narrower — so the remote PTY stays stranded at its old
        // grid and the agent's TUI renders cramped (see the SpawnTerminalView
        // note for the same SwiftTerm quirk). Idempotent: re-sending the same
        // winsize is a no-op for the child.
        view.onSizeSync = { [weak coordinator = context.coordinator] cols, rows in
            coordinator?.syncSize(cols: cols, rows: rows)
        }
        context.coordinator.terminalView = view
        context.coordinator.connect()
        return view
    }

    public func updateNSView(_ nsView: TerminalView, context: Context) {
        if context.coordinator.isReadyForInput {
            context.coordinator.requestFocus()
        }
    }

    public static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect(publishState: false)
    }

    // MARK: - Coordinator: WS lifecycle + SwiftTerm delegate

    @MainActor
    public final class Coordinator: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
        let sessionId: UUID
        let host: String
        let wsPort: Int
        let token: String
        let paneId: String?
        let onFirstOutput: (() -> Void)?
        let onConnectionStateChange: ((TerminalConnectionState) -> Void)?

        weak var terminalView: TerminalView?
        private var task: URLSessionWebSocketTask?
        private var sawOutput = false
        private var hasRequestedFocus = false

        /// True once shell output has arrived and the terminal is ready for typing.
        var isReadyForInput: Bool { sawOutput }

        /// Live WS reachability the view can surface (e.g. a "reconnecting…"
        /// banner). Flipped false on read-loop failure, true once a frame
        /// arrives after a (re)connect.
        @Published public private(set) var isConnected = false
        @Published public private(set) var connectionState: TerminalConnectionState = .disconnected

        /// Exp-backoff schedule between WS reconnect attempts, mirroring the
        /// iOS chat-subscribe ladder (1→30s, capped) so a daemon restart
        /// doesn't strand the terminal silently.
        private static let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        /// Stop after this many consecutive failures so a permanently-dead
        /// daemon doesn't spin forever.
        private static let maxReconnectAttempts = 8
        private var reconnectAttempt = 0
        private var reconnectTask: Task<Void, Never>?

        init(
            sessionId: UUID,
            host: String,
            wsPort: Int,
            token: String,
            paneId: String?,
            onFirstOutput: (() -> Void)?,
            onConnectionStateChange: ((TerminalConnectionState) -> Void)?
        ) {
            self.sessionId = sessionId
            self.host = host
            self.wsPort = wsPort
            self.token = token
            self.paneId = paneId
            self.onFirstOutput = onFirstOutput
            self.onConnectionStateChange = onConnectionStateChange
        }

        func connect() {
            // A pending backoff retry may have fired this; clear it so we
            // don't leave a dangling timer that re-arms a second socket.
            reconnectTask?.cancel()
            reconnectTask = nil
            publishConnectionState(.connecting)
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

        func disconnect(publishState: Bool = true) {
            reconnectTask?.cancel()
            reconnectTask = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            if publishState {
                isConnected = false
                publishConnectionState(.disconnected)
            }
        }

        private func readLoop() {
            task?.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    // Root cause: this arm previously only logged and returned,
                    // so the receive recursion died on the first WS error and
                    // the terminal silently froze with no reconnect. Surface a
                    // disconnected state and schedule a bounded backoff retry.
                    macTermLogger.debug("read: \(error.localizedDescription)")
                    Task { @MainActor in
                        self.scheduleReconnect()
                    }
                case .success(let message):
                    Task { @MainActor in
                        if !self.isConnected { self.isConnected = true }
                        self.publishConnectionState(.connected)
                        self.reconnectAttempt = 0
                        self.dispatch(message: message)
                        self.readLoop()
                    }
                }
            }
        }

        /// Re-`connect()` after an exp-backoff delay (with 0-20% jitter),
        /// giving up after `maxReconnectAttempts` consecutive failures.
        private func scheduleReconnect() {
            isConnected = false
            // A retry is already in flight; don't stack timers.
            guard reconnectTask == nil else { return }
            guard reconnectAttempt < Self.maxReconnectAttempts else {
                macTermLogger.debug("read: giving up after \(self.reconnectAttempt) reconnect attempts")
                publishConnectionState(.failed)
                return
            }
            reconnectAttempt += 1
            publishConnectionState(.reconnecting(attempt: reconnectAttempt))
            let idx = min(reconnectAttempt - 1, Self.backoffSchedule.count - 1)
            let base = Self.backoffSchedule[idx]
            // 0-20% jitter so a herd of terminals doesn't reconnect in lockstep.
            let delay = base + base * Double.random(in: 0...0.2)
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.reconnectTask = nil
                self.connect()
            }
        }

        private func publishConnectionState(_ state: TerminalConnectionState) {
            guard connectionState != state else { return }
            connectionState = state
            onConnectionStateChange?(state)
        }

        /// Move keyboard focus into the embedded terminal so the user can type
        /// immediately after a tab opens, without clicking the surface first.
        func requestFocus() {
            guard !hasRequestedFocus, let terminalView else { return }
            DispatchQueue.main.async { [weak self, weak terminalView] in
                guard let self, let terminalView else { return }
                guard let window = terminalView.window else { return }
                guard terminalView.acceptsFirstResponder else { return }
                // First output is async, so the user may already be typing in a
                // sibling text field. Don't yank focus out of a text editor;
                // latch so the updateNSView re-arm path doesn't keep retrying.
                if let current = window.firstResponder, current !== terminalView, current is NSText {
                    self.hasRequestedFocus = true
                    return
                }
                window.makeFirstResponder(terminalView)
                self.hasRequestedFocus = true
            }
        }

        #if DEBUG
        internal func simulateReadFailureForTesting() {
            scheduleReconnect()
        }
        #endif

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
                if !arr.isEmpty, !sawOutput {
                    sawOutput = true
                    onFirstOutput?()
                    requestFocus()
                }
                terminalView?.feed(byteArray: ArraySlice(arr))
            case .title:
                let title = String(decoding: payload, as: UTF8.self)
                terminalView?.window?.title = title
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
            sendResize(cols: newCols, rows: newRows)
        }

        /// Push the emulator's post-layout grid to the remote PTY. Backstops the
        /// change-gated `sizeChanged` delegate, which doesn't reliably re-fire
        /// when the hosting pane is resized (see `makeNSView`). Idempotent.
        func syncSize(cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            sendResize(cols: cols, rows: rows)
        }

        private func sendResize(cols: Int, rows: Int) {
            let resize = TerminalResize(cols: cols, rows: rows)
            guard let body = try? JSONEncoder().encode(resize) else { return }
            var frame = Data([TerminalFrameTag.resize.rawValue])
            frame.append(body)
            task?.send(.data(frame)) { _ in }
        }

        public func setTerminalTitle(source: TerminalView, title: String) {
            source.window?.title = title
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
