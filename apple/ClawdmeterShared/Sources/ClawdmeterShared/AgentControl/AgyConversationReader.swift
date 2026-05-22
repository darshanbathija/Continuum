// Snapshot reader for the `agy` CLI's conversation corpus.
//
// Antigravity 2.0 ships TWO observable surfaces, both backed by the same
// agent harness but with separate on-disk layouts:
//
//   1. Desktop IDE → `~/.gemini/antigravity/conversations/<uuid>.db`
//      (SQLite WAL — read by AntigravityConversationDB).
//   2. `agy` CLI  → `~/.gemini/antigravity-cli/conversations/<uuid>.pb`
//      (length-delimited protobuf — read here).
//
// Before this file, Clawdmeter was blind to surface #2. Sessions spawned
// via `agy` (the Go-based replacement for `gemini` CLI, GA at Google I/O
// 2026 on 2026-05-19) wrote conversation history to a directory nobody
// was watching, so menubar totals dropped to ~zero whenever the user
// switched from the IDE to the terminal.
//
// Storage layout (real install, captured 2026-05-22):
//
//   ~/.gemini/antigravity-cli/
//     bin/                       agy binary symlink
//     brain/<uuid>/              per-conversation artifact dir (markdown
//                                plans, metadata.json files — same shape
//                                as the desktop's brain dir)
//     cache/
//       last_conversations.json  workspace-path → conversation-uuid map
//       onboarding.json
//     conversations/
//       <uuid>.pb                one conversation per file
//     history.jsonl              user-prompt input history
//     log/cli-<timestamp>.log
//     settings.json              {colorScheme, model, trustedWorkspaces}
//
// We deliberately don't watch this with a DispatchSource yet — v1 is a
// pull-on-refresh snapshot, mirroring how `BrainSummaryIndexer` works.
// A push-mode observer (FSEvents on the conversations dir) is a sensible
// follow-up if menubar refresh latency starts to matter.

import Foundation

/// Aggregate usage snapshot for the agy CLI's conversation corpus.
/// Sums + counts are over every `.pb` file in `<root>/conversations/`,
/// each probed with `ConversationProtoParser.probe()` so the token
/// estimate uses the same heuristics the desktop side already trusts.
public struct AgyUsageSnapshot: Equatable, Sendable {
    /// Number of `.pb` files discovered under `<root>/conversations/`.
    public let conversationCount: Int
    /// Sum of `fileSize` across all conversations. Useful as a coarse
    /// activity meter even when token estimates are unavailable (e.g.
    /// when no brain dir is present to estimate from markdown).
    public let totalBytes: Int
    /// Sum of `estimatedTokens` across all conversations. Each individual
    /// estimate comes from `ConversationProtoParser.estimatePlaintextTokens`
    /// against the matching brain dir; conversations without a brain dir
    /// contribute 0.
    public let totalEstimatedTokens: Int
    /// Most recent mtime across all conversation files. Nil when the
    /// directory is empty or missing.
    public let lastModified: Date?
    /// Per-conversation probes, ordered by descending mtime so the
    /// caller can render "recent first" without re-sorting.
    public let conversations: [AgyConversation]

    public static let empty = AgyUsageSnapshot(
        conversationCount: 0,
        totalBytes: 0,
        totalEstimatedTokens: 0,
        lastModified: nil,
        conversations: []
    )

    public init(
        conversationCount: Int,
        totalBytes: Int,
        totalEstimatedTokens: Int,
        lastModified: Date?,
        conversations: [AgyConversation]
    ) {
        self.conversationCount = conversationCount
        self.totalBytes = totalBytes
        self.totalEstimatedTokens = totalEstimatedTokens
        self.lastModified = lastModified
        self.conversations = conversations
    }
}

/// One row in `AgyUsageSnapshot.conversations`. Pairs the conversation
/// UUID (parsed from the `.pb` filename) with a `ConversationProtoParser`
/// probe result. Equatable so test fixtures can compare snapshots.
public struct AgyConversation: Equatable, Sendable {
    /// UUID parsed from the filename stem (e.g. `e164cb85-…` from
    /// `e164cb85-….pb`). Stored as a string because callers want it for
    /// path-joining, not as a typed identifier.
    public let conversationUUID: String
    /// URL of the `.pb` file. Useful for callers that want to invoke
    /// `ConversationProtoParser.decode()` themselves on a step blob.
    public let conversationURL: URL
    /// URL of the matching brain dir (`<root>/brain/<uuid>/`) when it
    /// exists on disk. Nil when no brain dir is present — agy can ship
    /// a conversation file before the brain dir is written.
    public let brainURL: URL?
    /// Probe result from `ConversationProtoParser.probe`.
    public let probe: ConversationProbe

    public init(
        conversationUUID: String,
        conversationURL: URL,
        brainURL: URL?,
        probe: ConversationProbe
    ) {
        self.conversationUUID = conversationUUID
        self.conversationURL = conversationURL
        self.brainURL = brainURL
        self.probe = probe
    }
}

/// Pure-function reader. No state, no caching, no observers — callers
/// that want freshness call `read(...)` on every refresh. Cost: one
/// `contentsOfDirectory` + one stat per `.pb` file + one ~4KB read per
/// file for encryption detection. Negligible at typical corpus sizes
/// (single-digit conversations).
public enum AgyConversationReader {
    /// Canonical install root: `<home>/.gemini/antigravity-cli/`. Exposed
    /// so tests can hand in a synthetic root and so production callers
    /// don't have to remember the path.
    public static func defaultRoot(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    /// Cheap install probe. Returns true iff the `conversations/`
    /// subdirectory exists. We don't gate on the binary being on PATH
    /// because the user can run `agy` from a workspace-local checkout —
    /// the on-disk corpus is the authoritative signal that the CLI has
    /// been used.
    public static func isInstalled(
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDir: ObjCBool = false
        let path = rootURL.appendingPathComponent("conversations", isDirectory: true).path
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Snapshots the corpus under `<rootURL>/conversations/`. Returns
    /// `.empty` when the directory is missing — callers shouldn't have
    /// to special-case "agy not installed yet."
    public static func read(
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> AgyUsageSnapshot {
        let conversationsDir = rootURL.appendingPathComponent("conversations", isDirectory: true)
        let brainDir = rootURL.appendingPathComponent("brain", isDirectory: true)

        guard let entries = try? fileManager.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var conversations: [AgyConversation] = []
        var totalBytes = 0
        var totalTokens = 0
        var newestMtime: Date?

        for entry in entries where entry.pathExtension == "pb" {
            let uuid = entry.deletingPathExtension().lastPathComponent
            // Match brain dir by UUID. Absent dir is fine; the probe
            // falls back to a zero token estimate.
            let candidateBrain = brainDir.appendingPathComponent(uuid, isDirectory: true)
            let resolvedBrain: URL? = fileManager.fileExists(atPath: candidateBrain.path)
                ? candidateBrain : nil

            let probe = ConversationProtoParser.probe(
                conversationURL: entry,
                brainURL: resolvedBrain,
                fileManager: fileManager
            )

            conversations.append(
                AgyConversation(
                    conversationUUID: uuid,
                    conversationURL: entry,
                    brainURL: resolvedBrain,
                    probe: probe
                )
            )

            totalBytes += probe.fileSize
            totalTokens += probe.estimatedTokens
            if newestMtime == nil || probe.lastModified > (newestMtime ?? .distantPast) {
                newestMtime = probe.lastModified
            }
        }

        conversations.sort { $0.probe.lastModified > $1.probe.lastModified }

        return AgyUsageSnapshot(
            conversationCount: conversations.count,
            totalBytes: totalBytes,
            totalEstimatedTokens: totalTokens,
            lastModified: newestMtime,
            conversations: conversations
        )
    }
}
