import XCTest
@testable import ClawdmeterShared

final class CodePreferredAccountStoreTests: XCTestCase {

    private let defaultsKey = "clawdmeter.code.preferredAccountWireIdByKind"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func test_noPreference_primaryIsPreferred() {
        let primary = ProviderInstanceId.primary(kind: .claude)
        let work = ProviderInstanceId(kind: .claude, name: "work")
        XCTAssertTrue(CodePreferredAccountStore.isPreferred(primary))
        XCTAssertFalse(CodePreferredAccountStore.isPreferred(work))
        XCTAssertNil(CodePreferredAccountStore.providerInstanceId(for: .claude, available: [primary, work]))
    }

    func test_setSecondary_roundTrips() {
        CodePreferredAccountStore.setPreferred(wireId: "claude/personal", for: .claude)
        XCTAssertEqual(CodePreferredAccountStore.preferredWireId(for: .claude), "claude/personal")
        let personal = ProviderInstanceId(kind: .claude, name: "personal")
        XCTAssertTrue(CodePreferredAccountStore.isPreferred(personal))
        XCTAssertEqual(
            CodePreferredAccountStore.providerInstanceId(for: .claude, available: [ProviderInstanceId.primary(kind: .claude), personal]),
            "claude/personal"
        )
    }

    func test_setPrimary_clearsSecondaryPin() {
        CodePreferredAccountStore.setPreferred(wireId: "codex/work", for: .codex)
        CodePreferredAccountStore.setPreferred(wireId: nil, for: .codex)
        XCTAssertNil(CodePreferredAccountStore.preferredWireId(for: .codex))
        XCTAssertTrue(CodePreferredAccountStore.isPreferred(ProviderInstanceId.primary(kind: .codex)))
    }

    func test_stalePin_fallsBackToPrimary() {
        CodePreferredAccountStore.setPreferred(wireId: "claude/removed", for: .claude)
        XCTAssertNil(
            CodePreferredAccountStore.providerInstanceId(
                for: .claude,
                available: [ProviderInstanceId.primary(kind: .claude)]
            )
        )
    }
}
