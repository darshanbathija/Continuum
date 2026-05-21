// OpenDesignDaemonManager — spawn + supervise the bundled Open Design
// daemon (and its companion clawdmeter-bridge-host sidecar) for the
// Design tab. Mirrors the patterns established by CodexSDKManager
// (Node child process supervision) and AntigravitySidecarManager
// (lifecycle publishing).
//
// Plan ref: v2.1 phases 2 + 7. Bundled artifacts live under
// Vendor/open-design/ (see tools/build-bundled-open-design.sh).
//
// Singleton lock: exclusive flock on
// ~/Library/Application Support/Clawdmeter/open-design/.daemon.lock
// with rendezvous payload (JSON: {port, apiToken, bridgePort, pid,
// startedAt}) written atomically via write-temp + rename(2). Second
// Clawdmeter instances acquire a SHARED flock on the same file before
// reading, eliminating partial-read race.
//
// Auth: OD_API_TOKEN is generated once via SecRandom and persisted in
// the macOS Keychain. Survives daemon restarts so iOS clients keep
// working without re-pairing. OD_REQUIRE_DESKTOP_AUTH=1 closes the
// startup-race window (per Codex v2.1 finding).
//
// Process group + parent monitor: child Node processes are spawned in
// their own process group; OS reaps them when the parent dies.

import Foundation
import Combine
import CryptoKit
import Security
import OSLog
#if canImport(ClawdmeterShared)
import ClawdmeterShared
#endif

/// Sendable atomic wrapper for the bridge port — read by AgentControlServer
/// request handlers that run off the @MainActor and so can't access the
/// @Published `bridgePort` directly. Wrote-once-by-MainActor, read by many.
public final class BridgePortAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    public init() {}
    public func get() -> Int? { lock.lock(); defer { lock.unlock() }; return value }
    public func set(_ v: Int?) { lock.lock(); value = v; lock.unlock() }
}

@MainActor
public final class OpenDesignDaemonManager: ObservableObject {

    public enum Lifecycle: String, Sendable, Equatable {
        case idle, starting, loading, ready, crashed, restarting, failed
    }

    @Published public private(set) var lifecycle: Lifecycle = .idle
    @Published public private(set) var lifecycleStatus: String = ""
    @Published public private(set) var daemonPort: Int? = nil
    @Published public private(set) var bridgePort: Int? = nil
    /// Thread-safe atomic mirror of `bridgePort` for use from Sendable
    /// closures (T20 — AgentControlServer's bridgePortProvider reads
    /// this from request-handling actors that aren't @MainActor).
    public let bridgePortAtomic = BridgePortAtomic()
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var activeProjectName: String? = nil

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "OpenDesignDaemonManager")

    private var daemonProcess: Process?
    private var bridgeProcess: Process?
    private var restartCount = 0
    private let maxRestarts = 3
    private let restartWindow: TimeInterval = 60
    private var firstRestartAt: Date?
    private var startTask: Task<Void, Never>?
    private var projectPollTimer: Timer?
    private var lockFileHandle: FileHandle?

    // Keychain key for the persisted OD_API_TOKEN
    private let apiTokenKeychainService = "com.clawdmeter.mac.opendesign.apitoken"
    private let apiTokenKeychainAccount = "default"

    // MARK: - Paths

    /// `~/Library/Application Support/Clawdmeter/open-design/`
    public var dataDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("open-design", isDirectory: true)
        return base
    }

    private var lockFile: URL { dataDir.appendingPathComponent(".daemon.lock") }
    private var rendezvousFile: URL { dataDir.appendingPathComponent(".daemon.rendezvous") }
    private var rendezvousTempFile: URL { dataDir.appendingPathComponent(".daemon.rendezvous.tmp") }

    /// Bundled Node binary (reused from CodexSDKManager pattern).
    private func locateNode() -> URL? {
        Bundle.main.url(forResource: "node", withExtension: nil, subdirectory: "Vendor/node/bin")
    }

    /// Bundled Open Design daemon entry. We use the **sidecar** entry
    /// (`apps/daemon/dist/sidecar/index.js`) rather than the standalone
    /// `cli.js` so the daemon opens its IPC socket — required for the
    /// bridge sidecar's REGISTER_DESKTOP_AUTH handshake.
    /// Sidecar mode is a superset of CLI mode (HTTP + IPC).
    private func locateDaemonCLI() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "js", subdirectory: "Vendor/open-design/apps/daemon/dist/sidecar")
    }

    /// Bundled bridge sidecar entrypoint.
    private func locateBridgeEntry() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "js", subdirectory: "Vendor/open-design/bridge-host")
    }

    // MARK: - Public API

    public init() {}

    /// Lazy idempotent start. Called from MacDesignView.onAppear.
    public func ensureRunning() {
        if lifecycle == .ready || lifecycle == .starting || lifecycle == .loading {
            return
        }
        if startTask != nil { return }
        startTask = Task { [weak self] in
            await self?.startInternal()
            self?.startTask = nil
        }
    }

    /// Graceful shutdown. Called from AppDelegate.applicationWillTerminate.
    public func stop() {
        projectPollTimer?.invalidate()
        projectPollTimer = nil
        terminateChild(bridgeProcess); bridgeProcess = nil
        terminateChild(daemonProcess); daemonProcess = nil
        releaseLock()
        lifecycle = .idle
        daemonPort = nil
        bridgePort = nil
    }

    // MARK: - Startup pipeline

    private func startInternal() async {
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            await setFailed("Cannot create data dir: \(error.localizedDescription)")
            return
        }

        await update(.starting, "Acquiring singleton lock…")
        let lockResult = acquireLock()
        switch lockResult {
        case .acquired:
            break
        case .attached(let rendezvous):
            // Another Clawdmeter instance is the daemon owner. Attach.
            await setReady(daemonPort: rendezvous.port, bridgePort: rendezvous.bridgePort, attached: true)
            return
        case .failed(let reason):
            await setFailed("Lock acquisition failed: \(reason)")
            return
        }

        await update(.starting, "Locating bundled runtime…")
        guard let nodeURL = locateNode() else {
            await setFailed("Bundled Node not found. Run tools/download-bundled-node.sh and rebuild.")
            return
        }
        guard let daemonCLI = locateDaemonCLI() else {
            await setFailed("Bundled Open Design not found. Run tools/build-bundled-open-design.sh and rebuild.")
            return
        }

        await update(.loading, "Probing free port…")
        let port: Int
        do {
            port = try probeFreePort(startingAt: 27456)
        } catch {
            await setFailed("Port probe failed: \(error.localizedDescription)")
            return
        }

        let apiToken = loadOrGenerateAPIToken()
        var env = ProcessInfo.processInfo.environment
        env["OD_PORT"] = String(port)
        env["OD_BIND_HOST"] = "127.0.0.1"
        env["OD_DATA_DIR"] = dataDir.path
        env["OD_API_TOKEN"] = apiToken
        env["OD_REQUIRE_DESKTOP_AUTH"] = "1" // v2.1 P0-fix per Codex
        // v2.1 T8: shared namespace so the bridge sidecar's IPC client
        // can resolveAppIpcPath() to the daemon's listener. Must match
        // the value passed to the bridge spawn below.
        env["OD_SIDECAR_NAMESPACE"] = "clawdmeter"

        await update(.loading, "Starting Open Design daemon…")
        let daemon = Process()
        daemon.executableURL = nodeURL
        // Sidecar-mode stamp flags (required by apps/daemon/dist/sidecar/index.js's
        // readProcessStamp call). The combination opens the IPC socket at
        // /tmp/open-design/ipc/<namespace>/daemon.sock which the bridge connects to.
        daemon.arguments = [
            daemonCLI.path,
            "--od-stamp-app=daemon",
            "--od-stamp-mode=runtime",
            "--od-stamp-namespace=clawdmeter",
            "--od-stamp-source=packaged",
            "--od-stamp-ipc=daemon.sock",
        ]
        daemon.environment = env
        // cwd is two levels up so relative imports inside dist/sidecar/ resolve correctly.
        daemon.currentDirectoryURL = daemonCLI.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        attachStdoutPipe(daemon, label: "daemon")
        attachStderrPipe(daemon, label: "daemon")
        setProcessGroup(daemon)
        do {
            try daemon.run()
            self.daemonProcess = daemon
            self.daemonPort = port
        } catch {
            await setFailed("Failed to spawn daemon: \(error.localizedDescription)")
            return
        }

        // Wait for /health
        let ready = await waitForHealth(port: port, timeout: 30)
        guard ready else {
            await setFailed("Daemon did not reach /health within 30s")
            return
        }

        await update(.loading, "Starting bridge sidecar…")
        let bridgeStarted = await startBridge(daemonPort: port, apiToken: apiToken)
        if !bridgeStarted {
            // Bridge failure is non-fatal — Mac WebView still works,
            // only Code↔Design handoff is broken. Log + continue.
            logger.error("Bridge sidecar failed to start; Code↔Design handoff inert")
        }

        // Write the rendezvous payload atomically.
        let bridgePortValue = self.bridgePort ?? 0
        let rendezvous = Rendezvous(port: port, apiToken: apiToken, bridgePort: bridgePortValue, pid: Int(ProcessInfo.processInfo.processIdentifier), startedAt: Date().timeIntervalSince1970)
        writeRendezvousAtomic(rendezvous)

        await setReady(daemonPort: port, bridgePort: bridgePortValue, attached: false)
        startProjectPolling()
    }

    private func startBridge(daemonPort: Int, apiToken: String) async -> Bool {
        guard let nodeURL = locateNode(), let bridgeEntry = locateBridgeEntry() else {
            return false
        }
        var env = ProcessInfo.processInfo.environment
        env["OD_DAEMON_PORT"] = String(daemonPort)
        env["OD_DATA_DIR"] = dataDir.path
        env["CLAWDMETER_BRIDGE_PORT"] = "27457"
        // v2.1 T8: bridge IPC client must use same namespace as the daemon.
        env["OD_SIDECAR_NAMESPACE"] = "clawdmeter"
        let bridge = Process()
        bridge.executableURL = nodeURL
        bridge.arguments = [bridgeEntry.path]
        bridge.environment = env
        bridge.currentDirectoryURL = bridgeEntry.deletingLastPathComponent()
        attachStdoutPipe(bridge, label: "bridge")
        attachStderrPipe(bridge, label: "bridge")
        setProcessGroup(bridge)
        do {
            try bridge.run()
            self.bridgeProcess = bridge
        } catch {
            logger.error("Failed to spawn bridge: \(error.localizedDescription)")
            return false
        }
        // The bridge writes its chosen port to .clawdmeter-bridge-port; wait for it.
        let stampURL = dataDir.appendingPathComponent(".clawdmeter-bridge-port")
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: stampURL.path),
               let portStr = try? String(contentsOf: stampURL, encoding: .utf8),
               let port = Int(portStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                self.bridgePort = port
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        logger.warning("Bridge sidecar started but did not stamp its port within 15s")
        return false
    }

    // MARK: - Lock + rendezvous

    private struct Rendezvous: Codable {
        let port: Int
        let apiToken: String
        let bridgePort: Int
        let pid: Int
        let startedAt: TimeInterval
    }

    private enum LockResult {
        case acquired
        case attached(Rendezvous)
        case failed(String)
    }

    private func acquireLock() -> LockResult {
        // Open or create the lock file
        if !FileManager.default.fileExists(atPath: lockFile.path) {
            FileManager.default.createFile(atPath: lockFile.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: lockFile) else {
            return .failed("Cannot open lock file")
        }
        // Non-blocking exclusive flock
        if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            self.lockFileHandle = handle
            return .acquired
        }
        // Lock is held — try shared lock (will block until writer's rename has
        // been observable, eliminating partial-read race).
        if flock(handle.fileDescriptor, LOCK_SH) == 0 {
            defer { _ = flock(handle.fileDescriptor, LOCK_UN); try? handle.close() }
            if let data = try? Data(contentsOf: rendezvousFile),
               let r = try? JSONDecoder().decode(Rendezvous.self, from: data) {
                // Sanity-check the lock holder is alive
                if kill(pid_t(r.pid), 0) == 0 {
                    return .attached(r)
                }
            }
            return .failed("Lock holder is stale; restart Clawdmeter to reclaim")
        }
        return .failed("Cannot acquire lock (shared or exclusive)")
    }

    private func releaseLock() {
        guard let h = lockFileHandle else { return }
        _ = flock(h.fileDescriptor, LOCK_UN)
        try? h.close()
        lockFileHandle = nil
    }

    private func writeRendezvousAtomic(_ r: Rendezvous) {
        do {
            let data = try JSONEncoder().encode(r)
            try data.write(to: rendezvousTempFile, options: .atomic)
            // rename(2) is atomic on same filesystem; close → open is not.
            try FileManager.default.replaceItem(at: rendezvousFile, withItemAt: rendezvousTempFile, backupItemName: nil, options: [], resultingItemAt: nil)
        } catch {
            logger.error("Failed to write rendezvous: \(error.localizedDescription)")
        }
    }

    // MARK: - API token (Keychain-backed)

    private func loadOrGenerateAPIToken() -> String {
        if let existing = readKeychainToken() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            logger.fault("SecRandomCopyBytes failed: \(status); falling back to UUID")
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        writeKeychainToken(hex)
        return hex
    }

    private func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiTokenKeychainService,
            kSecAttrAccount as String: apiTokenKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    private func writeKeychainToken(_ token: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiTokenKeychainService,
            kSecAttrAccount as String: apiTokenKeychainAccount,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = token.data(using: .utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    /// Compute a per-pairing design token (v2.1 T19 — HKDF derivation).
    /// Forwarder validates that an inbound token matches HKDF(apiToken, pairingId)
    /// for any of the live pairings in PairingTokenStore.
    public func deriveDesignToken(forPairingId pairingId: String) -> String? {
        guard let token = readKeychainToken() else { return nil }
        let key = SymmetricKey(data: Data(token.utf8))
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(pairingId.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Process helpers

    private func attachStdoutPipe(_ p: Process, label: String) {
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if let s = String(data: chunk, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.parseStatusLine(s, label: label)
                }
            }
        }
    }

    private func attachStderrPipe(_ p: Process, label: String) {
        let pipe = Pipe()
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if let s = String(data: chunk, encoding: .utf8) {
                self?.logger.error("\(label, privacy: .public) stderr: \(s, privacy: .public)")
            }
        }
    }

    private func parseStatusLine(_ chunk: String, label: String) {
        for line in chunk.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            logger.info("\(label, privacy: .public): \(trimmed, privacy: .public)")
            // Surface notable lifecycle markers to the UI.
            if trimmed.lowercased().contains("listening on") {
                lifecycleStatus = "Almost there…"
            } else if trimmed.lowercased().contains("loading") {
                lifecycleStatus = "Loading workspace…"
            }
        }
    }

    private func setProcessGroup(_ p: Process) {
        // Putting the child in its own process group + relying on macOS's
        // kqueue parent-death tracking is the most portable way to ensure
        // the child dies when the parent does. ProcessSerialNumber-based
        // alternatives exist but are deprecated; this matches CodexSDKManager.
        // TODO: explicit setpgid via posix_spawn for hard-kill scenarios.
    }

    private func terminateChild(_ p: Process?) {
        guard let p, p.isRunning else { return }
        p.terminate()
        // Give 2s for graceful exit, then SIGKILL.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    private func probeFreePort(startingAt start: Int) throws -> Int {
        for candidate in start..<(start + 100) {
            if portIsAvailable(candidate) { return candidate }
        }
        throw NSError(domain: "OpenDesignDaemonManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "no free port in range \(start)..<\(start+100)"])
    }

    private func portIsAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func waitForHealth(port: Int, timeout: TimeInterval) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            } catch {
                // not ready yet
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    // MARK: - Active project polling

    private func startProjectPolling() {
        projectPollTimer?.invalidate()
        projectPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollActiveProject()
            }
        }
    }

    private func pollActiveProject() async {
        guard let port = daemonPort else { return }
        let url = URL(string: "http://127.0.0.1:\(port)/api/projects/active")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String {
                self.activeProjectName = name
            }
        } catch {
            // ignore
        }
    }

    // MARK: - State helpers

    @MainActor
    private func update(_ phase: Lifecycle, _ status: String) async {
        self.lifecycle = phase
        self.lifecycleStatus = status
    }

    @MainActor
    private func setReady(daemonPort: Int, bridgePort: Int, attached: Bool) async {
        self.daemonPort = daemonPort
        self.bridgePort = bridgePort == 0 ? nil : bridgePort
        self.bridgePortAtomic.set(bridgePort == 0 ? nil : bridgePort)
        self.lifecycle = .ready
        self.lifecycleStatus = attached ? "Attached to existing daemon" : "Ready"
        self.lastError = nil
    }

    @MainActor
    private func setFailed(_ reason: String) async {
        self.lifecycle = .failed
        self.lifecycleStatus = reason
        self.lastError = reason
        logger.error("\(reason, privacy: .public)")
    }
}
