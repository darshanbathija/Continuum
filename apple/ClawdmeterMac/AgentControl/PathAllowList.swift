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
        let canonical = canonicalize(path)
        if canonical.isEmpty {
            return .failure(.pathNotAllowed(reason: "empty path"))
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
    private static func resolveSymlinksOnExistingPrefix(_ path: String) -> String {
        let fm = FileManager.default
        // Fast path: the full path exists. realpath() it directly.
        if fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        // Walk up. Cap at 64 iterations to bound pathological inputs.
        var ancestor = (path as NSString).deletingLastPathComponent
        var trailing = [(path as NSString).lastPathComponent]
        var safety = 64
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
        // Nothing along the chain exists. Return the standardized path
        // as-is — the operation will fail downstream when it tries to
        // mkdir / write, and the validate() prefix check still uses the
        // canonicalized form against the resolved roots.
        return path
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
}
