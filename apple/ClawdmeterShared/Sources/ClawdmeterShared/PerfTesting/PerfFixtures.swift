import Foundation

/// Deterministic perf fixtures for the A0 baseline gate (Phase 0) + every
/// downstream Track 1 perf PR (A4-A13, B1-B3, C1, C2).
///
/// Each fixture is built lazily on first access and cached for the lifetime
/// of the process. All fixtures are generated with `SeededPRNG` so they're
/// bit-stable across machines + OS upgrades — required for the ranked
/// hotspot table to be reproducible.
///
/// **Scenarios served:**
///   - `sessions500` — 500-session sidebar fixture (sidebar projection
///     cache tests in A11; sidebar search keystrokes; archive/pinned
///     filter combinations)
///   - `messages10k` — 10k transcript items (transcript scroll p50/p99
///     in A5/A6/A9; whole-snapshot-publishing regression in A5; isolated
///     streaming bubble in A9)
///   - `diff50kLines` — 50k-line unified diff (off-main parse + virtual
///     rendering in A12)
///
/// **Plan reference:** A0 (Phase 0; D15) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`. Per-PR
/// acceptance criteria reference these fixtures by name; do not change
/// the public surface without updating the plan.
///
/// **Convention:** every Track 1 perf PR adds an XCTest perf gate (via
/// `measure` or `XCTPerformanceMetric_WallClockTime`) that reads from
/// these fixtures and asserts:
///   - No main-thread stall >100ms in the measured interaction
///   - Improvement vs the A0 baseline (recorded on first run via
///     XCTest's `XCTMeasureOptions.iterationCount`)
public enum PerfFixtures {

    // MARK: - Public access (lazy + cached)

    /// 500 deterministic mock sessions. Seed kept stable across runs so
    /// PR-to-PR comparisons are apples-to-apples.
    public static var sessions500: [MockSession] {
        Cache.shared.sessions500
    }

    /// 10,000 deterministic mock chat items.
    public static var messages10k: [MockMessage] {
        Cache.shared.messages10k
    }

    /// Unified diff with 50,000 lines.
    public static var diff50kLines: String {
        Cache.shared.diff50kLines
    }

    // MARK: - Mock types
    //
    // Lightweight shapes mirroring the FIELDS perf tests care about, not
    // the production AgentSession / WireChatItem / DiffHunk types. Tests
    // that need real types adapt these via a small builder in the test
    // file. Keeping these decoupled lets the production types evolve
    // without re-baselining the perf gates.

    public struct MockSession: Sendable, Equatable {
        public let id: String
        public let repoKey: String?
        public let title: String
        public let lastEventAt: Date
        public let archivedAt: Date?
        public let pinned: Bool
        public let provider: String   // "claude" / "codex" / "opencode" / "cursor" / "antigravity"
        public let messageCount: Int

        public init(
            id: String, repoKey: String?, title: String, lastEventAt: Date,
            archivedAt: Date?, pinned: Bool, provider: String, messageCount: Int
        ) {
            self.id = id
            self.repoKey = repoKey
            self.title = title
            self.lastEventAt = lastEventAt
            self.archivedAt = archivedAt
            self.pinned = pinned
            self.provider = provider
            self.messageCount = messageCount
        }
    }

    public struct MockMessage: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case user
            case assistant
            case toolUse
            case toolResult
            case error
        }
        public let id: String
        public let kind: Kind
        public let text: String
        public let timestamp: Date
        public let tokenCount: Int

        public init(id: String, kind: Kind, text: String, timestamp: Date, tokenCount: Int) {
            self.id = id
            self.kind = kind
            self.text = text
            self.timestamp = timestamp
            self.tokenCount = tokenCount
        }
    }
}

// MARK: - Cache

private final class Cache: @unchecked Sendable {
    static let shared = Cache()
    private let lock = NSLock()
    private var _sessions500: [PerfFixtures.MockSession]?
    private var _messages10k: [PerfFixtures.MockMessage]?
    private var _diff50kLines: String?

    var sessions500: [PerfFixtures.MockSession] {
        lock.lock(); defer { lock.unlock() }
        if let cached = _sessions500 { return cached }
        let generated = Generator.sessions(count: 500, seed: 0xA0_5E55_1043)
        _sessions500 = generated
        return generated
    }

    var messages10k: [PerfFixtures.MockMessage] {
        lock.lock(); defer { lock.unlock() }
        if let cached = _messages10k { return cached }
        let generated = Generator.messages(count: 10_000, seed: 0xA0_5E55_2043)
        _messages10k = generated
        return generated
    }

    var diff50kLines: String {
        lock.lock(); defer { lock.unlock() }
        if let cached = _diff50kLines { return cached }
        let generated = Generator.diff(lineCount: 50_000, seed: 0xA0_5E55_3043)
        _diff50kLines = generated
        return generated
    }
}

// MARK: - Generators

private enum Generator {

    static let baseDate = Date(timeIntervalSince1970: 1_715_000_000) // 2026-05-06T15:33:20Z

    private static let providers = ["claude", "codex", "opencode", "cursor", "antigravity"]
    private static let repos: [String?] = [
        nil, // chat session, no repo
        "monorepo",
        "billing-service",
        "ios-app",
        "infrastructure",
        "design-system",
        "experimental",
        "tools",
    ]
    private static let titleWords = [
        "refactor", "bug", "feature", "explore", "test", "doc", "spike",
        "perf", "release", "audit", "migration", "polish", "rebuild",
        "research", "wire", "cleanup", "review", "ship",
    ]
    private static let assistantSnippets = [
        "I'll start by reading the relevant files to understand the structure.",
        "Here's the diff for the change you requested.",
        "Running the test suite to confirm nothing regressed.",
        "Found three places where this pattern repeats — proposing one shared helper.",
        "Need to double-check the auth boundary before I touch this.",
        "Committing the WIP and re-running the build.",
    ]
    private static let userSnippets = [
        "Can you also add a test for the empty case?",
        "What happens if the input is nil here?",
        "Refactor this to use the existing utility.",
        "Open a PR with these changes.",
        "Run the linter and fix anything it flags.",
        "Why does this fail on cold start?",
    ]

    // MARK: Sessions

    static func sessions(count: Int, seed: UInt64) -> [PerfFixtures.MockSession] {
        var prng = SeededPRNG(seed: seed)
        var result: [PerfFixtures.MockSession] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let repoKey = prng.pick(repos) ?? nil
            let provider = prng.pick(providers) ?? "claude"
            let titleN = prng.nextInt(upperBound: 4) + 2
            var titleParts: [String] = []
            for _ in 0..<titleN {
                titleParts.append(prng.pick(titleWords) ?? "task")
            }
            let title = titleParts.joined(separator: " ")
            // 20% archived, 5% pinned (10% conditional given non-archived).
            let archived = prng.nextDouble() < 0.20
            let pinned = !archived && prng.nextDouble() < 0.10
            let archivedAt = archived
                ? baseDate.addingTimeInterval(TimeInterval(prng.nextInt(upperBound: 30 * 86_400)))
                : nil
            // lastEventAt spread across ~90 days back from baseDate.
            let lastOffset = TimeInterval(prng.nextInt(upperBound: 90 * 86_400))
            let lastEventAt = baseDate.addingTimeInterval(-lastOffset)
            let messageCount = prng.nextInt(upperBound: 200) + 5
            result.append(.init(
                id: "session-\(i)-\(provider)",
                repoKey: repoKey,
                title: title,
                lastEventAt: lastEventAt,
                archivedAt: archivedAt,
                pinned: pinned,
                provider: provider,
                messageCount: messageCount
            ))
        }
        return result
    }

    // MARK: Messages

    static func messages(count: Int, seed: UInt64) -> [PerfFixtures.MockMessage] {
        var prng = SeededPRNG(seed: seed)
        var result: [PerfFixtures.MockMessage] = []
        result.reserveCapacity(count)
        var lastTimestamp = baseDate.addingTimeInterval(-TimeInterval(count * 2))
        for i in 0..<count {
            // Realistic mix: 30% user turns, 50% assistant, 15% tool calls,
            // 4% tool results, 1% errors. Mirrors what a long agent session
            // looks like in production.
            let r = prng.nextDouble()
            let kind: PerfFixtures.MockMessage.Kind
            let snippet: String
            switch r {
            case 0..<0.30:
                kind = .user
                snippet = prng.pick(userSnippets) ?? ""
            case 0.30..<0.80:
                kind = .assistant
                snippet = prng.pick(assistantSnippets) ?? ""
            case 0.80..<0.95:
                kind = .toolUse
                snippet = "tool_use: Read(file: \"apple/ClawdmeterMac/source-\(prng.nextInt(upperBound: 200)).swift\")"
            case 0.95..<0.99:
                kind = .toolResult
                snippet = "tool_result: ok (\(prng.nextInt(upperBound: 4000)) lines read)"
            default:
                kind = .error
                snippet = "error: rate_limited — retrying in \(prng.nextInt(upperBound: 30))s"
            }
            // Add some padding text to vary message length 50–2000 chars.
            let padLen = 50 + prng.nextInt(upperBound: 1950)
            let pad = String(repeating: " padded", count: padLen / 8 + 1).prefix(padLen)
            let text = "\(snippet) \(pad)"
            // Messages step forward in time by 1–10 seconds.
            lastTimestamp = lastTimestamp.addingTimeInterval(TimeInterval(1 + prng.nextInt(upperBound: 10)))
            let tokenCount = max(1, text.count / 4)
            result.append(.init(
                id: "msg-\(i)",
                kind: kind,
                text: text,
                timestamp: lastTimestamp,
                tokenCount: tokenCount
            ))
        }
        return result
    }

    // MARK: Diff

    /// Build a unified diff (git-style) totaling at least `lineCount` lines.
    /// The diff spans multiple synthetic files for realism — sidebar +
    /// diff-tab tests want a multi-file diff, not one giant file.
    static func diff(lineCount: Int, seed: UInt64) -> String {
        var prng = SeededPRNG(seed: seed)
        var out = ""
        out.reserveCapacity(lineCount * 80)
        var emitted = 0
        var fileIndex = 0
        while emitted < lineCount {
            fileIndex += 1
            let path = "apple/ClawdmeterMac/PerfFixture/File\(fileIndex).swift"
            let oldOid = String(format: "%07x", prng.nextInt(upperBound: 0x0FFF_FFFF))
            let newOid = String(format: "%07x", prng.nextInt(upperBound: 0x0FFF_FFFF))
            out += "diff --git a/\(path) b/\(path)\n"
            out += "index \(oldOid)..\(newOid) 100644\n"
            out += "--- a/\(path)\n"
            out += "+++ b/\(path)\n"
            emitted += 4
            let hunksPerFile = prng.nextInt(upperBound: 5) + 1
            var fileLineNumber = 1
            for _ in 0..<hunksPerFile {
                let hunkLines = prng.nextInt(upperBound: 60) + 10
                let context = prng.nextInt(upperBound: 3)
                out += "@@ -\(fileLineNumber),\(hunkLines + context * 2) +\(fileLineNumber),\(hunkLines + context * 2) @@\n"
                emitted += 1
                for _ in 0..<context {
                    out += " // context line — unchanged\n"
                    emitted += 1
                }
                for h in 0..<hunkLines {
                    if prng.nextDouble() < 0.5 {
                        out += "-\(synthLine(prng: &prng, lineNo: fileLineNumber + h))\n"
                        emitted += 1
                    } else {
                        out += "+\(synthLine(prng: &prng, lineNo: fileLineNumber + h))\n"
                        emitted += 1
                    }
                    if emitted >= lineCount { return out }
                }
                for _ in 0..<context {
                    out += " // context line — unchanged\n"
                    emitted += 1
                    if emitted >= lineCount { return out }
                }
                fileLineNumber += hunkLines + context * 2 + 8
            }
        }
        return out
    }

    private static func synthLine(prng: inout SeededPRNG, lineNo: Int) -> String {
        // Vary line content + length to mimic real diffs.
        let style = prng.nextInt(upperBound: 5)
        switch style {
        case 0: return "    let x\(lineNo) = computeSomething(\(prng.nextInt(upperBound: 1000)))"
        case 1: return "    // refactored: was inline, now lives in PerfFixtures.\(lineNo)"
        case 2: return "        guard let value = optionalValue else { return .empty }"
        case 3: return "    return try await client.fetch(\(prng.nextInt(upperBound: 10000)))"
        default: return "    \(String(repeating: "indented chunk ", count: 4)) // \(lineNo)"
        }
    }
}
