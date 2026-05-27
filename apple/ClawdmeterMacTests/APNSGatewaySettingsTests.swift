// E6: settings store tests. Verifies defaults + per-surface gating.

import XCTest
@testable import Clawdmeter

final class APNSGatewaySettingsTests: XCTestCase {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "com.clawdmeter.test.apnsgateway.settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    func testDefaultsAllEnabled() {
        let defaults = makeIsolatedDefaults()
        let settings = APNSGatewaySettings(defaults: defaults)
        XCTAssertTrue(settings.pushEnabled)
        XCTAssertTrue(settings.notifyOnPlanApproval)
        XCTAssertTrue(settings.notifyOnSessionDone)
        XCTAssertTrue(settings.notifyOnPermissionPrompt)
        XCTAssertEqual(settings.sessionDoneMinimumRuntimeSeconds, 60)
    }

    func testIsEnabledRespectsMasterAndSurface() {
        let defaults = makeIsolatedDefaults()
        let settings = APNSGatewaySettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(surface: .planApproval))

        // Master kill switch.
        settings.pushEnabled = false
        XCTAssertFalse(settings.isEnabled(surface: .planApproval))
        XCTAssertFalse(settings.isEnabled(surface: .sessionDone))
        XCTAssertFalse(settings.isEnabled(surface: .permissionPrompt))
        settings.pushEnabled = true

        // Per-surface toggle.
        settings.notifyOnPermissionPrompt = false
        XCTAssertTrue(settings.isEnabled(surface: .planApproval))
        XCTAssertFalse(settings.isEnabled(surface: .permissionPrompt))
    }

    func testSettingsPersist() {
        let defaults = makeIsolatedDefaults()
        let settings = APNSGatewaySettings(defaults: defaults)
        settings.notifyOnSessionDone = false
        settings.sessionDoneMinimumRuntimeSeconds = 120

        // Re-instantiate against the same defaults.
        let reloaded = APNSGatewaySettings(defaults: defaults)
        XCTAssertFalse(reloaded.notifyOnSessionDone)
        XCTAssertEqual(reloaded.sessionDoneMinimumRuntimeSeconds, 120)
    }
}
