import Foundation
@testable import ClawdmeterShared

/// Deterministic synthetic-diff generator for parser + cache + perf
/// tests. Output is byte-stable across machines and OS upgrades so
/// `inputHash` is reproducible in CI.
///
/// This mirrors the shape of `git diff --unified=N` output but builds
/// it from a fixed-seed LCG so the file is identical from one run to
/// the next. We deliberately keep this in the test target — it's not
/// production code, and it has no callers outside the Diff test suite.
enum DiffFixtureBuilder {

    /// Build a unified-diff string with `fileCount` files, each
    /// containing `hunksPerFile` hunks of `linesPerHunk` lines.
    /// Roughly half of each hunk's lines are context, ¼ deletions,
    /// ¼ additions — close enough to real-world ratios that the
    /// parser exercises every branch.
    ///
    /// Total line count = `fileCount * hunksPerFile * linesPerHunk`.
    /// For the A12 acceptance gate (50k lines), call with e.g.
    /// `(fileCount: 5, hunksPerFile: 100, linesPerHunk: 100)`.
    static func build(fileCount: Int, hunksPerFile: Int, linesPerHunk: Int) -> String {
        var out = ""
        out.reserveCapacity(fileCount * hunksPerFile * linesPerHunk * 20)
        var rng: UInt64 = 0xC0FFEE_DEADBEEF
        for fileIdx in 0..<fileCount {
            let path = "src/synthetic/file_\(fileIdx).swift"
            out.append("diff --git a/\(path) b/\(path)\n")
            out.append("index 1234567..89abcde 100644\n")
            out.append("--- a/\(path)\n")
            out.append("+++ b/\(path)\n")
            var lineCursor = 1
            for hunkIdx in 0..<hunksPerFile {
                out.append("@@ -\(lineCursor),\(linesPerHunk) +\(lineCursor),\(linesPerHunk) @@ context\n")
                for lineIdx in 0..<linesPerHunk {
                    // Deterministic rotation: every 4th line is del,
                    // every 4th + 2 is add, rest are context.
                    let bucket = (lineIdx &+ hunkIdx) % 4
                    let payload = synthLine(rng: &rng, fileIdx: fileIdx, hunkIdx: hunkIdx, lineIdx: lineIdx)
                    switch bucket {
                    case 0: out.append("-\(payload)\n")
                    case 2: out.append("+\(payload)\n")
                    default: out.append(" \(payload)\n")
                    }
                }
                lineCursor += linesPerHunk
            }
        }
        return out
    }

    /// 50k-line fixture matching the A12 acceptance gate. Frozen
    /// shape — keep stable so perf trends across PRs are comparable.
    static func fiftyKLineDiff() -> String {
        // 5 files × 100 hunks × 100 lines = 50,000 diff lines.
        build(fileCount: 5, hunksPerFile: 100, linesPerHunk: 100)
    }

    // MARK: - Internals

    private static func synthLine(
        rng: inout UInt64,
        fileIdx: Int,
        hunkIdx: Int,
        lineIdx: Int
    ) -> String {
        // 64-bit xorshift — bit-stable across machines + OS upgrades.
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        let tag = String(rng % 999_983, radix: 36)
        return "synthetic line f=\(fileIdx) h=\(hunkIdx) l=\(lineIdx) tag=\(tag)"
    }
}
