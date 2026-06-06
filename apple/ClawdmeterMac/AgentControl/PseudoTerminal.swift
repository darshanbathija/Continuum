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
/// process spawning so we can run interactive subprocesses (like `claude` or
/// an interactive shell) that insist on a real tty on stdin.
///
/// `ClaudePtyHost` and `TerminalPtyHost` reuse it for per-session interactive
/// processes. Foundation's `Process` standardInput/Output expect Pipes or
/// FileHandles, and a plain Pipe makes Claude's Ink TUI refuse to render.
public final class PseudoTerminal {

    /// File descriptor for the master side of the PTY. Read from this to
    /// receive the subprocess's stdout/stderr; write to this to send input
    /// (keystrokes) to the subprocess.
    public private(set) var masterFD: Int32

    /// File descriptor for the slave side. Becomes the subprocess's
    /// stdin/stdout/stderr (we dup it 3x in the child).
    public private(set) var slaveFD: Int32

    /// Create the PTY pair with an initial window size.
    ///
    /// **Why the winsize matters (Track A).** A PTY created with a 0×0 / unset
    /// size makes Claude's Ink TUI render against a zero-column terminal — the
    /// composer is suppressed, the trust-folder warmup scraper sees nothing,
    /// and the first paste lands nowhere. A raw PTY must set it explicitly.
    /// We pass the size straight to `openpty`'s
    /// winsize argument so it's correct from the first byte (no follow-up
    /// `ioctl` race before the child execs).
    public init(cols: UInt16 = 120, rows: UInt16 = 40) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let result = openpty(&master, &slave, nil, nil, &ws)
        guard result == 0 else {
            throw NSError(domain: "PseudoTerminal", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed: \(String(cString: strerror(errno)))"])
        }
        self.masterFD = master
        self.slaveFD = slave
    }

    deinit {
        closeMaster()
        closeSlave()
    }

    public func closeMaster() {
        guard masterFD >= 0 else { return }
        let fd = masterFD
        masterFD = -1
        close(fd)
    }

    /// Relinquish ownership of the master fd WITHOUT closing it; returns the fd
    /// (or -1 if already closed/detached). The caller becomes responsible for
    /// `close()`.
    ///
    /// `ClaudePtyHost` uses this so its `DispatchSourceRead` cancel handler is
    /// the SOLE closer of the master fd: closing only after the source is fully
    /// cancelled guarantees an in-flight read handler can never `read()` a
    /// closed (or worse, recycled) fd. Detaching here stops `deinit`/`closeMaster`
    /// from double-closing the same fd number.
    @discardableResult
    public func detachMaster() -> Int32 {
        let fd = masterFD
        masterFD = -1
        return fd
    }

    public func closeSlave() {
        guard slaveFD >= 0 else { return }
        let fd = slaveFD
        slaveFD = -1
        close(fd)
    }

    /// Resize the terminal. The Terminal tab's RESIZE frames + any UI that
    /// rebinds a session to a different viewport need this so the child's
    /// SIGWINCH-driven relayout matches what the user sees.
    ///
    /// Uses the explicit `tiocswinsz` shim (below) rather than Swift's
    /// variadic `ioctl(_:_:_:)`, which is not callable from Swift.
    @discardableResult
    public func resize(cols: UInt16, rows: UInt16) -> Bool {
        guard masterFD >= 0 else { return false }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        return tiocswinsz(masterFD, &ws) == 0
    }

    /// Spawn a subprocess with the slave side of this PTY as its stdin/stdout/stderr.
    /// Returns the child PID. Caller is responsible for waitpid().
    ///
    /// We use `posix_spawn` rather than Foundation.Process because Process's
    /// stdio plumbing assumes pipes; wiring a PTY's slave fd as all three
    /// streams (with the right `setsid` + controlling-tty semantics) is what
    /// `forkpty(3)` would do — we approximate with posix_spawn + file actions.
    ///
    /// **`environment` is REQUIRED (no default).** A `nil`/defaulted env would
    /// inherit the daemon's full environment, which re-opens the billing leak
    /// `ClaudeSpawnEnv` exists to close: a stray `ANTHROPIC_API_KEY` would flow
    /// to the child and silently switch `claude` to pay-per-token. Every caller
    /// must decide its env explicitly; the Claude host passes
    /// `ClaudeSpawnEnv.sanitized()`.
    ///
    /// `cwd`, when non-nil, sets the child's working directory via
    /// `posix_spawn_file_actions_addchdir_np` — argv-only, no shell, so paths
    /// containing spaces (this repo's path does) can't break a shell `cd`.
    public func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String? = nil
    ) throws -> pid_t {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { ptr in if let p = ptr { free(p) } } }

        let envv: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envv.forEach { ptr in if let p = ptr { free(p) } } }

        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let masterFD = self.masterFD
        let slaveFD = self.slaveFD

        // Set the child's working directory before the dup2s. addchdir_np is
        // a file-action so it applies in the child only (no daemon-wide chdir
        // race). cwd-with-a-space is safe — no shell parsing involved.
        if let cwd {
            _ = cwd.withCString { posix_spawn_file_actions_addchdir_np(&fileActions, $0) }
        }

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
        closeSlave()
        return pid
    }
}

/// `ioctl(fd, TIOCSWINSZ, &ws)` is unreachable from Swift (variadic C). This
/// thin wrapper isolates the one call site. `TIOCSWINSZ` is imported as an
/// unsigned long; cast to `UInt` for the request slot.
@inline(__always)
private func tiocswinsz(_ fd: Int32, _ ws: inout winsize) -> Int32 {
    #if canImport(Darwin)
    return ioctl(fd, UInt(TIOCSWINSZ), &ws)
    #else
    return ioctl(fd, UInt(TIOCSWINSZ), &ws)
    #endif
}
