import Foundation

public enum RepoIdentityResolver {
    public static func badge(repoKey: String, displayName: String, remoteURL: String? = nil) -> RepoIdentityBadge {
        let normalizedKey = repoKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = normalizedKey.isEmpty ? "Repo" : URL(fileURLWithPath: normalizedKey).lastPathComponent
        let visibleName = name.isEmpty ? fallbackName : name
        let remote = parseRemote(remoteURL)
        return RepoIdentityBadge(
            repoKey: normalizedKey.isEmpty ? visibleName : normalizedKey,
            displayName: visibleName,
            symbol: symbol(for: visibleName, remote: remote),
            colorHex: colorHex(for: remote.map { "\($0.host)/\($0.slug)" } ?? (normalizedKey.isEmpty ? visibleName : normalizedKey)),
            remoteHost: remote?.host,
            remoteSlug: remote?.slug,
            iconURL: avatarURL(remote: remote),
            emoji: emoji(for: remote)
        )
    }

    public static func symbol(for displayName: String) -> String {
        symbol(for: displayName, remote: nil)
    }

    private static func symbol(for displayName: String, remote: (host: String, slug: String)?) -> String {
        if let host = remote?.host.lowercased() {
            if host.contains("github") { return "GH" }
            if host.contains("gitlab") { return "GL" }
            if host.contains("bitbucket") { return "BB" }
        }
        let words = displayName
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        let initials = words
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
        return initials.isEmpty ? "•" : initials
    }

    private static func avatarURL(remote: (host: String, slug: String)?) -> String? {
        guard let remote else { return nil }
        let owner = remote.slug.split(separator: "/").first.map(String.init)
        guard let owner, !owner.isEmpty else { return nil }
        let host = remote.host.lowercased()
        if host.contains("github") {
            return "https://github.com/\(owner).png?size=64"
        }
        if host.contains("gitlab") {
            return "https://gitlab.com/\(owner).png"
        }
        if host.contains("bitbucket") {
            return "https://bitbucket.org/\(owner)/avatar/64/"
        }
        return nil
    }

    private static func emoji(for remote: (host: String, slug: String)?) -> String? {
        guard let host = remote?.host.lowercased() else { return "📁" }
        if host.contains("github") { return "🐙" }
        if host.contains("gitlab") { return "🦊" }
        if host.contains("bitbucket") { return "🪣" }
        return "📁"
    }

    public static func colorHex(for key: String) -> String {
        let palette = [
            "#3B82F6", "#14B8A6", "#F97316", "#8B5CF6",
            "#22C55E", "#EC4899", "#F59E0B", "#06B6D4"
        ]
        let hash = key.utf8.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    public static func parseRemote(_ remoteURL: String?) -> (host: String, slug: String)? {
        guard let raw = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        if let url = URL(string: raw), let host = url.host {
            let slug = url.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: ".git", with: "")
            return slug.isEmpty ? nil : (host, slug)
        }

        if raw.hasPrefix("git@"),
           let at = raw.firstIndex(of: "@"),
           let colon = raw.firstIndex(of: ":") {
            let host = String(raw[raw.index(after: at)..<colon])
            let slug = raw[raw.index(after: colon)...]
                .replacingOccurrences(of: ".git", with: "")
            return slug.isEmpty ? nil : (host, slug)
        }

        return nil
    }
}
