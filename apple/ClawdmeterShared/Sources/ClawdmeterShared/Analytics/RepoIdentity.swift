import Foundation

/// Normalization + display helpers for the cwd-based repo keys. Lives behind
/// a type so future changes (e.g. `git remote`-derived display names) have
/// one site to update.
///
/// Per plan A12: case-preserving, NOT lowercased. Lowercasing would silently
/// merge two genuinely-different-by-case repos on macOS case-insensitive
/// volumes; ccusage doesn't lowercase either, so our totals stay aligned
/// with the user's terminal output.
public enum RepoIdentity {

    /// Normalize a raw `cwd` string into a stable `RepoKey`. Strips trailing
    /// `/`, resolves `~`. Returns `RepoKey.unknown` for empty / whitespace-only
    /// input.
    public static func normalize(_ rawCwd: String) -> RepoKey {
        let trimmed = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return RepoKey.unknown }

        // Resolve `~` against the current home directory. NSString gives us a
        // simple, dependency-free helper.
        let expanded = (trimmed as NSString).expandingTildeInPath

        // Strip trailing slashes but keep root `/` if that's literally the
        // entire string.
        var result = expanded
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Human-friendly short name. Last path component for absolute paths,
    /// or the original key for unknown / non-path values.
    public static func displayName(for key: RepoKey) -> String {
        if key == RepoKey.unknown { return "(unknown)" }

        let url = URL(fileURLWithPath: key)
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" {
            return key
        }
        return last
    }
}
