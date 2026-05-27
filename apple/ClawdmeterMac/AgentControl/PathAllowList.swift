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
/// Canonicalization uses `URL.standardizingFileURL` which resolves `..` and
/// `~` so attackers can't escape the allow-list via traversal. The deny-list
/// check happens after canonicalization, so `~/.ssh/../code` ends up as
/// `~/code` and is fine.
public enum PathAllowList {

    /// UserDefaults key for the user's preferred default-parent. Falls back
    /// to `~/code/` when unset. Created lazily on first use.
    public static let defaultParentKey = "clawdmeter.repos.defaultParent"

    /// Deny-listed home-relative subpaths. Any canonicalized path that lives
    /// under one of these → reject. Strings are expanded against
    /// `NSHomeDirectory()` before comparison.
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
    public static func validate(
        _ path: String,
        userDefaults: UserDefaults = .standard
    ) -> Result<String, RepoOnboardingError> {
        let canonical = canonicalize(path)
        // Empty input is an error class of its own.
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

    /// `~/code/` — created lazily by the daemon when first needed. We do
    /// NOT create the directory here; that's the caller's responsibility
    /// (validating that the dir exists is a separate concern from the
    /// allow-list check).
    private static func defaultParentFallback() -> String {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent("code")
    }

    /// Expand `~` and resolve `..` / symlinks via `standardizingPath`. We
    /// intentionally do NOT touch the filesystem (no `realpath`) because
    /// the path may not exist yet (Quick Start case — we're creating it).
    private static func canonicalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        // Strip trailing slashes but keep root `/`.
        var stripped = standardized
        while stripped.count > 1 && stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        return stripped
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
