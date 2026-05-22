// DesignPortForwarder — TCP-level byte-pump that fronts the loopback
// Open Design daemon to iOS clients over the existing Tailscale pairing
// channel.
//
// Plan ref: v2.1 phase 5. NOT an HTTP-aware proxy. Parses only the
// FIRST request's header block to extract an auth token (Authorization
// bearer, clawdmeter_design_session cookie, or ?token= query); then
// switches to pure streaming pass-through. SSE, WebSockets, multipart
// uploads, range requests all work because nothing inspects them.
//
// Auth model: tokens are HKDF-derived per-pairing from the daemon's
// OD_API_TOKEN by OpenDesignDaemonManager.deriveDesignToken(forPairingId:);
// the forwarder accepts ANY token that matches HKDF(apiToken, pairingId)
// for any live pairing in PairingTokenStore (v2.1 T19).
//
// On the first NON-1xx response, if the original request had a ?token=
// query (the iOS WebView's bootstrap GET), the forwarder injects a
// Set-Cookie response header so subsequent subresource fetches don't
// need to carry the query — WKHTTPCookieStore handles the rest.
//
// Dual-stack bind (IPv4 + IPv6) so Tailscale peers reaching us over
// v6 also work. DNS-rebinding defense: Host header must match the
// expected bind, accepting bracketed IPv6 literals.

import Foundation
import Network
import CryptoKit
import OSLog
#if canImport(ClawdmeterShared)
import ClawdmeterShared
#endif

@MainActor
public final class DesignPortForwarder {

    public typealias TokenValidator = (String) -> Bool

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "DesignPortForwarder")

    private var listener: NWListener?
    private let daemonHost: NWEndpoint.Host
    private let daemonPort: NWEndpoint.Port
    private let tokenValidator: TokenValidator
    private let bindPort: Int

    public init(daemonPort: Int, bindPort: Int = 21732, tokenValidator: @escaping TokenValidator) {
        self.daemonHost = "127.0.0.1"
        self.daemonPort = NWEndpoint.Port(integerLiteral: UInt16(daemonPort))
        self.bindPort = bindPort
        self.tokenValidator = tokenValidator
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        guard let port = NWEndpoint.Port(rawValue: UInt16(bindPort)) else {
            throw NSError(domain: "DesignPortForwarder", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid bind port \(bindPort)"])
        }
        let listener = try NWListener(using: parameters, on: port)
        // Dual-stack: NWListener with IPv4-only port binding falls back to
        // OS-default behavior. To force dual-stack we set serviceClass +
        // requiredInterfaceType=nil; macOS already binds both families
        // unless specified otherwise.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor in
                self.handleNewConnection(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.logger.info("listener state: \(String(describing: state), privacy: .public)")
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ ios: NWConnection) {
        ios.start(queue: .global(qos: .userInitiated))
        Task.detached { [weak self] in
            await self?.processConnection(ios)
        }
    }

    private func processConnection(_ ios: NWConnection) async {
        do {
            let (headerBytes, parsed) = try await readRequestHeader(ios)
            guard let parsed else {
                try? await sendError(ios, status: 400, message: "bad request")
                ios.cancel()
                return
            }
            // Auth gate
            let token = parsed.token
            guard let token, await Task { @MainActor in self.tokenValidator(token) }.value else {
                try? await sendError(ios, status: 401, message: "unauthorized")
                ios.cancel()
                return
            }
            // Host validation (DNS-rebind defense)
            // Accept loopback, paired host, and bracketed IPv6 forms.
            // (Tailscale provides peer identity at the network layer; we
            // additionally require Host: to match a known form.)
            if !isAcceptableHost(parsed.host) {
                logger.warning("rejected Host=\(parsed.host ?? "(none)", privacy: .public)")
                try? await sendError(ios, status: 421, message: "misdirected request")
                ios.cancel()
                return
            }
            // Rewrite header bytes: strip ?token= from request line so it
            // doesn't leak into daemon logs / WKWebView history.
            let rewrittenHeaderBytes = stripTokenQueryParam(headerBytes)
            // Open the daemon-side socket and start pumping.
            let daemon = NWConnection(host: daemonHost, port: daemonPort, using: .tcp)
            daemon.start(queue: .global(qos: .userInitiated))
            // Send the (rewritten) header buffer first.
            try await send(daemon, data: rewrittenHeaderBytes)
            let hadTokenQuery = parsed.tokenSource == .query
            await pumpBidirectional(ios: ios, daemon: daemon, injectCookieToken: hadTokenQuery ? token : nil)
        } catch {
            logger.error("connection failure: \(error.localizedDescription, privacy: .public)")
            ios.cancel()
        }
    }

    // MARK: - Header parsing

    private struct ParsedRequestHeader {
        enum TokenSource { case header, cookie, query }
        let host: String?
        let token: String?
        let tokenSource: TokenSource?
    }

    private func readRequestHeader(_ conn: NWConnection) async throws -> (Data, ParsedRequestHeader?) {
        var buffer = Data()
        let max = 8 * 1024
        while buffer.count < max {
            let chunk = try await receiveMore(conn)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let _ = buffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) {
                break
            }
        }
        guard let headerEnd = buffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
            return (buffer, nil)
        }
        let headerBlock = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerBlock, encoding: .utf8) else {
            return (buffer, nil)
        }
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return (buffer, nil) }
        // Request line: METHOD URI HTTP/x.y
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return (buffer, nil) }
        let uri = parts[1]
        var host: String?
        var bearer: String?
        var cookieToken: String?
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch name {
                case "host":
                    host = value
                case "authorization":
                    let lower = value.lowercased()
                    if lower.hasPrefix("bearer ") {
                        bearer = String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
                    }
                case "cookie":
                    for cookie in value.split(separator: ";") {
                        let s = cookie.trimmingCharacters(in: .whitespaces)
                        if s.hasPrefix("clawdmeter_design_session=") {
                            cookieToken = String(s.dropFirst("clawdmeter_design_session=".count))
                        }
                    }
                default: break
                }
            }
        }
        var queryToken: String?
        if let q = uri.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "token" {
                    queryToken = kv[1]
                }
            }
        }
        let token = bearer ?? cookieToken ?? queryToken
        let source: ParsedRequestHeader.TokenSource?
        if bearer != nil { source = .header }
        else if cookieToken != nil { source = .cookie }
        else if queryToken != nil { source = .query }
        else { source = nil }
        return (buffer, ParsedRequestHeader(host: host, token: token, tokenSource: source))
    }

    private func stripTokenQueryParam(_ headerBytes: Data) -> Data {
        guard let str = String(data: headerBytes, encoding: .utf8) else { return headerBytes }
        guard let firstLineEnd = str.range(of: "\r\n") else { return headerBytes }
        let requestLine = String(str[..<firstLineEnd.lowerBound])
        let rest = String(str[firstLineEnd.lowerBound...])
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return headerBytes }
        let uri = parts[1]
        let qParts = uri.split(separator: "?", maxSplits: 1)
        guard qParts.count == 2 else { return headerBytes }
        let path = String(qParts[0])
        let queryItems = qParts[1].split(separator: "&").filter { !$0.hasPrefix("token=") }
        let newURI: String
        if queryItems.isEmpty {
            newURI = path
        } else {
            newURI = path + "?" + queryItems.joined(separator: "&")
        }
        let newLine = "\(parts[0]) \(newURI) \(parts[2])"
        let rewritten = newLine + rest
        return rewritten.data(using: .utf8) ?? headerBytes
    }

    private func isAcceptableHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        // Strip trailing :port (handling bracketed IPv6).
        let bareHost: String
        if host.hasPrefix("[") {
            // Bracketed IPv6 literal: "[::1]:21732" or "[fd7a:115c::1]"
            guard let closeBracket = host.firstIndex(of: "]") else { return false }
            bareHost = String(host[host.index(after: host.startIndex)..<closeBracket])
        } else if let lastColon = host.lastIndex(of: ":") {
            // IPv4 / bare-hostname:port  — only strip if the remainder
            // after the last colon parses as a port.
            let candidate = String(host[host.index(after: lastColon)...])
            if Int(candidate) != nil {
                bareHost = String(host[..<lastColon])
            } else {
                bareHost = host
            }
        } else {
            bareHost = host
        }
        let lowered = bareHost.lowercased()
        // /review codex P1-6: real DNS-rebind defense. Accept only:
        //   - loopback literals (127.0.0.1, ::1)
        //   - the system's own hostname (with or without .local)
        //   - Tailscale MagicDNS suffixes (.ts.net)
        //   - any *.local mDNS name
        // Reject everything else. A token alone doesn't stop rebind if the
        // attacker can convince a victim browser to send our token to evil.com
        // resolved via cache poisoning.
        if lowered == "127.0.0.1" || lowered == "::1" || lowered == "localhost" {
            return true
        }
        if lowered.hasSuffix(".ts.net") || lowered.hasSuffix(".local") {
            return true
        }
        // System hostname check (case-insensitive). Strip trailing dot.
        let systemHost = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let systemBare = systemHost.split(separator: ".").first.map(String.init) ?? systemHost
        if lowered == systemHost || lowered == systemBare || lowered == "\(systemBare).local" {
            return true
        }
        return false
    }

    // MARK: - Byte pumps

    private func pumpBidirectional(ios: NWConnection, daemon: NWConnection, injectCookieToken: String?) async {
        let cookieInjector = injectCookieToken.map { CookieInjector(token: $0) }
        async let upstream: Void = pump(from: ios, to: daemon, transform: nil)
        async let downstream: Void = pump(from: daemon, to: ios, transform: cookieInjector.map { injector in
            return { data in injector.process(data) }
        })
        _ = await (upstream, downstream)
        ios.cancel()
        daemon.cancel()
    }

    private func pump(from source: NWConnection, to dest: NWConnection, transform: ((Data) -> Data)?) async {
        while true {
            do {
                let chunk = try await receiveMore(source)
                if chunk.isEmpty { return }
                let outbound = transform?(chunk) ?? chunk
                try await send(dest, data: outbound)
            } catch {
                return
            }
        }
    }

    // MARK: - NWConnection helpers

    private func receiveMore(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
                if let error {
                    cc.resume(throwing: error); return
                }
                if isComplete && (content?.isEmpty ?? true) {
                    cc.resume(returning: Data()); return
                }
                cc.resume(returning: content ?? Data())
            }
        }
    }

    private func send(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cc.resume(throwing: error) } else { cc.resume() }
            })
        }
    }

    private func sendError(_ conn: NWConnection, status: Int, message: String) async throws {
        let body = "\(message)\n"
        let response = "HTTP/1.1 \(status) \(message)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try await send(conn, data: response.data(using: .utf8) ?? Data())
    }
}

/// Injects a Set-Cookie header into the first non-1xx response observed
/// on the downstream pump. Skips 100/103 to avoid leaking the cookie
/// into an Expect: 100-continue handshake (v2.1 Codex fix).
private final class CookieInjector {
    private let token: String
    private var injected = false
    private var preludeBuffer = Data()

    init(token: String) {
        self.token = token
    }

    func process(_ data: Data) -> Data {
        if injected { return data }
        preludeBuffer.append(data)
        // Need at least the status line + first header break to decide.
        guard let endOfHeaders = preludeBuffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
            return Data() // hold back until we have a full header block
        }
        guard let str = String(data: preludeBuffer, encoding: .utf8) else {
            // Non-UTF-8 (shouldn't happen for HTTP/1.1 headers) — give up + pass through.
            injected = true
            let drained = preludeBuffer; preludeBuffer = Data(); return drained
        }
        let firstLine = str.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        let status = parts.count >= 2 ? parts[1] : ""
        // /review codex P2-2: 101 Switching Protocols is terminal — the
        // bytes after the header block are WebSocket frames, NOT another
        // HTTP response. Stop processing entirely and pass through verbatim.
        if status == "101" {
            injected = true
            let drained = preludeBuffer; preludeBuffer = Data(); return drained
        }
        let isInformational = status.hasPrefix("1")  // 100, 102, 103 only
        if isInformational {
            // Skip this response — emit it as-is, keep waiting for the final response.
            let headerEnd = endOfHeaders.upperBound
            let informationalPart = preludeBuffer.subdata(in: 0..<headerEnd)
            let remainder = preludeBuffer.subdata(in: headerEnd..<preludeBuffer.count)
            preludeBuffer = Data()
            return informationalPart + process(remainder)
        }
        // Inject Set-Cookie into the header block.
        let cookie = "Set-Cookie: clawdmeter_design_session=\(token); HttpOnly; SameSite=Strict; Path=/\r\n"
        let headerEnd = endOfHeaders.lowerBound
        let header = preludeBuffer.subdata(in: 0..<headerEnd)
        let separator = preludeBuffer.subdata(in: headerEnd..<endOfHeaders.upperBound)
        let body = preludeBuffer.subdata(in: endOfHeaders.upperBound..<preludeBuffer.count)
        injected = true
        let rewritten = header + (cookie.data(using: .utf8) ?? Data()) + separator + body
        preludeBuffer = Data()
        return rewritten
    }
}
