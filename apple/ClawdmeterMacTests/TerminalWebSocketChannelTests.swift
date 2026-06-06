import Foundation
import Network
import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class TerminalWebSocketChannelTests: XCTestCase {
    func test_outputFramesIncludeInitialClearAndPtyBytes() async throws {
        let pair = try await LocalWebSocketPair.make()
        defer { pair.cancel() }

        let stream = AsyncStream<Data>.makeStream(of: Data.self)
        let channel = TerminalWebSocketChannel(
            connection: pair.server,
            outputStream: { stream.stream },
            writeInput: { _ in true },
            resize: { _, _ in }
        )
        channel.start()
        defer { channel.stop() }

        let clear = try await pair.receiveData()
        XCTAssertEqual(clear.first, TerminalFrameTag.output.rawValue)
        XCTAssertTrue(String(decoding: clear.dropFirst(), as: UTF8.self).contains("\u{1B}[2J"))

        stream.continuation.yield(Data("PTY_READY".utf8))
        let output = try await pair.receiveData()
        XCTAssertEqual(output.first, TerminalFrameTag.output.rawValue)
        XCTAssertEqual(String(decoding: output.dropFirst(), as: UTF8.self), "PTY_READY")
    }

    func test_inputResizeAndInvalidFrames() async throws {
        let pair = try await LocalWebSocketPair.make()
        defer { pair.cancel() }
        let recorder = TerminalFrameRecorder()
        let stream = AsyncStream<Data>.makeStream(of: Data.self)
        let channel = TerminalWebSocketChannel(
            connection: pair.server,
            outputStream: { stream.stream },
            writeInput: { data in await recorder.recordInput(data) },
            resize: { cols, rows in await recorder.recordResize(cols: cols, rows: rows) }
        )
        channel.start()
        defer { channel.stop() }
        _ = try await pair.receiveData()

        try await pair.sendFrame(tag: .input, payload: Data([0x1b]) + Data("abc".utf8))
        try await waitUntil {
            await recorder.inputCount == 1
        }
        let firstInput = await recorder.firstInput()
        XCTAssertEqual(firstInput, Data([0x1b]) + Data("abc".utf8))

        let resize = try JSONEncoder().encode(TerminalResize(cols: 132, rows: 43))
        try await pair.sendFrame(tag: .resize, payload: resize)
        try await waitUntil {
            await recorder.resizeCount == 1
        }
        let firstResize = await recorder.firstResize()
        XCTAssertEqual(firstResize?.cols, 132)
        XCTAssertEqual(firstResize?.rows, 43)

        try await pair.sendFrame(tag: .resize, payload: Data("not-json".utf8))
        try await Task.sleep(nanoseconds: 120_000_000)
        let resizeCount = await recorder.resizeCount
        XCTAssertEqual(resizeCount, 1)

        try await pair.sendRaw(Data([0xff]) + Data("ignored".utf8))
        try await Task.sleep(nanoseconds: 120_000_000)
        let inputCount = await recorder.inputCount
        XCTAssertEqual(inputCount, 1)
    }

    func test_inputWriteFailureClosesChannel() async throws {
        let pair = try await LocalWebSocketPair.make()
        defer { pair.cancel() }
        let stream = AsyncStream<Data>.makeStream(of: Data.self)
        let channel = TerminalWebSocketChannel(
            connection: pair.server,
            outputStream: { stream.stream },
            writeInput: { _ in false },
            resize: { _, _ in }
        )
        channel.start()
        defer { channel.stop() }
        _ = try await pair.receiveData()

        try await pair.sendFrame(tag: .input, payload: Data("close".utf8))

        do {
            _ = try await withTimeout(seconds: 2) {
                try await pair.receiveData()
            }
            XCTFail("client should not receive another terminal frame after write failure")
        } catch {
            XCTAssertTrue(true)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let succeeded = await predicate()
        XCTAssertTrue(succeeded)
    }
}

private actor TerminalFrameRecorder {
    struct Resize: Equatable {
        let cols: Int
        let rows: Int
    }

    private(set) var inputs: [Data] = []
    private(set) var resizes: [Resize] = []

    var inputCount: Int { inputs.count }
    var resizeCount: Int { resizes.count }

    func firstInput() -> Data? {
        inputs.first
    }

    func firstResize() -> Resize? {
        resizes.first
    }

    func recordInput(_ data: Data) -> Bool {
        inputs.append(data)
        return true
    }

    func recordResize(cols: Int, rows: Int) {
        resizes.append(Resize(cols: cols, rows: rows))
    }
}

private final class LocalWebSocketPair {
    let listener: NWListener
    let server: NWConnection
    let client: URLSessionWebSocketTask

    private init(listener: NWListener, server: NWConnection, client: URLSessionWebSocketTask) {
        self.listener = listener
        self.server = server
        self.client = client
    }

    static func make() async throws -> LocalWebSocketPair {
        let params = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let accepted = AcceptedConnectionBox()
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            accepted.accept(connection)
        }
        try await listener.startAndWaitForPort()
        let port = try XCTUnwrap(listener.port?.rawValue)
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/terminal-test"))
        let client = URLSession.shared.webSocketTask(with: url)
        client.resume()
        let server = try await withTimeout(seconds: 3) {
            await accepted.wait()
        }
        return LocalWebSocketPair(listener: listener, server: server, client: client)
    }

    func sendFrame(tag: TerminalFrameTag, payload: Data) async throws {
        try await sendRaw(Data([tag.rawValue]) + payload)
    }

    func sendRaw(_ data: Data) async throws {
        try await client.send(.data(data))
    }

    func receiveData() async throws -> Data {
        let message = try await withTimeout(seconds: 3) {
            try await self.client.receive()
        }
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            throw URLError(.badServerResponse)
        }
    }

    func cancel() {
        client.cancel(with: .goingAway, reason: nil)
        server.cancel()
        listener.cancel()
    }
}

private final class AcceptedConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<NWConnection, Never>?

    func accept(_ connection: NWConnection) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: connection)
        } else {
            self.connection = connection
            lock.unlock()
        }
    }

    func wait() async -> NWConnection {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let connection {
                lock.unlock()
                continuation.resume(returning: connection)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private extension NWListener {
    func startAndWaitForPort() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock()
                guard !resumed else {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(URLError(.cancelled)))
                default:
                    break
                }
            }
            start(queue: .global())
        }
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw URLError(.timedOut)
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
