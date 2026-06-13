import Foundation
import XCTest
@testable import Clawdmeter
#if canImport(Darwin)
import Darwin
#endif

final class TerminalPtyHostTests: XCTestCase {
    func test_directPtyHostStreamsInputOutputAndAppliesResize() async throws {
        let host = TerminalPtyHost(
            title: "test",
            argv: [
                "/bin/sh",
                "-lc",
                "printf 'READY\\n'; IFS= read line; printf 'GOT:%s\\n' \"$line\"; stty size 2>/dev/null || true"
            ],
            cwd: NSTemporaryDirectory()
        )
        addTeardownBlock {
            Task { await host.kill() }
        }

        try await host.start(cols: 80, rows: 24)

        let sawReady = await waitForOutput(host, contains: "READY")
        XCTAssertTrue(sawReady)
        await host.resize(cols: 100, rows: 30)
        let wroteInput = await host.writeBytes(Data("hello\r".utf8))
        XCTAssertTrue(wroteInput)

        let sawInput = await waitForOutput(host, contains: "GOT:hello")
        let outputAfterInput = String(data: await host.snapshot(), encoding: .utf8) ?? ""
        XCTAssertTrue(sawInput, outputAfterInput)
        let sawResize = await waitForOutput(host, contains: "30 100")
        let output = String(data: await host.snapshot(), encoding: .utf8) ?? ""
        XCTAssertTrue(sawResize, output)
    }

    func test_terminalRegistryDropsHostAfterNaturalExit() async throws {
        let registry = TerminalPtyRegistry()
        let host = try await registry.spawnCommand("printf done", cwd: NSTemporaryDirectory(), title: "short")
        let id = await host.id.uuidString

        let exited = await waitUntil(timeout: 4) {
            await registry.host(id: id) == nil
        }

        XCTAssertTrue(exited, "naturally exited terminal host should be pruned from registry")
    }

    func test_terminalKillTerminatesProcessGroup() async throws {
        let host = TerminalPtyHost(
            title: "pgid",
            argv: ["/bin/sh", "-lc", "sleep 30 & echo CHILD:$!; wait"],
            cwd: NSTemporaryDirectory()
        )
        try await host.start()
        let childPid = try await waitForChildPid(host)

        await host.kill()

        let childExited = await waitUntil(timeout: 4) {
            !Self.processIsLive(childPid)
        }
        XCTAssertTrue(childExited, "kill() should terminate PTY child process group, including background jobs")
    }

    func test_claudePtyKillTerminatesProcessGroup() async throws {
        let sessionId = UUID()
        let host = ClaudePtyHost(
            sessionId: sessionId,
            argv: ["/bin/sh", "-lc", "sleep 30 & echo CHILD:$!; wait"],
            cwd: NSTemporaryDirectory()
        )
        try await host.start()
        let childPid = try await waitForChildPid(host)

        await host.kill()

        let childExited = await waitUntil(timeout: 4) {
            !Self.processIsLive(childPid)
        }
        XCTAssertTrue(
            childExited,
            "Claude PTY kill() should terminate background jobs in the PTY process group; child=\(childPid) state=\(Self.processDebug(childPid))"
        )
    }

    private func waitForOutput(
        _ host: TerminalPtyHost,
        contains needle: String,
        timeout: TimeInterval = 4
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let output = String(data: await host.snapshot(), encoding: .utf8) ?? ""
            if output.contains(needle) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let output = String(data: await host.snapshot(), encoding: .utf8) ?? ""
        return output.contains(needle)
    }

    private func waitForChildPid(_ host: TerminalPtyHost, timeout: TimeInterval = 4) async throws -> pid_t {
        try await waitForChildPid(snapshot: { await host.snapshot() }, timeout: timeout)
    }

    private func waitForChildPid(_ host: ClaudePtyHost, timeout: TimeInterval = 4) async throws -> pid_t {
        try await waitForChildPid(snapshot: { await host.snapshot() }, timeout: timeout)
    }

    private func waitForChildPid(snapshot: @escaping () async -> Data, timeout: TimeInterval) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let output = String(data: await snapshot(), encoding: .utf8) ?? ""
            if let match = output.range(of: #"CHILD:(\d+)"#, options: .regularExpression) {
                let raw = String(output[match]).replacingOccurrences(of: "CHILD:", with: "")
                if let pid = Int32(raw) { return pid }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "TerminalPtyHostTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "child pid not printed"])
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await predicate()
    }

    private static func processIsLive(_ pid: pid_t) -> Bool {
        #if canImport(Darwin)
        if kill(pid, 0) != 0 { return errno != ESRCH }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "stat="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return false }
            let state = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return !state.contains("Z")
        } catch {
            return true
        }
        #else
        return false
        #endif
    }

    private static func processDebug(_ pid: pid_t) -> String {
        #if canImport(Darwin)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "pid=,ppid=,pgid=,sess=,stat=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "ps failed: \(error)"
        }
        #else
        return "unsupported"
        #endif
    }
}
