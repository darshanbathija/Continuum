#if canImport(SwiftUI)
import Foundation

public enum TahoeCodeProjectList {
    public static func collapseDuplicateVisibleNames(
        _ repos: [TahoeCodeRepo],
        recentLimit: Int = 4
    ) -> [TahoeCodeRepo] {
        var output: [TahoeCodeRepo] = []
        var indexByVisibleName: [String: Int] = [:]

        for repo in repos {
            let visibleKey = normalizedVisibleName(repo.name)
            let dedupeKey = visibleKey.isEmpty ? repo.key.lowercased() : visibleKey

            guard let existingIndex = indexByVisibleName[dedupeKey] else {
                indexByVisibleName[dedupeKey] = output.count
                output.append(repo)
                continue
            }

            var merged = output[existingIndex]
            merged.liveSessionCount += repo.liveSessionCount
            merged.sessions = appendUniqueSessions(merged.sessions, repo.sessions)
            merged.recents = Array(appendUniqueRecents(merged.recents, repo.recents).prefix(recentLimit))
            output[existingIndex] = merged
        }

        return output
    }

    private static func normalizedVisibleName(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func appendUniqueSessions(
        _ existing: [TahoeCodeSession],
        _ incoming: [TahoeCodeSession]
    ) -> [TahoeCodeSession] {
        var seen = Set(existing.map(\.id))
        var merged = existing
        for session in incoming where !seen.contains(session.id) {
            seen.insert(session.id)
            merged.append(session)
        }
        return merged
    }

    private static func appendUniqueRecents(
        _ existing: [TahoeCodeRecent],
        _ incoming: [TahoeCodeRecent]
    ) -> [TahoeCodeRecent] {
        var seen = Set(existing.map(\.id))
        var merged = existing
        for recent in incoming where !seen.contains(recent.id) {
            seen.insert(recent.id)
            merged.append(recent)
        }
        return merged
    }
}
#endif
