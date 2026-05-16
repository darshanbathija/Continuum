import Foundation
import OSLog

private let inspectorLogger = Logger(subsystem: "com.clawdmeter.mac", category: "WireInspector")

/// Sessions v2 T18. Rolling in-memory buffer of HTTP request/response
/// payloads for debugging client/server skew. Off by default; toggle via
/// Settings → Diagnostics → Wire Inspector. Capped at `bufferCap` entries
/// (~5MB worst-case).
///
/// Body capture honors the existing audit-log plaintext opt-in
/// (`clawdmeter.audit.includePlaintext`, set from Settings → Privacy).
/// When plaintext is opt-OUT (default), bodies are stubbed as
/// `<bytes>B <content-type>` even when small + JSON-shaped. This keeps
/// the inspector useful for debugging request/response *shapes* without
/// silently mirroring the user's prompts into an in-memory buffer.
///
/// Hot-path note: the daemon's `sendResponse` is on every HTTP response.
/// Reaching the actor (`recordResponse`) costs at least one hop plus a
/// `Data` retain for the body capture. When the inspector is disabled
/// (the common case), callers should consult `isEnabledFast` before
/// constructing the Task at all — see the `nonisolated(unsafe)` flag
/// below.
///
/// HTTP only in v2.0.1 — the `recordWebSocket` entry point exists for a
/// later pass that wants to capture per-frame WS traffic without
/// ballooning the buffer with raw terminal bytes.
public actor WireInspector {
    public static let shared = WireInspector()

    /// Maximum number of entries kept in the rolling buffer.
    public static let bufferCap = 500
    /// Size threshold above which bodies are stubbed as `<bytes>B <ct>`
    /// instead of UTF-8 decoded (even when plaintext is on).
    public static let bodySniffThreshold = 16_000

    /// Fast, lock-free advisory read of the enabled state. Mirrored by
    /// `setEnabled` whenever the inspector toggles. Hot callers read this
    /// to avoid spawning a Task + body retain when the inspector is off.
    ///
    /// Safety: a missed read of a just-toggled value at most drops or
    /// gains one entry in the rolling buffer. The actor's own `enabled`
    /// is still the source of truth — `recordRequest` / `recordResponse`
    /// re-check it inside the actor so toggling from "on" to "off"
    /// concurrent with a record call can't smuggle an extra entry in.
    nonisolated(unsafe) public static var isEnabledFast: Bool = false

    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let at: Date
        public let direction: Direction
        public let kind: Kind
        public let method: String?
        public let path: String
        public let status: Int?
        public let bodyPreview: String
        public let peer: String

        public enum Direction: String, Sendable {
            case incoming = "→"
            case outgoing = "←"
        }
        public enum Kind: String, Sendable {
            case http
            case websocket
        }
    }

    private var buffer: [Entry] = []
    private var enabled = false

    public init() {}

    public func setEnabled(_ on: Bool) {
        enabled = on
        Self.isEnabledFast = on
        if !on {
            buffer.removeAll(keepingCapacity: false)
        }
        inspectorLogger.debug("WireInspector \(on ? "enabled" : "disabled")")
    }

    public func isEnabled() -> Bool { enabled }

    public func recordRequest(
        method: String, path: String, peer: String, body: Data?, contentType: String?
    ) {
        guard enabled else { return }
        let preview = bodyPreview(data: body, contentType: contentType)
        append(Entry(
            id: UUID(), at: Date(), direction: .incoming, kind: .http,
            method: method, path: path, status: nil,
            bodyPreview: preview, peer: peer
        ))
    }

    public func recordResponse(
        method: String, path: String, peer: String, status: Int, body: Data?, contentType: String?
    ) {
        guard enabled else { return }
        let preview = bodyPreview(data: body, contentType: contentType)
        append(Entry(
            id: UUID(), at: Date(), direction: .outgoing, kind: .http,
            method: method, path: path, status: status,
            bodyPreview: preview, peer: peer
        ))
    }

    public func recordWebSocket(
        direction: Entry.Direction, peer: String, op: String, body: Data?
    ) {
        guard enabled else { return }
        let preview = bodyPreview(data: body, contentType: "application/json")
        append(Entry(
            id: UUID(), at: Date(), direction: direction, kind: .websocket,
            method: nil, path: "ws:\(op)", status: nil,
            bodyPreview: preview, peer: peer
        ))
    }

    public func entries(limit: Int = WireInspector.bufferCap) -> [Entry] {
        Array(buffer.suffix(limit))
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: false)
    }

    private func append(_ entry: Entry) {
        buffer.append(entry)
        if buffer.count > Self.bufferCap {
            buffer.removeFirst(buffer.count - Self.bufferCap)
        }
    }

    private func bodyPreview(data: Data?, contentType: String?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let ct = contentType ?? ""
        if data.count > Self.bodySniffThreshold {
            return "\(data.count)B \(ct)"
        }
        // Plaintext gate: same UserDefaults flag the AuditLog respects.
        // When off (default), preview only the byte count + content type
        // even for small JSON bodies. Without this, every prompt sent
        // through the daemon while the inspector is on lands verbatim in
        // the rolling buffer, contradicting the inspector's privacy
        // posture and exposing it via the Diagnostics UI.
        let includePlaintext = UserDefaults.standard.bool(
            forKey: "clawdmeter.audit.includePlaintext"
        )
        guard includePlaintext else {
            return "\(data.count)B \(ct)"
        }
        if ct.contains("json") || ct.contains("text") || ct.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(data.count)B \(ct)"
    }
}
