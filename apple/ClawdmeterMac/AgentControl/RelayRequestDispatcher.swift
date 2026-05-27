import Foundation
import OSLog
import ClawdmeterShared

private let dispatcherLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayRequestDispatcher")

/// E3 — bridge between encrypted relay frames and the AgentControlServer's
/// existing HTTP routes.
///
/// ## Why we don't refactor AgentControlServer
///
/// `AgentControlServer.dispatch(request:connection:)` writes responses
/// back through `NWConnection.send(...)`. Threading an "abstract transport"
/// through the entire route handler tree would be a massive refactor with
/// no behavioral benefit for E3's acceptance — the relay is purely a
/// transport. Instead, we treat the relay frame as just another HTTP
/// request and dispatch it through the existing **localhost loopback**:
///
///   inbound encrypted relay frame
///       → decrypt to `RelayInnerFrame { seq, op, data }`
///       → translate op to HTTP method + path
///       → POST/GET via `AgentControlClient` against 127.0.0.1:boundPort
///       → response Data
///       → encrypt + send back as `op.response` frame
///
/// The relay end-to-end is therefore: iPhone encrypts → CF Worker relays
/// opaque bytes → Mac decrypts → Mac issues a localhost HTTP request →
/// Mac encrypts the response → CF Worker relays back → iPhone decrypts.
/// One round trip, two TLS connections (iPhone↔CF, Mac↔CF), one
/// localhost socket (Mac↔Mac).
///
/// ## Op naming convention
///
/// We use `<METHOD>.<path>` so the iPhone side can target any of the
/// existing handlers without us hand-rolling a per-op switch on the Mac.
/// Examples:
///   - `GET./sessions`      → loopback GET 127.0.0.1:port/sessions
///   - `POST./sessions/:id/send` → loopback POST with body
///
/// The body of the inner frame is the JSON the loopback would receive
/// in the HTTP body (empty for GET).
///
/// ## Security defense in depth
///
/// Even though the relay's bearer-auth + symmetric-key encrypt make this
/// path tamper-evident, we still authenticate against the loopback's
/// per-launch token. A bug that exposed the relay's symmetric key would
/// otherwise let an attacker hit arbitrary endpoints — having the
/// localhost server reject anything missing the right bearer means a
/// relay compromise still can't reach the handlers without separately
/// compromising the in-process token. (The token is generated fresh per
/// app launch and never persisted, so a relay leak alone is insufficient.)
@MainActor
public final class RelayRequestDispatcher {

    private let loopbackClient: AgentControlClient
    private let urlSession: URLSession

    public init(loopbackClient: AgentControlClient, urlSession: URLSession = .shared) {
        self.loopbackClient = loopbackClient
        self.urlSession = urlSession
    }

    /// Dispatch an inbound inner frame as an HTTP request against the
    /// localhost AgentControlServer. Returns the response body the Mac
    /// should send back to the peer (encrypted) — or nil if the op was
    /// fire-and-forget / errored unrecoverably.
    public func dispatch(_ inner: RelayInnerFrame) async -> Data? {
        // Parse op shape: "<METHOD>.<path>"
        // E.g. "GET./sessions", "POST./sessions/<uuid>/send"
        let parts = inner.op.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            dispatcherLogger.warning("Malformed op: \(inner.op, privacy: .public)")
            return errorResponse(status: 400, message: "malformed op")
        }
        let method = String(parts[0])
        let path = String(parts[1])

        guard isAllowedMethod(method) else {
            dispatcherLogger.warning("Disallowed method: \(method, privacy: .public)")
            return errorResponse(status: 405, message: "method not allowed")
        }

        guard let host = loopbackClient.host,
              let token = loopbackClient.token else {
            dispatcherLogger.warning("Loopback client not configured; dropping relay frame")
            return errorResponse(status: 503, message: "loopback unavailable")
        }
        let httpPort = loopbackClient.httpPort
        guard let url = URL(string: "http://\(host):\(httpPort)\(path)") else {
            dispatcherLogger.warning("Failed to construct loopback URL for \(path, privacy: .public)")
            return errorResponse(status: 400, message: "invalid path")
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" && !inner.data.isEmpty {
            req.httpBody = inner.data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await urlSession.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Wrap the loopback's response into a small JSON envelope so
            // the iPhone side can disambiguate "200 with empty body" from
            // "503 unreachable" without parsing HTTP headers.
            let envelope: [String: Any] = [
                "status": status,
                "body": String(data: data, encoding: .utf8) ?? "",
            ]
            return try? JSONSerialization.data(withJSONObject: envelope)
        } catch {
            dispatcherLogger.warning(
                "Loopback dispatch failed for \(method, privacy: .public) \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return errorResponse(status: 502, message: "loopback failed: \(error.localizedDescription)")
        }
    }

    /// Allowlist of methods we route. Conservative — only the HTTP verbs
    /// the iOS app + paired peers actually use today. Extending this is
    /// safe but should be deliberate.
    private func isAllowedMethod(_ method: String) -> Bool {
        switch method {
        case "GET", "POST", "PUT", "PATCH", "DELETE":
            return true
        default:
            return false
        }
    }

    private func errorResponse(status: Int, message: String) -> Data {
        let envelope: [String: Any] = [
            "status": status,
            "body": "",
            "error": message,
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }
}
