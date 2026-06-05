import XCTest
@testable import Clawdmeter
@testable import ClawdmeterShared

/// Track A — PseudoTerminal (cwd + winsize), ClaudePtyHost (spawn/ready/submit/
/// exit), and ClaudePtyRegistry (single-flight + LRU cap). Uses a fake-claude
/// stub script so the riskiest concurrency/lifecycle paths are deterministic
/// with no login / no subscription burn.
final class ClaudePtyHostTests: XCTestCase {

    // MARK: - Fake-claude stub fixture

    /// Writes an executable shell stub that prints a ready marker, echoes each
    /// input line as `GOT:<line>`, and exits 0 when it sees `QUIT`.
    private func makeStub() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fake-claude").path
        let script = """
        #!/bin/sh
        echo "READY_MARKER"
        while IFS= read -r line; do
          echo "GOT:$line"
          case "$line" in *QUIT*) exit 0;; esac
        done
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ cond: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await cond()
    }

    // MARK: - PseudoTerminal (T3)

    func testPseudoTerminalSpawnsInCwdWithSpace() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cwd space dir-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pty = try PseudoTerminal()
        _ = try pty.spawn(executable: "/bin/sh", arguments: ["-c", "pwd; sleep 0.2"],
                          environment: ProcessInfo.processInfo.environment, cwd: dir.path)
        var out = Data()
        let deadline = Date().addingTimeInterval(3)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = read(pty.masterFD, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else { break }
            if String(decoding: out, as: UTF8.self).contains("cwd space dir") { break }
        }
        pty.closeMaster()
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("cwd space dir"),
                      "child must start in the space-containing cwd; got: \(String(decoding: out, as: UTF8.self))")
    }

    func testPseudoTerminalInitialWinsize() throws {
        let pty = try PseudoTerminal(cols: 120, rows: 40)
        _ = try pty.spawn(executable: "/bin/sh", arguments: ["-c", "stty size; sleep 0.2"],
                          environment: ProcessInfo.processInfo.environment)
        var out = Data()
        let deadline = Date().addingTimeInterval(3)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = read(pty.masterFD, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else { break }
            if String(decoding: out, as: UTF8.self).contains("40 120") { break }
        }
        pty.closeMaster()
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("40 120"),
                      "stty size must report rows=40 cols=120; got: \(String(decoding: out, as: UTF8.self))")
    }

    // MARK: - ClaudePtyHost (T4)

    func testHostReachesReadyAndEchoesSubmit() async throws {
        let stub = try makeStub()
        let host = ClaudePtyHost(sessionId: UUID(), argv: [stub], cwd: nil)
        _ = try await host.start()
        let ready = await waitUntil { await host.recentOutput().contains("READY_MARKER") }
        XCTAssertTrue(ready, "host must reach the ready marker")
        await host.submitPrompt("hello", isChat: true)
        let echoed = await waitUntil { await host.recentOutput().contains("hello") }
        XCTAssertTrue(echoed, "submitted text must reach the child (GOT:…hello)")
        await host.kill()
        let running = await host.isRunning
        XCTAssertFalse(running, "kill() must mark not-running")
    }

    func testHostUnexpectedExitFiresCallback() async throws {
        let stub = try makeStub()
        let id = UUID()
        let host = ClaudePtyHost(sessionId: id, argv: [stub], cwd: nil)
        let exited = expectation(description: "onUnexpectedExit fires")
        await host.setOnUnexpectedExit { sid, _ in
            if sid == id { exited.fulfill() }
        }
        _ = try await host.start()
        _ = await waitUntil { await host.recentOutput().contains("READY_MARKER") }
        await host.submitPrompt("QUIT", isChat: true)   // stub exits 0
        await fulfillment(of: [exited], timeout: 5)
        let running = await host.isRunning
        XCTAssertFalse(running, "child exit must clear isRunning")
    }

    // MARK: - ClaudePtyRegistry (T4)

    func testRegistrySingleFlightReturnsOneHost() async throws {
        let stub = try makeStub()
        let reg = ClaudePtyRegistry()
        let id = UUID()
        let plan: @Sendable () -> ClaudePtyRegistry.SpawnPlan? = {
            ClaudePtyRegistry.SpawnPlan(argv: [stub], cwd: nil)
        }
        async let a = reg.resumeOrSpawn(id: id, plan: plan)
        async let b = reg.resumeOrSpawn(id: id, plan: plan)
        let (h1, h2) = try await (a, b)
        XCTAssertTrue(h1 === h2, "concurrent resumeOrSpawn must join ONE host")
        let count = await reg.liveCount()
        XCTAssertEqual(count, 1, "single-flight must not double-spawn")
        await reg.suspend(id)
    }

    // Review fix (C2): a suspend()/delete() that races an in-flight spawn must
    // not leave an orphan live host. Before the fix, suspend nil'd `inflight`
    // but didn't cancel the Task, and store() unconditionally re-inserted the
    // host AFTER the delete → a live `claude` for a deleted session. The
    // invariant (no live host for a suspended id) must hold in every ordering.
    func testRegistrySuspendDuringInflightSpawnLeavesNoOrphan() async throws {
        let stub = try makeStub()
        let reg = ClaudePtyRegistry()
        let id = UUID()
        // Gate the plan so the spawn is provably IN FLIGHT (inflight[id] set,
        // host not yet started) when suspend lands. The plan closure blocks on a
        // semaphore the test releases only AFTER calling suspend — that's exactly
        // the window where the old code stored a host for a deleted session.
        let gate = DispatchSemaphore(value: 0)
        let plan: @Sendable () -> ClaudePtyRegistry.SpawnPlan? = {
            gate.wait()
            return ClaudePtyRegistry.SpawnPlan(argv: [stub], cwd: nil)
        }
        let spawnTask = Task { try? await reg.resumeOrSpawn(id: id, plan: plan) }
        // Let resumeOrSpawn register inflight[id] and the inner task reach gate.wait().
        try await Task.sleep(nanoseconds: 250_000_000)
        await reg.suspend(id)   // cancels + clears the inflight slot
        gate.signal()           // plan proceeds → start() → store() must now bail
        _ = await spawnTask.value
        let host = await reg.host(for: id)
        XCTAssertNil(host, "a suspend during the in-flight spawn must not leave an orphan host")
        let count = await reg.liveCount()
        XCTAssertEqual(count, 0, "no live host should remain after suspend-during-spawn")
    }

    // Review fix (C5): submitPrompt after kill() must be a safe no-op — it must
    // not write a closed/recycled fd. (kill() sets masterFD=-1 + isRunning=false
    // synchronously; submit re-checks both.)
    func testSubmitAfterKillIsNoOp() async throws {
        let stub = try makeStub()
        let host = ClaudePtyHost(sessionId: UUID(), argv: [stub], cwd: nil)
        _ = try await host.start()
        _ = await waitUntil { await host.recentOutput().contains("READY_MARKER") }
        await host.kill()
        // Should not crash, hang, or write anything.
        await host.submitPrompt("after-kill", isChat: true)
        await host.writeBytes(Data([0x0d]))
        let running = await host.isRunning
        XCTAssertFalse(running)
    }

    func testRegistryHardCapEvictsLRU() async throws {
        let stub = try makeStub()
        let reg = ClaudePtyRegistry(maxLiveHosts: 2)
        let plan: @Sendable () -> ClaudePtyRegistry.SpawnPlan? = {
            ClaudePtyRegistry.SpawnPlan(argv: [stub], cwd: nil)
        }
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        _ = try await reg.resumeOrSpawn(id: id1, plan: plan)
        _ = try await reg.resumeOrSpawn(id: id2, plan: plan)
        _ = try await reg.resumeOrSpawn(id: id3, plan: plan)   // forces LRU evict of id1
        let count = await reg.liveCount()
        XCTAssertEqual(count, 2, "live hosts must stay capped at 2")
        let hasId1 = await reg.hasLiveHost(id1)
        XCTAssertFalse(hasId1, "oldest (id1) must be LRU-suspended")
        let hasId3 = await reg.hasLiveHost(id3)
        XCTAssertTrue(hasId3, "newest (id3) must be live")
        await reg.suspend(id2); await reg.suspend(id3)
    }
}
