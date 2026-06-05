import Foundation

/// Track B — B0: the subscription-over-relay **multiplex envelope**.
///
/// The relay's `RelayPlaintext` is `{seq, op, data}` and today carries only
/// request/response (`op = "GET./sessions"`). It has no way to (a) correlate
/// concurrent requests, (b) carry long-lived subscription streams, or
/// (c) split a frame that exceeds the relay's 64 KiB sealed-body cap.
///
/// B0 adds ONE new op — `RelayMux.op` (`"mux"`) — whose `data` slot is a
/// `RelayMuxFrame`. Every existing request/response frame is untouched
/// (different `op`), so the legacy HTTP tunnel stays byte-identical; only
/// `"mux"` frames reach the new loopback-WS bridge (B0.2).
///
/// Design corrections folded from the eng review:
/// - **opId is mandatory** on every frame and a duplicate *live* opId is
///   rejected by the dispatcher — `op`-echo alone can't correlate concurrent
///   same-route requests (CB-P1b).
/// - **Chunking has a concrete contract** — `{messageId, index, count}`, a
///   max-buffered cap, a reassembly timeout, and in-order delivery — because
///   existing chat snapshots already exceed the 64 KiB body cap (CB-P1c).
public enum RelayMux {

    /// The single reserved `RelayPlaintext.op` for all multiplex frames. Kept
    /// distinct from the `"<METHOD>.<path>"` request ops so the legacy
    /// `RelayRequestDispatcher` never sees a mux frame (and vice-versa).
    public static let op = "mux"

    /// Max RAW (pre-encode) payload bytes per chunk. The sealed body cap is
    /// 65536; after the RelayMuxFrame JSON (base64 of `payload` ≈ ×1.33 +
    /// ~120 B keys) is spliced raw into `RelayPlaintext.data` and AEAD-framed
    /// (nonce 24 + tag 16), 32 KiB raw leaves comfortable margin under 64 KiB.
    public static let maxRawPayloadBytes = 32 * 1024
}

/// Chunk header — present ONLY when a logical payload was split across frames.
/// All chunks of one logical frame share `messageId`; `index` is 0-based and
/// `count` is the total. A single-frame payload omits this entirely.
public struct RelayChunkHeader: Codable, Equatable, Sendable {
    public let messageId: String
    public let index: Int
    public let count: Int

    public init(messageId: String, index: Int, count: Int) {
        self.messageId = messageId
        self.index = index
        self.count = count
    }
}

/// What a `RelayMuxFrame` is. Request/response/end/error mirror the HTTP
/// tunnel but multiplexed; subscribe/subFrame/subEnd/unsubscribe carry the
/// long-lived WS streams (chat-subscribe, terminal, events, frontier, …).
public enum RelayMuxKind: String, Codable, Sendable {
    case request            // multiplexed one-shot request (payload = HTTP envelope)
    case response           // its response (payload = HTTP response envelope)
    case end                // request stream end (no more response frames)
    case error              // request/subscription error (payload = error JSON)
    case subscribe          // open a stream (payload = subscribe spec JSON: {op,sessionId,…})
    case subFrame           // one stream frame (payload = snapshot / terminal bytes / event)
    case subEnd             // stream closed by either side
    case unsubscribe        // client asks to close a stream
}

/// The multiplex envelope carried in `RelayPlaintext.data` for `op == "mux"`.
///
/// `opId` correlates a request with its response, or a subscribe with all its
/// `subFrame`s. It is MANDATORY — decode fails if absent (Codable required
/// field), so a malformed frame is a protocol violation, not a silent default.
public struct RelayMuxFrame: Codable, Equatable, Sendable {
    /// Correlation id. For requests: unique per request. For subscriptions:
    /// the stream id (shared by subscribe + every subFrame + subEnd).
    public let opId: String
    public let kind: RelayMuxKind
    /// Present only for a split payload; nil for single-frame payloads.
    public let chunk: RelayChunkHeader?
    /// Inner bytes — an HTTP envelope, a snapshot JSON, terminal bytes, an
    /// event, or a subscribe spec, depending on `kind`. base64 on the wire
    /// (one layer; `RelayPlaintext.data` then splices this JSON in raw).
    public let payload: Data?

    public init(opId: String, kind: RelayMuxKind, chunk: RelayChunkHeader? = nil, payload: Data? = nil) {
        self.opId = opId
        self.kind = kind
        self.chunk = chunk
        self.payload = payload
    }

    /// Encode to the JSON bytes that go into `RelayPlaintext(op: RelayMux.op, data:)`.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decode from a `RelayPlaintext.data` slot. Returns nil on any parse
    /// failure (incl. a missing `opId`) — the caller MUST treat nil as a
    /// protocol violation.
    public static func decode(_ bytes: Data) -> RelayMuxFrame? {
        try? JSONDecoder().decode(RelayMuxFrame.self, from: bytes)
    }
}

/// Splits a logical payload into one or more `RelayMuxFrame`s that each fit the
/// relay's sealed-body cap, and reassembles them on the far side.
public enum RelayChunker {

    /// Build the frame(s) for one logical payload. A payload at or under the
    /// cap yields a single frame with `chunk == nil`; a larger one yields N
    /// ordered frames sharing a `messageId`.
    ///
    /// - Parameter messageId: caller-supplied id grouping the chunks. Pass a
    ///   fresh UUID string per logical frame. (Injected so tests are
    ///   deterministic.)
    public static func split(
        opId: String,
        kind: RelayMuxKind,
        payload: Data,
        messageId: String,
        maxRawPayloadBytes: Int = RelayMux.maxRawPayloadBytes
    ) -> [RelayMuxFrame] {
        guard payload.count > maxRawPayloadBytes else {
            return [RelayMuxFrame(opId: opId, kind: kind, chunk: nil, payload: payload)]
        }
        let count = (payload.count + maxRawPayloadBytes - 1) / maxRawPayloadBytes
        var frames: [RelayMuxFrame] = []
        frames.reserveCapacity(count)
        var index = 0
        var start = payload.startIndex
        while start < payload.endIndex {
            let end = payload.index(start, offsetBy: maxRawPayloadBytes, limitedBy: payload.endIndex) ?? payload.endIndex
            let slice = Data(payload[start..<end])
            frames.append(RelayMuxFrame(
                opId: opId, kind: kind,
                chunk: RelayChunkHeader(messageId: messageId, index: index, count: count),
                payload: slice
            ))
            index += 1
            start = end
        }
        return frames
    }
}

/// Reassembles chunked `RelayMuxFrame`s back into the original payload.
///
/// Bounded so a malicious / buggy peer can't exhaust memory: a per-message
/// buffered-bytes cap and a reassembly timeout (a message that never completes
/// is dropped). Single-frame (un-chunked) payloads pass straight through.
///
/// Not thread-safe by itself — the relay client owns one per connection and
/// only touches it from its own actor/serial context.
public final class RelayChunkReassembler {

    public enum RejectReason: Equatable {
        case overCap          // total buffered bytes for a message exceeded the cap
        case badIndex         // index out of range / count mismatch
        case duplicate        // same (messageId,index) seen twice
    }

    private struct Partial {
        var count: Int
        var received: [Int: Data]
        var bytes: Int
        var firstSeen: Date
    }

    private let maxBufferedBytes: Int
    private let timeout: TimeInterval
    private var partials: [String: Partial] = [:]

    public init(maxBufferedBytes: Int = 8 * 1024 * 1024, timeout: TimeInterval = 30) {
        self.maxBufferedBytes = maxBufferedBytes
        self.timeout = timeout
    }

    /// Feed one frame. Returns the full payload when the LAST missing chunk of
    /// a message arrives (or immediately for an un-chunked frame); nil while a
    /// message is still incomplete; throws `RejectReason` on a cap/index/dup
    /// violation (the caller tears the stream down). `now` is injected for
    /// deterministic tests.
    @discardableResult
    public func accept(_ frame: RelayMuxFrame, now: Date = Date()) throws -> Data? {
        pruneExpired(now: now)
        guard let chunk = frame.chunk else {
            return frame.payload ?? Data()   // un-chunked: deliver as-is
        }
        guard chunk.count > 0, chunk.index >= 0, chunk.index < chunk.count else {
            throw RejectReason.badIndex
        }
        let slice = frame.payload ?? Data()
        var partial = partials[chunk.messageId]
            ?? Partial(count: chunk.count, received: [:], bytes: 0, firstSeen: now)
        guard partial.count == chunk.count else { throw RejectReason.badIndex }
        guard partial.received[chunk.index] == nil else { throw RejectReason.duplicate }
        if partial.bytes + slice.count > maxBufferedBytes {
            partials[chunk.messageId] = nil
            throw RejectReason.overCap
        }
        partial.received[chunk.index] = slice
        partial.bytes += slice.count
        if partial.received.count == partial.count {
            partials[chunk.messageId] = nil
            var full = Data(capacity: partial.bytes)
            for i in 0..<partial.count { full.append(partial.received[i] ?? Data()) }
            return full
        }
        partials[chunk.messageId] = partial
        return nil
    }

    /// Drop in-flight messages older than `timeout` (a peer that stalls
    /// mid-message can't pin memory forever).
    public func pruneExpired(now: Date) {
        guard !partials.isEmpty else { return }
        partials = partials.filter { now.timeIntervalSince($0.value.firstSeen) < timeout }
    }

    /// Test/diagnostic: count of messages currently mid-reassembly.
    public var inFlightCount: Int { partials.count }
}

extension RelayChunkReassembler.RejectReason: Error {}
