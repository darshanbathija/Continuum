import Foundation
import AppKit

/// Spawns one `claude --dangerously-skip-permissions` session per selected
/// plan row into a fresh `Terminal.app` window, cd'd into the row's
/// worktree.
///
/// The spawn path is deliberately Terminal-based rather than going through
/// `AgentControlServer`'s session route:
///   - Terminal windows are immediately visible to the user, so a "did
///     this actually start?" check is just glancing at the screen.
///   - Each window is independent; closing one doesn't kill the others.
///   - We don't need ChatV2 / tmux / worktree-manager wiring for a
///     one-shot fan-out — that machinery is for in-app chat sessions.
///
/// Per spawn we write two files into the worktree root:
///   - `.continue-plan/<id>-prompt.md` — the assignment + acceptance
///   - `.continue-plan/<id>-spawn.sh`  — chmod 700 wrapper that cd's,
///                                       prints the assignment, then
///                                       execs `claude` with the prompt
///
/// `.gitignore` keeps `.continue-plan/` out of the worktree's diff so the
/// spawn artifacts never accidentally land in a PR.
enum PlanRunner {
    enum SpawnError: Error, LocalizedError {
        case worktreeMissing(String)
        case promptWriteFailed(String)
        case scriptWriteFailed(String)
        case osascriptFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .worktreeMissing(let p):
                return "Worktree not found on disk: \(p)"
            case .promptWriteFailed(let p):
                return "Could not write prompt file at \(p)"
            case .scriptWriteFailed(let p):
                return "Could not write spawn script at \(p)"
            case .osascriptFailed(let code, let stderr):
                return "osascript exited \(code): \(stderr)"
            }
        }
    }

    struct SpawnResult {
        let row: PlanQueueRow
        let promptPath: String
        let scriptPath: String
    }

    /// Spawn every row sequentially. Each Terminal window opens a few
    /// hundred ms apart — driving them in parallel sometimes leaves
    /// Terminal.app racing its own window-list update and dropping a
    /// window on the floor, so we serialize.
    static func spawnAll(_ rows: [PlanQueueRow]) async throws -> [SpawnResult] {
        var results: [SpawnResult] = []
        for row in rows {
            let result = try await spawn(row)
            results.append(result)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return results
    }

    static func spawn(_ row: PlanQueueRow) async throws -> SpawnResult {
        let fm = FileManager.default
        let worktreeURL = URL(fileURLWithPath: row.assignment.worktreePath, isDirectory: true)
        guard fm.fileExists(atPath: worktreeURL.path) else {
            throw SpawnError.worktreeMissing(worktreeURL.path)
        }

        let spawnDir = worktreeURL.appendingPathComponent(".continue-plan", isDirectory: true)
        try? fm.createDirectory(at: spawnDir, withIntermediateDirectories: true)

        let safeId = row.id.replacingOccurrences(of: "/", with: "-")
        let promptURL = spawnDir.appendingPathComponent("\(safeId)-prompt.md")
        let scriptURL = spawnDir.appendingPathComponent("\(safeId)-spawn.sh")

        let promptText = renderPrompt(for: row)
        do {
            try promptText.write(to: promptURL, atomically: true, encoding: .utf8)
        } catch {
            throw SpawnError.promptWriteFailed(promptURL.path)
        }

        let scriptText = renderSpawnScript(promptPath: promptURL.path, worktreePath: worktreeURL.path, row: row)
        do {
            try scriptText.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw SpawnError.scriptWriteFailed(scriptURL.path)
        }

        try await runOsaScriptOpeningTerminal(scriptPath: scriptURL.path)

        return SpawnResult(row: row, promptPath: promptURL.path, scriptPath: scriptURL.path)
    }

    // MARK: - Prompt + script rendering

    static func renderPrompt(for row: PlanQueueRow) -> String {
        let files = row.item.files.isEmpty ? "(see plan doc)" : row.item.files.joined(separator: "\n- ")
        return """
        # Continue Plan — \(row.assignment.planItemId)

        You are continuing work on the 32-item Clawdmeter perf + relay +
        backend-architecture plan. Drive this PR to completion without
        pausing for confirmation between steps. The user explicitly
        authorized autonomous execution after plan approval.

        ## Your assignment

        - **PR id:** \(row.assignment.planItemId)
        - **Title:** \(row.item.title)
        - **Component:** \(row.item.component)
        - **Effort estimate:** \(row.item.effortCC) CC / \(row.item.effortHuman) human
        - **Branch:** `\(row.assignment.branch)` (already cut; you are in the worktree)
        - **Base branch:** `\(row.assignment.baseBranch)`
        - **Files:**
        - \(files)

        ## Plan reference

        Full acceptance criteria + sequencing context live in
        `.claude/plans/study-this-codebase-crystalline-shore.md`. Read
        the row for \(row.assignment.planItemId) before touching code.

        ## Workflow

        1. Implement the change against the acceptance criteria in the plan doc.
        2. Run the relevant test suites:
           - Shared changes: `swift test --package-path apple/ClawdmeterShared`
           - Mac changes: `xcodebuild -project apple/Clawdmeter.xcodeproj -scheme ClawdmeterMacTests test`
           - Worker changes: the suite in `infra/relay/` or `infra/apns-gateway/`
        3. Revert pbxproj / Package.resolved drift before committing:
           `git checkout apple/Clawdmeter.xcodeproj/project.pbxproj apple/ClawdmeterShared/Package.resolved`
        4. Commit using the standard template (Summary / Why / Test output /
           Plan reference / Co-Authored-By).
        5. Push to origin and open the PR with `gh pr create` — base it on
           `\(row.assignment.baseBranch)`.
        6. Move on — do not wait for review.

        Only pause if: tests cannot pass without a design clarification not
        in the plan, OR a destructive action outside the standing
        autonomous-execution authorization is needed.
        """
    }

    static func renderSpawnScript(promptPath: String, worktreePath: String, row: PlanQueueRow) -> String {
        // Heredoc-safe: PROMPT_PATH is escaped via single quotes in the
        // generated script; the prompt file itself never gets interpolated
        // through the shell.
        return """
        #!/bin/bash
        set -e

        echo "════════════════════════════════════════════════════════════"
        echo " Continue Plan — \(row.assignment.planItemId): \(row.item.title)"
        echo " Branch: \(row.assignment.branch)"
        echo " Base:   \(row.assignment.baseBranch)"
        echo "════════════════════════════════════════════════════════════"
        echo

        cd '\(worktreePath)'

        if ! command -v claude >/dev/null 2>&1; then
            echo "❌ claude CLI not on PATH — install Claude Code first."
            echo "Press any key to close."
            read -n 1
            exit 1
        fi

        PROMPT="$(cat '\(promptPath)')"
        exec claude --dangerously-skip-permissions "$PROMPT"
        """
    }

    // MARK: - osascript driver

    private static func runOsaScriptOpeningTerminal(scriptPath: String) async throws {
        // `do script` opens a new Terminal window and runs the command in
        // it. `activate` brings Terminal to the front so the user sees
        // each window appear.
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(scriptPath))"
        end tell
        """
        try await runOsaScript(appleScript)
    }

    private static func runOsaScript(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let errPipe = Pipe()
            process.standardError = errPipe
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: SpawnError.osascriptFailed(proc.terminationStatus, stderr))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// AppleScript string literals require backslash + double-quote
    /// escaping; backslashes themselves must be doubled. Paths from
    /// `FileManager` shouldn't contain either, but escape defensively so
    /// a user with `"` in a directory name doesn't break the spawn.
    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
