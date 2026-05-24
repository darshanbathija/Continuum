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
