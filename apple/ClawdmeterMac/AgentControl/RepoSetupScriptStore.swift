import Foundation

/// Per-repo **Setup Script** (Conductor parity).
///
/// A shell command the user configures once per repo that runs INSIDE each
/// freshly-provisioned worktree, before the agent starts — e.g.
/// `npm install`, `pnpm i`, `cp "$CONTINUUM_REPO_ROOT/.env" .`, or
/// `ln -s "$CONTINUUM_REPO_ROOT/node_modules" node_modules`.
///
/// **Why app config, not a committed repo file:** storing the script in the
/// user's own defaults (keyed by canonical repo root) — rather than reading a
/// `.continuum/setup` checked into the repo — means cloning or opening a
/// hostile repo can never auto-execute a script the user didn't write. The
/// user opts in per repo via the New Session sheet. This matches Conductor,
/// which keeps the setup script in its app database, not in the worktree.
enum RepoSetupScriptStore {
    static let defaultsKey = "clawdmeter.repos.setupScript"

    /// The configured setup script for `repoRoot`, or `nil` when unset/blank.
    static func script(forRepoRoot repoRoot: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let raw = map[canonicalize(repoRoot)]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    /// Persist (or clear, when blank) the setup script for `repoRoot`.
    static func setScript(_ script: String?, forRepoRoot repoRoot: String) {
        var map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let key = canonicalize(repoRoot)
        let trimmed = script?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = trimmed
        }
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    /// Normalize the key so `~`, `..`, and trailing slashes don't fork the
    /// stored entry. Matches how callers pass the repo root (an absolute path).
    private static func canonicalize(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}
