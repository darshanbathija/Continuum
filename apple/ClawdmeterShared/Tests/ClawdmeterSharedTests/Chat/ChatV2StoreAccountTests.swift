import XCTest
@testable import ClawdmeterShared

/// Multi-account: `ChatV2Store`'s per-vendor pinned account — the
/// client-side half of the daemon's 422 fail-closed contract (stale
/// pins must degrade to Default before they ever reach a create call).
@MainActor
final class ChatV2StoreAccountTests: XCTestCase {

    private func makeStore() -> (ChatV2Store, UserDefaults) {
        let suite = "ChatV2StoreAccountTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ChatV2Store(defaults: defaults), defaults)
    }

    func testSelectAccountRoundTrip() {
        let (store, _) = makeStore()
        store.selectAccount("claude/work", for: .claude)
        XCTAssertEqual(store.accountWireId(for: .claude), "claude/work")
        // Other vendors unaffected.
        XCTAssertNil(store.accountWireId(for: .chatgpt))
    }

    func testSelectingPrimaryClearsThePin() {
        let (store, _) = makeStore()
        store.selectAccount("claude/work", for: .claude)
        store.selectAccount("claude/__primary__", for: .claude)
        XCTAssertNil(store.accountWireId(for: .claude), "primary wireId must normalize to no-pin")
        store.selectAccount("claude/work", for: .claude)
        store.selectAccount(nil, for: .claude)
        XCTAssertNil(store.accountWireId(for: .claude))
    }

    func testStalePinDegradesToDefaultAgainstAvailableList() {
        let (store, _) = makeStore()
        store.selectAccount("claude/ghost", for: .claude)
        let available = [
            ProviderInstanceDTO(instance: .primary(kind: .claude)),
            ProviderInstanceDTO(instance: ProviderInstanceId(kind: .claude, name: "work")),
        ]
        XCTAssertNil(
            store.accountWireId(for: .claude, available: available),
            "a pin to a removed account must resolve nil (Default), never reach a create call"
        )
        // A live pin survives the same filter.
        store.selectAccount("claude/work", for: .claude)
        XCTAssertEqual(store.accountWireId(for: .claude, available: available), "claude/work")
    }

    func testAccountPinPersistsAcrossStoreInstances() {
        let suite = "ChatV2StoreAccountTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let first = ChatV2Store(defaults: defaults)
        first.selectAccount("codex/pro", for: .chatgpt)

        let second = ChatV2Store(defaults: defaults)
        XCTAssertEqual(second.accountWireId(for: .chatgpt), "codex/pro")
    }
}
