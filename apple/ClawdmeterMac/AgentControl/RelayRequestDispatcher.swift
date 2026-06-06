// E3: bridge between decrypted relay frames and AgentControlServer's
// existing HTTP routes.
//
// ## Why we don't refactor AgentControlServer
//
// `AgentControlServer.dispatch(request:connection:)` writes responses
// back through `NWConnection.send(...)`. Threading an "abstract
// transport" through the entire route-handler tree would balloon the
// change for no behavioral benefit — the relay is a postal service for
// opaque bytes. Instead, every inbound relay frame becomes a localhost
// HTTP request against the in-process `AgentControlServer`:
//
//   inbound encrypted relay frame
//     → MacRelayClient decrypts to `MacRelayInboundMessage(seq, op, data)`
//     → translate `op` ("<METHOD>.<path>") to an HTTP request
//     → POST/GET via the loopback `AgentControlClient` against 127.0.0.1
//     → response Data
//     → MacRelayClient encrypts + sends back as `op.response` frame
//
// End-to-end: iPhone encrypts → CF Worker forwards opaque bytes → Mac
// decrypts → Mac issues a localhost HTTP request → Mac encrypts the
// response → CF Worker relays back → iPhone decrypts. Two TLS hops, one
// localhost socket, every existing handler unchanged.
//
// ## Op-naming convention
//
// We use `<METHOD>.<path>` so the iPhone side targets handlers without
// the Mac hand-rolling a per-op switch. Examples:
//   - `GET./sessions` → loopback `GET 127.0.0.1:port/sessions`
//   - `POST./sessions/<uuid>/send` → loopback `POST` with body
//
// ## Security defense-in-depth
//
// The relay's bearer auth + symmetric-key encrypt make this path
// tamper-evident. We still authenticate against the loopback server's
// per-launch token — a bug that exposed the relay's symmetric key
// would otherwise let an attacker hit arbitrary endpoints. The loopback
// token is generated fresh per app launch + never persisted, so a relay
// compromise alone is insufficient.

import Foundation
import OSLog
import ClawdmeterShared

private let dispatcherLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayRequestDispatcher")

/// Default URLSession used by the dispatcher. Tests inject a fake.
@MainActor
public final class RelayRequestDispatcher {

    private let loopbackClient: AgentControlClient
    private let urlSession: URLSession

    public init(loopbackClient: AgentControlClient, urlSession: URLSession = .shared) {
        self.loopbackClient = loopbackClient
        self.urlSession = urlSession
    }

    /// Dispatch one inbound frame. Returns the response bytes the Mac
    /// should encrypt + send back to the peer, or nil for fire-and-
    /// forget. Errors are surfaced as JSON-envelope responses with
    /// non-200 status so the iPhone can disambiguate transport vs
    /// daemon errors.
    public func dispatch(_ inner: MacRelayInboundMessage) async -> Data? {
        // Op shape: "<METHOD>.<path>". Reject anything else as a
        // protocol error (the iPhone built the op string, so this
        // shouldn't happen in practice — but defense in depth).
        let parts = inner.op.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            dispatcherLogger.warning("Malformed op: \(inner.op, privacy: .public)")
            return Self.errorEnvelope(status: 400, message: "malformed op")
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])

        guard Self.isAllowedMethod(method) else {
            dispatcherLogger.warning("Disallowed method: \(method, privacy: .public)")
            return Self.errorEnvelope(status: 405, message: "method not allowed")
        }

        // Path MUST start with "/" to map to a loopback URL. We also
        // reject any embedded scheme/host (e.g., "https://attacker.com")
        // — `URL(string:)` would happily eat it otherwise.
        guard rawPath.hasPrefix("/"), !rawPath.contains("://") else {
            return Self.errorEnvelope(status: 400, message: "invalid path")
        }

        guard let host = loopbackClient.host,
              let token = loopbackClient.token else {
            dispatcherLogger.warning("Loopback client not configured; dropping relay frame")
            return Self.errorEnvelope(status: 503, message: "loopback unavailable")
        }
        let httpPort = loopbackClient.httpPort
        guard let url = URL(string: "http://\(AgentControlClient.urlHostLiteral(host)):\(httpPort)\(rawPath)") else {
            dispatcherLogger.warning("Failed to construct loopback URL for \(rawPath, privacy: .public)")
            return Self.errorEnvelope(status: 400, message: "invalid path")
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" && method != "DELETE" && !inner.data.isEmpty {
            req.httpBody = inner.data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await urlSession.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Wrap the loopback response in a small JSON envelope so the
            // iPhone can disambiguate "200 with empty body" from "503
            // unreachable" without parsing HTTP headers it never sees.
            // Carry bytes as base64 so artifact/binary responses don't
            // corrupt through a UTF-8 string round-trip.
            return Self.responseEnvelope(status: status, body: data)
        } catch {
            dispatcherLogger.warning(
                "Loopback dispatch failed for \(method, privacy: .public) \(rawPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return Self.errorEnvelope(status: 502, message: "loopback failed: \(error.localizedDescription)")
        }
    }

    /// Allowlist of methods we route. Conservative — only the HTTP
    /// verbs the iOS app + paired peers actually use today. Extending
    /// this is safe but should be a deliberate change.
    static func isAllowedMethod(_ method: String) -> Bool {
        switch method {
        case "GET", "POST", "PUT", "PATCH", "DELETE":
            return true
        default:
            return false
        }
    }

    static func errorEnvelope(status: Int, message: String) -> Data {
        responseEnvelope(status: status, body: Data(), error: message)
    }

    static func responseEnvelope(status: Int, body: Data, error: String? = nil) -> Data {
        var envelope: [String: Any] = [
            "status": status,
            "bodyBase64": body.base64EncodedString(),
            "bodyLength": body.count,
        ]
        if let text = String(data: body, encoding: .utf8) {
            envelope["body"] = text
        }
        if let error {
            envelope["error"] = error
            envelope["body"] = ""
        }
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }
}
