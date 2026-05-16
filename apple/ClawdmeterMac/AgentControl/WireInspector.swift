import Foundation
import OSLog

private let inspectorLogger = Logger(subsystem: "com.clawdmeter.mac", category: "WireInspector")

/// Sessions v2 T18. Rolling in-memory buffer of HTTP/WS payloads for
/// debugging client/server skew. Off by default; toggle via Settings →
/// Diagnostics → Wire Inspector. Capped at 500 entries (~5MB worst-case).
///
/// Bodies are sniffed when small (< 16KB) and JSON-ish; larger or binary
/// payloads are recorded as `<bytes>B <content-type>` stubs. This stays
/// safe by default for sensitive prompts even when the inspector is on —
/// users opt into the second layer separately via the existing audit-log
/// plaintext flag if they want full bodies.
public actor WireInspector {
    public static let shared = WireInspector()

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
    private let maxEntries = 500
    private var enabled = false

    public init() {}

    public func setEnabled(_ on: Bool) {
        enabled = on
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

    public func entries(limit: Int = 500) -> [Entry] {
        Array(buffer.suffix(limit))
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: false)
    }

    private func append(_ entry: Entry) {
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
    }

    private func bodyPreview(data: Data?, contentType: String?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let ct = contentType ?? ""
        if data.count > 16_000 {
            return "\(data.count)B \(ct)"
        }
        if ct.contains("json") || ct.contains("text") || ct.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(data.count)B \(ct)"
    }
}
