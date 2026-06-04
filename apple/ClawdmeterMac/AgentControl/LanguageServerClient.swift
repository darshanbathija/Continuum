// Talks to Antigravity 2's `language_server` Go binary running inside the
// Electron app. Phase 0 (commit 8a10ec3/f4dd0c0) + Phase 0.5 (commit 6fe759e)
// proved the real shape, which is materially different from v0.7's
// log-file-scrape design:
//
//   1. Antigravity.app launches `language_server` with two random ports
//      (HTTPS/gRPC + HTTP) and a per-launch CSRF token on argv:
//        --csrf_token <uuid> --https_server_port 0
//      Both port numbers are in the LS process's lsof output, NOT in any
//      log file. The HTTP port is the one agentapi uses.
//
//   2. agentapi is a thin CLI client that talks HTTP to the same LS
//      process. Invoked as:
//        `language_server agentapi <command> [args]`
//      with three env vars (D5/Phase 0):
//        ANTIGRAVITY_LS_ADDRESS=http://127.0.0.1:<port>
//        ANTIGRAVITY_CSRF_TOKEN=<uuid>
//        ANTIGRAVITY_PROJECT_ID=<project-uuid>
//      Returns JSON on stdout, fires + forgets. Agent work happens
//      server-side and the actual turn content gets persisted to SQLite
//      WAL DBs under ~/.gemini/antigravity/conversations/<id>.{db,db-wal}.
//
//   3. The Phase 0 plan called for re-discovering port + CSRF on every
//      call (D13: ~50ms × N calls/min/session). Implementing that here
//      via pgrep + ps + lsof rather than caching, per A3 lock.
//
// v0.7 callers that used `discoverLive()`/`currentModel()` keep working;
// new agentapi methods are additive.
//
// This file is mac-only — Antigravity.app, pgrep, lsof are all macOS-only
// surfaces.

import Foundation
import OSLog
import ClawdmeterShared

/// Result of `discoverLive()`. Either we found a live server, or we
/// didn't — the latter is a first-class state, NOT an error.
public enum LanguageServerProbe: Equatable, Sendable {
    case live(LiveLanguageServer)
    case notRunning
}

/// One live language_server instance. Port + CSRF together gate every
/// request. `httpsPort` is the gRPC port (still useful for v0.7
/// `currentModel()` via HTTPS); `httpPort` is the agentapi port.
public struct LiveLanguageServer: Equatable, Sendable {
    public let pid: Int
    public let csrfToken: String
    /// HTTP port for agentapi RPC. ~50ms-per-call discovery means we
    /// recompute on every call, so a stale value here only persists for
    /// the lifetime of one single agentapi invocation.
    public let httpPort: Int
    /// HTTPS port (gRPC + v0.7 `/v1/current-model`). Optional because
    /// some discovery paths may only resolve the HTTP port.
    public let httpsPort: Int?

    public var httpBaseURL: URL { URL(string: "http://127.0.0.1:\(httpPort)")! }
    public var httpsBaseURL: URL? {
        guard let p = httpsPort else { return nil }
        return URL(string: "https://127.0.0.1:\(p)")
    }

    public init(pid: Int, csrfToken: String, httpPort: Int, httpsPort: Int? = nil) {
        self.pid = pid
        self.csrfToken = csrfToken
        self.httpPort = httpPort
        self.httpsPort = httpsPort
    }
}

/// Discovery client for the Antigravity 2 `language_server`. Now used ONLY by the
/// usage/metering gauge (discoverLive + currentModel); the agentapi drive RPCs
/// (newConversation/sendMessage/…) + their error/model-tier enums were removed
/// once Gemini moved to the headless `agy` CLI.
/// Per D13: always re-discover port+CSRF before each call; ~50ms per
/// invocation accepted for correctness over caching.
public final class LanguageServerClient: NSObject {

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "LanguageServerClient")

    /// Path to the `language_server` Mach-O binary. Resolved via
    /// `AntigravityInstall.locateLanguageServer(in:)` lazily on each
    /// access. Nil only when Antigravity isn't installed; methods that
    /// need it throw `.binaryNotFound`.
    ///
    /// History note: a prior v0.23.5 attempt hypothesized an init-time
    /// race against bundle-content readability and switched this from
    /// a `let` to a lazy computed `var`. That diagnosis was wrong —
    /// the real Chat-V2 Gemini-500 was an `agentapi` response-envelope
    /// mismatch surfacing as `.malformedResponse` (NSError code 3),
    /// which Swift's payload-first case-ordering for Error→NSError made
    /// look like `.binaryNotFound` (also visually labelled "error 3").
    /// The lazy form is kept because re-probing 4 paths on each call is
    /// cheap (~50µs of stat() syscalls vs the agentapi RPC dominating)
    /// and lets a transient nil heal on the next attempt.
    public var languageServerURL: URL? {
        if let override = languageServerURLOverride {
            return override
        }
        #if os(macOS)
        let appBundle = URL(fileURLWithPath: "/Applications/Antigravity.app", isDirectory: true)
        return AntigravityInstall.locateLanguageServer(in: appBundle)
        #else
        return nil
        #endif
    }
    private let languageServerURLOverride: URL?

    /// Override for tests. Production wraps real `pgrep`, `ps`, `lsof`.
    private let processProbe: ProcessProbe

    public init(
        languageServerURL: URL? = nil,
        processProbe: ProcessProbe = .systemProbe
    ) {
        self.languageServerURLOverride = languageServerURL
        self.processProbe = processProbe
        super.init()
    }

    // MARK: - Discovery (D5 rewrite — pgrep + ps + lsof per Phase 0)

    /// Walks the live process table looking for Antigravity.app's
    /// `language_server`, parses argv for `--csrf_token`, parses lsof
    /// output for the listening HTTP port.
    ///
    /// Returns `.notRunning` when Antigravity isn't running (no
    /// matching pgrep hit) or any of the parse steps failed.
    public func discoverLive() -> LanguageServerProbe {
        guard let pid = processProbe.findAntigravityLSProcessID() else {
            return .notRunning
        }
        guard let argv = processProbe.argvForPID(pid),
              let csrf = parseCSRFToken(fromArgv: argv) else {
            logger.debug("discoverLive: pgrep hit PID=\(pid) but argv parse failed")
            return .notRunning
        }
        let ports = processProbe.listeningTCPPorts(pid)
        guard !ports.isEmpty else {
            logger.debug("discoverLive: PID=\(pid) holds no listening TCP ports")
            return .notRunning
        }
        // Phase 0: language_server listens on TWO consecutive ports —
        // the lower for HTTPS/gRPC, the higher for HTTP. Pick the
        // higher as the agentapi HTTP port; expose both for callers
        // that need gRPC.
        let sorted = ports.sorted()
        let httpsPort = sorted.first
        let httpPort = sorted.last ?? sorted[0]
        return .live(LiveLanguageServer(
            pid: pid,
            csrfToken: csrf,
            httpPort: httpPort,
            httpsPort: (sorted.count >= 2) ? httpsPort : nil
        ))
    }

    /// Extracts `--csrf_token <uuid>` (or `--csrf_token=<uuid>`) from
    /// the argv array of a `language_server` process. Returns nil when
    /// the flag is missing or empty.
    func parseCSRFToken(fromArgv argv: [String]) -> String? {
        var iter = argv.makeIterator()
        while let arg = iter.next() {
            if arg == "--csrf_token" {
                if let value = iter.next(), !value.isEmpty { return value }
            } else if arg.hasPrefix("--csrf_token=") {
                let value = String(arg.dropFirst("--csrf_token=".count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    // MARK: - v0.7 callers: keep currentModel() working

    private lazy var urlSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }()

    /// v0.7: fetch currently-selected model via HTTPS `/v1/current-model`.
    /// Phase 0 didn't reprobe this endpoint shape; if it has changed
    /// the existing tolerant decoder (bare-string OR `{"model": "..."}`)
    /// will surface nil and the dashboard subtitle degrades to a
    /// static label. No regression in v0.8 behavior.
    public func currentModel(probe: LanguageServerProbe? = nil) async -> String? {
        let live: LiveLanguageServer
        switch probe ?? discoverLive() {
        case .live(let l): live = l
        case .notRunning: return nil
        }
        guard let baseURL = live.httpsBaseURL else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/current-model"))
        request.setValue(live.csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        request.timeoutInterval = 5
        do {
            let (data, _) = try await urlSession.data(for: request)
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                if s.hasPrefix("{") {
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return obj["model"] as? String
                    }
                }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.debug("currentModel request failed: \(error.localizedDescription)")
        }
        return nil
    }
}

// MARK: - URLSessionDelegate — loopback-scoped TLS trust (kept from v0.7)

extension LanguageServerClient: URLSessionDelegate {
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
        if loopbackHosts.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - ProcessProbe — pgrep / ps / lsof wrapping for tests

/// Injection seam for the three subprocess probes used by discoverLive.
/// Tests provide a `ProcessProbe(...)` with stub closures; production
/// uses `.systemProbe` which shells out to real binaries.
public struct ProcessProbe: Sendable {
    public let findAntigravityLSProcessID: @Sendable () -> Int?
    public let argvForPID: @Sendable (Int) -> [String]?
    public let listeningTCPPorts: @Sendable (Int) -> [Int]

    public init(
        findAntigravityLSProcessID: @escaping @Sendable () -> Int?,
        argvForPID: @escaping @Sendable (Int) -> [String]?,
        listeningTCPPorts: @escaping @Sendable (Int) -> [Int]
    ) {
        self.findAntigravityLSProcessID = findAntigravityLSProcessID
        self.argvForPID = argvForPID
        self.listeningTCPPorts = listeningTCPPorts
    }

    // The wrapping `@Sendable { … }` closures exist purely to satisfy the
    // field type — ProcessProbeSystem's static funcs are pure subprocess
    // wrappers with no captured state, so the data-race warning the
    // compiler emits without the explicit `@Sendable` annotation is a
    // false positive.
    public static let systemProbe = ProcessProbe(
        findAntigravityLSProcessID: { @Sendable in ProcessProbeSystem.findAntigravityLSProcessID() },
        argvForPID: { @Sendable pid in ProcessProbeSystem.argvForPID(pid) },
        listeningTCPPorts: { @Sendable pid in ProcessProbeSystem.listeningTCPPorts(pid) }
    )
}

/// Real-system implementation of `ProcessProbe`. Shells out to pgrep,
/// ps, lsof. Mac-only.
enum ProcessProbeSystem {

    /// `pgrep -f "Antigravity.app/Contents/Resources/bin/language_server"`
    /// (or any candidate path that AntigravityInstall.locateLanguageServer
    /// would have matched). Returns the first PID. Antigravity.app
    /// usually only has one LS at a time.
    static func findAntigravityLSProcessID() -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "Antigravity.app/.*language_server"]
        let pipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            if let pid = Int(line.trimmingCharacters(in: .whitespaces)) {
                return pid
            }
        }
        return nil
    }

    /// `ps -p <pid> -o command=` returns the full argv as one
    /// whitespace-separated line. Naive split is sufficient for the
    /// `--csrf_token <uuid>` token we extract.
    static func argvForPID(_ pid: Int) -> [String]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -p <pid>` lists all TCP ports the
    /// PID is listening on. Output column 9 is `NAME` like
    /// `127.0.0.1:53824`. Returns the port half.
    static func listeningTCPPorts(_ pid: Int) -> [Int] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-p", String(pid)]
        let pipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe
        do { try task.run() } catch { return [] }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8) ?? ""

        var ports: Set<Int> = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("COMMAND") { continue }   // header
            // Parse the last `127.0.0.1:<N>` token in the line.
            if let colonRange = line.range(of: ":", options: .backwards) {
                let after = line[colonRange.upperBound...]
                let digits = after.prefix { $0.isNumber }
                if let p = Int(digits) { ports.insert(p) }
            }
        }
        return Array(ports)
    }
}
