import Foundation

// MARK: - HTTP request parsing helpers

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]  // lower-cased header names
    let body: Data
}

/// Streaming HTTP/1.1 request buffer. Accumulates bytes until a complete
/// request (headers + Content-Length body) is available, then returns it
/// from `tryParse()`. Reuses the same buffer across multiple `receive`
/// callbacks until parse succeeds.
///
/// @unchecked Sendable: this buffer is only ever mutated from within a
/// single NWConnection.receive callback chain; the callback shape isn't
/// quite Sendable-checkable but the runtime invariant holds.
final class HTTPRequestBuffer: @unchecked Sendable {
    enum ParseError: Error {
        case badRequest
        case payloadTooLarge
    }

    private static let maxHeaderBytes = 32 * 1024
    /// Raised from 1MB → 50MB in v0.4.8 so iOS can POST raw image
    /// bytes to `/sessions/:id/attachments`. Tailscale ACL + bearer
    /// auth still gate who can reach the daemon, so the worst case is
    /// a paired peer wasting Mac memory on one malformed upload — and
    /// per-endpoint handlers still enforce their own caps (the send
    /// path stays at 1MB, the artifact endpoint at 50MB, attachment
    /// uploads at 50MB).
    private static let maxBodyBytes = 50 * 1024 * 1024

    var data = Data()

    func append(_ chunk: Data) {
        data.append(chunk)
    }

    /// Attempt to extract a complete HTTP request. Returns nil if more bytes
    /// are needed.
    func tryParse() throws -> HTTPRequest? {
        guard data.count <= Self.maxHeaderBytes + Self.maxBodyBytes else {
            throw ParseError.payloadTooLarge
        }
        // Find headers/body boundary.
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > Self.maxHeaderBytes { throw ParseError.payloadTooLarge }
            return nil
        }
        guard headerEndRange.lowerBound <= Self.maxHeaderBytes else {
            throw ParseError.payloadTooLarge
        }
        let headerBytes = data[..<headerEndRange.lowerBound]
        let headerText = String(decoding: headerBytes, as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { throw ParseError.badRequest }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { throw ParseError.badRequest }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLengthRaw = headers["content-length"] ?? "0"
        guard let contentLength = Int(contentLengthRaw),
              contentLength >= 0 else {
            throw ParseError.badRequest
        }
        guard contentLength <= Self.maxBodyBytes else {
            throw ParseError.payloadTooLarge
        }
        let bodyStart = headerEndRange.upperBound
        let availableBody = data.count - bodyStart
        if availableBody < contentLength {
            return nil  // need more bytes
        }

        let body = data[bodyStart..<(bodyStart + contentLength)]
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }
}
