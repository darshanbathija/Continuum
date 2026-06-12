import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class OpenCodeGoQuotaClientTests: XCTestCase {
    func test_parseDashboardHTML_extractsRollingWeeklyMonthly() throws {
        let html = """
        rollingUsage:$R[1]={usagePercent:19,resetInSec:7200}
        weeklyUsage:$R[2]={usagePercent:31,resetInSec:345600}
        monthlyUsage:$R[3]={usagePercent:44,resetInSec:1414800}
        """
        let snapshot = try OpenCodeGoQuotaClient.parseDashboardHTML(html)
        XCTAssertEqual(snapshot.rolling?.usagePercent, 19)
        XCTAssertEqual(snapshot.weekly?.usagePercent, 31)
        XCTAssertEqual(snapshot.monthly?.usagePercent, 44)
    }

    func test_parseUsageAPI_mapsProposedShape() throws {
        let json = """
        {
          "rolling5h": { "usagePercent": 12, "resetInSec": 3600 },
          "weekly": { "usagePercent": 28, "resetInSec": 86400 },
          "monthly": { "usagePercent": 41, "resetInSec": 1209600 }
        }
        """.data(using: .utf8)!
        let snapshot = try OpenCodeGoQuotaClient.parseUsageAPI(json)
        let usage = snapshot.asUsageData(now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(usage.sessionPct, 12)
        XCTAssertEqual(usage.weeklyPct, 28)
        XCTAssertEqual(usage.opencodeGoQuota?.monthlyPct, 41)
    }

    func test_opencodeModelObject_routesGoModels() {
        let go = AgentControlServer.opencodeModelObject(forModelId: "kimi-k2.6")
        XCTAssertEqual(go?["providerID"], "opencode-go")
        XCTAssertEqual(go?["modelID"], "kimi-k2.6")

        let prefixed = AgentControlServer.opencodeModelObject(forModelId: "opencode-go/glm-5.1")
        XCTAssertEqual(prefixed?["providerID"], "opencode-go")
        XCTAssertEqual(prefixed?["modelID"], "glm-5.1")
    }

    // MARK: - No-fabrication (P1)

    func test_asUsageData_rollingOnly_doesNotMirrorIntoWeeklyOrMonthly() {
        let snap = OpenCodeGoQuotaClient.Snapshot(
            rolling: .init(usagePercent: 42, resetInSec: 3600),
            weekly: nil,
            monthly: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let usage = snap.asUsageData(now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(usage.sessionPct, 42)
        XCTAssertEqual(usage.weeklyPct, 0, "weekly must not mirror rolling when absent")
        XCTAssertEqual(usage.opencodeGoQuota?.weeklyAvailable, false)
        XCTAssertNil(usage.opencodeGoQuota?.monthlyPct, "monthly meter must be hidden when not fetched")
    }

    func test_asUsageData_rollingAndWeekly_monthlyStillHidden() {
        let snap = OpenCodeGoQuotaClient.Snapshot(
            rolling: .init(usagePercent: 10, resetInSec: 3600),
            weekly: .init(usagePercent: 55, resetInSec: 86_400),
            monthly: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let usage = snap.asUsageData(now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(usage.weeklyPct, 55)
        XCTAssertEqual(usage.opencodeGoQuota?.weeklyAvailable, true)
        XCTAssertNil(usage.opencodeGoQuota?.monthlyPct)
    }

    func test_asUsageData_statusLimitedOnlyFromFetchedWindow() {
        let limited = OpenCodeGoQuotaClient.Snapshot(
            rolling: .init(usagePercent: 100, resetInSec: 60), weekly: nil, monthly: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        ).asUsageData(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(limited.status, .limited)

        let allowed = OpenCodeGoQuotaClient.Snapshot(
            rolling: .init(usagePercent: 5, resetInSec: 60), weekly: nil, monthly: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        ).asUsageData(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(allowed.status, .allowed, "absent windows must not flip status to limited")
    }

    // MARK: - Scrape robustness

    func test_parseDashboardHTML_resetBeforePercentOrdering() throws {
        let snap = try OpenCodeGoQuotaClient.parseDashboardHTML(
            "rollingUsage:$R[1]={resetInSec:7200,usagePercent:19}")
        XCTAssertEqual(snap.rolling?.usagePercent, 19)
        XCTAssertEqual(snap.rolling?.resetInSec, 7200)
    }

    func test_parseDashboardHTML_noWindows_throws() {
        XCTAssertThrowsError(try OpenCodeGoQuotaClient.parseDashboardHTML("<html>nothing here</html>"))
    }

    func test_parseDashboardHTML_clampsPercentAndBoundsGarbageReset() throws {
        let snap = try OpenCodeGoQuotaClient.parseDashboardHTML(
            "monthlyUsage:$R[3]={usagePercent:250,resetInSec:999999999}")
        XCTAssertEqual(snap.monthly?.usagePercent, 100, "percent clamps to 100")
        XCTAssertEqual(snap.monthly?.resetInSec, 0, "absurd reset is dropped to unknown")
    }

    func test_parseUsageAPI_noWindows_throws() {
        XCTAssertThrowsError(try OpenCodeGoQuotaClient.parseUsageAPI("{}".data(using: .utf8)!))
    }

    // MARK: - Codable back-compat + input validation

    func test_openCodeGoQuota_decodesLegacyShapeAndRoundTripsNilMonthly() throws {
        // A snapshot written by an earlier build of this branch (monthlyPct as a
        // bare Int, no weeklyAvailable) must still decode, not throw.
        let legacy = #"{"monthlyPct":44,"monthlyResetMins":10,"monthlyResetEpoch":123}"#.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(UsageData.OpenCodeGoQuota.self, from: legacy)
        XCTAssertEqual(migrated.monthlyPct, 44)
        XCTAssertFalse(migrated.weeklyAvailable)

        let fresh = UsageData.OpenCodeGoQuota(weeklyAvailable: true, monthlyPct: nil, monthlyResetMins: 0, monthlyResetEpoch: 0)
        let back = try JSONDecoder().decode(UsageData.OpenCodeGoQuota.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(back, fresh)
        XCTAssertNil(back.monthlyPct)
        XCTAssertTrue(back.weeklyAvailable)
    }

    func test_isValidWorkspaceId_rejectsPathAndHeaderInjection() {
        XCTAssertTrue(OpenCodeGoCredentials.isValidWorkspaceId("ws_abc-123"))
        XCTAssertFalse(OpenCodeGoCredentials.isValidWorkspaceId("ws/../admin"))
        XCTAssertFalse(OpenCodeGoCredentials.isValidWorkspaceId("ws?x=1"))
        XCTAssertFalse(OpenCodeGoCredentials.isValidWorkspaceId("has space"))
        XCTAssertFalse(OpenCodeGoCredentials.isValidWorkspaceId(""))
    }

    func test_extractWorkspaceId_fromDashboardURL() {
        XCTAssertEqual(
            OpenCodeGoBrowserAuthImporter.extractWorkspaceId(from: "https://opencode.ai/workspace/wrk_01KS8WZZ3M8TK1JD8SCKPFSSA7/go"),
            "wrk_01KS8WZZ3M8TK1JD8SCKPFSSA7"
        )
        XCTAssertNil(OpenCodeGoBrowserAuthImporter.extractWorkspaceId(from: "https://opencode.ai/zen"))
    }

    func test_discoverWorkspaceId_prefersSavedUserDefaults() {
        let key = OpenCodeGoCredentials.workspaceDefaultsKey
        let prior = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("wrk_saved123", forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        XCTAssertEqual(OpenCodeGoBrowserAuthImporter.discoverWorkspaceId(), "wrk_saved123")
    }
}
