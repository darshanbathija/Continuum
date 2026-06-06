import Foundation
import Network
import OSLog
import ClawdmeterShared

private let wsLogger = Logger(subsystem: "com.clawdmeter.mac", category: "TerminalWS")

/// One-per-client WebSocket bridge between a direct PTY host and an
/// `xterm.js` / `SwiftTerm` consumer.
///
/// Wire envelope is intentionally unchanged:
///   tag (1 byte) + payload:
///     0x01 OUTPUT — raw bytes from PTY server → client
///     0x02 RESIZE — JSON `{cols, rows}` from client → server
///     0x03 INPUT  — raw bytes from client → PTY
///     0x04 TITLE  — UTF-8 string with pane title
@MainActor
public final class TerminalWebSocketChannel: WSChannel {

    public typealias OutputStreamFactory = @Sendable () async -> AsyncStream<Data>
    public typealias InputWriter = @Sendable (Data) async -> Bool
    public typealias Resizer = @Sendable (Int, Int) async -> Void

    private let connection: NWConnection
    private let outputStream: OutputStreamFactory
    private let writeInput: InputWriter
    private let resize: Resizer

    private var outputTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    public init(
        connection: NWConnection,
        outputStream: @escaping OutputStreamFactory,
        writeInput: @escaping InputWriter,
        resize: @escaping Resizer
    ) {
        self.connection = connection
        self.outputStream = outputStream
        self.writeInput = writeInput
        self.resize = resize
    }

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

    private func streamOutputToClient() async {
        let stream = await outputStream()
        await sendFrame(tag: .output, payload: Data("\u{1B}[2J\u{1B}[H".utf8))
        for await bytes in stream {
            if Task.isCancelled { break }
            await sendFrame(tag: .output, payload: bytes)
        }
    }

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
                _ = context
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
            if !(await writeInput(payload)) {
                wsLogger.warning("PTY input write failed; closing terminal channel")
                stop()
            }
        case .resize:
            guard let resizePayload = try? JSONDecoder().decode(TerminalResize.self, from: payload) else {
                return
            }
            await resize(resizePayload.cols, resizePayload.rows)
        case .output, .title:
            wsLogger.debug("Client sent unexpected \(tag.rawValue) frame")
        }
    }

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
