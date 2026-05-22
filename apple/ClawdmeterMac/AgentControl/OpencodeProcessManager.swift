// OpenCode singleton process manager — D11/D12, P1 architecture
//
// Per the eng-review decision P1: ONE `opencode serve` process for the
// whole app; every Clawdmeter opencode session is a concurrent SSE
// client of that one server. Bounds memory at ~200MB regardless of
// session count and matches OpenCode's native multi-client design.
//
// Responsibilities
//   1. Binary discovery — checks /opt/homebrew/bin/opencode,
//      /usr/local/bin/opencode, then $PATH (via ShellRunner.locateBinary
//      if helpful, but we duplicate the lookup here to keep the manager
//      self-contained).
//   2. Free-port allocation — picks an ephemeral TCP port via NWListener.
//   3. Spawns `opencode serve --port <p> --hostname 127.0.0.1` with a
//      per-launch `OPENCODE_SERVER_PASSWORD` token.
//   4. Health check — polls `GET /` (the Hono server's info endpoint)
//      until a 200 lands or the 10s deadline expires.
//   5. Auth probe — parses `opencode auth list` so the Settings panel
//      can show which providers the user has signed into.
//   6. Process supervisor — restart-on-crash with backoff; clean
//      shutdown on app quit.
//   7. State published via @Published for the Settings → Providers UI.
//
// Failure surfaces — three layers (mirrors AntigravitySidecarManager):
//   1. Binary missing → State.notInstalled with install hint.
//   2. Spawn failed → State.failed(detail). lastError captured.
//   3. Healthcheck timeout → State.failed("server did not become
//      reachable within 10s"). Process killed.
//
// AppRuntime owns the singleton's start/stop; AgentControlServer's
// handlePostSession routes opencode-kind requests through this manager
// instead of the tmux argv path.

import Foundation
import Network
import OSLog

@MainActor
public final class OpencodeProcessManager {

    public static let shared = OpencodeProcessManager()

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "OpencodeProcessManager")

    // MARK: - Published state

    /// Top-level state machine, surfaced via @Published so the Settings
    /// → Providers panel (lands in PR #31) can render it without polling.
    public enum State: Sendable, Equatable {
        case notInstalled
        case stopped
        case starting
        case running(port: Int)
        case failed(detail: String)
    }

    @Published public private(set) var state: State = .stopped

    /// Last error message from a spawn or healthcheck attempt. Surfaced
    /// in the Settings panel + readable in tests.
    @Published public private(set) var lastError: String?

    /// Discovered absolute path to the opencode binary. nil until the
    /// first `ensureRunning()` call probes the system. Surfaced in the
    /// Settings panel as "Installed at <path>".
    @Published public private(set) var binaryPath: String?

    /// Auth list parsed from `opencode auth list`. Each entry maps a
    /// provider name ("anthropic", "openai", "google") to the configured
    /// model id (e.g. "claude-3-5-sonnet"). Empty when no providers are
    /// signed in, nil when auth probe hasn't been run yet.
    @Published public private(set) var authStatus: [String: String]?

    // MARK: - Process state (private)

    /// Underlying NSProcess for `opencode serve`. nil when not running.
    private var serveProcess: Process?

    /// Port the server is bound to. Nil when not running.
    private var serverPort: Int?

    /// Per-launch token passed via OPENCODE_SERVER_PASSWORD. Every
    /// SSE client uses this in the Authorization header so a peer on
    /// the box can't snoop on the server.
    private var serverPassword: String?

    /// Restart counter — bounded to prevent crash loops eating CPU.
    /// Resets on a clean shutdown via `stop()`.
    private var restartCount: Int = 0
    private static let maxRestarts = 5

    /// Supervisor task — monitors serveProcess.isRunning + restarts on
    /// unexpected exit. nil when manager is stopped.
    private var supervisorTask: Task<Void, Never>?

    // MARK: - Public API

    /// Idempotent: discovers the binary, picks a free port, spawns the
    /// server, waits for healthcheck. Returns the running port on
    /// success, nil on failure (state set to .failed or .notInstalled).
    /// Subsequent calls when already-running are no-ops returning the
    /// existing port.
    @discardableResult
    public func ensureRunning() async -> Int? {
        if case .running(let port) = state {
            return port
        }
        state = .starting

        // Step 1: locate the binary.
        guard let binary = locateBinary() else {
            state = .notInstalled
            lastError = nil  // notInstalled is a state, not an error
            logger.info("opencode binary not found on PATH")
            return nil
        }
        binaryPath = binary

        // Step 2: pick a free port.
        let port: Int
        do {
            port = try await pickFreePort()
        } catch {
            let detail = "could not allocate free port: \(error.localizedDescription)"
            lastError = detail
            state = .failed(detail: detail)
            logger.error("\(detail, privacy: .public)")
            return nil
        }

        // Step 3: mint a per-launch password and spawn the server.
        let password = UUID().uuidString
        serverPassword = password

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve", "--port", String(port), "--hostname", "127.0.0.1"]
        var env = ProcessInfo.processInfo.environment
        env["OPENCODE_SERVER_PASSWORD"] = password
        process.environment = env
        // Capture stdout/stderr so a misconfigured spawn surfaces a
        // useful lastError instead of vanishing into the void. The
        // supervisor task drains these pipes on exit.
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            let detail = "opencode serve spawn failed: \(error.localizedDescription)"
            lastError = detail
            state = .failed(detail: detail)
            logger.error("\(detail, privacy: .public)")
            return nil
        }

        serveProcess = process
        serverPort = port
        logger.info("opencode serve pid=\(process.processIdentifier, privacy: .public) port=\(port, privacy: .public)")

        // Step 4: healthcheck loop.
        guard await waitForHealthcheck(port: port) else {
            let detail = "opencode serve did not become reachable within 10s"
            lastError = detail
            state = .failed(detail: detail)
            // Tear down the process — it's not useful.
            process.terminate()
            // Audit P1 fix: reap so we don't leak zombies on every
            // failed-healthcheck retry.
            Task.detached { process.waitUntilExit() }
            serveProcess = nil
            serverPort = nil
            return nil
        }

        // Step 5: kick off the supervisor + best-effort auth probe.
        state = .running(port: port)
        restartCount = 0
        startSupervisor()
        Task { await refreshAuthStatus() }
        return port
    }

    /// Clean shutdown. Used by AppRuntime's deinit + the Settings panel's
    /// "disable" toggle. Safe to call when already stopped.
    public func stop() {
        supervisorTask?.cancel()
        supervisorTask = nil
        if let proc = serveProcess {
            proc.terminate()
            // Audit P1 fix: reap so the OS doesn't hold the PID slot.
            Task.detached { proc.waitUntilExit() }
        }
        serveProcess = nil
        serverPort = nil
        serverPassword = nil
        restartCount = 0
        state = .stopped
        logger.info("opencode serve stopped")
    }

    /// Build a URLRequest for the running server, authorized via the
    /// per-launch password. Returns nil when the server isn't running —
    /// callers fall back to either ensureRunning() or a 503 response.
    public func makeAuthorizedRequest(path: String) -> URLRequest? {
        guard let port = serverPort, let password = serverPassword else { return nil }
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Refresh the auth status by running `opencode auth list`. The
    /// command output is parsed in `parseAuthList`. Cheap (~50ms);
    /// called automatically on start and exposed for the Settings panel
    /// to re-run after the user signs in via the CLI.
    public func refreshAuthStatus() async {
        guard let binary = binaryPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "list"]
        process.environment = ProcessInfo.processInfo.environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()  // discard
        do {
            try process.run()
        } catch {
            logger.info("opencode auth list spawn failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Wait for completion off the main actor.
        await Task.detached {
            process.waitUntilExit()
        }.value
        guard process.terminationStatus == 0 else {
            logger.info("opencode auth list returned \(process.terminationStatus, privacy: .public)")
            return
        }
        let data = stdout.fileHandleForReading.availableData
        let output = String(data: data, encoding: .utf8) ?? ""
        authStatus = Self.parseAuthList(output)
        logger.info("opencode auth status: \(self.authStatus?.count ?? 0, privacy: .public) providers")
    }

    // MARK: - Binary discovery

    /// Discover the opencode binary.
    ///
    /// Precedence (v0.23.0 O4 — PATH first, bundle as fallback):
    ///   1. `/opt/homebrew/bin/opencode`
    ///   2. `/usr/local/bin/opencode`
    ///   3. Explicit `$PATH` walk (mise / asdf / custom installs)
    ///   4. Bundled binary at `Bundle.main.url(forResource:opencode,
    ///      subdirectory:Vendor/opencode)` — the v0.23.0 zero-setup
    ///      install path shipped inside the .app
    ///
    /// Rationale: brew-managed users keep their managed version (no
    /// silent downgrade). The bundle exists for first-launch users who
    /// don't have opencode installed yet. Each candidate is gated by
    /// `isExecutableFile` (A1) so a corrupt bundle falls through to
    /// PATH instead of failing on spawn.
    internal func locateBinary() -> String? {
        let fixedCandidates = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]
        for path in fixedCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = String(dir) + "/opencode"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        if let bundled = Bundle.main.url(
            forResource: "opencode",
            withExtension: nil,
            subdirectory: "Vendor/opencode"
        ), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        // Dev-iteration fallback: when running from Xcode debug Bundle.main
        // points at DerivedData. Walk up to find the source tree path.
        let here = URL(fileURLWithPath: #file)
        var dir = here.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("ClawdmeterMac/Resources/Vendor/opencode/opencode")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Re-run binary discovery + auth-status probe, restart `opencode
    /// serve` if anything changed. Called from OpencodeProviderRow after
    /// Activate AND from OpencodeSetupSheet after every auth flow.
    ///
    /// Restart triggers (A3 + O5):
    ///   - binary path changed (brew upgrade / first bundle discovery)
    ///   - auth provider set changed (opencode reads creds at startup,
    ///     so serve started pre-auth won't see post-auth creds)
    public func reprobe() async {
        let priorBinary = binaryPath
        let priorAuthKeys = Set(authStatus?.keys.map { $0 } ?? [])

        binaryPath = locateBinary()
        let nextBinary = binaryPath

        await refreshAuthStatus()
        let nextAuthKeys = Set(authStatus?.keys.map { $0 } ?? [])

        let binaryChanged = (priorBinary != nextBinary) && (priorBinary != nil || nextBinary != nil)
        let authChanged = priorAuthKeys != nextAuthKeys
        let isRunning: Bool
        if case .running = state { isRunning = true } else { isRunning = false }

        if isRunning && (binaryChanged || authChanged) {
            let reason: String
            if binaryChanged {
                reason = "binary changed (\(priorBinary ?? "—") → \(nextBinary ?? "—"))"
            } else {
                reason = "auth changed"
            }
            logger.info("reprobe: restarting opencode serve — \(reason, privacy: .public)")
            stop()
            _ = await ensureRunning()
        } else if !isRunning && nextBinary != nil && !nextAuthKeys.isEmpty {
            logger.info("reprobe: cold-starting opencode serve")
            _ = await ensureRunning()
        }
    }

    // MARK: - Port allocation

    private enum PortError: Error {
        case allocationFailed
    }

    /// Pick a free ephemeral port. We bind a transient NWListener to
    /// port 0 (kernel picks), read the assigned port, then immediately
    /// cancel the listener. There's a TOCTOU race between us releasing
    /// the port and opencode binding it, but in practice the window is
    /// microseconds and `opencode serve` would simply error out fast,
    /// allowing the supervisor to retry on a new port.
    private func pickFreePort() async throws -> Int {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            throw PortError.allocationFailed
        }
        listener.start(queue: .global())
        // Wait for the listener to bind (port becomes non-nil).
        for _ in 0..<100 {
            if let port = listener.port?.rawValue {
                listener.cancel()
                return Int(port)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        listener.cancel()
        throw PortError.allocationFailed
    }

    // MARK: - Healthcheck

    /// Poll `GET /` until we get any 2xx/4xx (the server is responsive
    /// — even auth rejection counts as "alive"), or the 10s deadline
    /// expires. Returns true on success.
    private func waitForHealthcheck(port: Int) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let deadline = Date().addingTimeInterval(10)
        let session = URLSession(configuration: .ephemeral)
        while Date() < deadline {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1
            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    return true
                }
            } catch {
                // Connection refused while the server boots — keep polling.
            }
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }
        return false
    }

    // MARK: - Supervisor (restart-on-crash)

    private func startSupervisor() {
        supervisorTask?.cancel()
        supervisorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s tick
                guard let self else { return }
                let stillRunning = await MainActor.run { self.serveProcess?.isRunning ?? false }
                guard !stillRunning else { continue }
                // Process exited. Decide whether to restart.
                await self.handleUnexpectedExit()
                return  // either restarted (a fresh supervisor took over) or gave up
            }
        }
    }

    @MainActor
    private func handleUnexpectedExit() async {
        // Audit P1 fix: reset state to .stopped BEFORE calling
        // ensureRunning(). Previously this method left `state` at
        // .running, so ensureRunning() saw the cached running-state
        // and returned early without spawning a new `opencode serve` —
        // crash recovery never actually recovered.
        serveProcess = nil
        serverPort = nil
        serverPassword = nil
        state = .stopped
        restartCount += 1
        if restartCount > Self.maxRestarts {
            let detail = "opencode serve crashed \(restartCount) times in a row; giving up"
            lastError = detail
            state = .failed(detail: detail)
            logger.error("\(detail, privacy: .public)")
            return
        }
        logger.warning("opencode serve exited unexpectedly; restart attempt \(self.restartCount)/\(Self.maxRestarts)")
        // Exponential-ish backoff: 1s, 2s, 4s, 8s, 16s.
        let backoffNs = UInt64(1_000_000_000) * UInt64(1 << min(restartCount, 5))
        try? await Task.sleep(nanoseconds: backoffNs)
        _ = await ensureRunning()
    }

    // MARK: - Auth list parsing (testable)

    /// Parse the output of `opencode auth list`. The CLI prints one
    /// provider per line in a "provider: model" format (e.g.
    /// "anthropic: claude-3-5-sonnet"). The parser is lenient — blank
    /// lines, headers, and decorative separators are skipped.
    /// Internal so tests can exercise it without spawning the binary.
    internal static func parseAuthList(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  !trimmed.hasPrefix("─"),
                  trimmed.contains(":") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            // Filter obvious headers ("Provider", "Model", etc).
            let key = parts[0].lowercased()
            if key == "provider" || key == "name" { continue }
            result[parts[0]] = parts[1]
        }
        return result
    }
}
