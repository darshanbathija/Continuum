import XCTest
@testable import ClawdmeterShared

final class WireV18CodeWorkbenchTests: XCTestCase {

    func test_runProfileSnapshot_roundTrip() throws {
        let sessionId = UUID()
        let checkedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_777_000_120)
        let snapshot = CodeRunProfileSnapshot(
            sessionId: sessionId,
            cwd: "/Users/test/repo",
            command: "pnpm dev",
            detectedURL: "http://localhost:3000",
            source: "stdout",
            status: .running,
            health: CodeRunProfileHealth(
                state: .healthy,
                statusCode: 200,
                message: "OK",
                checkedAt: checkedAt
            ),
            stdoutLines: ["ready", "http://localhost:3000"],
            stderrLines: ["warn"],
            lastExitCode: nil,
            lastError: nil,
            updatedAt: updatedAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(CodeRunProfileResponse(profile: snapshot))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CodeRunProfileResponse.self, from: data).profile

        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.command, "pnpm dev")
        XCTAssertEqual(decoded.detectedURL, "http://localhost:3000")
        XCTAssertEqual(decoded.status, .running)
        XCTAssertEqual(decoded.health.state, .healthy)
        XCTAssertEqual(decoded.health.statusCode, 200)
        XCTAssertEqual(Array(decoded.stdoutLines.suffix(1)), ["http://localhost:3000"])
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_checkpointRestorePreview_roundTrip_andBlockedHelper() throws {
        let sessionId = UUID()
        let target = CodeCheckpointSnapshot(
            id: UUID(),
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/target",
            turnId: "turn-1",
            createdAt: Date(timeIntervalSince1970: 1_777_001_000),
            summary: "Before risky edit"
        )
        let safety = CodeCheckpointSnapshot(
            id: UUID(),
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/safety",
            createdAt: Date(timeIntervalSince1970: 1_777_001_100),
            summary: "Safety before restore"
        )
        let preview = CodeCheckpointRestorePreview(
            id: UUID(),
            target: target,
            safety: safety,
            diffStat: "2 files changed",
            diffPatch: "diff --git a/a b/a",
            patchTruncated: true,
            dirtyStatusLines: [" M Sources/App.swift"],
            untrackedOverwritePaths: ["tmp/generated.swift"],
            untrackedSnapshotPaths: ["notes.md"],
            blockingReasons: ["Untracked file would be overwritten"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(CodeCheckpointRestorePreviewResponse(preview: preview))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CodeCheckpointRestorePreviewResponse.self, from: data).preview

        XCTAssertEqual(decoded.target.id, target.id)
        XCTAssertEqual(decoded.safety.id, safety.id)
        XCTAssertTrue(decoded.patchTruncated)
        XCTAssertEqual(decoded.dirtyStatusLines, [" M Sources/App.swift"])
        XCTAssertEqual(decoded.untrackedOverwritePaths, ["tmp/generated.swift"])
        XCTAssertTrue(decoded.isBlocked)
    }

    func test_unknownRunProfileEnums_decodeToSafeDefaults() throws {
        let status = try JSONDecoder().decode(CodeRunProfileStatus.self, from: Data("\"future-status\"".utf8))
        let health = try JSONDecoder().decode(CodeRunProfileHealthState.self, from: Data("\"warming\"".utf8))
        XCTAssertEqual(status, .idle)
        XCTAssertEqual(health, .unknown)
    }

    func test_prStatus_roundTripsChecksAndReviewRequest() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_777_002_000)
        let pr = PRStatus(
            url: "https://github.com/example/repo/pull/99",
            number: 99,
            title: "Ship iOS workbench parity",
            body: "Adds mobile workbench controls.",
            state: .open,
            additions: 12,
            deletions: 3,
            changedFiles: 2,
            reviewDecision: "REVIEW_REQUIRED",
            checksRollup: "pending",
            checks: [
                PRCheckMirror(
                    name: "build",
                    state: .pending,
                    url: "https://github.com/example/repo/actions/runs/1",
                    completedAt: nil
                )
            ],
            mergeability: .blocked,
            lastCheckedAt: checkedAt
        )
        let request = PRReviewRequest(action: .requestChanges, body: "Needs one fix", idempotencyKey: "key-1")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let prData = try encoder.encode(pr)
        let requestData = try encoder.encode(request)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedPR = try decoder.decode(PRStatus.self, from: prData)
        let decodedRequest = try decoder.decode(PRReviewRequest.self, from: requestData)

        XCTAssertEqual(decodedPR.checks?.first?.name, "build")
        XCTAssertEqual(decodedPR.checks?.first?.state, .pending)
        XCTAssertEqual(decodedPR.mergeability, .blocked)
        XCTAssertNotNil(decodedPR.lastCheckedAt)
        XCTAssertEqual(decodedPR.lastCheckedAt!.timeIntervalSince1970, checkedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decodedRequest.action, .requestChanges)
        XCTAssertEqual(decodedRequest.body, "Needs one fix")
    }

    func test_diffAction_roundTrip() throws {
        let file = GitDiffFile(
            path: "Sources/App.swift",
            status: "M",
            additions: 4,
            deletions: 1,
            hunks: [],
            truncated: true,
            changeState: "mixed"
        )
        let response = GitDiffActionResponse(
            ok: true,
            files: [file],
            receipt: MobileCommandReceipt(idempotencyKey: "diff-key", status: .acknowledged),
            error: nil
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(GitDiffActionResponse.self, from: data)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.files.first?.path, "Sources/App.swift")
        XCTAssertEqual(decoded.files.first?.changeState, "mixed")
        XCTAssertEqual(decoded.receipt?.idempotencyKey, "diff-key")
    }
}
