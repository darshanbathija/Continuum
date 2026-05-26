import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// A12 — diff workbench virtual rendering.
//
// Pure-Swift, allocation-conscious parser for unified-diff text
// (`git diff --unified=N`). Lives in ClawdmeterShared so the Mac
// diff workbench AND any future iOS / CI consumer can share a single
// canonical model + cache.
//
// Design goals (from plan A12 acceptance: 50k-line diff in <500ms):
//   1. Single linear pass over the input — no nested re-walks per file
//      or per hunk. The old in-Mac parsers in `GitDiffPane.swift` and
//      `SessionWorkspaceView.TahoeDiffPreviewPane` re-Array-sliced and
//      re-firstIndex'd; that's quadratic in the worst case for large
//      multi-file diffs.
//   2. `Sendable` end-to-end so a `Task.detached(.utility)` can hand
//      results back to MainActor without copy-on-write surprises.
//   3. Pre-classified `ParsedDiff.Line.Kind` so SwiftUI rows don't
//      re-check `line.first` on every layout pass.
//   4. Stable IDs (file index + line index) so SwiftUI `ForEach` /
//      `LazyVStack` row recycling has a cheap identity to key on.
//      The previous Mac code used `"\(index)-\(text)"` per row which
//      allocates a String per identity check on every layout.

/// Parsed representation of a unified diff document. Value type, fully
/// `Sendable`, safe to compute on a detached task and hand to MainActor.
public struct ParsedDiff: Equatable, Hashable, Sendable {
    /// File-level slice of the diff. Each `diff --git` block becomes
    /// one `File`. Files may have zero hunks (pure rename / mode-only
    /// changes, binary files).
    public struct File: Equatable, Hashable, Sendable, Identifiable {
        /// Stable identity within a single `ParsedDiff` — index in
        /// `ParsedDiff.files`. The cache layer uses `(filePath,
        /// hunksHash)` for cross-parse keys; this `id` is only for
        /// SwiftUI row identity within one parse.
        public var id: Int { index }
        public let index: Int
        public let path: String
        public let oldPath: String?
        public let isNewFile: Bool
        public let isDeleted: Bool
        public let isBinary: Bool
        /// Verbatim `diff --git` … line plus any `index`, `new file
        /// mode`, `rename from/to`, `---`, `+++` lines that precede
        /// the first `@@`. Lets consumers re-emit the file as a
        /// standalone patch (`git apply --cached`).
        public let headerLines: [String]
        public let hunks: [Hunk]
        /// SHA256 of the sorted hunk header set + line text. Cache key
        /// component — repeat opens of the same file in the same diff
        /// snapshot resolve to an identical hash.
        public let hunksHash: String

        public init(
            index: Int,
            path: String,
            oldPath: String?,
            isNewFile: Bool,
            isDeleted: Bool,
            isBinary: Bool,
            headerLines: [String],
            hunks: [Hunk],
            hunksHash: String
        ) {
            self.index = index
            self.path = path
            self.oldPath = oldPath
            self.isNewFile = isNewFile
            self.isDeleted = isDeleted
            self.isBinary = isBinary
            self.headerLines = headerLines
            self.hunks = hunks
            self.hunksHash = hunksHash
        }

        public var addedCount: Int { hunks.reduce(0) { $0 + $1.addedCount } }
        public var removedCount: Int { hunks.reduce(0) { $0 + $1.removedCount } }
    }

    /// One `@@ -L1,N1 +L2,N2 @@ …` block.
    public struct Hunk: Equatable, Hashable, Sendable, Identifiable {
        /// Stable identity within a `File` — composite of file index
        /// + hunk index inside that file. Cheap to compute and stable
        /// across re-parses of identical input.
        public var id: String { "\(fileIndex):\(index)" }
        public let fileIndex: Int
        public let index: Int
        public let header: String
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let lines: [Line]
        public let addedCount: Int
        public let removedCount: Int

        public init(
            fileIndex: Int,
            index: Int,
            header: String,
            oldStart: Int,
            oldCount: Int,
            newStart: Int,
            newCount: Int,
            lines: [Line],
            addedCount: Int,
            removedCount: Int
        ) {
            self.fileIndex = fileIndex
            self.index = index
            self.header = header
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.lines = lines
            self.addedCount = addedCount
            self.removedCount = removedCount
        }
    }

    /// A single line inside a hunk.
    ///
    /// `text` is the raw line WITH the prefix char (` `, `+`, `-`) so
    /// downstream consumers (copy, "Explain hunk" payloads, patch
    /// reconstruction) can re-emit the verbatim diff. `displayText`
    /// strips the prefix for rendering.
    public struct Line: Equatable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Hashable, Sendable {
            case context
            case add
            case del
            case noNewline
        }
        /// Globally unique within a `ParsedDiff` — file index, hunk
        /// index, line offset. Cheap to compare, stable across parses.
        public var id: String { "\(fileIndex):\(hunkIndex):\(offset)" }
        public let fileIndex: Int
        public let hunkIndex: Int
        public let offset: Int
        public let kind: Kind
        public let text: String

        public init(
            fileIndex: Int,
            hunkIndex: Int,
            offset: Int,
            kind: Kind,
            text: String
        ) {
            self.fileIndex = fileIndex
            self.hunkIndex = hunkIndex
            self.offset = offset
            self.kind = kind
            self.text = text
        }

        public var displayText: String {
            switch kind {
            case .add, .del:
                return text.isEmpty ? text : String(text.dropFirst())
            case .context:
                // Context lines in unified format have a leading space
                // we don't want to render; strip it but tolerate the
                // empty-line case.
                if text.first == " " { return String(text.dropFirst()) }
                return text
            case .noNewline:
                return text
            }
        }
    }

    public let files: [File]
    /// SHA256 hex of the raw input + context-line count — the cache's
    /// primary key. Two parses of identical input produce the same
    /// digest, which is how `ParsedDiffCache` short-circuits repeats.
    public let inputHash: String

    public init(files: [File], inputHash: String) {
        self.files = files
        self.inputHash = inputHash
    }

    /// Total line count across all hunks. Used for perf-gate
    /// assertions ("50k-line diff opens in <500ms").
    public var totalLineCount: Int {
        files.reduce(0) { acc, file in
            acc + file.hunks.reduce(0) { $0 + $1.lines.count }
        }
    }
}

/// Stateless parser for unified-diff text. All methods are
/// `nonisolated` + `static` so callers can hop onto a detached
/// `.utility` task without dragging actor isolation along.
public enum UnifiedDiffParser {
    /// Parse a complete unified-diff document into a `ParsedDiff`.
    ///
    /// Empty input → `ParsedDiff(files: [], inputHash: …)`. Malformed
    /// blocks (no `+++`, missing `@@`, garbage between files) are
    /// tolerated by skipping the bad slice and continuing at the next
    /// `diff --git` boundary. We never throw — a render that shows
    /// "partial diff" beats a render that shows "error".
    public static func parse(_ input: String) -> ParsedDiff {
        let inputHash = sha256Hex(input)
        guard !input.isEmpty else {
            return ParsedDiff(files: [], inputHash: inputHash)
        }

        // Single split into lines. Substring slicing keeps allocations
        // bounded — each `Line.text` copies once into a `String` only
        // when we know we'll retain it.
        let raw = input.split(separator: "\n", omittingEmptySubsequences: false)

        var files: [ParsedDiff.File] = []
        var i = 0
        let endIndex = raw.count

        while i < endIndex {
            // Skip to the next `diff --git ` boundary.
            while i < endIndex, !raw[i].hasPrefix("diff --git ") {
                i += 1
            }
            guard i < endIndex else { break }

            // Find the end of this file's slice — either the next
            // `diff --git ` line or end of input.
            var j = i + 1
            while j < endIndex, !raw[j].hasPrefix("diff --git ") {
                j += 1
            }

            if let file = parseFile(
                slice: raw[i..<j],
                fileIndex: files.count
            ) {
                files.append(file)
            }
            i = j
        }

        return ParsedDiff(files: files, inputHash: inputHash)
    }

    /// SHA256 hex digest of a string. Public so `ParsedDiffCache`
    /// (and external callers wanting to pre-hash for cache lookups)
    /// can share the same hash function the parser uses internally.
    public static func sha256Hex(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - File-level parse

    private static func parseFile(
        slice: ArraySlice<Substring>,
        fileIndex: Int
    ) -> ParsedDiff.File? {
        guard let first = slice.first, first.hasPrefix("diff --git ") else {
            return nil
        }

        var path: String = ""
        var oldPath: String? = nil
        var isNew = false
        var isDel = false
        var isBinary = false
        var headerLines: [String] = []

        // Parse the file header. The header runs from the `diff --git`
        // line up to (but not including) the first `@@` hunk header,
        // OR end-of-slice for header-only files (binary, rename-only).
        var idx = slice.startIndex
        var hunkStart: Int? = nil
        while idx < slice.endIndex {
            let line = slice[idx]
            if line.hasPrefix("@@ ") {
                hunkStart = idx
                break
            }
            headerLines.append(String(line))

            if line.hasPrefix("new file mode") { isNew = true }
            if line.hasPrefix("deleted file mode") { isDel = true }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            }
            if line.hasPrefix("rename from ") {
                oldPath = String(line.dropFirst("rename from ".count))
            }
            if line.hasPrefix("--- a/") {
                // Fallback source of oldPath. Renames set it earlier;
                // straight modifications use this.
                if oldPath == nil {
                    oldPath = String(line.dropFirst("--- a/".count))
                }
            }
            if line.hasPrefix("+++ b/") {
                path = String(line.dropFirst("+++ b/".count))
            }
            idx = slice.index(after: idx)
        }

        // Header path fallback: parse out of the `diff --git a/X b/Y`
        // line itself. Paths may contain spaces, so split on ` b/`
        // (the unambiguous delimiter) rather than whitespace.
        if path.isEmpty {
            let raw = String(first.dropFirst("diff --git ".count))
            if let range = raw.range(of: " b/"),
               raw[..<range.lowerBound].hasPrefix("a/") {
                path = String(raw[range.upperBound...])
            }
        }
        // For pure deletions, `+++` is `/dev/null` so we fall back to
        // the `--- a/` half. `oldPath` already captures that.
        if path.isEmpty, let op = oldPath {
            path = op
        }

        // Parse hunks.
        var hunks: [ParsedDiff.Hunk] = []
        if let start = hunkStart {
            var k = start
            while k < slice.endIndex {
                guard slice[k].hasPrefix("@@ ") else { k = slice.index(after: k); continue }
                // Hunk body runs until the next `@@` or end of slice.
                var m = slice.index(after: k)
                while m < slice.endIndex, !slice[m].hasPrefix("@@ ") {
                    m = slice.index(after: m)
                }
                if let hunk = parseHunk(
                    headerLine: slice[k],
                    body: slice[slice.index(after: k)..<m],
                    fileIndex: fileIndex,
                    hunkIndex: hunks.count
                ) {
                    hunks.append(hunk)
                }
                k = m
            }
        }

        // Hash for cross-parse cache keys. Sorted-ish: hunk headers in
        // order + line text. Stable across machines because we operate
        // on UTF-8 bytes.
        var hasher = SHA256()
        for hunk in hunks {
            hasher.update(data: Array(hunk.header.utf8))
            for line in hunk.lines {
                hasher.update(data: Array(line.text.utf8))
                hasher.update(data: [0x0a])
            }
        }
        let hunksHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        return ParsedDiff.File(
            index: fileIndex,
            path: path,
            oldPath: oldPath,
            isNewFile: isNew,
            isDeleted: isDel,
            isBinary: isBinary,
            headerLines: headerLines,
            hunks: hunks,
            hunksHash: hunksHash
        )
    }

    // MARK: - Hunk-level parse

    private static func parseHunk(
        headerLine: Substring,
        body: ArraySlice<Substring>,
        fileIndex: Int,
        hunkIndex: Int
    ) -> ParsedDiff.Hunk? {
        let header = String(headerLine)
        // `@@ -L1,N1 +L2,N2 @@ optional context`
        // We're lenient — missing counts default to 1 (git omits ",N"
        // when N == 1).
        let trimmed = header.dropFirst(3) // drop leading "@@ "
        guard let endRange = trimmed.range(of: " @@") else {
            return nil
        }
        let coords = trimmed[..<endRange.lowerBound]
        let parts = coords.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let leftCoord = parts[0]   // -L1,N1
        let rightCoord = parts[1]  // +L2,N2
        guard leftCoord.first == "-", rightCoord.first == "+" else { return nil }

        let (oldStart, oldCount) = parseCoord(leftCoord.dropFirst())
        let (newStart, newCount) = parseCoord(rightCoord.dropFirst())

        var lines: [ParsedDiff.Line] = []
        lines.reserveCapacity(body.count)
        var added = 0
        var removed = 0
        var offset = 0
        for line in body {
            // Empty lines at the end of a diff happen because we
            // `split(omittingEmptySubsequences: false)` and the input
            // ends in a newline. Skip them rather than emit a phantom
            // context row.
            if line.isEmpty { continue }
            let kind: ParsedDiff.Line.Kind
            switch line.first {
            case "+": kind = .add; added += 1
            case "-": kind = .del; removed += 1
            case "\\": kind = .noNewline           // "\ No newline at end of file"
            default:  kind = .context
            }
            lines.append(ParsedDiff.Line(
                fileIndex: fileIndex,
                hunkIndex: hunkIndex,
                offset: offset,
                kind: kind,
                text: String(line)
            ))
            offset += 1
        }

        return ParsedDiff.Hunk(
            fileIndex: fileIndex,
            index: hunkIndex,
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: lines,
            addedCount: added,
            removedCount: removed
        )
    }

    /// Parse `"L,N"` (or `"L"`) into `(line, count)`.
    private static func parseCoord(_ raw: Substring) -> (Int, Int) {
        if let comma = raw.firstIndex(of: ",") {
            let start = Int(raw[..<comma]) ?? 0
            let count = Int(raw[raw.index(after: comma)...]) ?? 0
            return (start, count)
        }
        // Single-line hunk — `@@ -42 +42 @@` is legal git output.
        return (Int(raw) ?? 0, 1)
    }
}
