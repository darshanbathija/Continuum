import XCTest
@testable import ClawdmeterShared

final class SkillFrontmatterTests: XCTestCase {

    func test_singleLine_nameAndDescription() {
        let body = "---\nname: foo\ndescription: bar baz\n---\nrest of skill"
        let r = SkillFrontmatter.parse(body)
        XCTAssertEqual(r?.name, "foo")
        XCTAssertEqual(r?.description, "bar baz")
    }

    func test_blockScalarPipe_concatenatesContinuation() {
        let body = """
        ---
        name: foo
        description: |
          first line
          second line
        ---
        rest
        """
        let r = SkillFrontmatter.parse(body)
        XCTAssertEqual(r?.description, "first line second line")
    }

    func test_blockScalarFolded_concatenatesContinuation() {
        let body = """
        ---
        name: foo
        description: >
          line one
          line two
        ---
        """
        let r = SkillFrontmatter.parse(body)
        XCTAssertEqual(r?.description, "line one line two")
    }

    func test_missingOpeningFence_returnsNil() {
        XCTAssertNil(SkillFrontmatter.parse("name: foo\ndescription: bar"))
    }

    func test_missingClosingFence_returnsNil() {
        XCTAssertNil(SkillFrontmatter.parse("---\nname: foo\ndescription: bar"))
    }

    func test_missingName_returnsNil() {
        XCTAssertNil(SkillFrontmatter.parse("---\ndescription: orphan\n---"))
    }

    func test_emptyName_returnsNil() {
        XCTAssertNil(SkillFrontmatter.parse("---\nname: \ndescription: bar\n---"))
    }

    func test_nameOnly_descriptionDefaultsToEmpty() {
        let r = SkillFrontmatter.parse("---\nname: solo\n---")
        XCTAssertEqual(r?.name, "solo")
        XCTAssertEqual(r?.description, "")
    }

    func test_blockScalar_unindentedLineEndsBlock() {
        // Description block should close as soon as a non-indented line
        // appears (e.g., the next key, like `version:`).
        let body = """
        ---
        name: foo
        description: |
          first
          second
        version: 1.0
        ---
        """
        let r = SkillFrontmatter.parse(body)
        XCTAssertEqual(r?.description, "first second")
    }

    func test_realWorldFixture() {
        // Mirrors the actual /plan-ceo-review SKILL.md frontmatter shape
        // observed by the review on 2026-05-18.
        let body = """
        ---
        name: plan-ceo-review
        preamble-tier: 3
        interactive: true
        version: 1.0.0
        description: |
          CEO/founder-mode plan review. Rethink the problem, find the 10-star
          product, challenge premises, expand scope when it creates a better
          product. Four modes...
        ---
        rest of body
        """
        let r = SkillFrontmatter.parse(body)
        XCTAssertEqual(r?.name, "plan-ceo-review")
        XCTAssertTrue(r?.description.hasPrefix("CEO/founder-mode plan review.") == true)
    }
}
