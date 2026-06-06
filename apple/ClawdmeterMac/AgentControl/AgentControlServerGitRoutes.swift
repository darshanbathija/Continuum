import Foundation
import Network
import ClawdmeterShared

extension AgentControlServer {
    func handleGetDiff(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        do {
            let files = try await loadDiffFiles(session: session, gitBin: gitBin)
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(files) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            serverLogger.error("git diff failed: \(error.localizedDescription, privacy: .public)")
            if (error as NSError).code == 409 {
                sendResponse(HTTPResponse(
                    status: 409, reason: "Conflict",
                    contentType: "application/json",
                    body: Data(#"{"error":"Repo is in rebase/merge state, finish on Mac"}"#.utf8)
                ), on: connection)
                return
            }
            sendResponse(.internalError, on: connection)
        }
    }

    func handleGetDiffFile(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        guard let relPath = diffRelativePath(sessionId: sessionId, requestPath: request.path),
              isSafeGitRelativePath(relPath) else {
            sendResponse(.badRequest, on: connection); return
        }
        let context = diffContext(from: request.path)
        do {
            let numstat = try await ShellRunner.shared.run(
                executable: gitBin,
                arguments: ["diff", "--numstat", "HEAD", "--", relPath],
                cwd: session.effectiveCwd,
                timeout: 10
            )
            let counts = parseDiffCounts(numstat.stdoutString)
            let diff = try await ShellRunner.shared.run(
                executable: gitBin,
                arguments: ["diff", "--unified=\(context)", "HEAD", "--", relPath],
                cwd: session.effectiveCwd,
                timeout: 10
            )
            let file = ClawdmeterShared.GitDiffFile(
                path: relPath,
                status: "M",
                additions: counts.additions,
                deletions: counts.deletions,
                hunks: parseUnifiedDiffHunks(diff.stdoutString),
                truncated: false,
                changeState: nil
            )
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(file) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            serverLogger.error("git diff file failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    func handleDiffAction(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        guard let relPath = diffActionRelativePath(sessionId: sessionId, requestPath: request.path),
              isSafeGitRelativePath(relPath) else {
            sendResponse(.badRequest, on: connection); return
        }
        let req = (try? JSONDecoder().decode(GitDiffActionRequest.self, from: request.body))
            ?? GitDiffActionRequest(action: .stageFile)
        do {
            switch req.action {
            case .stageFile:
                try await runGitDiffAction(gitBin: gitBin, cwd: session.effectiveCwd, arguments: ["add", "--", relPath])
            case .unstageFile:
                try await runGitDiffAction(gitBin: gitBin, cwd: session.effectiveCwd, arguments: ["restore", "--staged", "--", relPath])
            case .discardFile:
                if try await isUntracked(gitBin: gitBin, cwd: session.effectiveCwd, relPath: relPath) {
                    try trashUntrackedFile(cwd: session.effectiveCwd, relPath: relPath)
                } else {
                    try await runGitDiffAction(
                        gitBin: gitBin,
                        cwd: session.effectiveCwd,
                        arguments: ["restore", "--staged", "--worktree", "--", relPath]
                    )
                }
            }
            let files = try await loadDiffFiles(session: session, gitBin: gitBin)
            let receipt = req.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
            }
            sendCodable(GitDiffActionResponse(ok: true, files: files, receipt: receipt), on: connection)
        } catch {
            sendCodable(GitDiffActionResponse(ok: false, error: "\(error)"), on: connection)
        }
    }

    private func loadDiffFiles(
        session: AgentSession,
        gitBin: String
    ) async throws -> [ClawdmeterShared.GitDiffFile] {
        let cwd = session.effectiveCwd
        // Refuse to diff mid-rebase/merge (Codex #11 / T11).
        if FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git/rebase-merge"))
            || FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git/MERGE_HEAD")) {
            throw NSError(
                domain: "AgentControlServer.Diff",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Repo is in rebase/merge state, finish on Mac"]
            )
        }
        let head = try await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["diff", "--numstat", "HEAD"],
            cwd: cwd,
            timeout: 10
        )
        let unstaged = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["diff", "--numstat"],
            cwd: cwd,
            timeout: 10
        )
        let staged = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["diff", "--cached", "--numstat"],
            cwd: cwd,
            timeout: 10
        )
        let status = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["status", "--porcelain=v1", "-z"],
            cwd: cwd,
            timeout: 10
        )
        let unstagedPaths = Set(parseNumstatFiles(unstaged?.stdoutString ?? "").map(\.path))
        let stagedPaths = Set(parseNumstatFiles(staged?.stdoutString ?? "").map(\.path))
        let statusMap = parsePorcelainStatus(status?.stdout ?? Data())

        var seen = Set<String>()
        var files: [ClawdmeterShared.GitDiffFile] = parseNumstatFiles(head.stdoutString).map { item in
            seen.insert(item.path)
            let staged = stagedPaths.contains(item.path)
            let unstaged = unstagedPaths.contains(item.path)
            return ClawdmeterShared.GitDiffFile(
                path: item.path,
                status: statusMap[item.path] ?? "M",
                additions: item.additions,
                deletions: item.deletions,
                hunks: [],
                truncated: true,
                changeState: diffChangeState(staged: staged, unstaged: unstaged)
            )
        }

        let untracked = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            cwd: cwd,
            timeout: 10
        )
        for path in parseNulSeparatedPaths(untracked?.stdout ?? Data()) where !seen.contains(path) {
            files.append(ClawdmeterShared.GitDiffFile(
                path: path,
                status: "A",
                additions: countTextLines(cwd: cwd, relPath: path),
                deletions: 0,
                hunks: [],
                truncated: true,
                changeState: "untracked"
            ))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func diffRelativePath(sessionId: String, requestPath: String) -> String? {
        let pathOnly = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestPath
        let prefix = "/sessions/\(sessionId)/diff/"
        guard pathOnly.hasPrefix(prefix) else { return nil }
        let encoded = String(pathOnly.dropFirst(prefix.count))
        return encoded.removingPercentEncoding
    }

    private func diffActionRelativePath(sessionId: String, requestPath: String) -> String? {
        let pathOnly = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestPath
        let prefix = "/sessions/\(sessionId)/diff-action/"
        guard pathOnly.hasPrefix(prefix) else { return nil }
        let encoded = String(pathOnly.dropFirst(prefix.count))
        return encoded.removingPercentEncoding
    }

    private func isSafeGitRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        guard !path.contains("\0"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func diffContext(from requestPath: String) -> Int {
        guard let comps = URLComponents(string: requestPath),
              let raw = comps.queryItems?.first(where: { $0.name == "context" })?.value,
              let value = Int(raw) else {
            return 80
        }
        return min(max(value, 0), 500)
    }

    private func runGitDiffAction(gitBin: String, cwd: String, arguments: [String]) async throws {
        let result = try await ShellRunner.shared.run(
            executable: gitBin,
            arguments: arguments,
            cwd: cwd,
            timeout: 15
        )
        guard result.exitStatus == 0 else {
            throw NSError(
                domain: "AgentControlServer.DiffAction",
                code: Int(result.exitStatus),
                userInfo: [NSLocalizedDescriptionKey: result.stderrString]
            )
        }
    }

    private func isUntracked(gitBin: String, cwd: String, relPath: String) async throws -> Bool {
        let result = try await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["ls-files", "--error-unmatch", "--", relPath],
            cwd: cwd,
            timeout: 10
        )
        return result.exitStatus != 0
    }

    private func trashUntrackedFile(cwd: String, relPath: String) throws {
        guard let fileURL = safeFileURL(cwd: cwd, relPath: relPath) else {
            throw NSError(
                domain: "AgentControlServer.DiffAction",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "unsafe path"]
            )
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
    }

    private func safeFileURL(cwd: String, relPath: String) -> URL? {
        guard isSafeGitRelativePath(relPath) else { return nil }
        let root = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(relPath).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return candidate
    }

    private func parseNulSeparatedPaths(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private struct DiffNumstatItem {
        let path: String
        let additions: Int
        let deletions: Int
    }

    private func parseNumstatFiles(_ stdout: String) -> [DiffNumstatItem] {
        stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return DiffNumstatItem(
                path: normalizeNumstatPath(parts[2]),
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0
            )
        }
    }

    private func normalizeNumstatPath(_ path: String) -> String {
        // Rename numstat can emit "{old => new}/file"; fall back to the
        // post-image path when the compact rename syntax is obvious.
        guard let arrow = path.range(of: " => ") else { return path }
        var normalized = path
        normalized.removeSubrange(path.startIndex..<arrow.upperBound)
        normalized.removeAll { $0 == "{" || $0 == "}" }
        return normalized
    }

    private func parsePorcelainStatus(_ data: Data) -> [String: String] {
        let entries = parseNulSeparatedPaths(data)
        var out: [String: String] = [:]
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard entry.count >= 4 else {
                index += 1
                continue
            }
            let xy = String(entry.prefix(2))
            var path = String(entry.dropFirst(3))
            if (xy.contains("R") || xy.contains("C")), index + 1 < entries.count {
                index += 1
                path = entries[index]
            }
            out[path] = gitStatus(from: xy)
            index += 1
        }
        return out
    }

    private func gitStatus(from xy: String) -> String {
        if xy == "??" { return "A" }
        if xy.contains("R") { return "R" }
        if xy.contains("C") { return "C" }
        if xy.contains("A") { return "A" }
        if xy.contains("D") { return "D" }
        return "M"
    }

    private func diffChangeState(staged: Bool, unstaged: Bool) -> String {
        if staged && unstaged { return "mixed" }
        if staged { return "staged" }
        return "unstaged"
    }

    private func countTextLines(cwd: String, relPath: String) -> Int {
        guard let url = safeFileURL(cwd: cwd, relPath: relPath),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= 512_000,
              !data.contains(0) else {
            return 0
        }
        if data.isEmpty { return 0 }
        return data.reduce(0) { $1 == 10 ? $0 + 1 : $0 } + (data.last == 10 ? 0 : 1)
    }

    private func parseDiffCounts(_ stdout: String) -> (additions: Int, deletions: Int) {
        guard let line = stdout.split(separator: "\n").first else { return (0, 0) }
        let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    private func parseUnifiedDiffHunks(_ stdout: String) -> [ClawdmeterShared.GitDiffHunk] {
        var hunks: [ClawdmeterShared.GitDiffHunk] = []
        var currentHeader: String?
        var currentLines: [ClawdmeterShared.GitDiffHunk.Line] = []

        func flush() {
            guard let header = currentHeader else { return }
            hunks.append(ClawdmeterShared.GitDiffHunk(header: header, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("@@") {
                flush()
                currentHeader = rawLine
                continue
            }
            guard currentHeader != nil else { continue }
            if rawLine.hasPrefix("+") {
                currentLines.append(.init(kind: .addition, text: String(rawLine.dropFirst())))
            } else if rawLine.hasPrefix("-") {
                currentLines.append(.init(kind: .deletion, text: String(rawLine.dropFirst())))
            } else if rawLine.hasPrefix(" ") {
                currentLines.append(.init(kind: .context, text: String(rawLine.dropFirst())))
            } else {
                currentLines.append(.init(kind: .context, text: rawLine))
            }
        }
        flush()
        return hunks
    }

    private func fetchPRStatus(cwd: String) async throws -> PRStatus? {
        guard let ghBin = ShellRunner.locateBinary("gh") else { return nil }
        let fields = [
            "url",
            "number",
            "title",
            "body",
            "state",
            "isDraft",
            "additions",
            "deletions",
            "changedFiles",
            "reviewDecision",
            "statusCheckRollup",
        ].joined(separator: ",")
        let result = try await ShellRunner.shared.run(
            executable: ghBin,
            arguments: ["pr", "view", "--json", fields],
            cwd: cwd,
            timeout: 20
        )
        guard result.exitStatus == 0 else {
            let stderr = result.stderrString.lowercased()
            if stderr.contains("no pull requests found")
                || stderr.contains("no open pull requests")
                || stderr.contains("could not find")
                || stderr.contains("not found") {
                return nil
            }
            throw NSError(
                domain: "AgentControlServer.PR",
                code: Int(result.exitStatus),
                userInfo: [NSLocalizedDescriptionKey: result.stderrString]
            )
        }
        guard let obj = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw NSError(
                domain: "AgentControlServer.PR",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not parse gh pr view JSON"]
            )
        }
        let isDraft = obj["isDraft"] as? Bool ?? false
        let state: PRStatus.State = {
            if isDraft { return .draft }
            switch (obj["state"] as? String ?? "").lowercased() {
            case "open": return .open
            case "merged": return .merged
            case "closed": return .closed
            default: return .open
            }
        }()
        let checksRollup = Self.checksRollup(from: obj["statusCheckRollup"])
        let mergeability: PRMergeability = {
            if state == .closed { return .blocked }
            if state == .merged { return .mergeable }
            switch checksRollup {
            case "failure", "pending": return .blocked
            default: return .mergeable
            }
        }()
        return PRStatus(
            url: obj["url"] as? String ?? "",
            number: obj["number"] as? Int ?? 0,
            title: obj["title"] as? String ?? "",
            body: obj["body"] as? String ?? "",
            state: state,
            additions: obj["additions"] as? Int ?? 0,
            deletions: obj["deletions"] as? Int ?? 0,
            changedFiles: obj["changedFiles"] as? Int ?? 0,
            reviewDecision: obj["reviewDecision"] as? String,
            checksRollup: checksRollup,
            checks: Self.checkMirrors(from: obj["statusCheckRollup"]),
            mergeability: mergeability,
            lastCheckedAt: Date()
        )
    }

    private static func checksRollup(from value: Any?) -> String? {
        guard let checks = value as? [[String: Any]], !checks.isEmpty else { return nil }
        var sawPending = false
        for check in checks {
            let status = ((check["status"] as? String) ?? "").lowercased()
            let conclusion = ((check["conclusion"] as? String) ?? "").lowercased()
            if ["failure", "failed", "timed_out", "cancelled", "action_required"].contains(conclusion) {
                return "failure"
            }
            if conclusion.isEmpty || status == "queued" || status == "in_progress" || status == "pending" {
                sawPending = true
            }
        }
        return sawPending ? "pending" : "success"
    }

    private static func checkMirrors(from value: Any?) -> [PRCheckMirror] {
        guard let checks = value as? [[String: Any]], !checks.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        return checks.enumerated().map { index, check in
            let name = (check["name"] as? String)
                ?? (check["workflowName"] as? String)
                ?? (check["context"] as? String)
                ?? "Check \(index + 1)"
            let status = ((check["status"] as? String) ?? "").lowercased()
            let conclusion = ((check["conclusion"] as? String) ?? "").lowercased()
            let state: PRCheckState
            if ["success", "passed"].contains(conclusion) {
                state = .success
            } else if ["failure", "failed", "timed_out", "cancelled", "action_required"].contains(conclusion) {
                state = .failure
            } else if ["skipped", "neutral"].contains(conclusion) {
                state = .skipped
            } else if conclusion.isEmpty || ["queued", "in_progress", "pending"].contains(status) {
                state = .pending
            } else {
                state = .unknown
            }
            let completedAt = (check["completedAt"] as? String).flatMap { formatter.date(from: $0) }
            let url = (check["detailsUrl"] as? String) ?? (check["targetUrl"] as? String)
            return PRCheckMirror(name: name, state: state, url: url, completedAt: completedAt)
        }
    }

    func handleGetPR(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard ShellRunner.locateBinary("gh") != nil else {
            sendJSON(["error": "gh CLI not found on Mac. Install: brew install gh"], on: connection, status: 503)
            return
        }
        do {
            guard let status = try await fetchPRStatus(cwd: session.effectiveCwd) else {
                sendJSON(["pr": NSNull()], on: connection)
                return
            }
            sendCodable(status, on: connection)
        } catch {
            sendJSON(["error": "gh pr view failed", "detail": "\(error)"], on: connection, status: 502)
        }
    }

    func handleCreatePR(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let req = (try? JSONDecoder().decode(CreatePRRequest.self, from: request.body)) ?? CreatePRRequest()
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        let cwd = session.effectiveCwd
        guard let ghBin = ShellRunner.locateBinary("gh") else {
            await sendCommandJSONError(
                ["error": "gh CLI not found on Mac. Install: brew install gh"],
                status: 503,
                key: req.idempotencyKey,
                kind: .createPR,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
            return
        }
        var args = ["pr", "create", "--fill"]
        if let title = req.title, !title.isEmpty { args += ["--title", title] }
        if let body = req.body, !body.isEmpty { args += ["--body", body] }
        if let base = req.baseBranch, !base.isEmpty { args += ["--base", base] }
        do {
            let result = try await ShellRunner.shared.run(
                executable: ghBin, arguments: args, cwd: cwd, timeout: 60
            )
            if result.exitStatus != 0 {
                let payload: [String: Any] = ["error": "gh pr create failed", "stderr": result.stderrString]
                await sendCommandJSONError(
                    payload,
                    status: 500,
                    key: req.idempotencyKey,
                    kind: .createPR,
                    sessionId: uuid,
                    payloadHash: payloadHash,
                    on: connection
                )
                return
            }
            let prURL = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            await sendCommandResponse(
                body: ["url": prURL],
                key: req.idempotencyKey,
                kind: .createPR,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
        } catch {
            await sendCommandJSONError(
                ["error": "gh pr create failed", "detail": "\(error)"],
                status: 500,
                key: req.idempotencyKey,
                kind: .createPR,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
        }
    }

    func handleReviewPR(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let req = (try? JSONDecoder().decode(PRReviewRequest.self, from: request.body)) ?? PRReviewRequest()
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        guard let ghBin = ShellRunner.locateBinary("gh") else {
            let receipt = req.idempotencyKey.map {
                MobileCommandReceipt(
                    idempotencyKey: $0,
                    status: .failed,
                    processedAt: Date(),
                    error: "gh CLI not found on Mac. Install: brew install gh"
                )
            }
            await sendCommandCodableResponse(
                PRReviewResponse(ok: false, receipt: receipt, error: "gh CLI not found on Mac. Install: brew install gh"),
                key: req.idempotencyKey,
                kind: .reviewPR,
                sessionId: uuid,
                payloadHash: payloadHash,
                status: 503,
                failed: true,
                errorMessage: "gh CLI not found on Mac. Install: brew install gh",
                on: connection
            )
            return
        }
        var args = ["pr", "review"]
        switch req.action {
        case .approve:
            args.append("--approve")
        case .comment:
            args.append("--comment")
        case .requestChanges:
            args.append("--request-changes")
        }
        if let body = req.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            args += ["--body", body]
        }
        do {
            let result = try await ShellRunner.shared.run(
                executable: ghBin,
                arguments: args,
                cwd: session.effectiveCwd,
                timeout: 45
            )
            guard result.exitStatus == 0 else {
                let receipt = req.idempotencyKey.map {
                    MobileCommandReceipt(
                        idempotencyKey: $0,
                        status: .failed,
                        processedAt: Date(),
                        error: result.stderrString
                    )
                }
                await sendCommandCodableResponse(
                    PRReviewResponse(ok: false, receipt: receipt, error: result.stderrString),
                    key: req.idempotencyKey,
                    kind: .reviewPR,
                    sessionId: uuid,
                    payloadHash: payloadHash,
                    failed: true,
                    errorMessage: result.stderrString,
                    on: connection
                )
                return
            }
            let refreshed = try? await fetchPRStatus(cwd: session.effectiveCwd)
            let receipt = req.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
            }
            await sendCommandCodableResponse(
                PRReviewResponse(ok: true, pr: refreshed ?? nil, receipt: receipt),
                key: req.idempotencyKey,
                kind: .reviewPR,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
        } catch {
            let errorText = "\(error)"
            let receipt = req.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
            }
            await sendCommandCodableResponse(
                PRReviewResponse(ok: false, receipt: receipt, error: errorText),
                key: req.idempotencyKey,
                kind: .reviewPR,
                sessionId: uuid,
                payloadHash: payloadHash,
                failed: true,
                errorMessage: errorText,
                on: connection
            )
        }
    }

    func handleMerge(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let mergeRequest = (try? JSONDecoder().decode(MergePRRequest.self, from: request.body)) ?? MergePRRequest()
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: mergeRequest.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = mergeRequest.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        let cwd = session.effectiveCwd
        guard let ghBin = ShellRunner.locateBinary("gh") else {
            let errorText = "gh CLI not found on Mac. Install: brew install gh"
            let receipt = mergeRequest.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
            }
            await sendCommandCodableResponse(
                MergePRResponse(ok: false, merged: false, receipt: receipt, error: errorText),
                key: mergeRequest.idempotencyKey,
                kind: .mergePR,
                sessionId: uuid,
                payloadHash: payloadHash,
                status: 503,
                failed: true,
                errorMessage: errorText,
                on: connection
            )
            return
        }
        let explicitOverride = mergeRequest.adminOverride || request.path.contains("override=true")
        do {
            guard let pr = try await fetchPRStatus(cwd: cwd) else {
                let errorText = "No PR found for this branch"
                let receipt = mergeRequest.idempotencyKey.map {
                    MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
                }
                await sendCommandCodableResponse(
                    MergePRResponse(ok: false, merged: false, receipt: receipt, error: errorText),
                    key: mergeRequest.idempotencyKey,
                    kind: .mergePR,
                    sessionId: uuid,
                    payloadHash: payloadHash,
                    status: 404,
                    failed: true,
                    errorMessage: errorText,
                    on: connection
                )
                return
            }
            if pr.state == .merged {
                let receipt = mergeRequest.idempotencyKey.map {
                    MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
                }
                await sendCommandCodableResponse(
                    MergePRResponse(ok: true, merged: true, pr: pr, receipt: receipt),
                    key: mergeRequest.idempotencyKey,
                    kind: .mergePR,
                    sessionId: uuid,
                    payloadHash: payloadHash,
                    on: connection
                )
                return
            }
            if !explicitOverride {
                if pr.checksRollup == "failure" {
                    let errorText = "Checks are failing"
                    let receipt = mergeRequest.idempotencyKey.map {
                        MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
                    }
                    await sendCommandCodableResponse(
                        MergePRResponse(ok: false, merged: false, pr: pr, receipt: receipt, error: errorText),
                        key: mergeRequest.idempotencyKey,
                        kind: .mergePR,
                        sessionId: uuid,
                        payloadHash: payloadHash,
                        status: 409,
                        failed: true,
                        errorMessage: errorText,
                        on: connection
                    )
                    return
                }
                if pr.checksRollup == "pending" {
                    let errorText = "Checks are still pending"
                    let receipt = mergeRequest.idempotencyKey.map {
                        MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
                    }
                    await sendCommandCodableResponse(
                        MergePRResponse(ok: false, merged: false, pr: pr, receipt: receipt, error: errorText),
                        key: mergeRequest.idempotencyKey,
                        kind: .mergePR,
                        sessionId: uuid,
                        payloadHash: payloadHash,
                        status: 409,
                        failed: true,
                        errorMessage: errorText,
                        on: connection
                    )
                    return
                }
                if pr.state == .closed {
                    let errorText = "PR is closed"
                    let receipt = mergeRequest.idempotencyKey.map {
                        MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
                    }
                    await sendCommandCodableResponse(
                        MergePRResponse(ok: false, merged: false, pr: pr, receipt: receipt, error: errorText),
                        key: mergeRequest.idempotencyKey,
                        kind: .mergePR,
                        sessionId: uuid,
                        payloadHash: payloadHash,
                        status: 409,
                        failed: true,
                        errorMessage: errorText,
                        on: connection
                    )
                    return
                }
            }
            var args = ["pr", "merge", String(pr.number)]
            switch mergeRequest.method {
            case .merge: args.append("--merge")
            case .squash: args.append("--squash")
            case .rebase: args.append("--rebase")
            }
            if mergeRequest.deleteBranch { args.append("--delete-branch") }
            if mergeRequest.auto { args.append("--auto") }
            if explicitOverride { args.append("--admin") }
            let result = try await ShellRunner.shared.run(
                executable: ghBin,
                arguments: args,
                cwd: cwd,
                timeout: 90
            )
            if result.exitStatus != 0 {
                let errorText = "gh pr merge failed"
                let receipt = mergeRequest.idempotencyKey.map {
                    MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
                }
                await sendCommandCodableResponse(
                    MergePRResponse(ok: false, merged: false, pr: pr, receipt: receipt, error: "\(errorText): \(result.stderrString)"),
                    key: mergeRequest.idempotencyKey,
                    kind: .mergePR,
                    sessionId: uuid,
                    payloadHash: payloadHash,
                    status: 409,
                    failed: true,
                    errorMessage: errorText,
                    on: connection
                )
                return
            }
            let refreshed = try? await fetchPRStatus(cwd: cwd)
            let receipt = mergeRequest.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
            }
            await sendCommandCodableResponse(
                MergePRResponse(ok: true, merged: true, pr: refreshed ?? pr, receipt: receipt),
                key: mergeRequest.idempotencyKey,
                kind: .mergePR,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
        } catch {
            let errorText = "\(error)"
            let receipt = mergeRequest.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .failed, processedAt: Date(), error: errorText)
            }
            await sendCommandCodableResponse(
                MergePRResponse(ok: false, merged: false, receipt: receipt, error: errorText),
                key: mergeRequest.idempotencyKey,
                kind: .mergePR,
                sessionId: uuid,
                payloadHash: payloadHash,
                status: 500,
                failed: true,
                errorMessage: errorText,
                on: connection
            )
        }
    }
}
