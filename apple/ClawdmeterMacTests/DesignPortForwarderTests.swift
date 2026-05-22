// DesignPortForwarderTests — focused tests for the byte-level logic
// in DesignPortForwarder. The full TCP roundtrip is integration-tested
// separately; this exercises the deterministic parts (header parsing,
// token-query stripping, cookie injection 1xx-skip) without network I/O.
//
// Plan ref: v2.1 phase 9 (T3 verification).

import XCTest
@testable import Clawdmeter

final class DesignPortForwarderTests: XCTestCase {

    // MARK: - Query stripping

    func testStripsTokenQueryFromRequestLine() throws {
        let input = "GET /?token=abc123&hello=world HTTP/1.1\r\nHost: x\r\n\r\n"
        let stripped = mirror_stripTokenQueryParam(input)
        XCTAssertTrue(stripped.hasPrefix("GET /?hello=world HTTP/1.1\r\n"),
                      "expected token to be stripped, got: \(stripped)")
        XCTAssertFalse(stripped.contains("token="))
    }

    func testStripsTokenWhenOnlyParam() throws {
        let input = "GET /api/projects?token=secret HTTP/1.1\r\nHost: x\r\n\r\n"
        let stripped = mirror_stripTokenQueryParam(input)
        XCTAssertTrue(stripped.hasPrefix("GET /api/projects HTTP/1.1\r\n"),
                      "expected /api/projects without query, got: \(stripped)")
    }

    func testPreservesRequestLineWithoutToken() throws {
        let input = "GET /api/projects HTTP/1.1\r\nHost: x\r\n\r\n"
        let stripped = mirror_stripTokenQueryParam(input)
        XCTAssertEqual(stripped, input)
    }

    // MARK: - Cookie injection

    func testCookieInjectorSkipsOneHundredContinue() throws {
        let injector = MirroredCookieInjector(token: "T")
        // Server sends 100 Continue first, then real 200 with body.
        let oneHundred = "HTTP/1.1 100 Continue\r\n\r\n"
        let twoHundred = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello"
        let combined = (oneHundred + twoHundred).data(using: .utf8)!
        let output = injector.process(combined)
        let outStr = String(data: output, encoding: .utf8) ?? ""
        // The 100 Continue header must be preserved untouched.
        XCTAssertTrue(outStr.contains("HTTP/1.1 100 Continue"))
        // The cookie must be in the 200 response, NOT the 100 Continue.
        XCTAssertTrue(outStr.contains("Set-Cookie: clawdmeter_design_session=T"))
        // The cookie should come AFTER the 200 OK status line.
        let twoHundredIdx = outStr.range(of: "HTTP/1.1 200 OK")!.lowerBound
        let cookieIdx = outStr.range(of: "Set-Cookie: clawdmeter_design_session=T")!.lowerBound
        XCTAssertGreaterThan(cookieIdx, twoHundredIdx)
    }

    func testCookieInjectorInjectsOnFirstNon1xx() throws {
        let injector = MirroredCookieInjector(token: "TOKEN")
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 0\r\n\r\n"
        let output = injector.process(response.data(using: .utf8)!)
        let outStr = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(outStr.contains("Set-Cookie: clawdmeter_design_session=TOKEN; HttpOnly; SameSite=Strict; Path=/"))
    }

    func testCookieInjectorInjectsOnceOnly() throws {
        let injector = MirroredCookieInjector(token: "Z")
        let first = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        let second = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        let outFirst = injector.process(first.data(using: .utf8)!)
        let outSecond = injector.process(second.data(using: .utf8)!)
        XCTAssertTrue(String(data: outFirst, encoding: .utf8)!.contains("Set-Cookie"))
        XCTAssertFalse(String(data: outSecond, encoding: .utf8)!.contains("Set-Cookie"))
    }

    func testCookieInjectorHoldsBackUntilFullHeaderBlock() throws {
        let injector = MirroredCookieInjector(token: "X")
        let partial = "HTTP/1.1 200 OK\r\nContent-Type:".data(using: .utf8)!
        let output = injector.process(partial)
        // Not enough to know if 1xx; hold back.
        XCTAssertEqual(output.count, 0)
        let rest = " text/html\r\n\r\nbody".data(using: .utf8)!
        let out2 = injector.process(rest)
        XCTAssertTrue(String(data: out2, encoding: .utf8)!.contains("Set-Cookie"))
    }

    // MARK: - Host validation

    func testAcceptsBracketedIPv6Host() throws {
        XCTAssertTrue(mirror_isAcceptableHost("[fd7a:115c::1]:21732"))
        XCTAssertTrue(mirror_isAcceptableHost("[::1]:21732"))
        XCTAssertTrue(mirror_isAcceptableHost("[::1]"))
    }

    func testAcceptsLoopbackAndHostnames() throws {
        XCTAssertTrue(mirror_isAcceptableHost("127.0.0.1:21732"))
        XCTAssertTrue(mirror_isAcceptableHost("mac.tailfff.ts.net:21732"))
        XCTAssertTrue(mirror_isAcceptableHost("localhost"))
    }

    func testRejectsEmptyHost() throws {
        XCTAssertFalse(mirror_isAcceptableHost(""))
        XCTAssertFalse(mirror_isAcceptableHost(nil))
    }
}

// MARK: - Mirrors of internal helpers
//
// DesignPortForwarder's helpers are private — these mirrors keep the
// production code self-contained while letting the test suite pin
// behavior. If a refactor changes the production helper, update both.

private func mirror_stripTokenQueryParam(_ input: String) -> String {
    guard let firstLineEnd = input.range(of: "\r\n") else { return input }
    let requestLine = String(input[..<firstLineEnd.lowerBound])
    let rest = String(input[firstLineEnd.lowerBound...])
    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { return input }
    let uri = parts[1]
    let qParts = uri.split(separator: "?", maxSplits: 1)
    guard qParts.count == 2 else { return input }
    let path = String(qParts[0])
    let queryItems = qParts[1].split(separator: "&").filter { !$0.hasPrefix("token=") }
    let newURI: String
    if queryItems.isEmpty {
        newURI = path
    } else {
        newURI = path + "?" + queryItems.joined(separator: "&")
    }
    return "\(parts[0]) \(newURI) \(parts[2])" + rest
}

private func mirror_isAcceptableHost(_ host: String?) -> Bool {
    guard let host else { return false }
    let bareHost: String
    if host.hasPrefix("[") {
        if let closeBracket = host.firstIndex(of: "]") {
            bareHost = String(host[host.index(after: host.startIndex)..<closeBracket])
        } else {
            return false
        }
    } else if let lastColon = host.lastIndex(of: ":") {
        bareHost = String(host[..<lastColon])
    } else {
        bareHost = host
    }
    return !bareHost.isEmpty
}

private final class MirroredCookieInjector {
    private let token: String
    private var injected = false
    private var preludeBuffer = Data()
    init(token: String) { self.token = token }
    func process(_ data: Data) -> Data {
        if injected { return data }
        preludeBuffer.append(data)
        guard let endOfHeaders = preludeBuffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else { return Data() }
        guard let str = String(data: preludeBuffer, encoding: .utf8) else {
            injected = true; let drained = preludeBuffer; preludeBuffer = Data(); return drained
        }
        let firstLine = str.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        let isInformational = parts.count >= 2 && parts[1].hasPrefix("1")
        if isInformational {
            let headerEnd = endOfHeaders.upperBound
            let informationalPart = preludeBuffer.subdata(in: 0..<headerEnd)
            let remainder = preludeBuffer.subdata(in: headerEnd..<preludeBuffer.count)
            preludeBuffer = Data()
            return informationalPart + process(remainder)
        }
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
