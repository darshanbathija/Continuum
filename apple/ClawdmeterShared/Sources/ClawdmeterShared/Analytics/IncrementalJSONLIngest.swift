import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Plan B1 (Codex D14#2 acceptance folded in): incremental JSONL ingest actor.
///
/// **Foundation PR scope:** this file lands the actor + its test suite.
/// Wiring into `UsageHistoryLoader.parseClaudeFile` / `parseCodexFile`
/// (the lines the plan named as 484-491 in `UsageHistoryLoader.swift`)
/// and into `JSONLTail` (the chat path) lands in a follow-up B1-wire PR.
/// Foundation pattern follows F1 (#128 → #129–#135).
///
/// Replaces the "read whole file from byte 0 on every refresh" pattern that
/// `UsageHistoryLoader.parseClaudeFile` / `parseCodexFile` use today. On
/// each `ingest(at:)` call the actor returns ONLY the newline-terminated
/// lines that were appended since the last call, plus enough metadata for
/// the caller to detect when a rotation / truncation forced a full reparse.
///
/// Design:
///   - State is keyed by `URL.path` so the same `IncrementalJSONLIngest`
///     instance can track many files (one per `~/.claude/projects/<repo>/`
///     session JSONL).
///   - Per-file we remember `(byteOffset, lineCount, mtime, size, inode)`.
///     `inode` is the kernel's identifier for the inode the path resolved
///     to last time; a change means the path now points at a different
///     file (rotation, atomic replace, etc.) so we MUST reset the offset.
///   - **D9 cross-check (Codex D14#2):** the caller-side parsers count
///     how many lines they consumed. The actor verifies `lineCount` grew
///     by EXACTLY the number of newlines the actor itself observed in the
///     newly-read bytes. Mismatch is a structural invariant violation
///     (the file got rewritten under us without an inode change, or our
///     offset arithmetic drifted) — the actor logs, resets offset to 0,
///     and the next call reparses the whole file. We never silently lose
///     lines on a mismatch.
///   - **Partial-line-at-EOF safety:** if the last read chunk doesn't end
///     in `\n`, we hold that trailing fragment back and advance `offset`
///     only past the last newline we saw. The next call reads from that
///     point and re-sees the partial fragment plus whatever else got
///     appended.
///   - **Rotation/deletion/truncation:** any of (file size < stored
///     size), (inode change), (mtime older than stored mtime) ⇒ reset
///     offset to 0 and reparse the whole file. Deletion ⇒ drop the
///     state entry; next ingest call (if the file reappears) starts
///     fresh.
///
/// Thread-safety: the actor IS the synchronization boundary. Callers
/// `await` `ingest(at:)`; no internal locks needed. The actor never
/// re-enters itself.
///
/// Intentionally provider-agnostic: this actor doesn't know about
/// Claude / Codex / etc. The caller passes a closure that turns a
/// `Data` (one JSONL line, without trailing `\n`) into a domain
/// object (e.g. `UsageRecord?`).
public actor IncrementalJSONLIngest {

    #if canImport(OSLog)
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "IncrementalJSONLIngest")
    #endif

    /// Per-file ingest cursor. `Sendable` + `Codable` so callers that want
    /// to persist state across launches (the AnalyticsCache path) can
    /// serialize the dict directly.
    public struct FileState: Codable, Sendable, Equatable {
        /// Next byte to read from. The byte at `byteOffset` is the first
        /// byte the next `ingest(at:)` call will return.
        public var byteOffset: UInt64
        /// Number of complete newline-terminated lines the actor has
        /// observed across all reads of this file at this inode. Used by
        /// the D9 cross-check to detect missed lines.
        public var lineCount: UInt64
        /// File size at the time we last read it. Used to detect
        /// truncation (current size < stored size ⇒ reset).
        public var size: UInt64
        /// File mtime at last read. Stored as TimeInterval so it round-
        /// trips through `Codable` without DateFormatter weirdness.
        public var mtime: TimeInterval
        /// Inode the path last resolved to. Stored as `UInt64` even on
        /// platforms where `st_ino` is narrower so we have one schema.
        /// `0` ⇒ unknown / first-touch.
        public var inode: UInt64

        public init(
            byteOffset: UInt64 = 0,
            lineCount: UInt64 = 0,
            size: UInt64 = 0,
            mtime: TimeInterval = 0,
            inode: UInt64 = 0
        ) {
            self.byteOffset = byteOffset
            self.lineCount = lineCount
            self.size = size
            self.mtime = mtime
            self.inode = inode
        }
    }

    /// Result of a single `ingest(at:)` call. `lines` is empty when nothing
    /// new has been appended. `didReset` is `true` when the actor detected
    /// rotation / truncation / cross-check mismatch and reparsed the file
    /// from byte 0 — useful for the caller to log or invalidate its own
    /// downstream cache for this path.
    public struct IngestResult: Sendable, Equatable {
        /// Each element is one JSONL line WITHOUT its trailing `\n`. Empty
        /// lines (zero-length between two consecutive `\n`s) are skipped.
        public var lines: [Data]
        /// State after this ingest. Caller can persist this to disk so the
        /// next launch picks up where this one left off.
        public var stateAfter: FileState
        /// Number of newlines THIS ingest call observed in the byte range
        /// it just read. The caller uses this as the right-hand side of
        /// the D9 cross-check: if the parser consumed N lines from
        /// `lines` (or N lines including malformed/empty ones), they
        /// pass N to `commit(...)` and the actor verifies N == this
        /// number. `lines.count` is NOT the same — empty lines and
        /// stripped `\r\n` lines bump this counter but not `lines`.
        public var observedNewlinesThisCall: UInt64
        /// `true` when the actor reset the cursor to byte 0 (rotation,
        /// truncation, or cross-check mismatch). When `true`, `lines`
        /// contains EVERY line currently in the file, not just the new
        /// tail — the caller's domain cache for this file should be
        /// discarded and rebuilt from these lines.
        public var didReset: Bool
        /// Reason for the reset. `.none` when `didReset == false`.
        public var resetReason: ResetReason

        public enum ResetReason: String, Sendable, Codable {
            case none
            case firstTouch
            case inodeChanged
            case truncated
            case mtimeWentBackwards
            case lineCountMismatch
            case offsetExceedsSize
        }
    }

    /// Per-path cursor state. `URL.path` is the key. Callers can hydrate
    /// from disk via `seed(states:)` and snapshot via `snapshot()`.
    private var states: [String: FileState] = [:]

    public init(initialStates: [String: FileState] = [:]) {
        self.states = initialStates
    }

    // MARK: - State accessors (for persistence)

    public func snapshot() -> [String: FileState] {
        states
    }

    public func seed(states: [String: FileState]) {
        self.states = states
    }

    public func state(for url: URL) -> FileState? {
        states[url.path]
    }

    /// Drop the cursor for a file that no longer exists (deletion). The
    /// caller's enumeration pass surfaces missing files; pass them here
    /// so we don't leak FileState entries forever.
    public func forget(_ url: URL) {
        states.removeValue(forKey: url.path)
    }

    // MARK: - Ingest

    /// Read the new tail of `url` since the last `ingest` call. The
    /// returned `lines` are ready to hand to a per-provider parser
    /// (`ClaudeUsageParser.parse(line:)` etc.). The caller MUST report
    /// back via `commit(_:for:lineCountAfter:)` once it has finished
    /// processing the lines, OR pass `autoCommit: true` to have the
    /// actor advance the cursor without a cross-check (useful for
    /// callers that don't track line counts independently).
    ///
    /// - Parameter url: file to read from
    /// - Parameter autoCommit: when `true`, the cursor advances on the
    ///   actor side immediately. The actor uses the newline count it
    ///   observed itself as the `lineCountAfter` value, so the cross-
    ///   check becomes a tautology — caller forfeits the cross-check
    ///   guarantee. When `false`, the cursor only advances on
    ///   `commit(...)`, and the caller's reported line count is verified
    ///   against the actor's observed newline count.
    public func ingest(
        at url: URL,
        autoCommit: Bool = false
    ) throws -> IngestResult {
        let path = url.path
        var prior = states[path] ?? FileState()
        let isFirstTouch = states[path] == nil

        // Stat the file. Missing file ⇒ throw a typed error so the caller
        // can decide whether to forget() or retry.
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw IngestError.statFailed(path: path, underlying: error)
        }
        let currentSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let currentMtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let currentInode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        // Decide whether we have to reset before reading.
        var resetReason: IngestResult.ResetReason = .none
        if isFirstTouch {
            // First-touch isn't a "reset" semantically (there was nothing
            // to lose) but we still need to mark didReset=true so the
            // caller knows the returned `lines` are the WHOLE file, not
            // an incremental tail.
            resetReason = .firstTouch
        } else if prior.inode != 0, currentInode != 0, prior.inode != currentInode {
            resetReason = .inodeChanged
        } else if currentSize < prior.size {
            resetReason = .truncated
        } else if currentMtime != 0, prior.mtime != 0, currentMtime + 0.001 < prior.mtime {
            // mtime going backwards while size is consistent is suspicious
            // (atomic replace by editor, restore-from-backup, etc.). Tiny
            // epsilon to absorb filesystem-level rounding on some hosts.
            resetReason = .mtimeWentBackwards
        } else if prior.byteOffset > currentSize {
            // Should never happen — offset only advances on successful
            // reads. If it does, something tampered with the state dict
            // (or persistence rolled back). Reset rather than seeking
            // past EOF.
            resetReason = .offsetExceedsSize
        }

        if resetReason != .none {
            prior = FileState(
                byteOffset: 0,
                lineCount: 0,
                size: 0,
                mtime: 0,
                inode: 0
            )
            #if canImport(OSLog)
            if resetReason != .firstTouch {
                logger.notice("IncrementalJSONLIngest reset \(path, privacy: .public): \(resetReason.rawValue, privacy: .public)")
            }
            #endif
        }

        // Nothing new to read?
        if currentSize == prior.byteOffset {
            let unchanged = FileState(
                byteOffset: prior.byteOffset,
                lineCount: prior.lineCount,
                size: currentSize,
                mtime: currentMtime,
                inode: currentInode
            )
            states[path] = unchanged
            return IngestResult(
                lines: [],
                stateAfter: unchanged,
                observedNewlinesThisCall: 0,
                didReset: resetReason != .none,
                resetReason: resetReason
            )
        }

        // Open + seek + read.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw IngestError.openFailed(path: path, underlying: error)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: prior.byteOffset)
        } catch {
            throw IngestError.seekFailed(path: path, offset: prior.byteOffset, underlying: error)
        }

        // Read everything from offset to current EOF in one slurp. JSONL
        // session files for Claude run a few MB at most; the cumulative
        // load across many files is what we're optimizing, not any one
        // file. Pull into Data; split out complete lines; hold back any
        // trailing partial.
        let toRead = Int(currentSize - prior.byteOffset)
        let chunk: Data
        do {
            chunk = (try handle.read(upToCount: toRead)) ?? Data()
        } catch {
            throw IngestError.readFailed(path: path, underlying: error)
        }

        var lines: [Data] = []
        var bytesConsumed: UInt64 = 0
        var observedNewlines: UInt64 = 0

        // Walk the chunk, slicing on `\n` (0x0A). Empty lines are skipped
        // but they DO count as newlines for the D9 cross-check (the caller
        // didn't see them as records but the underlying file definitely
        // had a newline there).
        var lineStart = 0
        var i = 0
        let bytes = [UInt8](chunk)
        while i < bytes.count {
            if bytes[i] == 0x0A {
                observedNewlines += 1
                if i > lineStart {
                    let slice = chunk.subdata(in: lineStart..<i)
                    // Tolerate \r\n (rare on macOS but real on Windows-
                    // touched JSONLs).
                    if slice.last == 0x0D {
                        let trimmed = slice.subdata(in: slice.startIndex..<(slice.startIndex + slice.count - 1))
                        if !trimmed.isEmpty {
                            lines.append(trimmed)
                        }
                    } else {
                        lines.append(slice)
                    }
                }
                bytesConsumed = UInt64(i + 1)
                lineStart = i + 1
            }
            i += 1
        }
        // Any bytes after the last `\n` are a partial line — leave them
        // unconsumed so the next call re-reads them after the writer
        // finishes the line.

        let newOffset = prior.byteOffset + bytesConsumed
        let newLineCount = prior.lineCount + observedNewlines
        let stateAfter = FileState(
            byteOffset: newOffset,
            lineCount: newLineCount,
            size: currentSize,
            mtime: currentMtime,
            inode: currentInode
        )

        // If auto-commit is on, advance the cursor immediately. The
        // observed-newlines count IS the caller's count by definition in
        // this mode, so the cross-check is vacuous but the bookkeeping is
        // identical.
        if autoCommit {
            states[path] = stateAfter
        }
        // When !autoCommit, the caller is expected to invoke commit(_:for:lineCountAfter:)
        // with their own line count so the D9 cross-check has bite. Until
        // then the cursor stays at `prior.byteOffset` so a crash mid-parse
        // doesn't lose data.

        return IngestResult(
            lines: lines,
            stateAfter: stateAfter,
            observedNewlinesThisCall: observedNewlines,
            didReset: resetReason != .none,
            resetReason: resetReason
        )
    }

    /// Commit a successful parse. The caller passes `linesProcessed` —
    /// the number of lines the parser SAW (not necessarily the number
    /// that produced records; a malformed line still counts because
    /// the underlying byte range had a `\n`). The actor compares
    /// against `result.observedNewlinesThisCall` (the number of `\n`s
    /// the actor observed in the same byte range). Mismatch ⇒ reset
    /// the cursor to 0 (so the next ingest reparses the whole file)
    /// and throw `crossCheckFailed`.
    ///
    /// The mismatch case maps to the D9 "we missed lines" pathology: if
    /// the caller parsed N lines but the byte range had N+K newlines,
    /// the K extra were lost somewhere in the pipeline. Resetting and
    /// reparsing gives the caller a second chance to see them.
    public func commit(
        _ result: IngestResult,
        for url: URL,
        linesProcessed: UInt64
    ) throws {
        let expected = result.observedNewlinesThisCall
        if linesProcessed != expected {
            // Remove the state entry entirely. Next ingest() will see
            // `isFirstTouch == true`, surface that to the caller via
            // `didReset=true, resetReason=.firstTouch`, and reparse the
            // whole file. The caller's downstream cache for this file
            // should be discarded since we cannot trust any partial
            // state derived from a parse that lost lines.
            states.removeValue(forKey: url.path)
            #if canImport(OSLog)
            logger.error("IncrementalJSONLIngest cross-check failed \(url.path, privacy: .public): observed=\(expected, privacy: .public) parsed=\(linesProcessed, privacy: .public) — resetting")
            #endif
            throw IngestError.crossCheckFailed(
                path: url.path,
                observedNewlines: expected,
                parsedLineCount: linesProcessed
            )
        }
        states[url.path] = result.stateAfter
    }

    // MARK: - Errors

    public enum IngestError: Error, Equatable, Sendable {
        case statFailed(path: String, underlying: Error)
        case openFailed(path: String, underlying: Error)
        case seekFailed(path: String, offset: UInt64, underlying: Error)
        case readFailed(path: String, underlying: Error)
        case crossCheckFailed(path: String, observedNewlines: UInt64, parsedLineCount: UInt64)

        public static func == (lhs: IngestError, rhs: IngestError) -> Bool {
            switch (lhs, rhs) {
            case (.statFailed(let lp, _), .statFailed(let rp, _)): return lp == rp
            case (.openFailed(let lp, _), .openFailed(let rp, _)): return lp == rp
            case (.seekFailed(let lp, let lo, _), .seekFailed(let rp, let ro, _)): return lp == rp && lo == ro
            case (.readFailed(let lp, _), .readFailed(let rp, _)): return lp == rp
            case (.crossCheckFailed(let lp, let lo, let lc), .crossCheckFailed(let rp, let ro, let rc)):
                return lp == rp && lo == ro && lc == rc
            default: return false
            }
        }
    }
}
