import Foundation

/// Shared release/update configuration for the Mac updater, release
/// scripts, and tests. Sparkle is the primary update detector; GitHub
/// Releases remains the browser fallback and public asset host.
enum ReleaseUpdateConfig {
    static let owner = "darshanbathija"
    static let repo = "Continuum"
    static let appName = "Continuum"
    static let bundleIdentifier = "ai.continuum.mac"
    static let minimumSystemVersion = "26.0"
    static let tagPrefix = "v"
    static let tagSuffix = "-mac"
    static let releaseAssetPrefix = "Continuum"
    static let pagesBaseURL = URL(string: "https://darshanbathija.github.io/Continuum")!
    static let appcastPath = "updates/appcast.xml"
    static let releaseHistoryPath = "updates/history.json"
    static let releaseNotesPath = "updates/release-notes"

    /// Browser URL for manual recovery. `/releases/latest` redirects to
    /// the newest public release and avoids baking a possibly stale tag
    /// into failure UI.
    static var releasesLatestURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    /// Kept for release automation diagnostics and compatibility tests.
    /// Runtime update detection does not poll this endpoint anymore.
    static var releasesLatestAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    static var appcastURL: URL {
        pagesBaseURL.appendingPathComponent(appcastPath)
    }

    static var releaseHistoryURL: URL {
        pagesBaseURL.appendingPathComponent(releaseHistoryPath)
    }

    static func releaseTagURL(version: String) -> URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(releaseTag(version: version))")!
    }

    static func releaseDownloadBaseURL(version: String) -> URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(releaseTag(version: version))/")!
    }

    static func releaseNotesURL(version: String) -> URL {
        pagesBaseURL
            .appendingPathComponent(releaseNotesPath)
            .appendingPathComponent("\(version).md")
    }

    static func releaseTag(version: String) -> String {
        "\(tagPrefix)\(version)\(tagSuffix)"
    }

    /// Parse the Mac release tag pattern `v<MAJOR>.<MINOR>.<PATCH>-mac`
    /// into a plain semver string. Channel suffixes are intentionally
    /// rejected until beta/nightly feeds are explicitly designed.
    static func parseVersion(fromTag tag: String) -> String? {
        guard tag.hasPrefix(tagPrefix), tag.hasSuffix(tagSuffix) else { return nil }
        let withoutPrefix = String(tag.dropFirst(tagPrefix.count))
        let withoutSuffix = String(withoutPrefix.dropLast(tagSuffix.count))
        guard !withoutSuffix.isEmpty else { return nil }
        let components = withoutSuffix.split(separator: ".")
        guard components.count == 3,
              components.allSatisfy({ Int($0) != nil })
        else { return nil }
        return withoutSuffix
    }

    /// Numeric semver comparison. `0.23.10 > 0.23.9` correctly
    /// while preserving the existing three-part release contract.
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

/// Compatibility alias for older tests/docs that still name the old
/// GitHub-only checker. New code should use `ReleaseUpdateConfig`.
typealias GitHubReleaseConstants = ReleaseUpdateConfig

struct ReleaseHistoryEntry: Codable, Equatable, Identifiable {
    var id: String { version }
    let version: String
    let build: String?
    let title: String
    let publishedAt: Date?
    let notesURL: URL?

    init(
        version: String,
        build: String? = nil,
        title: String,
        publishedAt: Date? = nil,
        notesURL: URL? = nil
    ) {
        self.version = version
        self.build = build
        self.title = title
        self.publishedAt = publishedAt
        self.notesURL = notesURL
    }
}
