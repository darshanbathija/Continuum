import Foundation

struct RepoFileMatch: Identifiable, Hashable, Sendable {
    var path: String
    var line: Int?
    var score: Int
    var isRecent: Bool

    var id: String { line.map { "\(path):\($0)" } ?? path }

    var subtitle: String {
        if let line {
            return "\(path):\(line)"
        }
        return path
    }
}

enum RepoFileSearch {
    static func parse(_ query: String) -> (needle: String, line: Int?, path: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":") else {
            return (trimmed.lowercased(), nil, trimmed.isEmpty ? nil : trimmed)
        }
        let after = trimmed[trimmed.index(after: colon)...]
        guard let line = Int(after), line > 0 else {
            return (trimmed.lowercased(), nil, trimmed.isEmpty ? nil : trimmed)
        }
        let path = String(trimmed[..<colon])
        return (path.lowercased(), line, path)
    }

    static func matchesWithGit(
        query: String,
        repoRoot: String,
        recents: [String],
        limit: Int = 160
    ) -> (matches: [RepoFileMatch], error: String?) {
        let loaded = gitFiles(repoRoot: repoRoot)
        guard loaded.error == nil else {
            return ([], loaded.error)
        }
        return (
            matches(
                query: query,
                files: loaded.files,
                recents: recents,
                limit: limit
            ),
            nil
        )
    }

    static func matches(
        query: String,
        files: [String],
        recents: [String],
        limit: Int = 160
    ) -> [RepoFileMatch] {
        let parsed = parse(query)
        let recentPaths = recents.compactMap { parse($0).path }.filter { files.contains($0) }
        let recentSet = Set(recentPaths)
        if parsed.needle.isEmpty {
            let recentMatches = unique(recentPaths).map {
                RepoFileMatch(path: $0, line: parsed.line, score: 10_000, isRecent: true)
            }
            let rest = files.filter { !recentSet.contains($0) }.prefix(max(0, limit - recentMatches.count)).map {
                RepoFileMatch(path: $0, line: parsed.line, score: 0, isRecent: false)
            }
            return Array((recentMatches + rest).prefix(limit))
        }

        return files.compactMap { path -> RepoFileMatch? in
            guard let score = fuzzyScore(needle: parsed.needle, path: path) else { return nil }
            return RepoFileMatch(
                path: path,
                line: parsed.line,
                score: score + (recentSet.contains(path) ? 1_000 : 0),
                isRecent: recentSet.contains(path)
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func gitFiles(repoRoot: String) -> (files: [String], error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot, "ls-files", "--cached", "--others", "--exclude-standard"]
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                return ([], stderr.isEmpty ? "git ls-files failed." : stderr)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return (text.split(separator: "\n").map(String.init).sorted(), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private static func fuzzyScore(needle: String, path: String) -> Int? {
        let haystack = path.lowercased()
        if haystack == needle { return 20_000 }
        if (path as NSString).lastPathComponent.lowercased() == needle { return 18_000 }
        if haystack.contains(needle) { return 12_000 - haystack.count }

        var score = 0
        var searchStart = haystack.startIndex
        var streak = 0
        for character in needle {
            guard let found = haystack[searchStart...].firstIndex(of: character) else { return nil }
            let distance = haystack.distance(from: searchStart, to: found)
            streak = distance == 0 ? streak + 1 : 0
            score += max(1, 80 - distance) + (streak * 12)
            searchStart = haystack.index(after: found)
        }
        let basenameBonus = (path as NSString).lastPathComponent.lowercased().contains(String(needle.prefix(1))) ? 300 : 0
        return score + basenameBonus - min(path.count, 260)
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for path in paths where !seen.contains(path) {
            seen.insert(path)
            output.append(path)
        }
        return output
    }
}
