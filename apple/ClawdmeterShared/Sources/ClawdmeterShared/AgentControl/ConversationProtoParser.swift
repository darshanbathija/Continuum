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

    // MARK: - v0.8.0: step_payload blob decode (Phase 0.5 verdict T7=A)

    /// Plain protobuf wire format. Phase 0.5 confirmed step_payload
    /// blobs in the SQLite WAL conversation DBs are unencrypted —
    /// hex dumps showed visible ASCII strings ("list_dir", "view_file",
    /// tool call IDs) right next to the wire-format tags. Decoding via
    /// the byte-level varint reader below avoids dragging in
    /// swift-protobuf and the vendored conversation.proto schema, both
    /// of which would also need to track Antigravity's proto evolution.
    /// The wire format itself is stable across proto-schema changes;
    /// only the field meanings shift, and we only care about a few
    /// fields here (tool name + tool call id, for the chat UI tags).

    /// What a step row represents. Mirrors the SQLite `steps.step_type`
    /// values Phase 0 captured (8=tool_call_request, 9=tool_call_response,
    /// 13=assistant_text, etc.) but kept as a raw integer so adding new
    /// types upstream doesn't require a Swift enum update.
    public struct DecodedStep: Equatable, Sendable {
        /// Outer field 1 varint. Matches the `step_type` SQLite column.
        public let stepType: UInt64?
        /// Outer field 4 varint. Matches the `status` SQLite column.
        public let stepStatus: UInt64?
        /// Tool-call identifier (UTF-8 string at nested field 4 → field 1
        /// in the Phase 0.5 hex examples). Nil for non-tool steps.
        public let toolCallId: String?
        /// Human-readable tool name like `list_dir`, `view_file`,
        /// `apply_patch`. Same nesting as toolCallId.
        public let toolName: String?
        /// True iff the outer wrapper parsed without short-reads or
        /// malformed varints. False indicates a partial decode — the
        /// fields above may still be set but cannot be trusted.
        public let parseClean: Bool

        public init(
            stepType: UInt64? = nil,
            stepStatus: UInt64? = nil,
            toolCallId: String? = nil,
            toolName: String? = nil,
            parseClean: Bool = true
        ) {
            self.stepType = stepType
            self.stepStatus = stepStatus
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.parseClean = parseClean
        }
    }

    /// Decode a raw `step_payload` blob into the small subset of fields
    /// the chat UI consumes. Tolerant — returns the partial result on
    /// malformed input with `parseClean=false`.
    ///
    /// Wire layout (Phase 0.5 verdict):
    /// ```
    ///   outer: { 1: varint stepType, 4: varint status, 5: bytes inner }
    ///   inner: { 1: nested metadata (12 bytes timestamps), 4: bytes toolcall }
    ///   toolcall: { 1: string toolCallId, 2: string toolName }
    /// ```
    public static func decode(_ data: Data) -> DecodedStep {
        var reader = ProtoReader(data: data)
        var stepType: UInt64?
        var stepStatus: UInt64?
        var toolCallId: String?
        var toolName: String?
        var clean = true

        while let (fieldNumber, wireType) = reader.readTag() {
            switch (fieldNumber, wireType) {
            case (1, .varint):
                if let v = reader.readVarint() { stepType = v } else { clean = false }
            case (4, .varint):
                if let v = reader.readVarint() { stepStatus = v } else { clean = false }
            case (5, .lengthDelimited):
                if let inner = reader.readLengthDelimited() {
                    let (id, name, innerClean) = decodeInnerPayload(inner)
                    if let id { toolCallId = id }
                    if let name { toolName = name }
                    if !innerClean { clean = false }
                } else {
                    clean = false
                }
            default:
                if !reader.skipField(wireType: wireType) { clean = false }
            }
        }

        if !reader.isClean { clean = false }
        return DecodedStep(
            stepType: stepType,
            stepStatus: stepStatus,
            toolCallId: toolCallId,
            toolName: toolName,
            parseClean: clean
        )
    }

    /// Inner payload at outer field 5. Looks for the toolcall submessage
    /// at inner field 4 → unpacks tool_call_id (field 1) + tool_name
    /// (field 2). All other fields are skipped — we don't yet need the
    /// nested timestamps or step-graph metadata.
    private static func decodeInnerPayload(_ data: Data) -> (id: String?, name: String?, clean: Bool) {
        var reader = ProtoReader(data: data)
        var toolCallId: String?
        var toolName: String?
        var clean = true

        while let (fieldNumber, wireType) = reader.readTag() {
            if fieldNumber == 4 && wireType == .lengthDelimited {
                guard let tc = reader.readLengthDelimited() else { clean = false; continue }
                var tcReader = ProtoReader(data: tc)
                while let (tcField, tcWire) = tcReader.readTag() {
                    switch (tcField, tcWire) {
                    case (1, .lengthDelimited):
                        toolCallId = tcReader.readString()
                        if toolCallId == nil { clean = false }
                    case (2, .lengthDelimited):
                        toolName = tcReader.readString()
                        if toolName == nil { clean = false }
                    default:
                        if !tcReader.skipField(wireType: tcWire) { clean = false }
                    }
                }
                if !tcReader.isClean { clean = false }
            } else if !reader.skipField(wireType: wireType) {
                clean = false
            }
        }
        if !reader.isClean { clean = false }
        return (toolCallId, toolName, clean)
    }
}

// MARK: - Minimal protobuf wire-format reader

/// Just enough of the protobuf wire format to walk varints, length-delimited
/// fields, and length-prefixed UTF-8 strings. Not a general decoder —
/// callers are expected to know the schema shape they're consuming.
/// Failures are surfaced via nil returns + the `isClean` flag.
private struct ProtoReader {
    private let data: Data
    private var cursor: Int = 0
    private(set) var isClean: Bool = true

    init(data: Data) { self.data = data }

    enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
        case unknown = 99
    }

    var atEnd: Bool { cursor >= data.count }

    mutating func readTag() -> (fieldNumber: Int, wireType: WireType)? {
        guard !atEnd, let raw = readVarint() else { return nil }
        let fieldNumber = Int(raw >> 3)
        let wireRaw = Int(raw & 0x07)
        let wireType = WireType(rawValue: wireRaw) ?? .unknown
        return (fieldNumber, wireType)
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < data.count {
            let byte = data[data.startIndex + cursor]
            cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 { isClean = false; return nil }
        }
        isClean = false
        return nil
    }

    mutating func readLengthDelimited() -> Data? {
        guard let length = readVarint() else { return nil }
        let intLen = Int(length)
        guard intLen >= 0, cursor + intLen <= data.count else {
            isClean = false
            return nil
        }
        let start = data.startIndex + cursor
        let slice = data.subdata(in: start..<(start + intLen))
        cursor += intLen
        return slice
    }

    mutating func readString() -> String? {
        guard let bytes = readLengthDelimited() else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// Walk past a field whose tag we already consumed. Returns false
    /// when the field is malformed (i.e. ran off the buffer).
    mutating func skipField(wireType: ProtoReader.WireType) -> Bool {
        switch wireType {
        case .varint:
            return readVarint() != nil
        case .fixed64:
            if cursor + 8 > data.count { isClean = false; return false }
            cursor += 8
            return true
        case .lengthDelimited:
            return readLengthDelimited() != nil
        case .fixed32:
            if cursor + 4 > data.count { isClean = false; return false }
            cursor += 4
            return true
        case .unknown:
            isClean = false
            return false
        }
    }
}
