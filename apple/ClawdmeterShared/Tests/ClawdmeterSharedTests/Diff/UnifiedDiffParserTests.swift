import XCTest
@testable import ClawdmeterShared

final class UnifiedDiffParserTests: XCTestCase {

    // MARK: - Basic shape

    func testEmptyInputYieldsZeroFiles() {
        let parsed = UnifiedDiffParser.parse("")
        XCTAssertEqual(parsed.files.count, 0)
        XCTAssertEqual(parsed.totalLineCount, 0)
        // Empty-string hash is stable.
        XCTAssertFalse(parsed.inputHash.isEmpty)
    }

    func testNonDiffNoiseProducesNoFiles() {
        let parsed = UnifiedDiffParser.parse("random text\nno diff here\n")
        XCTAssertEqual(parsed.files.count, 0)
    }

    func testSingleFileSingleHunk() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        index 0000001..0000002 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 1)
        let file = parsed.files[0]
        XCTAssertEqual(file.path, "foo.swift")
        XCTAssertEqual(file.oldPath, "foo.swift")
        XCTAssertFalse(file.isNewFile)
        XCTAssertFalse(file.isDeleted)
        XCTAssertFalse(file.isBinary)
        XCTAssertEqual(file.hunks.count, 1)
        let hunk = file.hunks[0]
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.oldCount, 3)
        XCTAssertEqual(hunk.newStart, 1)
        XCTAssertEqual(hunk.newCount, 3)
        XCTAssertEqual(hunk.addedCount, 1)
        XCTAssertEqual(hunk.removedCount, 1)
        XCTAssertEqual(hunk.lines.count, 4)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .del, .add, .context])
    }

    func testMultiFileBoundaries() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -10,2 +10,3 @@
         keep
        +added
         tail
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 2)
        XCTAssertEqual(parsed.files[0].path, "a.swift")
        XCTAssertEqual(parsed.files[1].path, "b.swift")
        XCTAssertEqual(parsed.files[0].hunks[0].lines.count, 2)
        XCTAssertEqual(parsed.files[1].hunks[0].lines.count, 3)
    }

    func testNewFileMode() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..1234567
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +alpha
        +beta
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertTrue(parsed.files[0].isNewFile)
        XCTAssertFalse(parsed.files[0].isDeleted)
        XCTAssertEqual(parsed.files[0].path, "new.txt")
        XCTAssertNil(parsed.files[0].oldPath)
    }

    func testDeletedFileMode() {
        let diff = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 1234567..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -alpha
        -beta
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertTrue(parsed.files[0].isDeleted)
        XCTAssertFalse(parsed.files[0].isNewFile)
        // For a deletion, `+++` is `/dev/null` and we fall back to the
        // `--- a/` half, which is captured in `oldPath`.
        XCTAssertEqual(parsed.files[0].path, "gone.txt")
        XCTAssertEqual(parsed.files[0].oldPath, "gone.txt")
    }

    func testRenameKeepsBothPaths() {
        let diff = """
        diff --git a/old/foo.swift b/new/foo.swift
        similarity index 100%
        rename from old/foo.swift
        rename to new/foo.swift
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertEqual(parsed.files[0].path, "new/foo.swift")
        XCTAssertEqual(parsed.files[0].oldPath, "old/foo.swift")
        XCTAssertEqual(parsed.files[0].hunks.count, 0)
    }

    func testBinaryFileFlagged() {
        let diff = """
        diff --git a/logo.png b/logo.png
        index 1234567..89abcde 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertTrue(parsed.files[0].isBinary)
        XCTAssertEqual(parsed.files[0].hunks.count, 0)
    }

    func testSingleLineHunkHeader() {
        // `@@ -42 +42 @@` (no count) is legal when N == 1.
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -42 +42 @@
        -one
        +two
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 1)
        let hunk = parsed.files[0].hunks[0]
        XCTAssertEqual(hunk.oldStart, 42)
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newStart, 42)
        XCTAssertEqual(hunk.newCount, 1)
    }

    func testNoNewlineMarker() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let parsed = UnifiedDiffParser.parse(diff)
        let lines = parsed.files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].kind, .noNewline)
    }

    func testPathWithSpaces() {
        let diff = """
        diff --git a/dir/my file.txt b/dir/my file.txt
        --- a/dir/my file.txt
        +++ b/dir/my file.txt
        @@ -1 +1 @@
        -a
        +b
        """
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertEqual(parsed.files[0].path, "dir/my file.txt")
    }

    // MARK: - Identity / display

    func testStableLineIdentity() {
        let diff = """
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        """
        let parsed = UnifiedDiffParser.parse(diff)
        let lines = parsed.files[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.id), ["0:0:0", "0:0:1", "0:0:2"])
    }

    func testDisplayTextStripsPrefix() {
        let diff = """
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -1,3 +1,3 @@
         keep
        -old
        +new
        """
        let parsed = UnifiedDiffParser.parse(diff)
        let lines = parsed.files[0].hunks[0].lines
        XCTAssertEqual(lines[0].displayText, "keep")
        XCTAssertEqual(lines[1].displayText, "old")
        XCTAssertEqual(lines[2].displayText, "new")
    }

    // MARK: - Hash determinism

    func testInputHashIsStable() {
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        let a = UnifiedDiffParser.parse(diff)
        let b = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(a.inputHash, b.inputHash)
        XCTAssertEqual(a.files[0].hunksHash, b.files[0].hunksHash)
    }

    func testDifferentInputProducesDifferentHash() {
        let a = UnifiedDiffParser.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        let b = UnifiedDiffParser.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+c\n")
        XCTAssertNotEqual(a.inputHash, b.inputHash)
        XCTAssertNotEqual(a.files[0].hunksHash, b.files[0].hunksHash)
    }

    // MARK: - Large-input correctness

    func testLargeDiffParsesAllLines() {
        // 3 files × 100 hunks × 25 lines each = 7,500 lines.
        let diff = DiffFixtureBuilder.build(fileCount: 3, hunksPerFile: 100, linesPerHunk: 25)
        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.files.count, 3)
        XCTAssertEqual(parsed.files[0].hunks.count, 100)
        XCTAssertEqual(parsed.totalLineCount, 7_500)
    }
}
