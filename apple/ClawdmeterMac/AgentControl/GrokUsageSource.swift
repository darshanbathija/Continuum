import Foundation
import ClawdmeterShared
import Darwin

/// Live Grok credit-usage source.
///
/// Grok Build 0.2.x exposes account usage through the interactive `/usage show`
/// command. It is not an ACP method and `grok --output-format json` does not
/// currently print it, so this source drives the same command through a short
/// PTY session and parses the visible terminal text:
///
///   Credits used: 14%
///   Resets: Jun 30, 16:00 PT
///   Pay as you go: disabled
///
/// This is intentionally separate from `GrokUsageLedger`: the ledger records
/// historical token analytics, while this source is the live account-limit
/// percentage used by the menu bar and Usage tab gauges.
public final class GrokUsageSource: AISource, @unchecked Sendable {
    public let providerID = "grok"
    public let displayName = "Grok"

    private let binaryPathProvider: @Sendable () -> String?
    private let nowProvider: @Sendable () -> Date
    private let timeoutSeconds: TimeInterval

    public init(
        binaryPathProvider: @escaping @Sendable () -> String? = { ShellRunner.locateBinary("grok") },
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        timeoutSeconds: TimeInterval = 12
    ) {
        self.binaryPathProvider = binaryPathProvider
        self.nowProvider = nowProvider
        self.timeoutSeconds = timeoutSeconds
    }

    public var isAuthenticated: Bool {
        guard let binary = binaryPathProvider() else { return false }
        return FileManager.default.isExecutableFile(atPath: binary)
    }

    public func refreshCredentialsIfNeeded() async throws -> Bool {
        isAuthenticated
    }

    public func dataChangedSince(_ date: Date?) -> Bool {
        guard let date else { return true }
        return nowProvider().timeIntervalSince(date) >= 15 * 60
    }

    public func poll() async throws -> UsageData {
        guard let binary = binaryPathProvider() else {
            throw AISourceError.unauthenticated
        }
        let output = try await Self.captureUsageShow(
            binary: binary,
            cwd: ClawdmeterRealHome.url().path,
            timeoutSeconds: timeoutSeconds
        )
        return try Self.parseUsageShow(output, now: nowProvider())
    }

    static func parseUsageShow(_ output: String, now: Date) throws -> UsageData {
        let visible = stripANSI(output)
        guard let percent = parsePercent(from: visible) else {
            throw AISourceError.malformedResponse(detail: "Grok /usage show missing Credits used percent")
        }

        let reset = parseReset(from: visible, now: now)
        let resetEpoch = reset.map { Int($0.timeIntervalSince1970) } ?? 0
        let nowEpoch = Int(now.timeIntervalSince1970)
        let resetMins = resetEpoch > nowEpoch ? max(0, (resetEpoch - nowEpoch + 59) / 60) : 0
        let status: UsageData.Status = percent >= 100 ? .limited : .allowed

        return UsageData(
            sessionPct: percent,
            sessionResetMins: resetMins,
            sessionEpoch: resetEpoch,
            weeklyPct: percent,
            weeklyResetMins: resetMins,
            weeklyEpoch: resetEpoch,
            status: status,
            representativeClaim: .unknown,
            updatedAt: now
        )
    }

    private static func captureUsageShow(
        binary: String,
        cwd: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let pty = try PseudoTerminal(cols: 80, rows: 24)
                    let pid = try pty.spawn(
                        executable: binary,
                        arguments: ["--no-alt-screen", "--no-leader"],
                        environment: ProcessInfo.processInfo.environment,
                        cwd: cwd
                    )
                    pty.closeSlave()

                    let fd = pty.detachMaster()
                    let flags = fcntl(fd, F_GETFL, 0)
                    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
                    var output = Data()
                    let deadline = Date().addingTimeInterval(timeoutSeconds)

                    func writeString(_ text: String) {
                        guard let data = text.data(using: .utf8) else { return }
                        data.withUnsafeBytes { raw in
                            guard let base = raw.baseAddress else { return }
                            _ = Darwin.write(fd, base, raw.count)
                        }
                    }

                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.9) {
                        writeString("\u{15}/usage show\r")
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.0) {
                        writeString("\u{15}/quit\r")
                    }

                    var buffer = [UInt8](repeating: 0, count: 4096)
                    var completed = false
                    while Date() < deadline {
                        let n = Darwin.read(fd, &buffer, buffer.count)
                        if n > 0 {
                            output.append(buffer, count: n)
                            if let text = String(data: output, encoding: .utf8),
                               text.contains("Credits"),
                               text.contains("used:") {
                                completed = true
                                break
                            }
                        } else if n == 0 {
                            break
                        } else if errno == EAGAIN || errno == EWOULDBLOCK {
                            Thread.sleep(forTimeInterval: 0.05)
                        } else if errno != EINTR {
                            break
                        }
                    }

                    if !completed {
                        writeString("\u{15}/quit\r")
                    }
                    close(fd)
                    kill(pid, SIGTERM)
                    var status: Int32 = 0
                    if waitpid(pid, &status, WNOHANG) == 0 {
                        usleep(100_000)
                        if waitpid(pid, &status, WNOHANG) == 0 {
                            kill(pid, SIGKILL)
                            _ = waitpid(pid, &status, 0)
                        }
                    }

                    let text = String(data: output, encoding: .utf8) ?? ""
                    guard !text.isEmpty else {
                        throw AISourceError.malformedResponse(detail: "Grok /usage show produced no terminal output")
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func parsePercent(from text: String) -> Int? {
        guard let line = text
            .components(separatedBy: .newlines)
            .first(where: { $0.localizedCaseInsensitiveContains("Credits used") })
        else { return nil }
        let pattern = #"(\d{1,3})\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line),
              let value = Int(line[range])
        else { return nil }
        return max(0, min(100, value))
    }

    private static func parseReset(from text: String, now: Date) -> Date? {
        guard let line = text
            .components(separatedBy: .newlines)
            .first(where: { $0.localizedCaseInsensitiveContains("Resets:") })
        else { return nil }
        let raw = line
            .replacingOccurrences(of: "Resets:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "yyyy MMM d, HH:mm"
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let normalized = raw
            .replacingOccurrences(of: " PT", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = formatter.date(from: "\(year) \(normalized)") else { return nil }
        if parsed < now, let nextYear = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: parsed) {
            return nextYear
        }
        return parsed
    }

    static func stripANSI(_ text: String) -> String {
        let pattern = #"\u001B\[[0-?]*[ -/]*[@-~]|\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}

public struct GrokTokenProvider: TokenProvider {
    public var hasToken: Bool { ShellRunner.locateBinary("grok") != nil }
    public var currentAccessToken: String? { hasToken ? "grok-cli" : nil }
    public init() {}
    public func refreshIfNeeded() async throws -> Bool { hasToken }
}
