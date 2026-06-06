import Foundation
import ClawdmeterShared

/// Mac-daemon owned run profile service for remote Code workbench clients.
/// The desktop Browser pane keeps its local `RunProfileManager`; this service
/// exists so iOS can ask the paired Mac to run the same command in the same cwd.
@MainActor
final class CodeRunProfileService {
    private final class Profile {
        let sessionId: UUID
        var cwd: String?
        var command: String?
        var detectedURL: String?
        var source: String?
        var status: CodeRunProfileStatus = .idle
        var health: CodeRunProfileHealth = CodeRunProfileHealth()
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var lastExitCode: Int32?
        var lastError: String?
        var updatedAt: Date = Date()
        var processHandle: RunProcessHandle?

        init(sessionId: UUID) {
            self.sessionId = sessionId
        }

        func snapshot() -> CodeRunProfileSnapshot {
            CodeRunProfileSnapshot(
                sessionId: sessionId,
                cwd: cwd,
                command: command,
                detectedURL: detectedURL,
                source: source,
                status: status,
                health: health,
                stdoutLines: stdoutLines,
                stderrLines: stderrLines,
                lastExitCode: lastExitCode,
                lastError: lastError,
                updatedAt: updatedAt
            )
        }
    }

    private let processManager: RunProcessManaging
    private let repoEnvResolver: RepoEnvRuntimeResolver?
    private var profiles: [UUID: Profile] = [:]
    private let previewLaunchController = PreviewLaunchController()
    private let maxBufferedLines = 200

    init(
        processManager: RunProcessManaging = LocalRunProcessManager(),
        repoEnvResolver: RepoEnvRuntimeResolver? = nil
    ) {
        self.processManager = processManager
        self.repoEnvResolver = repoEnvResolver
    }

    deinit {
        for profile in profiles.values {
            profile.processHandle?.terminate()
        }
    }

    func snapshot(session: AgentSession, messages: [ChatMessage]) async -> CodeRunProfileSnapshot {
        let profile = profile(for: session.id)
        profile.cwd = session.effectiveCwd
        detectTranscriptURLIfNeeded(profile: profile, messages: messages)
        return profile.snapshot()
    }

    func start(
        session: AgentSession,
        command rawCommand: String?,
        messages: [ChatMessage]
    ) async -> CodeRunProfileSnapshot {
        let profile = profile(for: session.id)
        let explicitCommand = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isManualRetry = explicitCommand?.isEmpty == false
        let current = PreviewCurrentRunSnapshot(
            command: profile.command,
            cwd: profile.cwd,
            url: profile.detectedURL.flatMap(URL.init(string:)),
            isRunning: profile.status == .running,
            isHealthy: profile.health.state == .healthy
        )
        let preparation = await previewLaunchController.prepare(
            session: session,
            messages: messages,
            persistedCommand: explicitCommand?.isEmpty == false ? explicitCommand : profile.command,
            current: current,
            forceRestart: false,
            retryFailedSetup: isManualRetry,
            runSetup: { [weak self, weak profile] script, cwd, environment in
                guard let self, let profile else {
                    return PreviewSetupResult(succeeded: false, message: "Preview runner disappeared.")
                }
                return await self.runSetup(script: script, cwd: cwd, environment: environment, profile: profile)
            }
        )

        let command: String
        let configuredLaunch: PreviewLaunchCommand
        switch preparation {
        case .failed(let message):
            if profile.processHandle == nil {
                profile.status = .failed
            }
            profile.lastError = message == "No preview command or local URL detected." ? "Enter a run command first." : message
            profile.updatedAt = Date()
            return profile.snapshot()
        case .open(let url, let source):
            publishDetectedURL(url, source: source.rawValue, profile: profile)
            return profile.snapshot()
        case .reuse:
            profile.updatedAt = Date()
            return profile.snapshot()
        case .start(let preparedCommand, let launch, _):
            command = preparedCommand
            configuredLaunch = launch
        }

        stopProcess(profile: profile, resetToIdle: false)
        profile.cwd = session.effectiveCwd
        profile.command = command
        profile.stdoutLines = []
        profile.stderrLines = []
        profile.lastExitCode = nil
        profile.lastError = nil
        profile.status = .starting
        profile.updatedAt = Date()

        do {
            let repoEnv = try repoEnvResolver?.resolveForLaunch(session: session)?.environment ?? [:]
            let env = repoEnv.merging(configuredLaunch.environment) { _, new in new }
            profile.processHandle = try processManager.start(
                command: command,
                cwd: session.effectiveCwd,
                environment: env,
                onOutput: { [weak self] output in
                    Task { @MainActor [weak self] in
                        self?.record(output, sessionId: session.id)
                    }
                },
                onExit: { [weak self] exitCode in
                    Task { @MainActor [weak self] in
                        self?.recordExit(exitCode, sessionId: session.id)
                    }
                }
            )
            profile.status = .running
            profile.updatedAt = Date()
        } catch {
            profile.status = .failed
            profile.lastError = error.localizedDescription
            profile.updatedAt = Date()
        }

        if let expectedURL = configuredLaunch.expectedURL {
            publishDetectedURL(expectedURL, source: configuredLaunch.source.rawValue, profile: profile)
        }
        detectTranscriptURLIfNeeded(profile: profile, messages: messages)
        return profile.snapshot()
    }

    func stop(session: AgentSession, messages: [ChatMessage]) async -> CodeRunProfileSnapshot {
        let profile = profile(for: session.id)
        profile.cwd = session.effectiveCwd
        stopProcess(profile: profile, resetToIdle: true)
        detectTranscriptURLIfNeeded(profile: profile, messages: messages)
        return profile.snapshot()
    }

    private func profile(for sessionId: UUID) -> Profile {
        if let existing = profiles[sessionId] { return existing }
        let created = Profile(sessionId: sessionId)
        profiles[sessionId] = created
        return created
    }

    private func stopProcess(profile: Profile, resetToIdle: Bool) {
        profile.processHandle?.terminate()
        profile.processHandle = nil
        if resetToIdle, profile.status == .running || profile.status == .starting {
            profile.status = .idle
            profile.updatedAt = Date()
        }
    }

    private func record(_ output: RunProcessOutput, sessionId: UUID) {
        let profile = profile(for: sessionId)
        let text: String
        switch output {
        case .stdout(let value):
            text = value
            appendBuffered(value, to: &profile.stdoutLines)
        case .stderr(let value):
            text = value
            appendBuffered(value, to: &profile.stderrLines)
        }
        profile.updatedAt = Date()
        guard let url = RunProfileManager.firstLocalHTTPURL(in: text) else { return }
        publishDetectedURL(url, source: "run", profile: profile)
    }

    private func recordExit(_ exitCode: Int32?, sessionId: UUID) {
        let profile = profile(for: sessionId)
        profile.processHandle = nil
        profile.lastExitCode = exitCode
        profile.status = (exitCode == 0) ? .exited : .failed
        if let exitCode, exitCode != 0 {
            profile.lastError = "Run exited with status \(exitCode)."
        }
        profile.updatedAt = Date()
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

    private func detectTranscriptURLIfNeeded(profile: Profile, messages: [ChatMessage]) {
        guard profile.detectedURL == nil || profile.source == "transcript" else { return }
        guard let detected = RunProfileManager.detectPreviewURL(in: messages) else { return }
        publishDetectedURL(detected, source: "transcript", profile: profile)
    }

    private func publishDetectedURL(_ url: URL, source: String, profile: Profile) {
        profile.detectedURL = url.absoluteString
        profile.source = source
        profile.health = CodeRunProfileHealth(state: .unknown)
        profile.updatedAt = Date()
        let sessionId = profile.sessionId
        Task { [weak self] in
            let health = await Self.check(url)
            await MainActor.run {
                guard let profile = self?.profiles[sessionId],
                      profile.detectedURL == url.absoluteString else { return }
                profile.health = health
                if health.state == .unhealthy {
                    profile.lastError = health.message
                } else {
                    profile.lastError = nil
                }
                profile.updatedAt = Date()
            }
        }
    }

    private nonisolated static func check(_ url: URL) async -> CodeRunProfileHealth {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return CodeRunProfileHealth(state: .unhealthy, message: "No HTTP response", checkedAt: Date())
            }
            if (200..<500).contains(http.statusCode) {
                return CodeRunProfileHealth(state: .healthy, statusCode: http.statusCode, checkedAt: Date())
            }
            return CodeRunProfileHealth(
                state: .unhealthy,
                statusCode: http.statusCode,
                message: "HTTP \(http.statusCode)",
                checkedAt: Date()
            )
        } catch {
            return CodeRunProfileHealth(state: .unhealthy, message: error.localizedDescription, checkedAt: Date())
        }
    }

    private func runSetup(script: String, cwd: String, environment: [String: String], profile: Profile) async -> PreviewSetupResult {
        profile.status = .starting
        profile.updatedAt = Date()
        do {
            let result = try await ShellRunner.shared.run(
                executable: "/bin/zsh",
                arguments: ["-lc", script],
                cwd: cwd,
                environment: ProcessInfo.processInfo.environment.merging(environment) { _, new in new },
                timeout: 600
            )
            appendBuffered(result.stdoutString, to: &profile.stdoutLines)
            appendBuffered(result.stderrString, to: &profile.stderrLines)
            if result.exitStatus != 0 {
                let message = "Setup exited with status \(result.exitStatus)."
                profile.lastError = message
                profile.updatedAt = Date()
                return PreviewSetupResult(succeeded: false, message: message)
            }
            profile.updatedAt = Date()
            return PreviewSetupResult(succeeded: true, message: nil)
        } catch {
            let message = "Setup failed: \(error.localizedDescription)"
            profile.lastError = message
            profile.updatedAt = Date()
            return PreviewSetupResult(succeeded: false, message: message)
        }
    }
}
