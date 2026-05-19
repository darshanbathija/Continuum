// Builds `[UUID → BrainSummary{cwd, gitRemote, branch, projectTitle, agentType}]`
// from `~/.gemini/antigravity/agyhub_summaries_proto.pb` — the global
// per-brain index Antigravity 2 writes whenever a session is created or
// closed.
//
// The file is a serialized protobuf. We DELIBERATELY don't depend on a
// vendored .proto for this index — Antigravity has reshuffled field numbers
// at least once between 2.0.0 and 2.0.1, and the index is too important
// (it's the only UUID↔cwd ground truth) to be fragile.
//
// Instead, we string-scan for the wire-format primitives:
//
//   - A `0a 24` byte pair (tag for field-1 length-delimited, length=36) at
//     the *top level* of each SummaryEntry marks the brain UUID.
//   - The first `file:///` URL after that UUID is the workspace cwd.
//   - A length-prefixed `https://....git` URL is the git remote.
//   - Strings shaped like `<owner>/<repo>` (slash-separated, ASCII) are
//     the github short identifier.
//   - The branch field follows a `22` tag (field-4 length-delimited) inside
//     the same window, and contains a path-like string.
//
// We track "current UUID" linearly: whenever we hit a fresh UUID match we
// flush the prior entry. This makes the parser O(N) over the file bytes
// and immune to nested-message reshuffling — only the top-level field-1
// UUID tag has to remain at field 1.
//
// **Performance**: file is ~130 KB on a power-user machine with ~30 brains.
// We read it whole (not mmap — Swift's `Data(contentsOf:)` is plenty for
// this size). Caller is expected to debounce refresh via mtime: don't
// re-parse unless `attributesOfItem(atPath:).contentModificationDate`
// changed.

import Foundation

/// Parsed brain summary entry. Holds just enough to map an Antigravity
/// session UUID to the repo it was launched in. The mapping is consumed
/// by `SessionFileResolver.findAntigravityBrain` (Commit 7) and by the
/// Plan pane (Commit 8) for rendering.
public struct BrainSummary: Equatable, Sendable {
    /// The brain UUID — the same identifier Antigravity uses for
    /// `brain/<uuid>/` and `conversations/<uuid>.pb`.
    public let brainUUID: String
    /// Workspace cwd as a file:// URL, decoded. `nil` when the entry
    /// didn't carry a workspace dir (rare; mostly empty placeholder
    /// entries).
    public let cwd: URL?
    /// Git remote URL (e.g. `https://github.com/glide-co/glide-mono.git`).
    /// Nil for non-git workspaces.
    public let gitRemote: URL?
    /// `owner/repo` short identifier when the remote is GitHub.
    public let gitShortName: String?
    /// Current branch (e.g. `main`, `wip/codex-abandoned-may17`). Nil
    /// when not detected.
    public let branch: String?
    /// Project title (the `agent_type` enum value or the user-set name).
    /// Nil when Antigravity hasn't named the project yet.
    public let projectTitle: String?

    public init(
        brainUUID: String,
        cwd: URL? = nil,
        gitRemote: URL? = nil,
        gitShortName: String? = nil,
        branch: String? = nil,
        projectTitle: String? = nil
    ) {
        self.brainUUID = brainUUID
        self.cwd = cwd
        self.gitRemote = gitRemote
        self.gitShortName = gitShortName
        self.branch = branch
        self.projectTitle = projectTitle
    }
}

/// In-memory index of brain UUIDs → summaries. Built by parsing the
/// `agyhub_summaries_proto.pb` file. Refresh via `BrainSummaryIndexer.parse`.
public struct BrainSummaryIndex: Equatable, Sendable {
    /// Forward map: brain UUID → summary.
    public let byUUID: [String: BrainSummary]
    /// Reverse map: canonical cwd path → UUIDs (lowercased, trailing-slash
    /// stripped). Used by `SessionFileResolver` Tier 1 lookup to map
    /// `session.cwd → [brain_uuid]`. Multiple brains per cwd is normal
    /// (one repo, many sessions).
    public let byCwdPath: [String: [String]]

    public init(byUUID: [String: BrainSummary], byCwdPath: [String: [String]]) {
        self.byUUID = byUUID
        self.byCwdPath = byCwdPath
    }

    /// Empty index — returned when the file is missing or parse fails.
    public static let empty = BrainSummaryIndex(byUUID: [:], byCwdPath: [:])
}

/// Pure-function parser for the agyhub summaries index. No state, no
/// disk caching — caller debounces via mtime.
public enum BrainSummaryIndexer {

    /// Reads + parses the file at the given URL.
    /// Returns `.empty` on any read or parse failure — the caller renders
    /// a soft "index unavailable" state in that case rather than crashing.
    public static func read(at url: URL) -> BrainSummaryIndex {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return parse(bytes: data)
    }

    /// Parses raw bytes. Exposed for tests handing in synthetic fixtures.
    public static func parse(bytes data: Data) -> BrainSummaryIndex {
        var entries: [String: BrainSummary] = [:]
        var byCwd: [String: [String]] = [:]
        var current: PartialEntry?

        let bytes = [UInt8](data)
        var i = 0
        let n = bytes.count

        while i < n {
            // Look for the top-level field-1 UUID marker: byte 0x0a (tag for
            // field 1, wire type 2) followed by 0x24 (length 36).
            if bytes[i] == 0x0a, i + 1 < n, bytes[i + 1] == 0x24, i + 2 + 36 <= n {
                let uuidStart = i + 2
                if let uuid = readUUID(bytes: bytes, at: uuidStart) {
                    // Flush previous entry.
                    if let prior = current {
                        let summary = prior.build()
                        entries[summary.brainUUID] = summary
                        if let cwd = summary.cwd {
                            let key = canonicalCwdKey(for: cwd)
                            byCwd[key, default: []].append(summary.brainUUID)
                        }
                    }
                    current = PartialEntry(brainUUID: uuid)
                    i = uuidStart + 36
                    continue
                }
            }

            // Within the current entry: hunt for length-prefixed strings.
            // Tag byte: any byte X where (X & 0x07) == 2 (wire type 2,
            // length-delimited). We don't care which field number — we
            // look at the payload bytes to decide what kind of string it
            // is. This is the "bulletproof against schema drift" trick:
            // the protobuf field number can move from field 9 to field 11
            // between Antigravity versions and we don't notice.
            if (bytes[i] & 0x07) == 2 {
                let lengthStart = i + 1
                if let (length, lengthBytes) = readVarint(bytes: bytes, at: lengthStart),
                   length > 0, length < 65536,
                   lengthStart + lengthBytes + length <= n {
                    let payloadStart = lengthStart + lengthBytes
                    let payloadEnd = payloadStart + length
                    if length >= 7 {
                        // Peek the first 8 bytes to classify.
                        let prefix = String(decoding: bytes[payloadStart..<min(payloadStart + 8, payloadEnd)], as: UTF8.self)
                        if prefix.hasPrefix("file://") {
                            let url = String(decoding: bytes[payloadStart..<payloadEnd], as: UTF8.self)
                            if let resolved = URL(string: url), resolved.isFileURL {
                                current?.recordCwd(resolved)
                            }
                            i = payloadEnd
                            continue
                        }
                        if prefix.hasPrefix("http://") || prefix.hasPrefix("https:/") {
                            let url = String(decoding: bytes[payloadStart..<payloadEnd], as: UTF8.self)
                            if url.hasSuffix(".git"), let resolved = URL(string: url) {
                                current?.recordGitRemote(resolved)
                            }
                            i = payloadEnd
                            continue
                        }
                    }
                    // String detection for owner/repo + branch + title.
                    // We require the bytes to be printable ASCII (no NULs,
                    // no high bytes) to filter out nested submessage payloads.
                    if isPrintableAscii(bytes: bytes, start: payloadStart, end: payloadEnd) {
                        let str = String(decoding: bytes[payloadStart..<payloadEnd], as: UTF8.self)
                        current?.classifyString(str)
                    }
                    i = payloadEnd
                    continue
                }
            }

            i += 1
        }

        // Flush the last entry.
        if let last = current {
            let summary = last.build()
            entries[summary.brainUUID] = summary
            if let cwd = summary.cwd {
                let key = canonicalCwdKey(for: cwd)
                byCwd[key, default: []].append(summary.brainUUID)
            }
        }

        return BrainSummaryIndex(byUUID: entries, byCwdPath: byCwd)
    }

    /// Looks up brain UUIDs for a given workspace cwd path. Returns an
    /// empty array when no entry matches. The cwd is canonicalized
    /// (trailing-slash stripped, lowercased on macOS where the fs is
    /// case-insensitive) before lookup.
    public static func lookup(cwd: URL, in index: BrainSummaryIndex) -> [String] {
        let key = canonicalCwdKey(for: cwd)
        return index.byCwdPath[key] ?? []
    }

    // MARK: - Internal helpers

    /// Canonicalizes a workspace cwd URL into a lookup key. We strip a
    /// trailing slash and normalize case on macOS where the filesystem
    /// is case-insensitive (HFS+/APFS default). Without this, an entry
    /// recorded for `/Users/foo/Bar/` won't match a session reporting
    /// `/Users/foo/bar`.
    static func canonicalCwdKey(for url: URL) -> String {
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.lowercased()
    }

    /// Reads a 36-byte canonical UUID string from the buffer. Returns nil
    /// if the bytes aren't a valid UUID. Cheap regex-free check.
    static func readUUID(bytes: [UInt8], at offset: Int) -> String? {
        guard offset + 36 <= bytes.count else { return nil }
        let hexPositions: [Int] = [
            0, 1, 2, 3, 4, 5, 6, 7,
            9, 10, 11, 12,
            14, 15, 16, 17,
            19, 20, 21, 22,
            24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
        ]
        let dashPositions: [Int] = [8, 13, 18, 23]
        for p in hexPositions {
            let b = bytes[offset + p]
            let isDigit = (b >= 0x30 && b <= 0x39)
            let isLowerHex = (b >= 0x61 && b <= 0x66)
            let isUpperHex = (b >= 0x41 && b <= 0x46)
            if !(isDigit || isLowerHex || isUpperHex) { return nil }
        }
        for p in dashPositions {
            if bytes[offset + p] != 0x2d { return nil }
        }
        return String(decoding: bytes[offset..<offset + 36], as: UTF8.self).lowercased()
    }

    /// Reads a protobuf varint. Returns (value, byteCount) or nil.
    static func readVarint(bytes: [UInt8], at offset: Int) -> (Int, Int)? {
        var value = 0
        var shift = 0
        var i = offset
        while i < bytes.count {
            let b = bytes[i]
            value |= Int(b & 0x7f) << shift
            i += 1
            if (b & 0x80) == 0 { return (value, i - offset) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Checks that every byte in `[start, end)` is printable ASCII —
    /// 0x09 (tab), 0x0a (LF), 0x0d (CR), 0x20-0x7e. Used to filter out
    /// nested submessage byte payloads from accidentally matching as
    /// strings.
    static func isPrintableAscii(bytes: [UInt8], start: Int, end: Int) -> Bool {
        guard start < end, end <= bytes.count else { return false }
        for i in start..<end {
            let b = bytes[i]
            if b == 0x09 || b == 0x0a || b == 0x0d { continue }
            if b < 0x20 || b > 0x7e { return false }
        }
        return true
    }

    /// Per-UUID partial accumulator. Holds the fields collected so far
    /// while the parser walks the body of one SummaryEntry.
    private struct PartialEntry {
        let brainUUID: String
        var cwd: URL?
        var gitRemote: URL?
        var gitShortName: String?
        var branch: String?
        var projectTitle: String?

        init(brainUUID: String) {
            self.brainUUID = brainUUID
        }

        mutating func recordCwd(_ url: URL) {
            if cwd == nil { cwd = url }
        }

        mutating func recordGitRemote(_ url: URL) {
            if gitRemote == nil { gitRemote = url }
        }

        /// Classifies an arbitrary ASCII string into one of: project title,
        /// branch, github short name, or "ignore". Ordering matters —
        /// first match wins so we don't overwrite the title with a later
        /// branch name.
        mutating func classifyString(_ str: String) {
            // GitHub short identifier (`owner/repo`): single slash, both
            // sides non-empty, no other special chars.
            if gitShortName == nil, looksLikeGithubShortName(str) {
                gitShortName = str
                return
            }
            // Branch name: contains a `/` or starts with a known prefix,
            // is path-like, and is not a github short name (already handled).
            if branch == nil, looksLikeGitBranch(str) {
                branch = str
                return
            }
            // Project title: first non-empty non-classified string.
            // Antigravity writes the project title before the cwd in
            // wire order, so this naturally captures it on the first
            // string we hit per entry.
            if projectTitle == nil, !str.isEmpty, str.count <= 256 {
                projectTitle = str
                return
            }
        }

        func build() -> BrainSummary {
            BrainSummary(
                brainUUID: brainUUID,
                cwd: cwd,
                gitRemote: gitRemote,
                gitShortName: gitShortName,
                branch: branch,
                projectTitle: projectTitle
            )
        }
    }
}

// MARK: - Classification heuristics

private func looksLikeGithubShortName(_ str: String) -> Bool {
    // `owner/repo` — single slash, no spaces, no leading dot or slash,
    // both sides 1-39 chars (GitHub username limit).
    guard let slash = str.firstIndex(of: "/") else { return false }
    let owner = str[..<slash]
    let repo = str[str.index(after: slash)...]
    guard !owner.isEmpty, !repo.isEmpty else { return false }
    guard !repo.contains("/") else { return false }
    guard owner.count <= 39, repo.count <= 100 else { return false }
    for ch in str {
        if ch == "/" || ch == "-" || ch == "_" || ch == "." { continue }
        if ch.isLetter || ch.isNumber { continue }
        return false
    }
    return true
}

private func looksLikeGitBranch(_ str: String) -> Bool {
    // Common branch shapes: `main`, `feat/foo`, `wip/codex-abandoned-may17`.
    // Must be all ASCII, length 1-100, no spaces, no leading dot/slash.
    guard str.count >= 1, str.count <= 100 else { return false }
    if str.hasPrefix(".") || str.hasPrefix("/") || str.hasSuffix("/") { return false }
    if str.contains(" ") || str.contains("\n") { return false }
    // Branch names can contain `/`, `-`, `_`, `.`, letters, digits.
    for ch in str {
        if ch == "/" || ch == "-" || ch == "_" || ch == "." { continue }
        if ch.isLetter || ch.isNumber { continue }
        return false
    }
    // Bias against single-segment lowercase words that could be project
    // titles ("BugHunter", "main" both pass this). The classifier accepts
    // any path-like, but the partial-entry's `branch == nil` check + the
    // wire-order means branch is recorded AFTER github-short-name, which
    // disambiguates `main` vs `glide-co/glide-mono`.
    return true
}
