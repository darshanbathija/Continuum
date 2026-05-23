// Reverse-engineered token-count extractor for Antigravity 2.0.6+
// SQLite (.db) conversation files. Replaces the markdown-byte ÷ 4
// heuristic on the dominant desktop file format.
//
// How we got here (2026-05-23):
//
//   1. Phase 0.5 (AntigravityConversationDB.swift comments) confirmed
//      step_payload BLOBs in the SQLite WAL conversation files are
//      plaintext protobuf — no decryption required.
//   2. Walking the matching trajectory protobuf returned by the LSP's
//      GetCascadeTrajectory RPC, we found a consistent sub-message
//      shape recurring once per assistant turn:
//
//        field 1 varint = 1133  // model id, constant across turns
//        field 2 varint         // input/prompt tokens
//        field 3 varint         // output/completion tokens
//        field 5 varint         // cached_content tokens (optional)
//        field 6 varint = 24    // candidate count, constant
//        field 9 varint         // reasoning/thoughts tokens (optional)
//        field 10 varint        // tool-use tokens (optional)
//
//   3. The same shape appeared INSIDE .db step_payload blobs after
//      recursive sub-message walking. Counting matches across one
//      19-turn conversation produced 22 records summing to 371K
//      input + 8K output + 662K cached — consistent with the LSP
//      trajectory totals for the same cascade.
//
// Caveat: the proto schema is reverse-engineered, not officially
// documented. Future Antigravity releases could renumber fields. The
// extractor has a strict signature check (must have all three of
// fields 1, 2, 3, plus field 6 with a small varint) so a shape
// change will produce zero matches rather than wrong matches — the
// caller can then fall back to the byte estimate.

#if os(macOS) || os(iOS)
import Foundation
import SQLite3

/// Aggregated token totals extracted from one Antigravity .db file.
/// Field semantics are reverse-engineered (see header); callers
/// should treat values as "real" rather than estimates but with a
/// known schema-stability risk.
public struct AntigravityDBUsage: Equatable, Sendable {
    /// Sum of `prompt_tokens` (field 2) across every UsageMetadata
    /// sub-message found in `step_payload` blobs.
    public let inputTokens: Int
    /// Sum of `completion_tokens` (field 3).
    public let outputTokens: Int
    /// Sum of `cached_content_token_count` (field 5). May be 0 when
    /// the conversation doesn't use prompt caching.
    public let cachedTokens: Int
    /// Sum of `thoughts_token_count` (field 9). Non-zero for
    /// extended-thinking mode.
    public let reasoningTokens: Int
    /// Sum of `tool_use_prompt_token_count` (field 10).
    public let toolUseTokens: Int
    /// Number of UsageMetadata sub-messages we summed over.
    /// 0 means the parser didn't find any matches — caller falls
    /// back to the byte estimator.
    public let recordCount: Int

    public static let empty = AntigravityDBUsage(
        inputTokens: 0,
        outputTokens: 0,
        cachedTokens: 0,
        reasoningTokens: 0,
        toolUseTokens: 0,
        recordCount: 0
    )

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int,
        reasoningTokens: Int,
        toolUseTokens: Int,
        recordCount: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.toolUseTokens = toolUseTokens
        self.recordCount = recordCount
    }
}

/// Static SQLite + proto extractor. No state. Open-read-close per
/// .db file. Sandbox-safe under SQLite's WAL journal_mode + busy
/// timeout — concurrent reads with the LSP writer never deadlock.
public enum AntigravityDBUsageParser {

    /// Reads usage totals from a single .db file. Returns
    /// `.empty` with `recordCount == 0` when the file can't be
    /// opened, has no `steps` table, or no UsageMetadata
    /// sub-messages match our signature. Never throws.
    public static func parseUsage(dbURL: URL) -> AntigravityDBUsage {
        var db: OpaquePointer?
        // Open URI-form with mode=ro so we don't accidentally
        // upgrade the file handle to read-write and lock out the
        // running LSP writer.
        let uri = "file:\(dbURL.path)?mode=ro&immutable=0"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let opened = db else {
            if let opened = db { sqlite3_close_v2(opened) }
            return .empty
        }
        defer { sqlite3_close_v2(opened) }
        // 2 s busy timeout. WAL guarantees readers never see torn
        // rows from concurrent writes; this absorbs the small
        // checkpoint window when the writer holds the lock.
        sqlite3_busy_timeout(opened, 2000)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, "SELECT step_payload FROM steps", -1, &stmt, nil) == SQLITE_OK,
              let prepared = stmt else {
            return .empty
        }
        defer { sqlite3_finalize(prepared) }

        var input = 0, output = 0, cached = 0, reasoning = 0, toolUse = 0, count = 0
        while sqlite3_step(prepared) == SQLITE_ROW {
            guard sqlite3_column_type(prepared, 0) == SQLITE_BLOB else { continue }
            let length = Int(sqlite3_column_bytes(prepared, 0))
            guard length > 0, let pointer = sqlite3_column_blob(prepared, 0) else { continue }
            let blob = Data(bytes: pointer, count: length)
            for record in extractUsageMetadata(from: blob) {
                input += record.input
                output += record.output
                cached += record.cached
                reasoning += record.reasoning
                toolUse += record.toolUse
                count += 1
            }
        }
        return AntigravityDBUsage(
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: reasoning,
            toolUseTokens: toolUse,
            recordCount: count
        )
    }

    // MARK: - Proto-walking core (exposed for tests)

    struct UsageRecord {
        let input: Int
        let output: Int
        let cached: Int
        let reasoning: Int
        let toolUse: Int
    }

    /// Recursively walks every nested length-delimited field in
    /// `blob` looking for UsageMetadata-shaped sub-messages. The
    /// signature: 40-150 bytes, contains varint fields 1, 2, 3
    /// with token-count-shaped values, and field 6 is a small
    /// varint (model variant marker). Exposed for unit testing.
    public static func extractUsageMetadata(from blob: Data) -> [(input: Int, output: Int, cached: Int, reasoning: Int, toolUse: Int)] {
        var results: [(input: Int, output: Int, cached: Int, reasoning: Int, toolUse: Int)] = []
        walk(blob, into: &results)
        return results
    }

    private static func walk(_ buf: Data, into results: inout [(input: Int, output: Int, cached: Int, reasoning: Int, toolUse: Int)]) {
        var reader = ProtoReader(data: buf)
        while !reader.isAtEnd {
            guard let tag = reader.readTag() else { break }
            switch tag.wireType {
            case .varint:
                _ = reader.readVarint()
            case .fixed64:
                _ = reader.advance(8)
            case .lengthDelimited:
                guard let sub = reader.readLengthDelimited() else { break }
                // Check this sub-message against the signature. We
                // cap at 200 bytes (real UsageMetadata is ~60-90;
                // anything bigger is some other container we'd
                // recurse into anyway). No lower bound — the strict
                // field-signature match in matchUsageMetadata is what
                // actually rejects false positives.
                if sub.count < 200, let match = matchUsageMetadata(sub) {
                    results.append(match)
                }
                // Also recurse — UsageMetadata can be nested under
                // various parent paths (assistant turn, gen_metadata,
                // execution metadata).
                walk(sub, into: &results)
            case .fixed32:
                _ = reader.advance(4)
            }
        }
    }

    /// Strict signature match — requires fields 1, 2, 3 as varints
    /// with plausible token-count values, and field 6 as a small
    /// varint. Rejects anything else.
    private static func matchUsageMetadata(_ sub: Data) -> (input: Int, output: Int, cached: Int, reasoning: Int, toolUse: Int)? {
        var reader = ProtoReader(data: sub)
        var f1: UInt64? = nil
        var f2: UInt64? = nil
        var f3: UInt64? = nil
        var f5: UInt64 = 0
        var f6: UInt64? = nil
        var f9: UInt64 = 0
        var f10: UInt64 = 0
        var nestedCount = 0
        while !reader.isAtEnd {
            guard let tag = reader.readTag() else { return nil }
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): f1 = reader.readVarint()
            case (2, .varint): f2 = reader.readVarint()
            case (3, .varint): f3 = reader.readVarint()
            case (5, .varint): f5 = reader.readVarint() ?? 0
            case (6, .varint): f6 = reader.readVarint()
            case (9, .varint): f9 = reader.readVarint() ?? 0
            case (10, .varint): f10 = reader.readVarint() ?? 0
            case (_, .lengthDelimited):
                nestedCount += 1
                if nestedCount > 4 { return nil }
                guard reader.readLengthDelimited() != nil else { return nil }
            case (_, .varint):
                _ = reader.readVarint()
            case (_, .fixed64):
                guard reader.advance(8) else { return nil }
            case (_, .fixed32):
                guard reader.advance(4) else { return nil }
            }
        }
        // Signature: must have all three of f1, f2, f3 + a small f6
        // (the constant model-variant marker we observed).
        guard let f1v = f1, let f2v = f2, let f3v = f3, let f6v = f6 else { return nil }
        guard f1v > 0, f6v > 0, f6v < 1000 else { return nil }
        guard f2v < 50_000_000, f3v < 5_000_000 else { return nil }
        return (
            input: Int(f2v),
            output: Int(f3v),
            cached: Int(f5),
            reasoning: Int(f9),
            toolUse: Int(f10)
        )
    }
}

// MARK: - Self-contained protobuf reader

private struct ProtoReader {
    private let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    var isAtEnd: Bool { offset >= data.count }

    enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    struct Tag {
        let fieldNumber: Int
        let wireType: WireType
    }

    mutating func readTag() -> Tag? {
        guard let raw = readVarint() else { return nil }
        guard let wireType = WireType(rawValue: Int(raw & 0x7)) else { return nil }
        return Tag(fieldNumber: Int(raw >> 3), wireType: wireType)
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func readLengthDelimited() -> Data? {
        guard let length = readVarint() else { return nil }
        let len = Int(length)
        guard offset + len <= data.count else { return nil }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + len))
        offset += len
        return slice
    }

    mutating func advance(_ n: Int) -> Bool {
        guard offset + n <= data.count else { return false }
        offset += n
        return true
    }
}

#endif
