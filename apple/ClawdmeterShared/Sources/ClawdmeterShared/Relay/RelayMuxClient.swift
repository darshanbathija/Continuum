import Foundation

/// Track B — B0.3: the **client side** of subscription-over-relay (used by iOS).
///
/// Mirror of the Mac `RelaySubscriptionBridge`: where the bridge turns inbound
/// `.subscribe` frames into loopback WS streams, this client *opens* streams
/// over the relay and *demuxes* the `subFrame`s back to the right per-stream
/// sink. It owns:
///
/// - **opId allocation + active-stream tracking** — so a reconnect can
///   re-subscribe every live stream (D4); the Mac then replays each stream's
///   current snapshot.
/// - **chunk reassembly per stream** (`RelayChunkReassembler`) for payloads
///   that crossed the 64 KiB cap on the way out (CB-P1c).
/// - **full-duplex input** — terminal keystrokes/resize go out as `subFrame`s
///   on the stream's opId (CB-P1a).
///
/// Pure transport plumbing: the caller (the iOS relay client) injects the
/// `send` closure that seals + ships a `RelayMuxFrame`, and registers per-stream
/// handlers that forward reassembled payloads into the existing chat/terminal/
/// events/frontier stores. `makeOpId` / `makeMessageId` are injected so tests
/// are deterministic.
@MainActor
public final class RelayMuxClient {

    /// Ships one multiplex frame over the relay (seal + send `op == "mux"`).
    public typealias SendMux = @MainActor (RelayMuxFrame) async -> Void

    /// Per-stream callbacks. `onFrame` gets each fully-reassembled payload;
    /// `onEnd`/`onError` fire once and the stream is dropped.
    public struct StreamHandlers {
        public let onFrame: @MainActor (Data) -> Void
        public let onEnd: @MainActor () -> Void
        public let onError: @MainActor (String) -> Void
        public init(
            onFrame: @escaping @MainActor (Data) -> Void,
            onEnd: @escaping @MainActor () -> Void = {},
            onError: @escaping @MainActor (String) -> Void = { _ in }
        ) {
            self.onFrame = onFrame
            self.onEnd = onEnd
            self.onError = onError
        }
    }

    private struct Stream {
        let spec: RelaySubscribeSpec
        let handlers: StreamHandlers
        let reassembler: RelayChunkReassembler
    }

    private let send: SendMux
    private let makeOpId: @MainActor () -> String
    private let makeMessageId: @MainActor () -> String
    private let maxRawPayloadBytes: Int
    private var streams: [String: Stream] = [:]

    public init(
        send: @escaping SendMux,
        makeOpId: @escaping @MainActor () -> String = { UUID().uuidString },
        makeMessageId: @escaping @MainActor () -> String = { UUID().uuidString },
        maxRawPayloadBytes: Int = RelayMux.maxRawPayloadBytes
    ) {
        self.send = send
        self.makeOpId = makeOpId
        self.makeMessageId = makeMessageId
        self.maxRawPayloadBytes = maxRawPayloadBytes
    }

    public var activeCount: Int { streams.count }
    public func isActive(_ opId: String) -> Bool { streams[opId] != nil }

    // MARK: - Open / close streams

    /// Open a stream. Registers handlers, sends the `.subscribe` frame, and
    /// returns the opId the caller uses for input/unsubscribe.
    @discardableResult
    public func subscribe(_ spec: RelaySubscribeSpec, handlers: StreamHandlers) async -> String {
        let opId = makeOpId()
        streams[opId] = Stream(spec: spec, handlers: handlers, reassembler: RelayChunkReassembler())
        await emitSubscribe(opId: opId, spec: spec)
        return opId
    }

    /// Close a stream: tell the Mac to stop, then drop local state. Idempotent.
    public func unsubscribe(_ opId: String) async {
        guard streams[opId] != nil else { return }
        streams[opId] = nil
        await send(RelayMuxFrame(opId: opId, kind: .unsubscribe))
    }

    /// Full-duplex: send input bytes (terminal keystrokes / resize) up the
    /// stream, chunked if they exceed the cap.
    public func sendInput(_ opId: String, _ data: Data) async {
        guard streams[opId] != nil else { return }
        let frames = RelayChunker.split(
            opId: opId, kind: .subFrame, payload: data,
            messageId: makeMessageId(), maxRawPayloadBytes: maxRawPayloadBytes
        )
        for f in frames { await send(f) }
    }

    // MARK: - Inbound demux

    /// Route one inbound mux frame to its stream. Reassembles chunks; on a
    /// complete payload calls `onFrame`. `subEnd`/`error` fire the matching
    /// handler once and drop the stream. Unknown opIds are ignored (a frame for
    /// a stream we already closed).
    public func handleInbound(_ frame: RelayMuxFrame) {
        guard let stream = streams[frame.opId] else { return }
        switch frame.kind {
        case .subFrame:
            do {
                if let payload = try stream.reassembler.accept(frame) {
                    stream.handlers.onFrame(payload)
                }
            } catch {
                // A chunk-protocol violation (cap/dup/bad-index) tears the
                // stream down — better to resync than to deliver corruption.
                streams[frame.opId] = nil
                stream.handlers.onError("chunk reassembly failed")
            }
        case .subEnd:
            streams[frame.opId] = nil
            stream.handlers.onEnd()
        case .error:
            streams[frame.opId] = nil
            let msg = frame.payload.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }?["error"] as? String
            stream.handlers.onError(msg ?? "stream error")
        case .subscribe, .request, .response, .end, .unsubscribe:
            break   // not inbound-to-client kinds
        }
    }

    // MARK: - Reconnect

    /// Re-send a `.subscribe` for every live stream after a relay reconnect.
    /// The Mac re-opens each loopback WS and replays the current snapshot, so
    /// streams resume without the caller re-registering handlers (D4).
    ///
    /// NOTE: depends on the reconnect replay-seq epoch fix (CB-P0b) to avoid
    /// the resubscribe frames being dropped as replays — that fix gates B5.
    public func resubscribeAll() async {
        for (opId, stream) in streams {
            stream.reassembler.pruneExpired(now: Date())   // drop half-received messages from before the drop
            await emitSubscribe(opId: opId, spec: stream.spec)
        }
    }

    /// Drop all streams (relay stopped / unpaired). Does not notify the Mac
    /// (the socket is gone); callers re-subscribe fresh on the next connect.
    public func reset() {
        streams.removeAll()
    }

    // MARK: - Internals

    private func emitSubscribe(opId: String, spec: RelaySubscribeSpec) async {
        let payload = (try? spec.encoded()) ?? Data()
        await send(RelayMuxFrame(opId: opId, kind: .subscribe, payload: payload))
    }
}
