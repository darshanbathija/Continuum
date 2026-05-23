import Foundation

/// Single source of truth for GitHub repository URLs and release
/// metadata used by the in-app update checker.
///
/// Centralizing here means a future repo rename touches one Swift
/// constant and one shell variable (in `tools/build-mac-dmg.sh`) —
/// the unit tests assert the URL formats so a typo during rename
/// fails the build instead of silently 404-ing the appcast.
enum GitHubReleaseConstants {
    static let owner = "darshanbathija"
    static let repo = "Clawdmeter"

    /// Browser URL — the user-facing "Open in Browser" fallback.
    /// `/releases/latest` 302-redirects to the most recent non-draft,
    /// non-prerelease release, which matches our shipping pattern.
    static var releasesLatestURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    /// JSON API URL — the daily check hits this and decodes
    /// `GitHubRelease`. Unauthenticated; 60 req/hr per IP budget.
    static var releasesLatestAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    /// Tag-scoped release page. Used if we ever want a version-derived
    /// fallback link; the always-on fallback uses `releasesLatestURL`.
    static func releaseTagURL(version: String) -> URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/v\(version)-mac")!
    }

    /// Parse the Mac release tag pattern `v<MAJOR>.<MINOR>.<PATCH>-mac`
    /// into a plain semver string. Returns nil for tags that don't
    /// match exactly (channel suffixes, linux tags, malformed) so the
    /// coordinator skips them rather than trying to chip an update
    /// the rest of the pipeline isn't ready for.
    static func parseVersion(fromTag tag: String) -> String? {
        guard tag.hasPrefix("v"), tag.hasSuffix("-mac") else { return nil }
        let withoutPrefix = String(tag.dropFirst())
        let withoutSuffix = String(withoutPrefix.dropLast("-mac".count))
        guard !withoutSuffix.isEmpty else { return nil }
        let components = withoutSuffix.split(separator: ".")
        guard components.count == 3,
              components.allSatisfy({ Int($0) != nil })
        else { return nil }
        return withoutSuffix
    }

    /// Numeric semver comparison. `0.23.10 > 0.23.9` correctly
    /// (lexicographic would give the opposite). Components beyond
    /// `MAJOR.MINOR.PATCH` are ignored. Non-numeric components fall
    /// back to `.orderedSame` so callers don't crash on garbage —
    /// the caller should have validated via `parseVersion(fromTag:)`.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai < bi { return .orderedAscending }
            if ai > bi { return .orderedDescending }
        }
        return .orderedSame
    }
}

/// Minimal Codable subset of GitHub's
/// `GET /repos/:owner/:repo/releases/latest` response. We only
/// consume what the chip + popover render; the API can add fields
/// freely without breaking decode.
struct GitHubRelease: Codable, Equatable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}
