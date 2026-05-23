// Client for the locally-running Antigravity LSP server's gRPC API.
//
// Discovery (2026-05-23): Antigravity 2.0.6 ships a Go-based language
// server at /Applications/Antigravity.app/Contents/Resources/bin/language_server
// that listens on two localhost ports while the Electron UI is running:
//
//   * https://localhost:<APIport>  — HTTPS/HTTP-2 + gRPC, the actual
//     API. Serves both the SPA static assets AND gRPC method endpoints
//     under /exa.<package>.<Service>/<Method> paths. Self-signed cert.
//   * http://localhost:<webport>   — same SPA, plain HTTP. Unused by
//     us; we always talk to the HTTPS port for gRPC.
//
// Authentication is two-factor: the SPA root (GET /) embeds a
// csrfToken in window.__APP_CONFIG__, and every gRPC call must
// carry it as an x-codeium-csrf-token header. The token rotates on
// each LSP process restart.
//
// What this unblocks (follow-up work, not in this commit):
//   * SDK-mode usage extraction — call GetCascadeTrajectory for each
//     conversation ID, parse the UsageMetadata proto out of the
//     trajectory, and replace the markdown-byte-÷-4 heuristic with
//     real per-turn token counts.
//   * Live model + effort introspection — FetchUserInfo /
//     ListModelConfigs expose the user's account state.
//   * Anything else the Electron UI does — the entire feature surface
//     is reachable from any process that can read the CSRF token.

#if os(macOS)
import Foundation

/// Async gRPC client for the locally-running Antigravity LSP. Stateless
/// across calls — every request re-fetches the CSRF token if our cache
/// becomes stale (the LSP rotates it on restart).
public actor AntigravityLSPClient {

    public struct Endpoint: Sendable, Equatable {
        /// Hostname the LSP binds to. Defaults to 127.0.0.1 because
        /// the server's TLS cert is self-signed and pinned to local.
        public let host: String
        /// TLS port the LSP serves gRPC on. Discovered via
        /// `Self.discover()`; changes per restart so callers must
        /// not hard-code it.
        public let port: Int

        public init(host: String = "127.0.0.1", port: Int) {
            self.host = host
            self.port = port
        }

        var baseURL: URL { URL(string: "https://\(host):\(port)")! }
    }

    public enum LSPError: Error, Equatable, Sendable {
        /// GET / didn't return HTML or didn't contain a CSRF token.
        /// Usually means the LSP isn't running or the port is wrong.
        case csrfFetchFailed
        /// gRPC returned a non-zero status code via the grpc-status
        /// trailer. The associated string is the grpc-message header
        /// when one was sent.
        case grpcStatus(code: Int, message: String?)
        /// Transport-level error from URLSession — TLS handshake,
        /// connection refused, timeout, etc.
        case transport(String)
        /// Response body was structurally invalid (e.g. shorter than
        /// the 5-byte gRPC frame header).
        case invalidResponse
    }

    public let endpoint: Endpoint
    private let session: URLSession
    private var cachedCSRF: String?

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = nil
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        // Custom delegate trusts the self-signed cert.
        self.session = URLSession(
            configuration: cfg,
            delegate: SelfSignedTrustDelegate(),
            delegateQueue: nil
        )
    }

    // MARK: - LSP discovery

    /// Scans for the running language_server process and returns its
    /// TLS gRPC port. Nil when no instance is running. Implementation
    /// note: we deliberately don't use `lsof -c language_` because
    /// macOS's lsof has a bug where -c sometimes returns sockets from
    /// an unrelated process whose command happens to share a prefix.
    /// We instead pull the unfiltered listen list and grep for
    /// "language_" ourselves.
    public static func discover() -> Endpoint? {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var ports: [Int] = []
        for line in text.split(separator: "\n")
            where line.hasPrefix("language_") && line.contains("LISTEN") {
            // Format: language_ <pid> <user> <fd> ... TCP 127.0.0.1:54765 (LISTEN)
            if let range = line.range(of: "127.0.0.1:") ?? line.range(of: "localhost:"),
               let portRange = line[range.upperBound...].range(of: "[0-9]+", options: .regularExpression),
               let port = Int(line[range.upperBound...][portRange]) {
                ports.append(port)
            }
        }
        guard let minPort = ports.min() else { return nil }
        return Endpoint(port: minPort)
    }

    /// Alternative CSRF token source: the language_server process
    /// embeds it in its command-line argv as `--csrf_token <uuid>`.
    /// Tries this first; falls back to the HTML scrape if reading
    /// process args isn't permitted. Returns nil on any failure.
    public static func discoverCSRFFromProcessArgs() -> String? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-A", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("language_server") {
            if let range = line.range(of: "--csrf_token ") {
                let rest = line[range.upperBound...]
                if let end = rest.range(of: " ") {
                    return String(rest[..<end.lowerBound])
                }
                return String(rest)
            }
        }
        return nil
    }

    // MARK: - CSRF token

    /// Fetches the SPA's CSRF token from GET /. Cached for the
    /// lifetime of this client instance. Force-refreshes if invalidate
    /// is true (e.g. after a 403 from a prior call).
    public func refreshCSRFToken(invalidate: Bool = false) async throws -> String {
        if invalidate { cachedCSRF = nil }
        if let cached = cachedCSRF { return cached }
        var req = URLRequest(url: endpoint.baseURL)
        req.httpMethod = "GET"
        let (data, _): (Data, URLResponse)
        do {
            (data, _) = try await session.data(for: req)
        } catch {
            throw LSPError.transport(error.localizedDescription)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw LSPError.csrfFetchFailed
        }
        // Look for csrfToken":"<uuid>". Format is stable and
        // Google-controlled; cheaper than a full HTML parse.
        let marker = "csrfToken\":\""
        guard let start = html.range(of: marker) else {
            throw LSPError.csrfFetchFailed
        }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: "\"") else {
            throw LSPError.csrfFetchFailed
        }
        let token = String(rest[..<end.lowerBound])
        cachedCSRF = token
        return token
    }

    // MARK: - gRPC call

    /// Performs a unary gRPC call. Generic over wire-format payload:
    /// callers serialize their request to Data and decode the response
    /// Data themselves. Keeps the client agnostic to specific proto
    /// schemas (we'd otherwise need to vendor every proto Google ships).
    ///
    /// fullMethod must match the form /exa.<package>.<Service>/<Method>.
    /// requestBody is the raw protobuf wire payload (without the
    /// 5-byte gRPC frame header — this method adds the frame).
    public func unary(fullMethod: String, requestBody: Data) async throws -> Data {
        let csrf = try await refreshCSRFToken()
        let url = endpoint.baseURL.appendingPathComponent(fullMethod)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        req.setValue("identity", forHTTPHeaderField: "grpc-encoding")
        req.setValue("identity, gzip", forHTTPHeaderField: "grpc-accept-encoding")
        req.setValue("trailers", forHTTPHeaderField: "te")
        req.setValue(csrf, forHTTPHeaderField: "x-codeium-csrf-token")
        req.httpBody = Self.frame(body: requestBody)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LSPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LSPError.invalidResponse
        }
        // gRPC over HTTP/2: status is in headers `grpc-status` /
        // `grpc-message`. URLSession exposes trailers as additional
        // header fields on the response.
        let statusStr = (http.value(forHTTPHeaderField: "grpc-status")
                         ?? http.value(forHTTPHeaderField: "Grpc-Status")
                         ?? "0")
        let status = Int(statusStr) ?? 0
        let message = http.value(forHTTPHeaderField: "grpc-message")
                      ?? http.value(forHTTPHeaderField: "Grpc-Message")
        if status != 0 {
            // Invalidate the CSRF cache on auth failure so the next
            // call re-fetches.
            if status == 16 || status == 7 { cachedCSRF = nil }
            throw LSPError.grpcStatus(code: status, message: message)
        }
        return try Self.unframe(payload: data)
    }

    /// Convenience: roundtrip an empty-body request to confirm the
    /// LSP is reachable + the CSRF token is valid. HasAuthToken is a
    /// no-arg method that always returns OK on a working install.
    @discardableResult
    public func ping() async throws -> Data {
        try await unary(
            fullMethod: "/exa.language_server_pb.LanguageServerService/HasAuthToken",
            requestBody: Data()
        )
    }

    /// Fetches the full trajectory for a conversation. Returns the
    /// raw protobuf bytes — callers parse out whichever sub-message
    /// they need. The proto schema is reverse-engineered from the LSP
    /// binary's Go reflection metadata; future work will add typed
    /// parsing for UsageMetadata so we can extract real token counts.
    ///
    /// `conversationID` is the cascade_id, which matches the `.db`
    /// filename stem in `~/.gemini/antigravity/conversations/`. The
    /// LSP returns `grpc-status: 2 (NOT_FOUND)` when no live trajectory
    /// exists for that id — we surface that as `LSPError.grpcStatus`.
    public func getCascadeTrajectory(conversationID: String) async throws -> Data {
        // Request shape: field 1 (string, tag 0x0a) = cascade_id.
        // Reverse-engineered by sending the conversation UUID as field 1
        // against the live LSP and getting back a full trajectory.
        let idBytes = Array(conversationID.utf8)
        var body = Data()
        body.append(0x0a) // tag: field 1, wire-type length-delimited
        body.append(contentsOf: Self.encodeVarint(UInt64(idBytes.count)))
        body.append(contentsOf: idBytes)
        return try await unary(
            fullMethod: "/exa.language_server_pb.LanguageServerService/GetCascadeTrajectory",
            requestBody: body
        )
    }

    /// Encodes a UInt64 as protobuf varint bytes. Exposed via
    /// `internal` instead of `private` so the same helper is available
    /// for hand-rolled request encoders in callers.
    internal static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v > 0
        return bytes
    }

    // MARK: - gRPC framing helpers (exposed for testing)

    /// Prepends the 5-byte gRPC frame header to a proto payload:
    /// 1 byte (compressed flag, 0=uncompressed) + 4-byte big-endian
    /// payload length.
    public static func frame(body: Data) -> Data {
        var out = Data(capacity: body.count + 5)
        out.append(0) // not compressed
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Strips the 5-byte gRPC frame header. Returns the payload
    /// portion only.
    public static func unframe(payload: Data) throws -> Data {
        guard payload.count >= 5 else { throw LSPError.invalidResponse }
        let body = payload.subdata(in: 5..<payload.count)
        return body
    }
}

// MARK: - TLS skip-verify delegate

/// URLSessionDelegate that trusts any self-signed cert presented on
/// the LSP's localhost port. We only ever use this delegate against
/// 127.0.0.1; never against remote hosts.
private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Only bypass for localhost — defense-in-depth against an
        // attacker proxying our requests off-machine.
        let host = challenge.protectionSpace.host
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

#endif
