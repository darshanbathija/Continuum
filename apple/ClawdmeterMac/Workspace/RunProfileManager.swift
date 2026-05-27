import Foundation
import Combine
import ClawdmeterShared

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
            status: status.rawValue
        )
    }

    func startRun(command rawCommand: String? = nil, cwd runCwd: String, environment: [String: String]? = nil) {
        let command = (rawCommand ?? runCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            lastError = "Enter a run command first."
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
        } catch {
            status = .failed
            lastError = error.localizedDescription
        }
    }

    func stopRun(resetToIdle: Bool = true) {
        processHandle?.terminate()
        processHandle = nil
        if resetToIdle, status == .running || status == .starting {
            status = .idle
        }
    }

    func restartRun(cwd runCwd: String) {
        let command = runCommand
        startRun(command: command, cwd: runCwd)
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
        } else {
            lastError = nil
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
