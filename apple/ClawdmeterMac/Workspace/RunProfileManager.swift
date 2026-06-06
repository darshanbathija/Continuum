import Foundation
import Combine
import ClawdmeterShared
import Darwin

enum PreviewLaunchState: String, Codable, Equatable, Sendable, CaseIterable {
    case idle
    case resolving
    case settingUp
    case reusing
    case starting
    case running
    case healthy
    case unhealthy
    case failed
    case restarting
}

enum RunProcessOutput: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
}

protocol RunProcessHandle: AnyObject, Sendable {
    func terminate()
}

protocol RunProcessManaging: Sendable {
    func start(
        command: String,
        cwd: String,
        environment: [String: String]?,
        onOutput: @escaping @Sendable (RunProcessOutput) -> Void,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> RunProcessHandle
}

final class LocalRunProcessHandle: RunProcessHandle, @unchecked Sendable {
    private let process: Process
    private let stdout: Pipe
    private let stderr: Pipe

    init(process: Process, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    func terminate() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
    }
}

struct LocalRunProcessManager: RunProcessManaging {
    func start(
        command: String,
        cwd: String,
        environment: [String: String]?,
        onOutput: @escaping @Sendable (RunProcessOutput) -> Void,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> RunProcessHandle {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            onOutput(.stdout(text))
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            onOutput(.stderr(text))
        }
        process.terminationHandler = { proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus)
        }
        try process.run()
        return LocalRunProcessHandle(process: process, stdout: stdout, stderr: stderr)
    }
}

struct PreviewLaunchCommand: Equatable, Sendable {
    enum Source: String, Sendable {
        case conductor
        case persisted
        case packageScript
        case transcriptURL
    }

    var command: String?
    var source: Source
    var setupScript: String?
    var setupFingerprint: String?
    var expectedURL: URL?
    var portBase: Int
    var environment: [String: String]
}

struct PreviewSetupResult: Equatable, Sendable {
    var succeeded: Bool
    var message: String?
}

struct PreviewCurrentRunSnapshot: Equatable, Sendable {
    var command: String?
    var cwd: String?
    var url: URL?
    var isRunning: Bool
    var isHealthy: Bool
}

struct PreviewPortReservation: Equatable, Sendable {
    var key: String
    var portBase: Int
    var activePort: Int

    var portEnd: Int {
        portBase + PreviewLaunchPolicy.portRangeSize - 1
    }
}

enum PreviewLaunchPreparation: Equatable, Sendable {
    case open(URL, source: PreviewLaunchCommand.Source)
    case reuse(URL)
    case start(command: String, launch: PreviewLaunchCommand, reservation: PreviewPortReservation)
    case failed(String)
}

enum PreviewLaunchPolicy {
    static let portRangeSize = 10

    static func portBase(for sessionId: UUID) -> Int {
        let scalarSum = sessionId.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return 19_000 + (scalarSum % 700) * 10
    }

    static func portRange(startingAt portBase: Int) -> [Int] {
        Array(portBase..<(portBase + portRangeSize))
    }

    static func environment(session: AgentSession, portBase: Int, activePort: Int? = nil) -> [String: String] {
        let port = activePort ?? portBase
        return [
            "CONDUCTOR_WORKSPACE_NAME": session.displayLabel,
            "CONDUCTOR_WORKSPACE_PATH": session.effectiveCwd,
            "CONDUCTOR_ROOT_PATH": session.repoKey ?? session.effectiveCwd,
            "CONDUCTOR_DEFAULT_BRANCH": "main",
            "CONDUCTOR_PORT_BASE": "\(portBase)",
            "CONDUCTOR_PORT_END": "\(portBase + portRangeSize - 1)",
            "CONDUCTOR_PORT": "\(port)",
            "PORT": "\(port)",
            "VITE_PORT": "\(port)",
            "NEXT_PUBLIC_PORT": "\(port)"
        ]
    }

    static func setupAttemptKey(sessionId: UUID, cwd: String, fingerprint: String) -> String {
        "\(sessionId.uuidString)#\(cwd)#\(fingerprint)"
    }

    static func portReservationKey(sessionId: UUID, cwd: String) -> String {
        "\(sessionId.uuidString)#\(cwd)"
    }

    static func command(_ command: PreviewLaunchCommand, configuredFor session: AgentSession, activePort: Int) -> PreviewLaunchCommand {
        var copy = command
        copy.expectedURL = URL(string: "http://localhost:\(activePort)")
        copy.environment = environment(session: session, portBase: command.portBase, activePort: activePort)
        return copy
    }

    static func firstAvailablePort(startingAt portBase: Int) -> Int? {
        portRange(startingAt: portBase).first(where: isPortAvailable)
    }

    static func isPortAvailable(_ port: Int) -> Bool {
        guard port > 0, port <= 65_535 else { return false }
        return isIPv4PortAvailable(port) && isIPv6PortAvailable(port)
    }

    private static func isIPv4PortAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var value: Int32 = 1
        _ = withUnsafePointer(to: &value) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func isIPv6PortAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var value: Int32 = 1
        _ = withUnsafePointer(to: &value) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(port).bigEndian
        addr.sin6_addr = in6addr_loopback

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return result == 0
    }

    static func resolve(
        session: AgentSession,
        messages: [ChatMessage],
        persistedCommand: String?
    ) -> PreviewLaunchCommand? {
        let cwd = session.effectiveCwd
        let portBase = portBase(for: session.id)
        let env = environment(session: session, portBase: portBase)
        let conductor = conductorScripts(in: cwd)
        if let run = conductor.run {
            return PreviewLaunchCommand(
                command: run,
                source: .conductor,
                setupScript: conductor.setup,
                setupFingerprint: conductor.setup.map { setupFingerprint(cwd: cwd, script: $0) },
                expectedURL: URL(string: "http://localhost:\(portBase)"),
                portBase: portBase,
                environment: env
            )
        }
        if let persisted = persistedCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !persisted.isEmpty {
            return PreviewLaunchCommand(
                command: persisted,
                source: .persisted,
                expectedURL: URL(string: "http://localhost:\(portBase)"),
                portBase: portBase,
                environment: env
            )
        }
        if let package = packageRunCommand(in: cwd) {
            return PreviewLaunchCommand(
                command: package,
                source: .packageScript,
                expectedURL: URL(string: "http://localhost:\(portBase)"),
                portBase: portBase,
                environment: env
            )
        }
        if let transcriptURL = RunProfileManager.detectPreviewURL(in: messages) {
            return PreviewLaunchCommand(
                command: nil,
                source: .transcriptURL,
                expectedURL: transcriptURL,
                portBase: portBase,
                environment: env
            )
        }
        return nil
    }

    static func shouldReuse(
        requested command: PreviewLaunchCommand,
        currentCommand: String,
        currentCwd: String?,
        currentURL: URL?,
        currentHealth: RunProfileManager.Health?,
        currentStatus: RunProfileManager.Status,
        sessionCwd: String
    ) -> Bool {
        guard let requestedCommand = command.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedCommand.isEmpty,
              requestedCommand == currentCommand.trimmingCharacters(in: .whitespacesAndNewlines),
              currentCwd == sessionCwd,
              isURL(currentURL, withinPortRangeStartingAt: command.portBase),
              currentStatus == .running,
              case .healthy = currentHealth
        else { return false }
        return true
    }

    static func shouldReuse(
        requested command: PreviewLaunchCommand,
        current: PreviewCurrentRunSnapshot,
        sessionCwd: String
    ) -> Bool {
        guard let requestedCommand = command.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              let currentCommand = current.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedCommand.isEmpty,
              requestedCommand == currentCommand,
              current.cwd == sessionCwd,
              isURL(current.url, withinPortRangeStartingAt: command.portBase),
              current.isRunning,
              current.isHealthy
        else { return false }
        return true
    }

    static func isURL(_ url: URL?, withinPortRangeStartingAt portBase: Int) -> Bool {
        guard let port = url?.port else { return false }
        return port >= portBase && port < portBase + portRangeSize
    }

    static func conductorScripts(in cwd: String) -> (setup: String?, run: String?) {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent("conductor.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = root["scripts"] as? [String: Any]
        else { return (nil, nil) }
        return (
            (scripts["setup"] as? String)?.nonEmptyTrimmed,
            (scripts["run"] as? String)?.nonEmptyTrimmed
        )
    }

    static func packageRunCommand(in cwd: String) -> String? {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = root["scripts"] as? [String: Any]
        else { return nil }
        let scriptName = ["dev", "start", "preview"].first { scripts[$0] is String }
        guard let scriptName else { return nil }
        let fm = FileManager.default
        let command: String
        if fm.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("pnpm-lock.yaml").path) {
            command = "pnpm run \(scriptName)"
        } else if fm.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("yarn.lock").path) {
            command = "yarn \(scriptName)"
        } else if fm.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("bun.lockb").path) {
            command = "bun run \(scriptName)"
        } else {
            command = "npm run \(scriptName)"
        }
        return command
    }

    static func setupFingerprint(cwd: String, script: String) -> String {
        "\(cwd)#\(script)"
    }
}

@MainActor
final class PreviewLaunchController {
    typealias SetupRunner = @MainActor (_ script: String, _ cwd: String, _ environment: [String: String]) async -> PreviewSetupResult

    private var attemptedSetupKeys: Set<String> = []
    private var failedSetupKeys: [String: String] = [:]
    private var portReservations: [String: PreviewPortReservation] = [:]

    func prepare(
        session: AgentSession,
        messages: [ChatMessage],
        persistedCommand: String?,
        current: PreviewCurrentRunSnapshot,
        forceRestart: Bool,
        retryFailedSetup: Bool = false,
        runSetup: SetupRunner,
        onStateChange: (PreviewLaunchState) -> Void = { _ in }
    ) async -> PreviewLaunchPreparation {
        guard let launch = PreviewLaunchPolicy.resolve(
            session: session,
            messages: messages,
            persistedCommand: persistedCommand
        ) else {
            return .failed("No preview command or local URL detected.")
        }

        if let url = launch.expectedURL, launch.command == nil {
            onStateChange(.reusing)
            return .open(url, source: launch.source)
        }

        guard let command = launch.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else {
            return .failed("No preview command detected.")
        }

        if !forceRestart,
           PreviewLaunchPolicy.shouldReuse(requested: launch, current: current, sessionCwd: session.effectiveCwd),
           let url = current.url ?? launch.expectedURL {
            onStateChange(.reusing)
            reserveExistingPortIfNeeded(session: session, launch: launch, currentURL: url)
            return .reuse(url)
        }

        guard let reservation = reservePortRange(session: session, launch: launch, current: current, forceRestart: forceRestart) else {
            return .failed("No free preview port in assigned range \(launch.portBase)-\(launch.portBase + PreviewLaunchPolicy.portRangeSize - 1).")
        }
        let configuredLaunch = PreviewLaunchPolicy.command(launch, configuredFor: session, activePort: reservation.activePort)

        if let setup = configuredLaunch.setupScript,
           let fingerprint = configuredLaunch.setupFingerprint {
            let setupKey = PreviewLaunchPolicy.setupAttemptKey(
                sessionId: session.id,
                cwd: session.effectiveCwd,
                fingerprint: fingerprint
            )
            if forceRestart || retryFailedSetup {
                attemptedSetupKeys.remove(setupKey)
                failedSetupKeys.removeValue(forKey: setupKey)
            }
            if let message = failedSetupKeys[setupKey] {
                return .failed(message)
            }
            if !attemptedSetupKeys.contains(setupKey) {
                attemptedSetupKeys.insert(setupKey)
                onStateChange(.settingUp)
                let result = await runSetup(setup, session.effectiveCwd, configuredLaunch.environment)
                if !result.succeeded {
                    let message = result.message ?? "Setup failed."
                    failedSetupKeys[setupKey] = message
                    return .failed(message)
                }
            }
        }

        return .start(command: command, launch: configuredLaunch, reservation: reservation)
    }

    private func reservePortRange(
        session: AgentSession,
        launch: PreviewLaunchCommand,
        current: PreviewCurrentRunSnapshot,
        forceRestart: Bool
    ) -> PreviewPortReservation? {
        let key = PreviewLaunchPolicy.portReservationKey(sessionId: session.id, cwd: session.effectiveCwd)
        let activePort: Int?
        if forceRestart,
           let currentPort = current.url?.port,
           PreviewLaunchPolicy.isURL(current.url, withinPortRangeStartingAt: launch.portBase) {
            activePort = currentPort
        } else {
            activePort = PreviewLaunchPolicy.firstAvailablePort(startingAt: launch.portBase)
        }
        guard let activePort else {
            portReservations.removeValue(forKey: key)
            return nil
        }
        let reservation = PreviewPortReservation(key: key, portBase: launch.portBase, activePort: activePort)
        portReservations[key] = reservation
        return reservation
    }

    private func reserveExistingPortIfNeeded(session: AgentSession, launch: PreviewLaunchCommand, currentURL: URL) {
        guard let port = currentURL.port,
              PreviewLaunchPolicy.isURL(currentURL, withinPortRangeStartingAt: launch.portBase)
        else { return }
        let key = PreviewLaunchPolicy.portReservationKey(sessionId: session.id, cwd: session.effectiveCwd)
        portReservations[key] = PreviewPortReservation(key: key, portBase: launch.portBase, activePort: port)
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

protocol URLHealthChecking: Sendable {
    func check(_ url: URL) async -> RunProfileManager.Health
}

struct URLSessionHealthChecker: URLHealthChecking {
    func check(_ url: URL) async -> RunProfileManager.Health {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unhealthy("No HTTP response")
            }
            return (200..<500).contains(http.statusCode)
                ? .healthy(statusCode: http.statusCode)
                : .unhealthy("HTTP \(http.statusCode)")
        } catch {
            return .unhealthy(error.localizedDescription)
        }
    }
}

@MainActor
final class RunProfileManager: ObservableObject {
    enum Status: String, Equatable, Codable, Sendable {
        case idle
        case starting
        case running
        case exited
        case failed
    }

    enum Health: Equatable, Sendable {
        case unknown
        case healthy(statusCode: Int)
        case unhealthy(String)
    }

    struct Snapshot: Equatable, Sendable {
        let sessionId: UUID
        let url: URL
        let source: String
        let health: Health
        let lastCheckedAt: Date?
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    @Published var runCommand: String
    @Published private(set) var cwd: String?
    @Published private(set) var status: Status
    @Published private(set) var previewState: PreviewLaunchState
    @Published private(set) var stdoutLines: [String] = []
    @Published private(set) var stderrLines: [String] = []
    @Published private(set) var lastExitCode: Int32?

    private let profileId: UUID
    private let sessionId: UUID
    private let chatStore: SessionChatStore?
    private let healthChecker: URLHealthChecking
    private let processManager: RunProcessManaging
    private var subscription: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var processHandle: RunProcessHandle?
    private let maxBufferedLines = 200
    private let previewLaunchController = PreviewLaunchController()

    init(
        sessionId: UUID,
        chatStore: SessionChatStore?,
        healthChecker: URLHealthChecking = URLSessionHealthChecker(),
        processManager: RunProcessManaging = LocalRunProcessManager(),
        initialState: RunProfileStateSnapshot? = nil
    ) {
        self.sessionId = sessionId
        self.chatStore = chatStore
        self.healthChecker = healthChecker
        self.processManager = processManager
        self.profileId = initialState?.profileId ?? UUID()
        self.runCommand = initialState?.command ?? ""
        self.cwd = initialState?.cwd
        if let raw = initialState?.status,
           let status = Status(rawValue: raw),
           status != .starting,
           status != .running {
            self.status = status
        } else {
            self.status = .idle
        }
        self.previewState = initialState?.previewState.flatMap(PreviewLaunchState.init(rawValue:)) ?? .idle
        if let urlString = initialState?.detectedURL,
           let url = URL(string: urlString) {
            self.snapshot = Snapshot(
                sessionId: sessionId,
                url: url,
                source: "persisted",
                health: .unknown,
                lastCheckedAt: nil
            )
        }
    }

    deinit {
        subscription?.cancel()
        refreshTask?.cancel()
        processHandle?.terminate()
    }

    func start() {
        subscription?.cancel()
        // C2 — was `chatStore?.$snapshot` pre-C2. With SessionChatStore
        // migrated to `@Observable`, the daemon-side Combine bridge is
        // `snapshotPublisher`.
        subscription = chatStore?.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
        refresh()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        refreshTask?.cancel()
        let messages = chatStore?.messages ?? []
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            await self.resolve(messages: messages)
        }
    }

    func resolveNowForTesting(messages: [ChatMessage]) async {
        refreshTask?.cancel()
        await resolve(messages: messages)
    }

    var stateSnapshot: RunProfileStateSnapshot {
        RunProfileStateSnapshot(
            profileId: profileId,
            sessionId: sessionId,
            cwd: cwd,
            command: runCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : runCommand,
            detectedURL: snapshot?.url.absoluteString,
            status: status.rawValue,
            previewState: previewState.rawValue
        )
    }

    func launchPreview(session: AgentSession, forceRestart: Bool = false) async -> URL? {
        previewState = forceRestart ? .restarting : .resolving
        let messages = chatStore?.messages ?? []
        let current = PreviewCurrentRunSnapshot(
            command: runCommand,
            cwd: cwd,
            url: snapshot?.url,
            isRunning: status == .running,
            isHealthy: isCurrentSnapshotHealthy
        )
        let preparation = await previewLaunchController.prepare(
            session: session,
            messages: messages,
            persistedCommand: runCommand,
            current: current,
            forceRestart: forceRestart,
            runSetup: { [weak self] script, cwd, environment in
                guard let self else { return PreviewSetupResult(succeeded: false, message: "Preview runner disappeared.") }
                return await self.runSetup(script: script, cwd: cwd, environment: environment)
            },
            onStateChange: { [weak self] state in
                self?.previewState = state
            }
        )

        switch preparation {
        case .failed(let message):
            previewState = .failed
            if processHandle == nil {
                status = .failed
            }
            lastError = message
            return nil
        case .open(let url, let source):
            await publishDetectedURL(url, source: source.rawValue)
            previewState = healthState(from: snapshot?.health)
            return url
        case .reuse(let url):
            previewState = .reusing
            return url
        case .start(let command, let configuredLaunch, _):
            previewState = forceRestart ? .restarting : .starting
            startRun(command: command, cwd: session.effectiveCwd, environment: configuredLaunch.environment)
            if let expectedURL = configuredLaunch.expectedURL {
                await publishDetectedURL(expectedURL, source: configuredLaunch.source.rawValue)
                previewState = healthState(from: snapshot?.health)
                return expectedURL
            }
            previewState = .running
            return snapshot?.url
        }
    }

    private var isCurrentSnapshotHealthy: Bool {
        if case .healthy = snapshot?.health {
            return true
        } else {
            return false
        }
    }

    func startRun(command rawCommand: String? = nil, cwd runCwd: String, environment: [String: String]? = nil) {
        let command = (rawCommand ?? runCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            lastError = "Enter a run command first."
            previewState = .failed
            return
        }
        stopRun(resetToIdle: false)
        runCommand = command
        cwd = runCwd
        stdoutLines = []
        stderrLines = []
        lastExitCode = nil
        lastError = nil
        status = .starting
        previewState = .starting
        do {
            processHandle = try processManager.start(
                command: command,
                cwd: runCwd,
                environment: environment,
                onOutput: { [weak self] output in
                    Task { @MainActor [weak self] in
                        self?.record(output)
                    }
                },
                onExit: { [weak self] exitCode in
                    Task { @MainActor [weak self] in
                        self?.recordExit(exitCode)
                    }
                }
            )
            status = .running
            previewState = .running
        } catch {
            status = .failed
            previewState = .failed
            lastError = error.localizedDescription
        }
    }

    func stopRun(resetToIdle: Bool = true) {
        processHandle?.terminate()
        processHandle = nil
        if resetToIdle, status == .running || status == .starting {
            status = .idle
            previewState = .idle
        }
    }

    func restartRun(cwd runCwd: String, environment: [String: String]? = nil) {
        let command = runCommand
        startRun(command: command, cwd: runCwd, environment: environment)
    }

    func failRun(_ message: String) {
        stopRun(resetToIdle: false)
        status = .failed
        previewState = .failed
        lastError = message
    }

    private func resolve(messages: [ChatMessage]) async {
        guard let detected = Self.detectPreviewURL(in: messages) else {
            if status == .idle {
                snapshot = nil
            }
            lastError = nil
            return
        }
        await publishDetectedURL(detected, source: "transcript")
    }

    private func record(_ output: RunProcessOutput) {
        switch output {
        case .stdout(let text):
            appendBuffered(text, to: &stdoutLines)
        case .stderr(let text):
            appendBuffered(text, to: &stderrLines)
        }
        let text: String
        switch output {
        case .stdout(let value), .stderr(let value):
            text = value
        }
        guard let url = Self.firstLocalHTTPURL(in: text) else { return }
        Task { await publishDetectedURL(url, source: "run") }
    }

    private func recordExit(_ exitCode: Int32?) {
        processHandle = nil
        lastExitCode = exitCode
        status = (exitCode == 0) ? .exited : .failed
        previewState = (exitCode == 0) ? .idle : .failed
        if let exitCode, exitCode != 0 {
            lastError = "Run exited with status \(exitCode)."
        }
    }

    private func appendBuffered(_ text: String, to lines: inout [String]) {
        let chunks = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        if chunks.isEmpty {
            lines.append(text)
        } else {
            lines.append(contentsOf: chunks)
        }
        if lines.count > maxBufferedLines {
            lines.removeFirst(lines.count - maxBufferedLines)
        }
    }

    private func publishDetectedURL(_ detected: URL, source: String) async {
        isChecking = true
        let health = await healthChecker.check(detected)
        isChecking = false
        snapshot = Snapshot(
            sessionId: sessionId,
            url: detected,
            source: source,
            health: health,
            lastCheckedAt: Date()
        )
        if case .unhealthy(let message) = health {
            lastError = message
            previewState = .unhealthy
        } else {
            lastError = nil
            previewState = .healthy
        }
    }

    private func runSetup(script: String, cwd: String, environment: [String: String]) async -> PreviewSetupResult {
        do {
            let result = try await ShellRunner.shared.run(
                executable: "/bin/zsh",
                arguments: ["-lc", script],
                cwd: cwd,
                environment: ProcessInfo.processInfo.environment.merging(environment) { _, new in new },
                timeout: 600
            )
            appendBuffered(result.stdoutString, to: &stdoutLines)
            appendBuffered(result.stderrString, to: &stderrLines)
            if result.exitStatus != 0 {
                let message = "Setup exited with status \(result.exitStatus)."
                lastError = message
                return PreviewSetupResult(succeeded: false, message: message)
            }
            return PreviewSetupResult(succeeded: true, message: nil)
        } catch {
            let message = "Setup failed: \(error.localizedDescription)"
            lastError = message
            return PreviewSetupResult(succeeded: false, message: message)
        }
    }

    private func healthState(from health: Health?) -> PreviewLaunchState {
        switch health {
        case .healthy: return .healthy
        case .unhealthy: return .unhealthy
        case .unknown, nil: return .running
        }
    }

    nonisolated static func detectPreviewURL(in messages: [ChatMessage]) -> URL? {
        for message in messages.reversed() {
            let fields = [
                message.body,
                message.detail,
                message.bashResult?.stdout,
                message.bashResult?.stderr,
            ].compactMap { $0 }
            for field in fields {
                if let url = firstLocalHTTPURL(in: field) {
                    return url
                }
            }
        }
        return nil
    }

    nonisolated static func firstLocalHTTPURL(in text: String) -> URL? {
        let localURLRegex = try? NSRegularExpression(
            pattern: #"https?://(?:localhost|127\.0\.0\.1|\[::1\])(?::\d{2,5})?(?:/[^\s<>"']*)?"#,
            options: [.caseInsensitive]
        )
        guard let regex = localURLRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        let raw = String(text[swiftRange])
        return URL(string: raw)
    }
}
