import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The fs/terminal trust boundary for harness-driven agents (Phase 6).
///
/// When an ACP agent asks the client to read/write a file or run a terminal
/// command, the daemon must NOT blindly obey — `PathAllowList` (scoped to iOS
/// workspace onboarding) is insufficient. `RepoTrustGate` binds every fs/exec
/// request to a per-session **repo root** and validates it the safe way:
/// symlinks resolved, `..` collapsed, and the *canonical* result required to
/// sit at/under the root — defeating traversal (`../../etc/passwd`), absolute-
/// path escape, and symlink-escape (a `link → /etc` inside the repo). It is
/// TOCTOU-aware: it returns the resolved canonical path so the caller opens
/// THAT exact path (resolve-then-use), never re-resolving the attacker-supplied
/// string.
///
/// Pure value type (Foundation + POSIX `realpath` only) so it is fully unit-
/// testable without the daemon. The gate is advisory infrastructure: ACP fs/
/// terminal client capabilities are advertised ONLY for repos the user has
/// granted autopilot trust, and every authorized op flows through here first.
public struct RepoTrustGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Authorized. `resolvedPath` is the canonical absolute path the caller
        /// MUST use for the operation (do not re-resolve the original string).
        case allow(resolvedPath: String)
        case deny(reason: String)
    }

    public enum CommandDecision: Sendable, Equatable {
        case allow
        case deny(reason: String)
    }

    /// Canonical absolute repo root — the trust boundary.
    public let repoRoot: String
    /// Canonical absolute session cwd; relative paths resolve against it. Always
    /// at/under `repoRoot`.
    public let sessionCwd: String
    /// Byte cap on read / terminal output returned to the agent (anti-DoS).
    public let maxOutputBytes: Int

    /// Fails (nil) if the root/cwd can't be canonicalized or cwd is not under
    /// root — a gate that can't establish its boundary must not exist.
    public init?(repoRoot: String, sessionCwd: String? = nil, maxOutputBytes: Int = 2_000_000) {
        guard maxOutputBytes > 0 else { return nil }
        guard let root = Self.realpath(repoRoot) else { return nil }
        guard let cwd = Self.realpath(sessionCwd ?? repoRoot) else { return nil }
        guard Self.isAtOrUnder(cwd, root: root) else { return nil }
        self.repoRoot = root
        self.sessionCwd = cwd
        self.maxOutputBytes = maxOutputBytes
    }

    // MARK: - File access

    /// Authorize a read. The path must resolve (symlinks + `..`) to an EXISTING
    /// file at/under the root.
    public func authorizeRead(path: String) -> Decision {
        authorize(path: path, requireExisting: true)
    }

    /// Authorize a write. The path need not exist yet, but its parent chain
    /// must resolve to a location at/under the root (so you can't create a file
    /// outside via a symlinked parent or a `..` leaf).
    public func authorizeWrite(path: String) -> Decision {
        authorize(path: path, requireExisting: false)
    }

    private func authorize(path: String, requireExisting: Bool) -> Decision {
        guard !path.isEmpty else { return .deny(reason: "empty path") }
        guard !path.contains("\0") else { return .deny(reason: "NUL byte in path") }
        let abs = (path as NSString).isAbsolutePath
            ? path
            : (sessionCwd as NSString).appendingPathComponent(path)
        guard let resolved = Self.resolveSafe(abs) else {
            return .deny(reason: "unresolvable path")
        }
        guard Self.isAtOrUnder(resolved, root: repoRoot) else {
            return .deny(reason: "path escapes repo root")
        }
        if requireExisting {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
                return .deny(reason: "not an existing file")
            }
        }
        return .allow(resolvedPath: resolved)
    }

    // MARK: - Terminal commands

    /// Default-deny obviously destructive / privilege-escalating commands. The
    /// primary safety is the cwd binding (the caller spawns in `sessionCwd`) +
    /// the fs gate; this denylist is a coarse second line. Conservative on
    /// purpose — broaden via an explicit allowlist if a repo needs it.
    public func authorizeCommand(executable: String, arguments: [String]) -> CommandDecision {
        let exeBase = (executable as NSString).lastPathComponent.lowercased()
        // Block privilege escalation + shells that re-interpret quoting (which
        // would let an agent smuggle a denied command past argv inspection).
        let bannedExecutables: Set<String> = ["sudo", "doas", "su", "pkexec"]
        if bannedExecutables.contains(exeBase) {
            return .deny(reason: "privilege escalation is not permitted")
        }
        let joined = ([executable] + arguments).joined(separator: " ")
        let lower = joined.lowercased()
        // Catastrophic / out-of-cwd destructive patterns.
        let bannedSubstrings = [
            "rm -rf /", "rm -fr /", "rm -rf ~", "rm -rf /*",
            ":(){", "mkfs", "dd if=", "> /dev/sd", "of=/dev/",
            "shutdown", "reboot", "halt", "/etc/passwd", "/etc/shadow",
            "curl | sh", "wget | sh", "| bash", "| sh",
        ]
        for pat in bannedSubstrings where lower.contains(pat) {
            return .deny(reason: "command matches a blocked pattern: \(pat)")
        }
        return .allow
    }

    /// Truncate output to the byte cap (anti-DoS for huge reads / chatty
    /// commands). Returns the (possibly truncated) data + whether it was cut.
    public func cap(_ data: Data) -> (data: Data, truncated: Bool) {
        guard data.count > maxOutputBytes else { return (data, false) }
        return (data.prefix(maxOutputBytes), true)
    }

    // MARK: - Safe path resolution

    /// Resolve an absolute path to its canonical form: collapse `.`/`..`
    /// lexically, then resolve symlinks. For a path that doesn't exist yet
    /// (a write target), resolve symlinks on the longest existing ancestor and
    /// re-append the non-existent remainder — so a symlinked parent can't be
    /// used to escape the root, while still permitting new-file creation.
    static func resolveSafe(_ absPath: String) -> String? {
        let std = (absPath as NSString).standardizingPath
        guard std.hasPrefix("/") else { return nil }
        if let rp = realpath(std) { return rp }       // exists → fully resolved
        // Doesn't exist: realpath the longest existing ancestor + append rest.
        var comps = (std as NSString).pathComponents   // ["/", "a", "b", "c"]
        var remainder: [String] = []
        while comps.count > 1 {
            // Defense in depth: a `..` surviving standardizingPath (shouldn't
            // for absolute inputs) must never be appended onto a resolved root.
            if comps.last == ".." { return nil }
            let prefix = NSString.path(withComponents: comps)
            if let rp = realpath(prefix) {
                var result = rp
                for r in remainder.reversed() {
                    result = (result as NSString).appendingPathComponent(r)
                }
                return result
            }
            remainder.append(comps.removeLast())
        }
        return nil
    }

    /// Canonical-prefix containment. Both args are realpath output (no trailing
    /// slash), so a component-boundary prefix check is exact — `"/repo-evil"` is
    /// correctly NOT under `"/repo"`.
    static func isAtOrUnder(_ path: String, root: String) -> Bool {
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// POSIX `realpath(3)` — fully resolves symlinks; nil if the path (or an
    /// intermediate component) doesn't exist.
    static func realpath(_ path: String) -> String? {
        path.withCString { cstr -> String? in
            guard let resolved = Foundation.realpath(cstr, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
