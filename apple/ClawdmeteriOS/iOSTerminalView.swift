import SwiftUI
import UIKit
import SwiftTerm
import ClawdmeterShared
import OSLog

private let iosTermLogger = Logger(subsystem: "com.clawdmeter.ios", category: "TerminalView")

/// iOS wrapper around SwiftTerm.TerminalView with a keyboard accessory bar
/// (Esc, Ctrl, Tab, ↑↓←→). Per design Pass 7 = 7 buttons × 44pt each.
enum IOSTerminalCommand: Equatable {
    case send(UUID, String)
    case raw(UUID, [UInt8])
    case reconnect(UUID)
}

enum IOSTerminalConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

struct iOSTerminalView: UIViewRepresentable {

    let sessionId: UUID
    let host: String
    let wsPort: Int
    let token: String
    /// Optional tmux pane filter. When nil the daemon falls back to the
    /// session's primary pane (preserves single-pane behavior).
    var paneId: String? = nil
    @Binding var command: IOSTerminalCommand?
    var onConnectionStateChange: (IOSTerminalConnectionState) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionId: sessionId,
            host: host,
            wsPort: wsPort,
            token: token,
            paneId: paneId,
            onConnectionStateChange: onConnectionStateChange
        )
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        view.inputAccessoryView = makeAccessory(coordinator: context.coordinator)
        context.coordinator.connect()
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.onConnectionStateChange = onConnectionStateChange
        guard let command else { return }
        switch command {
        case .send(_, let text):
            context.coordinator.sendRaw(Array(text.utf8))
        case .raw(_, let bytes):
            context.coordinator.sendRaw(bytes)
        case .reconnect:
            context.coordinator.disconnect()
            context.coordinator.connect()
        }
        DispatchQueue.main.async {
            self.command = nil
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    private func makeAccessory(coordinator: Coordinator) -> UIView {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.barTintColor = .systemBackground
        bar.items = [
            keyButton("esc", coordinator: coordinator, code: [0x1B]),
            keyButton("ctrl", coordinator: coordinator, code: nil, action: #selector(Coordinator.toggleCtrl)),
            keyButton("tab", coordinator: coordinator, code: [0x09]),
            UIBarButtonItem.flexibleSpace(),
            keyButton("↑", coordinator: coordinator, code: [0x1B, 0x5B, 0x41]),
            keyButton("↓", coordinator: coordinator, code: [0x1B, 0x5B, 0x42]),
            keyButton("←", coordinator: coordinator, code: [0x1B, 0x5B, 0x44]),
            keyButton("→", coordinator: coordinator, code: [0x1B, 0x5B, 0x43]),
        ]
        return bar
    }

    private func keyButton(
        _ title: String,
        coordinator: Coordinator,
        code: [UInt8]?,
        action: Selector? = nil
    ) -> UIBarButtonItem {
        if let action {
            return UIBarButtonItem(title: title, style: .plain, target: coordinator, action: action)
        }
        let item = UIBarButtonItem(title: title, style: .plain, target: nil, action: nil)
        item.primaryAction = UIAction { [weak coordinator] _ in
            if let code { coordinator?.sendRaw(code) }
        }
        return item
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let sessionId: UUID
        let host: String
        let wsPort: Int
        let token: String
        let paneId: String?

        weak var terminalView: TerminalView?
        private var task: URLSessionWebSocketTask?
        private var ctrlEngaged = false
        var onConnectionStateChange: (IOSTerminalConnectionState) -> Void

        init(
            sessionId: UUID,
            host: String,
            wsPort: Int,
            token: String,
            paneId: String?,
            onConnectionStateChange: @escaping (IOSTerminalConnectionState) -> Void
        ) {
            self.sessionId = sessionId
            self.host = host
            self.wsPort = wsPort
            self.token = token
            self.paneId = paneId
            self.onConnectionStateChange = onConnectionStateChange
        }

        func connect() {
            setState(.connecting)
            guard let url = URL(string: "ws://\(AgentControlClient.urlHostLiteral(host)):\(wsPort)/") else {
                setState(.failed("Bad terminal tunnel URL."))
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            var envelope: [String: Any] = [
                "op": "terminal",
                "token": token,
                "sessionId": sessionId.uuidString,
            ]
            if let paneId { envelope["paneId"] = paneId }
            if let data = try? JSONSerialization.data(withJSONObject: envelope) {
                task.send(.data(data)) { [weak self] error in
                    Task { @MainActor in
                        if let error {
                            self?.setState(.failed(error.localizedDescription))
                        } else {
                            self?.setState(.connected)
                        }
                    }
                }
            }
            readLoop()
        }

        func disconnect() {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            setState(.disconnected)
        }

        private func readLoop() {
            task?.receive { [weak self] result in
                guard let self else { return }
                if case .success(let message) = result {
                    Task { @MainActor in
                        self.dispatch(message: message)
                        self.readLoop()
                    }
                } else if case .failure(let err) = result {
                    iosTermLogger.debug("WS receive: \(err.localizedDescription)")
                    Task { @MainActor in
                        if self.task != nil {
                            self.setState(.failed(err.localizedDescription))
                        }
                    }
                }
            }
        }

        private func setState(_ state: IOSTerminalConnectionState) {
            onConnectionStateChange(state)
        }

        private func dispatch(message: URLSessionWebSocketTask.Message) {
            let bytes: Data
            switch message {
            case .data(let d): bytes = d
            case .string(let s): bytes = Data(s.utf8)
            @unknown default: return
            }
            guard let first = bytes.first,
                  let tag = TerminalFrameTag(rawValue: first) else { return }
            let payload = bytes.dropFirst()
            if tag == .output {
                let arr = Array(payload)
                terminalView?.feed(byteArray: ArraySlice(arr))
            }
        }

        // TerminalViewDelegate

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var bytes = Array(data)
            if ctrlEngaged && !bytes.isEmpty {
                // Map next byte to Ctrl-N (A=1, B=2, ...). Lowercase only.
                if let first = bytes.first {
                    if first >= 0x61 && first <= 0x7A {
                        bytes[0] = first - 0x60
                    } else if first >= 0x41 && first <= 0x5A {
                        bytes[0] = first - 0x40
                    }
                }
                ctrlEngaged = false
            }
            sendRaw(bytes)
        }

        func sendRaw(_ bytes: [UInt8]) {
            var frame = Data([TerminalFrameTag.input.rawValue])
            frame.append(contentsOf: bytes)
            task?.send(.data(frame)) { _ in }
        }

        @objc func toggleCtrl() {
            ctrlEngaged.toggle()
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let resize = TerminalResize(cols: newCols, rows: newRows)
            guard let body = try? JSONEncoder().encode(resize) else { return }
            var frame = Data([TerminalFrameTag.resize.rawValue])
            frame.append(body)
            task?.send(.data(frame)) { _ in }
        }

        public func setTerminalTitle(source: TerminalView, title: String) {}
        public func scrolled(source: TerminalView, position: Double) {}
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        public func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = s
            }
        }
        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        public func bell(source: TerminalView) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
