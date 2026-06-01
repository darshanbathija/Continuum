import Foundation

/// Resolves the `PATH` that spawned agent panes run with.
///
/// **Why this exists:** Continuum is a GUI app launched by launchd/Finder, so
/// it inherits only launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`).
/// tmux panes we spawn for agents inherit that PATH, so the agent's own
/// tooling can't be found — most visibly, Claude Code's `node`-based
/// SessionStart hooks fail with `node: command not found` because Homebrew's
/// `/opt/homebrew/bin` isn't on the inherited PATH. (`claude`/`codex`/`tmux`
/// themselves still launch because `ShellRunner.locateBinary` resolves them by
/// absolute path — but the hooks the agent runs rely on PATH.)
///
/// We resolve the user's real login-shell PATH once per process and reuse it
/// for every spawn, with Homebrew dirs as a backstop.
enum SpawnPathResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    /// Common Mac CLI install dirs, always folded in as a backstop in case the
    /// login shell can't be read or omits them.
    private static let backstopDirs = [
        "/opt/homebrew/bin",   // Apple Silicon Homebrew (node, npm, …)
        "/usr/local/bin",      // Intel Homebrew / manual installs
    ]

    /// The enriched PATH string, computed once per process (login-shell read
    /// is ~100-300ms, so it's cached behind a lock).
    static func enrichedPATH() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let value = Self.compute(loginShell: Self.loginShellPATH())
        cached = value
        return value
    }

    /// Merge the enriched PATH into a spawn environment. A caller-supplied
    /// PATH keeps precedence for shadowed binaries (its dirs stay first); the
    /// enriched dirs are appended so node/npm/etc. remain discoverable.
    static func merged(into env: [String: String]) -> [String: String] {
        Self.merge(env: env, enriched: enrichedPATH())
    }

    // MARK: - Pure helpers (unit-testable; no process/IO)

    /// Build the ordered, de-duplicated PATH from the login-shell value (may be
    /// nil), the backstop dirs, and the current process PATH. Order matters:
    /// login-shell first (it's the user's intent), then backstops, then the
    /// minimal system dirs last.
    static func compute(loginShell: String?, processPATH: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        var dirs: [String] = []
        if let loginShell { dirs.append(contentsOf: split(loginShell)) }
        dirs.append(contentsOf: backstopDirs)
        if let processPATH { dirs.append(contentsOf: split(processPATH)) }
        return dedup(dirs).joined(separator: ":")
    }

    /// Append enriched dirs to a caller PATH (caller wins for shadowed names),
    /// or set the enriched PATH outright when the caller supplied none.
    static func merge(env: [String: String], enriched: String) -> [String: String] {
        var env = env
        if let existing = env["PATH"], !existing.isEmpty {
            var seen = Set(split(existing))
            let appended = split(enriched).filter { seen.insert($0).inserted }
            env["PATH"] = appended.isEmpty ? existing : existing + ":" + appended.joined(separator: ":")
        } else {
            env["PATH"] = enriched
        }
        return env
    }

    private static func split(_ path: String) -> [String] {
        path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func dedup(_ dirs: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for dir in dirs where !dir.isEmpty && seen.insert(dir).inserted {
            ordered.append(dir)
        }
        return ordered
    }

    // MARK: - Login-shell read

    /// Run the user's login shell to print its PATH. Returns nil on any
    /// failure — the backstop dirs cover the common (Homebrew) case regardless.
    private static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-lc` runs a non-interactive login shell, which sources the profile
        // files (`.zprofile` / `.bash_profile`) where Homebrew's `shellenv`
        // and most PATH setup live.
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Guard against a hung shell profile: terminate after 4s. Normal
        // profiles print PATH and exit in well under that.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}
