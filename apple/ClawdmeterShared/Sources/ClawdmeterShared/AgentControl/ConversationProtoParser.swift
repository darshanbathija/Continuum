// Probes `~/.gemini/antigravity/conversations/<uuid>.pb` for usage signals.
//
// CRITICAL ARCHITECTURAL NOTE — discovered during v0.6.0 Commit 4 impl:
//
// Antigravity 2.0.0 encrypts every per-conversation `.pb` file at rest.
// We confirmed this against 36 live conversations on the dev machine:
// every file shows ~58% non-printable byte ratio (the signature of a
// uniformly-random ciphertext). A plaintext protobuf would be <25%
// non-printable; a snappy/zstd-compressed protobuf would be >85%.
// 57-60% non-printable is the unmistakable mark of encrypted content.
//
// This kills the original plan section D ("ConversationProtoParser via
// vendored .proto"). swift-protobuf can't decode ciphertext. Even if we
// vendored the right .proto schema, the wire bytes are scrambled.
//
// Adaptation: **Disk mode doesn't surface chat history OR exact token
// counts.** Instead, we extract every plaintext signal the brain dir
// gives us:
//
//   1. `<brain>/conversations/<uuid>.pb` file SIZE (rough proxy for
//      activity volume — bigger file ≈ longer conversation).
//   2. File MTIME (last-modified — proxy for "when did the agent last
//      write here").
//   3. `<brain>/*.metadata.json` `updatedAt` timestamps (each artifact
//      writes a metadata file when produced — count = turn count).
//   4. Heuristic token estimate: sum of all plaintext artifact byte
//      sizes, ÷ 4 chars/token. Provisional `~` marker on the value.
//
// **SDK mode** (Commit 10, opt-in toggle) gets real-time live token
// counts from the running Antigravity language_server via the SDK's
// `agent.conversation.total_usage` introspection. That's the path to
// exact analytics for users who want it; Disk mode users see the
// approximation with a clear `~` provisional marker.
//
// Tests assert the detection works: live encrypted files → `.encrypted`,
// synthetic plaintext bytes → `.plaintext`.

import Foundation

/// What we discovered when inspecting a `<uuid>.pb` file.
public enum ConversationFileKind: Equatable, Sendable {
    /// File doesn't exist.
    case missing
    /// File is empty (zero bytes).
    case empty
    /// File appears encrypted (high non-printable byte ratio). Disk mode
    /// can't extract conversation contents from this — caller falls back
    /// to metadata-based usage estimation.
    case encrypted
    /// File appears plaintext-encoded protobuf (low non-printable byte
    /// ratio). This is unexpected on a production Antigravity install but
    /// we leave the branch for future Antigravity versions that may
    /// switch back to plaintext (or for users in some debug mode).
    case plaintext
}

/// Coarse data extracted from a conversation .pb file. The shape mirrors
/// what `Conversation` would expose if we could decode it — same field
/// names where they overlap so SDK mode can populate a richer version of
/// the same struct.
public struct ConversationProbe: Equatable, Sendable {
    /// Result of the file inspection — controls how callers render.
    public let kind: ConversationFileKind
    /// File size in bytes. Zero when `.missing` or `.empty`.
    public let fileSize: Int
    /// Last modification time. `Date.distantPast` when missing.
    public let lastModified: Date
    /// Coarse turn count — derived from how many `*.metadata.json` files
    /// the matching brain dir has. Zero when we can't compute (no brain
    /// URL provided or no metadata files yet).
    public let turnCount: Int
    /// Coarse token estimate, derived from plaintext artifact byte sizes
    /// summed over the brain dir ÷ 4 chars/token. Renders with a `~`
    /// provisional marker in the UI. Zero when no brain dir.
    public let estimatedTokens: Int

    public init(
        kind: ConversationFileKind,
        fileSize: Int,
        lastModified: Date,
        turnCount: Int,
        estimatedTokens: Int
    ) {
        self.kind = kind
        self.fileSize = fileSize
        self.lastModified = lastModified
        self.turnCount = turnCount
        self.estimatedTokens = estimatedTokens
    }

    /// True iff Disk mode can give the user meaningful chat content.
    /// Caller renders "—" or "SDK mode required" copy in the chat pane
    /// when this is false.
    public var hasReadableContent: Bool { kind == .plaintext }
}

/// Pure-function probe. Caller supplies the conversation .pb URL and
/// optionally the matching brain URL (for turn-count + token estimate).
public enum ConversationProtoParser {

    /// Threshold above which we declare a file encrypted. Empirically
    /// 0.55 is the floor for the encrypted corpus (lowest observed: 57%
    /// non-printable). Plaintext protobufs typically run 0.10–0.25
    /// non-printable bytes; snappy/zstd compressed ones run 0.85+.
    /// 0.45 is well-separated from both regimes.
    static let encryptionThreshold: Double = 0.45

    /// Probes the file at the given URL. Never throws — all failure modes
    /// produce a probe with `.missing` / `.empty` and zeros.
    public static func probe(
        conversationURL: URL,
        brainURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> ConversationProbe {
        guard fileManager.fileExists(atPath: conversationURL.path) else {
            return ConversationProbe(
                kind: .missing,
                fileSize: 0,
                lastModified: .distantPast,
                turnCount: 0,
                estimatedTokens: 0
            )
        }

        let size = (try? fileManager.attributesOfItem(atPath: conversationURL.path)[.size] as? Int) ?? 0
        let mtime = (try? fileManager.attributesOfItem(atPath: conversationURL.path)[.modificationDate] as? Date) ?? .distantPast
        if size == 0 {
            return ConversationProbe(
                kind: .empty,
                fileSize: 0,
                lastModified: mtime,
                turnCount: 0,
                estimatedTokens: 0
            )
        }

        let kind = detectKind(url: conversationURL, fileSize: size, fileManager: fileManager)
        let turnCount = brainURL.map { countTurns(brainURL: $0, fileManager: fileManager) } ?? 0
        let estimated = brainURL.map { estimatePlaintextTokens(brainURL: $0, fileManager: fileManager) } ?? 0
        return ConversationProbe(
            kind: kind,
            fileSize: size,
            lastModified: mtime,
            turnCount: turnCount,
            estimatedTokens: estimated
        )
    }

    /// Detects encryption by sampling the first 4KB and computing the
    /// non-printable byte ratio. We deliberately sample a prefix rather
    /// than the whole file — a 4MB conversation should not pull 4MB
    /// through this call, and the prefix is a representative sample of
    /// the byte distribution (encryption is uniform; plaintext is uniform
    /// in a different way).
    static func detectKind(url: URL, fileSize: Int, fileManager: FileManager) -> ConversationFileKind {
        let sampleSize = min(fileSize, 4096)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Couldn't open — treat as encrypted (conservative; caller
            // can't read it either way).
            return .encrypted
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sampleSize), !data.isEmpty else {
            return .encrypted
        }
        let nonPrintable = countNonPrintable(in: data)
        let ratio = Double(nonPrintable) / Double(data.count)
        return ratio > encryptionThreshold ? .encrypted : .plaintext
    }

    /// Counts bytes that aren't printable ASCII (0x20-0x7e), tab (0x09),
    /// LF (0x0a), or CR (0x0d). The threshold-based detection is
    /// implemented as a ratio of this count to total sampled bytes.
    static func countNonPrintable(in data: Data) -> Int {
        var count = 0
        for byte in data {
            if byte == 0x09 || byte == 0x0a || byte == 0x0d { continue }
            if byte < 0x20 || byte > 0x7e { count += 1 }
        }
        return count
    }

    /// Counts how many `*.metadata.json` files exist in the brain dir.
    /// Each artifact (task.md, implementation_plan.md, walkthrough.md,
    /// per-subagent reports, …) ships with one metadata.json — so the
    /// count is a reasonable proxy for turn count.
    static func countTurns(brainURL: URL, fileManager: FileManager) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(at: brainURL, includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.filter { $0.lastPathComponent.hasSuffix(".metadata.json") }.count
    }

    /// Sums the byte sizes of all plaintext markdown artifacts in the
    /// brain dir (task.md, implementation_plan.md, walkthrough.md,
    /// subagent reports). Divides by 4 chars/token — an industry-standard
    /// coarse approximation for English text. Returns 0 when no markdown
    /// is found.
    static func estimatePlaintextTokens(brainURL: URL, fileManager: FileManager) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: brainURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var totalBytes = 0
        for entry in entries where entry.pathExtension == "md" {
            if let size = try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += size
            }
        }
        return totalBytes / 4
    }
}
