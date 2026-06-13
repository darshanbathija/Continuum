import Foundation

private struct FffSearchHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

actor FffRepoSearchIndex {
    private let repoRoot: String
    private let library: FffLibrary
    private let workQueue = DispatchQueue(label: "com.clawdmeter.mac.fff-repo-search-index")
    private var handle: FffSearchHandle?
    private var prepareTask: Task<Void, Error>?
    private var isReady = false

    init(repoRoot: String, library: FffLibrary = .shared) {
        self.repoRoot = repoRoot
        self.library = library
    }

    func prepare(timeoutMs: UInt64 = 15_000) async throws {
        if isReady { return }
        if let prepareTask {
            try await prepareTask.value
            return
        }

        let repoRoot = repoRoot
        let library = library
        let workQueue = workQueue
        let task = Task<Void, Error> {
            let preparedHandle = try await Self.perform(on: workQueue) {
                let handle = try library.createInstance(basePath: repoRoot)
                guard try library.waitForScan(handle, timeoutMs: timeoutMs) else {
                    library.destroy(handle)
                    throw FffLibraryError.loadFailed("FFF index scan timed out for \(repoRoot)")
                }
                return FffSearchHandle(pointer: handle)
            }
            self.storePreparedHandle(preparedHandle)
        }
        prepareTask = task
        // Clear the in-flight task only after it settles on the actor, so
        // concurrent callers coalesce onto the same prepare and a failure
        // doesn't silently drop the dedup mid-flight.
        do {
            try await task.value
            prepareTask = nil
        } catch {
            prepareTask = nil
            throw error
        }
    }

    func search(query: String, recents: [String], limit: Int = 160) async throws -> [RepoFileMatch] {
        try await prepare()
        guard let handle else { return [] }

        let parsed = RepoFileSearch.parse(query)
        let trimmedNeedle = parsed.needle.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchQuery = trimmedNeedle.isEmpty ? "" : (parsed.path ?? query)

        let library = library
        let workQueue = workQueue
        return try await Self.perform(on: workQueue) {
            try Self.runSearch(
                library: library,
                handle: handle.pointer,
                query: searchQuery,
                parsedLine: parsed.line,
                recents: recents,
                limit: limit
            )
        }
    }

    private func storePreparedHandle(_ handle: FffSearchHandle) {
        self.handle = handle
        isReady = true
    }

    deinit {
        if let handle {
            workQueue.sync {
                library.destroy(handle.pointer)
            }
        }
    }

    private static func perform<T: Sendable>(
        on queue: DispatchQueue,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSearch(
        library: FffLibrary,
        handle: OpaquePointer,
        query: String,
        parsedLine: Int?,
        recents: [String],
        limit: Int
    ) throws -> [RepoFileMatch] {
        let recentPaths = Set(
            recents.compactMap { RepoFileSearch.parse($0).path }
        )

        let searchResult = try library.search(handle, query: query, limit: limit)
        defer { library.freeSearchResult(searchResult) }

        let count = Int(searchResult.pointee.count)
        var matches: [RepoFileMatch] = []
        if count > 0, let items = searchResult.pointee.items {
            matches.reserveCapacity(count)
            for index in 0..<count {
                let item = items[index]
                guard let relativePathPtr = item.relativePath else { continue }
                let path = String(cString: relativePathPtr)
                let score = Int(item.totalFrecencyScore)
                matches.append(
                    RepoFileMatch(
                        path: path,
                        line: parsedLine,
                        score: score + (recentPaths.contains(path) ? 1_000 : 0),
                        isRecent: recentPaths.contains(path)
                    )
                )
            }
        }

        if query.isEmpty {
            let recentMatches = recents.compactMap { recent -> RepoFileMatch? in
                let parsed = RepoFileSearch.parse(recent)
                guard let path = parsed.path else { return nil }
                return RepoFileMatch(
                    path: path,
                    line: parsed.line,
                    score: 10_000,
                    isRecent: true
                )
            }
            let seen = Set(recentMatches.map(\.path))
            let rest = matches.filter { !seen.contains($0.path) }
            return Array((recentMatches + rest).prefix(limit))
        }

        return matches
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }
}

actor RepoFileSearchService {
    static let shared = RepoFileSearchService()

    private var indexes: [String: FffRepoSearchIndex] = [:]

    func matches(
        query: String,
        repoRoot: String,
        recents: [String],
        limit: Int = 160
    ) async -> (matches: [RepoFileMatch], backend: RepoFileSearchBackend, error: String?) {
        let canonicalRoot = (repoRoot as NSString).standardizingPath
        guard !canonicalRoot.isEmpty else {
            return ([], .unavailable, "No open code session has a repo root.")
        }

        if FffLibrary.shared.isAvailable {
            do {
                let index = index(for: canonicalRoot)
                let results = try await index.search(query: query, recents: recents, limit: limit)
                return (results, .fff, nil)
            } catch {
                // Fall back to git indexing when FFF fails to initialize.
            }
        }

        let fallback = await Task.detached(priority: .utility) {
            RepoFileSearch.matchesWithGit(
                query: query,
                repoRoot: canonicalRoot,
                recents: recents,
                limit: limit
            )
        }.value

        if fallback.error != nil {
            return (fallback.matches, .gitFallback, fallback.error)
        }
        return (fallback.matches, .gitFallback, nil)
    }

    func warmIndex(repoRoot: String) async {
        let canonicalRoot = (repoRoot as NSString).standardizingPath
        guard FffLibrary.shared.isAvailable, !canonicalRoot.isEmpty else { return }
        _ = try? await index(for: canonicalRoot).prepare()
    }

    private func index(for repoRoot: String) -> FffRepoSearchIndex {
        if let existing = indexes[repoRoot] {
            return existing
        }
        let created = FffRepoSearchIndex(repoRoot: repoRoot)
        indexes[repoRoot] = created
        return created
    }
}

enum RepoFileSearchBackend: String, Sendable {
    case fff
    case gitFallback
    case unavailable
}
