import XCTest
@testable import ClawdmeterShared

final class ChatEnvPasteDetectorTests: XCTestCase {
    func testDetectsSupabaseEnvBlock() {
        let text = """
        Here is my project config:
        SUPABASE_URL=https://abc.supabase.co
        SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test
        """
        let detection = ChatEnvPasteDetector.detect(
            in: text,
            contextHints: "Set up Supabase auth next"
        )

        XCTAssertEqual(detection?.vendorId, "supabase")
        XCTAssertEqual(detection?.candidates.map(\.key).sorted(), ["SUPABASE_ANON_KEY", "SUPABASE_URL"])
    }

    func testUsesChatContextToDisambiguateVendor() {
        let text = "HCLOUD_TOKEN=secret-token-value"
        let detection = ChatEnvPasteDetector.detect(
            in: text,
            contextHints: "Deploy the app on Hetzner Cloud"
        )

        XCTAssertEqual(detection?.vendorId, "hetzner")
        XCTAssertEqual(detection?.candidates.map(\.key), ["HCLOUD_TOKEN"])
    }

    func testReturnsNilWhenNoVendorKeysMatch() {
        let text = "OPENAI_API_KEY=sk-test\nPlease wire this up."
        XCTAssertNil(ChatEnvPasteDetector.detect(in: text))
    }

    func testRedactEnvLinesRemovesMatchingAssignments() {
        let text = """
        Please configure auth.

        SUPABASE_URL=https://abc.supabase.co
        SUPABASE_ANON_KEY=secret

        Then run the migration.
        """
        let redacted = ChatEnvPasteDetector.redactEnvLines(
            from: text,
            keys: ["SUPABASE_URL", "SUPABASE_ANON_KEY"]
        )

        XCTAssertFalse(redacted.contains("SUPABASE_URL="))
        XCTAssertFalse(redacted.contains("SUPABASE_ANON_KEY="))
        XCTAssertTrue(redacted.contains("Please configure auth."))
        XCTAssertTrue(redacted.contains("Then run the migration."))
    }

    func testContextHintsJoinsRecentMessages() {
        let messages = [
            ChatMessage(
                id: "1",
                kind: .userText,
                title: "You",
                body: "Use Supabase for auth",
                at: Date()
            ),
            ChatMessage(
                id: "2",
                kind: .assistantText,
                title: "Claude",
                body: "Paste your SUPABASE_URL",
                at: Date()
            ),
        ]

        let hints = ChatEnvPasteDetector.contextHints(from: messages)
        XCTAssertTrue(hints.contains("Supabase"))
        XCTAssertTrue(hints.contains("SUPABASE_URL"))
    }
}
