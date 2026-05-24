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
    private var profiles: [UUID: Profile] = [:]
    private let maxBufferedLines = 200

    init(processManager: RunProcessManaging = LocalRunProcessManager()) {
        self.processManager = processManager
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
        let command = (rawCommand ?? profile.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            profile.lastError = "Enter a run command first."
            profile.status = .failed
            profile.updatedAt = Date()
            return profile.snapshot()
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
            profile.processHandle = try processManager.start(
                command: command,
                cwd: session.effectiveCwd,
                environment: nil,
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
}
