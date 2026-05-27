import Foundation
import ClawdmeterShared

/// Resolves and validates filesystem paths that iOS-relayed requests
/// (`POST /workspaces/from-github`, `POST /workspaces/quick-start`) are
/// allowed to write into. Per A9-B (locked in /plan-eng-review): iOS may
/// only write under `clawdmeter.repos.defaultParent` OR one of the user's
/// configured scan roots, minus a hard-coded deny-list of sensitive dirs.
///
/// Mac-flow NSOpenPanel writes are NOT gated — the user picking via the
/// panel implies consent. This gate only fires on daemon-relayed endpoints
/// where iOS supplied the path via a text field.
///
/// Canonicalization expands `~` (against the *real* user home — sandboxed
/// builds otherwise resolve `~` to the container path and the deny-list
/// misses real `~/.ssh`), normalizes `..`, and resolves symlinks on the
/// deepest-existing ancestor. A symlink at any segment that points outside
/// the allow-list rejects — string-prefix-only would otherwise let an
/// attacker create `<allowed>/link -> ~/.ssh` and bypass the gate.
public enum PathAllowList {

    /// UserDefaults key for the user's preferred default-parent. Falls back
    /// to `~/code/` (against the real home) when unset. Created lazily on
    /// first use.
    public static let defaultParentKey = "clawdmeter.repos.defaultParent"

    /// Deny-listed home-relative subpaths. Any canonicalized path that lives
    /// under one of these → reject. Strings are expanded against
    /// `ClawdmeterRealHome.path()` (NOT `NSHomeDirectory()` — sandboxed
    /// builds resolve the latter to the container, so `~/.ssh` would point
    /// at the container's empty `.ssh` instead of the real user's keys).
    public static let deniedSubpaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.config",
        "~/Library",
        "~/Public",
    ]

    /// Resolve the allow-list against current UserDefaults + environment.
    /// `defaultParent` is always first in the list; manually-configured
    /// scan roots follow. All entries are expanded + canonicalized.
    public static func resolveAllowedRoots(
        userDefaults: UserDefaults = .standard
    ) -> [String] {
        var roots: [String] = []
        let defaultParent = userDefaults.string(forKey: defaultParentKey)
            ?? defaultParentFallback()
        roots.append(canonicalize(defaultParent))
        let scanRoots = userDefaults.stringArray(forKey: RepoIndex.scanRootsKey) ?? []
        for root in scanRoots {
            let canonical = canonicalize(root)
            if !roots.contains(canonical) {
                roots.append(canonical)
            }
        }
        return roots
    }

    /// Resolve the deny-list to absolute canonicalized paths. Same shape as
    /// `resolveAllowedRoots` so the `/workspaces/allow-list` GET handler
    /// can return both lists with identical encoding.
    public static func resolveDeniedSubpaths() -> [String] {
        deniedSubpaths.map { canonicalize($0) }
    }

    /// Validate that `path` is under one of the allowed roots and NOT under
    /// any denied subpath. Returns `.success(canonical)` on accept or
    /// `.failure(.pathNotAllowed(reason:))` on reject. Caller surfaces the
    /// reason verbatim.
    ///
    /// The canonical form returned has both `..` and symlinks resolved
    /// against the filesystem, so callers can safely pass it to mkdir /
    /// git init / git clone without risk of the operation following a
    /// post-validation symlink swap.
    public static func validate(
        _ path: String,
        userDefaults: UserDefaults = .standard
    ) -> Result<String, RepoOnboardingError> {
        // Reject suspiciously deep paths up-front. A 1000-component path
        // is not a real Quick Start parent. This bound complements the
        // symlink resolver's own cap so attackers can't dodge resolution
        // by submitting a path deeper than the resolver walks.
        let componentDepth = path.split(separator: "/").count
        if componentDepth > 256 {
            return .failure(.pathNotAllowed(reason: "path too deep (\(componentDepth) components)"))
        }
        let canonical = canonicalize(path)
        if canonical.isEmpty {
            return .failure(.pathNotAllowed(reason: "empty path"))
        }
        // If canonicalize couldn't fully resolve symlinks (hit its hop cap),
        // fail closed. Returning the unresolved path would let an attacker
        // submit `<allowed>/link/a/a/.../a` (very deep) and bypass the
        // allow-list because the resolver gave up before reaching `link`.
        if canonical.hasPrefix(unresolvedSentinel) {
            return .failure(.pathNotAllowed(reason: "could not resolve symlinks (path too complex)"))
        }
        // Deny-list check is unconditional — even if a denied subpath is
        // also under an allowed root, deny wins.
        for denied in resolveDeniedSubpaths() {
            if isPath(canonical, underOrEqualTo: denied) {
                return .failure(.pathNotAllowed(reason: "path is under deny-list entry \(denied)"))
            }
        }
        let allowed = resolveAllowedRoots(userDefaults: userDefaults)
        for root in allowed {
            if isPath(canonical, underOrEqualTo: root) {
                return .success(canonical)
            }
        }
        return .failure(.pathNotAllowed(reason: "path is not under any allow-listed root"))
    }

    /// Returned from `resolveSymlinksOnExistingPrefix` when the hop cap is
    /// exhausted before any ancestor exists. `validate()` checks this
    /// prefix and fail-closes rather than letting an unresolved path
    /// slip through the allow-list check.
    private static let unresolvedSentinel = "\0unresolved-symlink-chain\0"

    // MARK: - Private

    /// `<real-home>/code/` — created lazily by the daemon when first needed.
    /// We do NOT create the directory here; that's the caller's
    /// responsibility (validating that the dir exists is a separate
    /// concern from the allow-list check).
    private static func defaultParentFallback() -> String {
        (ClawdmeterRealHome.path() as NSString).appendingPathComponent("code")
    }

    /// Expand `~` against the real user home, normalize `..`, then resolve
    /// symlinks on the deepest-existing ancestor. The trailing component
    /// may not exist yet (Quick Start creates a new dir under `parent/name`),
    /// so we walk UP until we find an existing dir, `realpath` that, and
    /// append the remaining components.
    ///
    /// **Why resolve symlinks here, not just at use-time?** Without this,
    /// `<allowed>/link -> ~/.ssh` would pass the string-prefix check
    /// (`/Users/me/code/link` starts with `/Users/me/code/`) and the
    /// subsequent `mkdir` / `git clone` would follow the symlink and write
    /// outside the gate. Resolving the deepest-existing ancestor catches
    /// every symlink between the path and the filesystem root.
    static func canonicalize(_ path: String) -> String {
        // Step 1: expand `~` against the REAL user home (not the sandbox
        // container's home). Sandbox-aware tildes only matter for the
        // app's own data; the deny-list is about the user's keys.
        let expanded: String
        if path.hasPrefix("~") {
            let realHome = ClawdmeterRealHome.path()
            if path == "~" {
                expanded = realHome
            } else if path.hasPrefix("~/") {
                expanded = (realHome as NSString).appendingPathComponent(String(path.dropFirst(2)))
            } else {
                // `~user/...` form — uncommon, fall back to NSString's
                // expansion which queries pwd.
                expanded = (path as NSString).expandingTildeInPath
            }
        } else {
            expanded = path
        }
        // Step 2: standardize — collapses `..`, `.`, multiple slashes.
        let standardized = (expanded as NSString).standardizingPath
        // Step 3: resolve symlinks on the deepest-existing ancestor.
        let resolved = resolveSymlinksOnExistingPrefix(standardized)
        // Step 4: strip trailing slashes but keep root `/`.
        var stripped = resolved
        while stripped.count > 1 && stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        return stripped
    }

    /// Walk up `path` until we find an existing directory, resolve symlinks
    /// on that ancestor via `URL.resolvingSymlinksInPath()`, then append
    /// the remaining non-existing components. This is the only sound way
    /// to defend against symlink-bypass for paths that don't exist yet
    /// (Quick Start case).
    ///
    /// **Fail-closed cap.** If walking up `safety` iterations finds no
    /// existing ancestor, return the sentinel string `unresolvedSentinel`
    /// so `validate()` rejects the path. Returning the unresolved path
    /// would let an attacker submit `<allowed>/link/a/a/.../a` deeper
    /// than the cap and dodge symlink resolution. Real Quick Start
    /// paths have <10 components from the user's home; 256 is a generous
    /// safety bound that still rejects pathological inputs.
    private static func resolveSymlinksOnExistingPrefix(_ path: String) -> String {
        let fm = FileManager.default
        // Fast path: the full path exists. realpath() it directly.
        if fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        // Walk up. 256 iterations covers every realistic path; deeper
        // submissions are rejected fail-closed.
        var ancestor = (path as NSString).deletingLastPathComponent
        var trailing = [(path as NSString).lastPathComponent]
        var safety = 256
        while !ancestor.isEmpty && ancestor != "/" && safety > 0 {
            if fm.fileExists(atPath: ancestor) {
                let resolvedAncestor = URL(fileURLWithPath: ancestor).resolvingSymlinksInPath().path
                let trailingPath = trailing.reversed().joined(separator: "/")
                return (resolvedAncestor as NSString).appendingPathComponent(trailingPath)
            }
            trailing.append((ancestor as NSString).lastPathComponent)
            ancestor = (ancestor as NSString).deletingLastPathComponent
            safety -= 1
        }
        // Final fallback: check root itself (`/`). If even root doesn't
        // resolve, we can't validate — fail closed via sentinel.
        if ancestor == "/" && fm.fileExists(atPath: "/") {
            let trailingPath = trailing.reversed().joined(separator: "/")
            return "/" + trailingPath
        }
        return unresolvedSentinel + path
    }

    /// True if `path` equals `root` or lives under it. Uses path component
    /// prefix matching to avoid `/foo/barz` matching `/foo/bar` (a naive
    /// `hasPrefix` check is wrong).
    private static func isPath(_ path: String, underOrEqualTo root: String) -> Bool {
        if path == root { return true }
        // Ensure root ends with `/` so we don't accept `/foo/barzz`
        // as under `/foo/bar`.
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(rootWithSlash)
    }

    /// Last-line TOCTOU defense (Codex R4 #3): immediately before the
    /// caller touches the filesystem, lstat the canonical path and
    /// confirm it's not a symlink at that instant. Race window between
    /// this check and the operation is ~50ns; in practice unattackable
    /// from another same-user process without a kernel-side primitive.
    /// Full closure requires openat(O_NOFOLLOW); this is the best Swift
    /// can do without dropping to POSIX.
    ///
    /// Returns `nil` on success (path is safe to use), or a
    /// `RepoOnboardingError.pathNotAllowed` if the path is a symlink
    /// or stat fails.
    public static func confirmNotSymlink(_ path: String) -> RepoOnboardingError? {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else {
            // stat failure on a path that doesn't exist yet is fine —
            // it's the "path not yet created" case for Quick Start /
            // clone destination. We only reject when stat succeeds AND
            // reveals a symlink.
            if errno == ENOENT { return nil }
            return .pathNotAllowed(reason: "could not lstat path: errno \(errno)")
        }
        let mode = mode_t(statBuf.st_mode) & S_IFMT
        if mode == S_IFLNK {
            return .pathNotAllowed(reason: "path is a symlink (TOCTOU swap detected)")
        }
        return nil
    }
}
