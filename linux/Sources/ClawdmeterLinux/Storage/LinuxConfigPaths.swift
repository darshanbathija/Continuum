import Foundation

/// XDG Base Directory resolver — replaces macOS `Application Support` /
/// `Caches` paths for the Linux app.
///
/// Spec: https://specifications.freedesktop.org/basedir-spec/latest/
///
/// Replaces every macOS `~/Library/Application Support/Clawdmeter/...`
/// and `~/Library/Caches/...` reference for the Linux daemon + UI.
public enum LinuxConfigPaths {

    /// Audit P2 fix: per the XDG Base Directory spec, "If $XDG_DATA_HOME is
    /// either not set or empty, a default equal to $HOME/.local/share
    /// should be used … All paths set in these environment variables
    /// must be absolute. If an implementation encounters a relative
    /// path in any of these variables it should consider the path
    /// invalid and ignore it." Honor that by treating empty / relative
    /// values as if the var were unset.
    private static func xdgPath(env name: String, defaultPath: @autoclosure () -> String) -> String {
        let raw = ProcessInfo.processInfo.environment[name] ?? ""
        if raw.hasPrefix("/") { return raw }
        return defaultPath()
    }

    /// `$XDG_DATA_HOME/clawdmeter/` — persistent app data (audit logs,
    /// usage cache, sessions registry, attachments). Default: `~/.local/share/clawdmeter/`.
    public static var dataHome: URL {
        let base = xdgPath(env: "XDG_DATA_HOME", defaultPath: "\(NSHomeDirectory())/.local/share")
        return URL(fileURLWithPath: base).appendingPathComponent("clawdmeter", isDirectory: true)
    }

    /// `$XDG_CONFIG_HOME/clawdmeter/` — user prefs (prefs.json, autopilot
    /// trust list, ignored-extension prompts). Default: `~/.config/clawdmeter/`.
    public static var configHome: URL {
        let base = xdgPath(env: "XDG_CONFIG_HOME", defaultPath: "\(NSHomeDirectory())/.config")
        return URL(fileURLWithPath: base).appendingPathComponent("clawdmeter", isDirectory: true)
    }

    /// `$XDG_CACHE_HOME/clawdmeter/` — analytics cache, thumbnails.
    /// Default: `~/.cache/clawdmeter/`.
    public static var cacheHome: URL {
        let base = xdgPath(env: "XDG_CACHE_HOME", defaultPath: "\(NSHomeDirectory())/.cache")
        return URL(fileURLWithPath: base).appendingPathComponent("clawdmeter", isDirectory: true)
    }

    /// `$XDG_RUNTIME_DIR/clawdmeter/` — ephemeral runtime files (live gauge
    /// PNGs, pid files, daemon sockets). Falls back to `/tmp/clawdmeter-<uid>/`
    /// on systems that don't set XDG_RUNTIME_DIR.
    public static var runtimeDir: URL {
        let raw = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? ""
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).appendingPathComponent("clawdmeter", isDirectory: true)
        }
        let uid = getuid()
        return URL(fileURLWithPath: "/tmp").appendingPathComponent("clawdmeter-\(uid)", isDirectory: true)
    }

    /// Errors thrown by `ensureDirectory` when we can't get an owner-private
    /// directory at the requested path.
    public enum LinuxConfigPathError: Error {
        case unsafeOwnership(path: String)
        case statFailed(path: String, errno: Int32)
    }

    /// Ensures a directory exists with mode 0700 owned by the current uid.
    /// Throws on I/O failure or if the existing entry is a symlink, owned
    /// by another uid, OR has group/world write bits set (potential
    /// symlink attack on `/tmp` fallback paths).
    ///
    /// P1-Linux-5: when XDG_RUNTIME_DIR isn't set, runtimeDir falls back
    /// to `/tmp/clawdmeter-<uid>/`. `/tmp` is world-writable, so a local
    /// attacker can pre-create that path as a symlink to redirect daemon
    /// writes, or as a real directory with permissive bits. Validate
    /// ownership + mode + non-symlink before trusting the directory;
    /// refuse to use it otherwise.
    ///
    /// Codex follow-up: the earlier patch returned success silently on
    /// `lstat()` failure and never checked the actual mode bits. Both
    /// gaps are closed here: lstat errors now throw, and the post-create
    /// check rejects anything with group/world write bits set.
    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let path = url.path
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        // Post-conditions: not a symlink, owned by us, mode tight enough.
        // lstat(2) reports the link itself; stat(2) follows.
        var st = stat()
        if lstat(path, &st) != 0 {
            throw LinuxConfigPathError.statFailed(path: path, errno: errno)
        }
        let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
        let ownedByUs = st.st_uid == getuid()
        // Permission bits in the low 9 bits. Refuse anything with group
        // or world write set (0o022) — even an attacker-readable dir is
        // a leak vector for runtime files (live tokens, sockets, IPC).
        let groupOrWorldWrite = (mode_t(st.st_mode) & 0o022) != 0
        if isSymlink || !ownedByUs || groupOrWorldWrite {
            throw LinuxConfigPathError.unsafeOwnership(path: path)
        }
        return url
    }

    /// Convenience: usage cache JSON path. Matches Mac's
    /// `~/Library/Application Support/Clawdmeter/usage-store.json` shape.
    public static var usageStoreFile: URL {
        dataHome.appendingPathComponent("usage-store.json")
    }

    /// Convenience: analytics cache JSON path (schema v8).
    public static var analyticsCacheFile: URL {
        cacheHome.appendingPathComponent("analytics-cache.json")
    }

    /// Convenience: autopilot trust list (was ~/.clawdmeter/autopilot-trusted-repos.json).
    public static var autopilotTrustFile: URL {
        dataHome.appendingPathComponent("autopilot-trusted-repos.json")
    }

    /// Convenience: file-fallback bearer token (when Secret Service unavailable).
    public static var bearerTokenFile: URL {
        configHome.appendingPathComponent(".token")
    }

    /// Convenience: file-fallback OAuth token storage.
    public static var oauthTokenFile: URL {
        configHome.appendingPathComponent(".oauth-tokens.json")
    }

    /// Sessions registry path (was ~/.clawdmeter/sessions.json).
    public static var sessionsRegistryFile: URL {
        dataHome.appendingPathComponent("sessions.json")
    }

    /// Audit log directory (was ~/.clawdmeter/audit/).
    public static var auditLogDir: URL {
        dataHome.appendingPathComponent("audit", isDirectory: true)
    }

    /// Live gauge PNG dir (XDG_RUNTIME_DIR — tmpfs).
    public static var gaugePNGDir: URL {
        runtimeDir.appendingPathComponent("gauge", isDirectory: true)
    }
}
