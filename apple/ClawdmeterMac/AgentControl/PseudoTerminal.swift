import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
// On Linux: openpty(3) lives in libutil (not Glibc proper). The linux/
// package adds a `CLibUtil` system-shim module map that exports
// <pty.h> + `link "util"`. Phase 2's daemon move (T5) is what brings
// this file into shared; until then `#elseif canImport(Glibc)` here
// just documents the Linux story.
import Glibc
import CLibUtil
#endif

/// Minimal pseudo-terminal helper. Wraps `openpty(3)` and `forkpty`-style
/// process spawning so we can run interactive subprocesses (like `tmux -CC`)
/// that insist on a real tty on stdin.
///
/// Phase 2's `TmuxControlClient` will reuse this in the main app — Foundation's
/// `Process` standardInput/Output expect Pipes or FileHandles, and a plain
/// Pipe trips `tcgetattr: Operation not supported by device` from tmux.
public final class PseudoTerminal {

    /// File descriptor for the master side of the PTY. Read from this to
    /// receive the subprocess's stdout/stderr; write to this to send input
    /// (keystrokes) to the subprocess.
    public let masterFD: Int32

    /// File descriptor for the slave side. Becomes the subprocess's
    /// stdin/stdout/stderr (we dup it 3x in the child).
    public let slaveFD: Int32

    public init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        let result = openpty(&master, &slave, nil, nil, nil)
        guard result == 0 else {
            throw NSError(domain: "PseudoTerminal", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed: \(String(cString: strerror(errno)))"])
        }
        self.masterFD = master
        self.slaveFD = slave
    }

    deinit {
        if masterFD >= 0 { close(masterFD) }
        if slaveFD >= 0 { close(slaveFD) }
    }

    /// Spawn a subprocess with the slave side of this PTY as its stdin/stdout/stderr.
    /// Returns the child PID. Caller is responsible for waitpid().
    ///
    /// We use `posix_spawn` rather than Foundation.Process because Process's
    /// stdio plumbing assumes pipes; wiring a PTY's slave fd as all three
    /// streams (with the right `setsid` + controlling-tty semantics) is what
    /// `forkpty(3)` would do — we approximate with posix_spawn + file actions.
    public func spawn(executable: String, arguments: [String], environment: [String: String]? = nil) throws -> pid_t {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { ptr in if let p = ptr { free(p) } } }

        let envDict = environment ?? ProcessInfo.processInfo.environment
        let envv: [UnsafeMutablePointer<CChar>?] =
            envDict.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envv.forEach { ptr in if let p = ptr { free(p) } } }

        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Dup slave fd to stdin (0), stdout (1), stderr (2)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, 0)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, 2)
        // Close the slave fd in the child after dup'ing.
        posix_spawn_file_actions_addclose(&fileActions, slaveFD)
        // Close the master fd in the child — only parent needs it.
        posix_spawn_file_actions_addclose(&fileActions, masterFD)

        var attrs = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // Make the child a session leader and acquire the controlling tty.
        // POSIX_SPAWN_SETSID is the equivalent of setsid() in the child.
        let flags: Int16 = Int16(POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&attrs, flags)

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attrs,
                                      argv.map { $0.map(UnsafeMutablePointer.init) }, envv)
        guard spawnResult == 0 else {
            throw NSError(domain: "PseudoTerminal", code: Int(spawnResult),
                          userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(Int32(spawnResult))))"])
        }
        // Close the slave end in the parent — only the child needs it.
        close(slaveFD)
        return pid
    }
}
