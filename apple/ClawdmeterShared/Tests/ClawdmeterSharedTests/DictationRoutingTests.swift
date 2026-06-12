import XCTest
@testable import ClawdmeterShared

final class DictationRoutingTests: XCTestCase {
    func testResolveRoutesActiveRecordingWithoutTabSwitch() {
        let resolution = DictationRouteResolver.resolve(
            .init(currentTab: "settings", activeRecordingTarget: .chat)
        )
        XCTAssertEqual(resolution, .route(.chat))
    }

    func testResolvePrefersChatWhenChatTabActive() {
        let resolution = DictationRouteResolver.resolve(.init(currentTab: "chat"))
        XCTAssertEqual(resolution, .route(.chat))
    }

    func testResolveBlocksReadOnlyChatTab() {
        let resolution = DictationRouteResolver.resolve(
            .init(currentTab: "chat", chatComposerIsReadOnly: true)
        )
        XCTAssertEqual(resolution, .unavailableReadOnlyChat)
    }

    func testResolvePrefersCodeWhenCodeTabActive() {
        let resolution = DictationRouteResolver.resolve(.init(currentTab: "code"))
        XCTAssertEqual(resolution, .route(.code))
    }

    func testResolveFallsBackToLastDictationTab() {
        let resolution = DictationRouteResolver.resolve(
            .init(currentTab: "usage", lastDictationTab: .chat)
        )
        XCTAssertEqual(resolution, .route(.chat))
    }

    func testResolveDefaultsToCodeWithoutHistory() {
        let resolution = DictationRouteResolver.resolve(.init(currentTab: "settings"))
        XCTAssertEqual(resolution, .route(.code))
    }

    func testTextMergePreservesBaseAndPartial() {
        XCTAssertEqual(
            DictationTextMerge.mergedText(baseBeforeSession: "draft", sessionPartial: "hello world"),
            "draft hello world"
        )
    }

    func testTextMergeReturnsPartialWhenBaseEmpty() {
        XCTAssertEqual(
            DictationTextMerge.mergedText(baseBeforeSession: "", sessionPartial: "hello"),
            "hello"
        )
    }

    func testTextMergeIgnoresEmptyPartial() {
        XCTAssertEqual(
            DictationTextMerge.mergedText(baseBeforeSession: "draft", sessionPartial: "   "),
            "draft"
        )
    }

    func testToggleNotificationRouting() {
        let note = Notification(
            name: Notification.Name("test"),
            object: nil,
            userInfo: DictationToggleNotification.userInfo(for: .chat)
        )
        XCTAssertTrue(DictationToggleNotification.shouldHandle(note, as: .chat))
        XCTAssertFalse(DictationToggleNotification.shouldHandle(note, as: .code))
    }

    func testToggleNotificationLegacyCodeDefault() {
        let note = Notification(name: Notification.Name("test"))
        XCTAssertTrue(DictationToggleNotification.shouldHandle(note, as: .code))
        XCTAssertFalse(DictationToggleNotification.shouldHandle(note, as: .chat))
    }

    func testGlobalDeliveryRoutesComposerWhenContinuumFocused() {
        let delivery = GlobalDictationDeliveryResolver.resolve(
            continuumBundleID: "ai.continuum.mac",
            frontmostBundleID: "ai.continuum.mac",
            systemWideEnabled: false
        )
        XCTAssertEqual(delivery, .composer)
    }

    func testGlobalDeliveryPastesWhenSystemWideEnabled() {
        let delivery = GlobalDictationDeliveryResolver.resolve(
            continuumBundleID: "ai.continuum.mac",
            frontmostBundleID: "com.apple.Safari",
            systemWideEnabled: true
        )
        XCTAssertEqual(delivery, .externalPaste)
    }

    func testGlobalDeliveryDisabledOutsideContinuumWhenToggleOff() {
        let delivery = GlobalDictationDeliveryResolver.resolve(
            continuumBundleID: "ai.continuum.mac",
            frontmostBundleID: "com.apple.Safari",
            systemWideEnabled: false
        )
        XCTAssertEqual(delivery, .systemWideDisabled)
    }

    func testStopDeliveryUsesFrontmostAppAtStopTime() {
        let composerAtStop = GlobalDictationStopDeliveryResolver.resolve(
            continuumBundleID: "ai.continuum.mac",
            frontmostBundleID: "ai.continuum.mac",
            systemWideEnabled: false,
            composerResolution: .route(.chat)
        )
        XCTAssertEqual(composerAtStop, .composer(.chat))

        let externalAtStop = GlobalDictationStopDeliveryResolver.resolve(
            continuumBundleID: "ai.continuum.mac",
            frontmostBundleID: "com.apple.Safari",
            systemWideEnabled: true,
            composerResolution: .route(.code)
        )
        XCTAssertEqual(externalAtStop, .externalPaste)

        let disabledAtStop = GlobalDictationStopDeliveryResolver.resolve(
            continuumBundleID: "ai.continuum.mac",
            frontmostBundleID: "com.apple.Safari",
            systemWideEnabled: false,
            composerResolution: .route(.code)
        )
        XCTAssertEqual(
            disabledAtStop,
            .unavailable("Enable system-wide dictation in Voice settings")
        )
    }
}
