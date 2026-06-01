import Foundation
import Network
import OSLog
import ClawdmeterShared

private let wsLogger = Logger(subsystem: "com.clawdmeter.mac", category: "TerminalWS")

/// One-per-client WebSocket bridge between a tmux pane and an `xterm.js` /
/// `SwiftTerm` consumer.
///
/// Wire envelope (binary frames):
///   tag (1 byte) + payload:
///     0x01 OUTPUT — payload is raw bytes from `%output` for the terminal
///     0x02 RESIZE — payload is JSON `{cols, rows}` from client → server
///     0x03 INPUT  — payload is raw bytes from client to send to pane
///     0x04 TITLE  — payload is UTF-8 string with new pane title
///
/// Per Codex Round 2 #1: input ≤256B with no escape sequences goes via
/// `tmux send-keys -l -H` (hex-encoded literal). Larger or escape-rich
/// input goes via `load-buffer + paste-buffer -d`.
@MainActor
public final class TerminalWebSocketChannel: WSChannel {

    private let connection: NWConnection
    private let tmux: TmuxControlClient
    private let paneId: String
    private let registry: AgentSessionRegistry
    private let sessionId: UUID

    private var outputTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    public init(
        connection: NWConnection,
        tmux: TmuxControlClient,
        paneId: String,
        registry: AgentSessionRegistry,
        sessionId: UUID
    ) {
        self.connection = connection
        self.tmux = tmux
        self.paneId = paneId
        self.registry = registry
        self.sessionId = sessionId
    }

    /// Start streaming. Spawns two concurrent tasks: one drains pane output
    /// to the client, the other receives client frames and forwards them
    /// to tmux.
    public func start() {
        outputTask = Task { [weak self] in
            await self?.streamOutputToClient()
        }
        receiveTask = Task { [weak self] in
            await self?.receiveFromClient()
        }
    }

    public func stop() {
        outputTask?.cancel()
        receiveTask?.cancel()
        connection.cancel()
    }

    // MARK: - Output: tmux → client

    private func streamOutputToClient() async {
        let stream = await tmux.subscribeToPane(paneId)
        // Guarantee the client receives a non-empty first frame immediately so
        // the "Waiting for visible shell output" overlay always clears — even
        // when the pane is idle (no live %output) or its snapshot fails. This
        // was the cause of terminals hanging forever: capture-pane errored on a
        // stale pane id (tmux server restarted → "degraded" session), the error
        // was swallowed, no frame was ever sent, and an idle/dead pane emits
        // nothing. The clear-screen + cursor-home is a safe, always-available
        // first frame; scrollback (or a degraded notice) follows.
        await sendFrame(tag: .output, payload: Data("\u{1B}[2J\u{1B}[H".utf8))
        await sendInitialPaneSnapshot()
        for await bytes in stream {
            if Task.isCancelled { break }
            await sendFrame(tag: .output, payload: bytes)
        }
    }

    /// A remote iOS terminal often attaches after the desktop session has
    /// already produced output. Seed the SwiftTerm client with the current
    /// tmux pane contents before live `%output` bytes arrive. Best-effort: the
    /// clear-screen frame in `streamOutputToClient()` has already unblocked the
    /// UI, so a failure here only means "no scrollback", not "stuck terminal".
    private func sendInitialPaneSnapshot() async {
        do {
            let result = try await tmux.command([
                "capture-pane",
                "-p",
                "-t", paneId,
                "-S", "-160",
                "-E", "-",
            ])
            let snapshot = result.lines.joined(separator: "\r\n")
            guard !snapshot.isEmpty else { return }
            var bytes = Data(snapshot.utf8)
            bytes.append(Data("\r\n".utf8))
            await sendFrame(tag: .output, payload: bytes)
        } catch {
            // The pane almost certainly no longer exists — the tmux server was
            // restarted (e.g. app relaunch) and reassigned pane ids, leaving
            // this session's recorded `tmuxPaneId` stale ("degraded"). Surface
            // that to the user instead of a silent blank terminal so they know
            // to revive/restart the session rather than stare at a dead pane.
            wsLogger.warning("capture-pane for \(self.paneId, privacy: .public) failed (pane likely gone / session degraded): \(error.localizedDescription)")
            let notice = "\u{1B}[33m[Continuum]\u{1B}[0m This terminal isn’t connected — the tmux session was restarted and this pane (\(paneId)) is gone.\r\nRevive or restart the session to reconnect a live shell.\r\n"
            await sendFrame(tag: .output, payload: Data(notice.utf8))
        }
    }

    // MARK: - Input: client → tmux

    private func receiveFromClient() async {
        while !Task.isCancelled {
            do {
                let (data, context, _) = try await receiveOneMessage()
                guard !data.isEmpty else { continue }
                let tagByte = data[0]
                guard let tag = TerminalFrameTag(rawValue: tagByte) else {
                    wsLogger.debug("Unknown frame tag \(tagByte); dropping")
                    continue
                }
                let payload = data.dropFirst()
                _ = context  // unused but kept for future opcode dispatch
                await handle(tag: tag, payload: Data(payload))
            } catch {
                wsLogger.debug("Receive loop ended: \(error.localizedDescription)")
                break
            }
        }
    }

    private func handle(tag: TerminalFrameTag, payload: Data) async {
        switch tag {
        case .input:
            await forwardInput(payload)
        case .resize:
            await handleResize(payload)
        case .output, .title:
            // Server → client only; client should not send these.
            wsLogger.debug("Client sent unexpected \(tag.rawValue) frame")
        }
    }

    /// Forward input bytes to the tmux pane. Threshold + safety: short
    /// keystrokes go via `send-keys -l -H`; everything else via
    /// `load-buffer + paste-buffer -d` (Codex #1 byte-safe transport).
    private func forwardInput(_ bytes: Data) async {
        let isShort = bytes.count <= 256
        let hasEscape = bytes.contains(0x1B)  // ESC byte
        let needsPasteBuffer = !isShort || hasEscape
        do {
            if needsPasteBuffer {
                try await tmux.pasteBytes(paneId: paneId, bytes: bytes)
            } else {
                try await tmux.sendKeys(paneId: paneId, bytes: bytes)
            }
        } catch {
            wsLogger.warning("Forward input failed: \(error.localizedDescription)")
        }
    }

    private func handleResize(_ payload: Data) async {
        guard let resize = try? JSONDecoder().decode(TerminalResize.self, from: payload) else {
            return
        }
        do {
            try await tmux.resizePane(paneId, cols: resize.cols, rows: resize.rows)
        } catch {
            wsLogger.debug("Resize failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Frame send/receive primitives

    private func sendFrame(tag: TerminalFrameTag, payload: Data) async {
        var bytes = Data([tag.rawValue])
        bytes.append(payload)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "frame", metadata: [metadata]
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(
                content: bytes,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in cont.resume() }
            )
        }
    }

    private func receiveOneMessage() async throws -> (Data, NWConnection.ContentContext?, Bool) {
        try await withCheckedThrowingContinuation { cont in
            connection.receiveMessage { data, context, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: (data ?? Data(), context, isComplete))
            }
        }
    }
}
