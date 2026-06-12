import Foundation

protocol ShellRunning: Sendable {
    @discardableResult
    func run(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ShellRunner.Result
}

extension ShellRunner: ShellRunning {}

extension ShellRunning {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ShellRunner.Result {
        try await run(
            executable: executable,
            arguments: arguments,
            cwd: nil,
            environment: nil,
            timeout: timeout
        )
    }
}
