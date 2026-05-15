import Foundation
import Darwin
import TmuxControlMode

// tmux-cc-probe: Phase 0 sanity probe for the Sessions feature.
//
// Spawns `tmux -CC -L probe new-session -d` over a real pseudo-terminal,
// parses its control-mode output for a battery of cases, and reports pass/fail
// per criterion.
//
// The unit tests (TmuxControlModeTests) already cover the parser logic
// hermetically. This probe is the live-integration sanity check: does our
// parser shape match what tmux actually emits? Phase 2 lifts the parser +
// PTY helper into ClawdmeterMac.
//
// Run: `cd tools/tmux-cc-probe && swift run tmux-cc-probe`

let tmuxBinary = "/opt/homebrew/bin/tmux"
let socketName = "clawdmeter-probe-\(getpid())"

func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func runProbe() -> Int32 {
    log("=== tmux-cc-probe: Phase 0 sanity probe ===")
    log("tmux binary: \(tmuxBinary)")
    log("socket name: \(socketName)")

    guard FileManager.default.isExecutableFile(atPath: tmuxBinary) else {
        log("FAIL: tmux not executable at \(tmuxBinary)")
        return 1
    }

    // Open a PTY. tmux -CC requires its stdin be a tty (it calls tcgetattr).
    let pty: PseudoTerminal
    do {
        pty = try PseudoTerminal()
    } catch {
        log("FAIL: openpty failed: \(error)")
        return 2
    }
    log("PTY master fd=\(pty.masterFD) slave fd=\(pty.slaveFD)")

    // Spawn tmux -CC over the PTY.
    let pid: pid_t
    do {
        // `-C` (single C) is plain control mode. `-CC` (double C) wraps every
        // line in iTerm2's DCS escape envelope (`\eP1000p…\e\\`) — useful
        // when running tmux INSIDE iTerm2, but it adds parsing surface we
        // don't need. Stick with single `-C`. Phase 2 lifts the same choice.
        pid = try pty.spawn(
            executable: tmuxBinary,
            arguments: [
                "-C",
                "-L", socketName,
                "new-session", "-A", "-s", "probe-session",
                "--", "/bin/bash", "-l",
            ]
        )
    } catch {
        log("FAIL: posix_spawn tmux failed: \(error)")
        return 3
    }
    log("spawned tmux pid \(pid)")

    // Drain the PTY master fd in a background queue.
    var parser = ControlModeParser()
    let frameLock = NSLock()
    var allFrames: [ControlModeFrame] = []

    let readQueue = DispatchQueue(label: "tmux-cc-probe.read")
    readQueue.async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(pty.masterFD, &buffer, buffer.count)
            if n <= 0 { break }  // EOF / error
            frameLock.lock()
            parser.feed(buffer[0..<n])
            while let frame = parser.nextFrame() {
                allFrames.append(frame)
            }
            frameLock.unlock()
        }
    }

    Thread.sleep(forTimeInterval: 0.6)

    var passed = 0
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            log("PASS  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            passed += 1
        } else {
            log("FAIL  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            failed += 1
        }
    }

    func snapshotFrames() -> [ControlModeFrame] {
        frameLock.lock()
        let copy = allFrames
        frameLock.unlock()
        return copy
    }

    // ---- C1: initial control-mode frames received ----
    let initialFrames = snapshotFrames()
    check("C1 initial frames received", !initialFrames.isEmpty,
          "got \(initialFrames.count) frames")

    if initialFrames.isEmpty {
        kill(pid, SIGKILL)
        return 4
    }

    // ---- C2: %begin and %end pair appears for the implicit new-session ----
    let hasBegin = initialFrames.contains { if case .begin = $0 { return true } else { return false } }
    let hasEnd = initialFrames.contains { if case .end = $0 { return true } else { return false } }
    check("C2 %begin/%end emitted", hasBegin && hasEnd)

    // ---- C3: send a tmux command via PTY master + observe response cycle ----
    let beforeCount = snapshotFrames().count
    let cmd = "list-sessions -F '#{session_name}'\n"
    let cmdBytes = Array(cmd.utf8)
    _ = cmdBytes.withUnsafeBufferPointer { buf in
        write(pty.masterFD, buf.baseAddress, buf.count)
    }
    Thread.sleep(forTimeInterval: 0.4)
    let afterCount = snapshotFrames().count
    check("C3 command response cycle", afterCount > beforeCount,
          "frame count \(beforeCount) → \(afterCount)")

    // ---- C4: kill-server (out-of-band) and observe %exit ----
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: tmuxBinary)
    kill.arguments = ["-L", socketName, "kill-server"]
    kill.standardOutput = Pipe()
    kill.standardError = Pipe()
    do {
        try kill.run()
        kill.waitUntilExit()
    } catch {
        log("note: kill-server invocation: \(error)")
    }

    Thread.sleep(forTimeInterval: 0.5)
    let finalFrames = snapshotFrames()
    let hasExit = finalFrames.contains { if case .exit = $0 { return true } else { return false } }
    check("C4 %exit emitted after kill-server", hasExit)

    // ---- C5: parser produced ≥50% known-directive coverage ----
    let unknownCount = finalFrames.compactMap { frame -> String? in
        if case .unknown(let raw) = frame { return raw }
        return nil
    }
    let unknownRatio = finalFrames.isEmpty ? 0.0 : Double(unknownCount.count) / Double(finalFrames.count)
    check("C5 known-directive coverage ≥50%", unknownRatio < 0.5,
          "unknown=\(unknownCount.count)/\(finalFrames.count) (\(Int(unknownRatio * 100))%)")
    if !unknownCount.isEmpty {
        log("      unknown directives (informational):")
        for u in Set(unknownCount).prefix(10) {
            log("        \(u)")
        }
    }

    // ---- C6: tmux exits cleanly after kill-server ----
    // Give the child time to terminate and reap it.
    var status: Int32 = 0
    var reaped = false
    for _ in 0..<10 {
        if waitpid(pid, &status, WNOHANG) == pid {
            reaped = true
            break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if !reaped {
        Darwin.kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
    }
    let exitStatus: Int32 = (status >> 8) & 0xFF
    check("C6 tmux -CC exited cleanly", reaped && (exitStatus == 0 || exitStatus == 1),
          "reaped=\(reaped) exit=\(exitStatus)")

    log("")
    log("=== Probe summary: \(passed) passed, \(failed) failed ===")
    log("Total frames decoded: \(finalFrames.count)")

    // Cleanup: best-effort kill of any leftover server.
    let cleanup = Process()
    cleanup.executableURL = URL(fileURLWithPath: tmuxBinary)
    cleanup.arguments = ["-L", socketName, "kill-server"]
    cleanup.standardOutput = Pipe()
    cleanup.standardError = Pipe()
    try? cleanup.run()
    cleanup.waitUntilExit()

    return failed == 0 ? 0 : 5
}

exit(runProbe())
