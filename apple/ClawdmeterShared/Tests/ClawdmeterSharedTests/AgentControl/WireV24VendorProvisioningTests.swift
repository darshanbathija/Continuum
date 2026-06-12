import XCTest
@testable import ClawdmeterShared

final class WireV24VendorProvisioningTests: XCTestCase {
    func testWireVersionGatesVendorProvisioning() {
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 24)
        XCTAssertEqual(AgentControlWireVersion.vendorProvisioningMinimum, 24)
        XCTAssertFalse(AgentControlWireVersion.supportsVendorProvisioning(serverWireVersion: nil))
        XCTAssertFalse(AgentControlWireVersion.supportsVendorProvisioning(serverWireVersion: 23))
        XCTAssertTrue(AgentControlWireVersion.supportsVendorProvisioning(serverWireVersion: 24))
    }

    func testVendorCheckResponseRoundTrips() throws {
        let vendor = try XCTUnwrap(VendorProvisioningCatalog.vendor(id: "cloudflare"))
        let response = VendorProvisioningCheckResponse(
            vendors: [vendor],
            statuses: [
                VendorProvisioningStatus(
                    vendorId: vendor.id,
                    cliStatus: .authenticated,
                    installedBinary: "/opt/homebrew/bin/wrangler",
                    version: "wrangler 4.0.0",
                    accountLabel: "user@example.com",
                    projectLabel: "example.com",
                    message: "Cloudflare CLI is authenticated.",
                    mcpMatches: [
                        VendorProvisioningMCPMatch(
                            name: "cloudflare",
                            kind: "codexMCP",
                            source: "~/.codex/config.toml"
                        ),
                    ]
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VendorProvisioningCheckResponse.self, from: data)

        XCTAssertEqual(decoded.vendors.first?.id, "cloudflare")
        XCTAssertEqual(decoded.statuses.first?.cliStatus, .authenticated)
        XCTAssertEqual(decoded.statuses.first?.mcpMatches.first?.name, "cloudflare")
    }

    func testVendorMentionCatalogMatching() {
        let cloudflareMatches = VendorProvisioningCatalog.vendors(matchingMentionQuery: "cloud")
        XCTAssertTrue(cloudflareMatches.contains { $0.id == "cloudflare" })

        XCTAssertEqual(
            VendorProvisioningCatalog.bestVendorMatch(forMentionQuery: "Cloudflare")?.id,
            "cloudflare"
        )
        XCTAssertNil(VendorProvisioningCatalog.bestVendorMatch(forMentionQuery: "c"))
    }

    func testVendorMentionConnectionLabels() {
        let connected = VendorProvisioningStatus(vendorId: "cloudflare", cliStatus: .authenticated)
        let disconnected = VendorProvisioningStatus(vendorId: "cloudflare", cliStatus: .notInstalled)

        XCTAssertEqual(connected.mentionConnectionLabel, "connected")
        XCTAssertTrue(connected.isMentionConnected)
        XCTAssertEqual(disconnected.mentionConnectionLabel, "not connected")
        XCTAssertFalse(disconnected.isMentionConnected)
    }

    func testEnvPreviewAndImportPayloadsRoundTripWithoutSecretInPreviewResponse() throws {
        let workspaceId = UUID()
        let previewRequest = VendorEnvPreviewRequest(
            currentWorkspaceId: workspaceId,
            workspaceIds: [workspaceId],
            candidates: [
                VendorEnvCandidate(key: "SUPABASE_ANON_KEY", value: "anon-secret-value"),
            ]
        )
        let importRequest = VendorEnvImportRequest(
            currentWorkspaceId: workspaceId,
            workspaceIds: [workspaceId],
            selectedSetIds: [UUID()],
            candidates: previewRequest.candidates,
            conflictStrategy: .overwrite
        )
        let previewResponse = VendorEnvPreviewResponse(
            vendorId: "supabase",
            workspaceId: workspaceId,
            previews: [
                VendorEnvPreviewItem(
                    line: 1,
                    key: "SUPABASE_ANON_KEY",
                    status: "ready",
                    message: "Ready to import.",
                    canImport: true
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let previewBody = try encoder.encode(previewResponse)
        let importBody = try encoder.encode(importRequest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(VendorEnvPreviewRequest.self, from: try encoder.encode(previewRequest)).candidates.first?.value, "anon-secret-value")
        XCTAssertEqual(try decoder.decode(VendorEnvPreviewRequest.self, from: try encoder.encode(previewRequest)).workspaceIds, [workspaceId])
        XCTAssertEqual(try decoder.decode(VendorEnvImportRequest.self, from: importBody).conflictStrategy, .overwrite)
        XCTAssertEqual(try decoder.decode(VendorEnvPreviewResponse.self, from: previewBody).previews.first?.key, "SUPABASE_ANON_KEY")
        XCTAssertFalse(String(decoding: previewBody, as: UTF8.self).contains("anon-secret-value"))
    }

    func testPreviewRequestDecodesMissingWorkspaceIdsAsEmptyForOlderClients() throws {
        let body = Data(#"{"candidates":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(VendorEnvPreviewRequest.self, from: body)

        XCTAssertNil(decoded.currentWorkspaceId)
        XCTAssertEqual(decoded.workspaceIds, [])
        XCTAssertEqual(decoded.candidates, [])
    }

    func testOnboardingGuideHidesInstallWhenCLIInstalled() {
        let installed = VendorProvisioningStatus(
            vendorId: "supabase",
            cliStatus: .unauthenticated,
            installedBinary: "/opt/homebrew/bin/supabase",
            message: "CLI installed, authentication not confirmed."
        )
        let guide = VendorProvisioningOnboardingGuide.resolve(status: installed)

        XCTAssertEqual(guide.step, .authenticate)
        XCTAssertFalse(guide.showsInstall)
        XCTAssertTrue(guide.showsAuthenticate)
        XCTAssertEqual(guide.primaryActionKind, .authenticate)
        XCTAssertEqual(guide.statusLabel, "Needs Auth")
    }

    func testOnboardingGuideShowsInstallOnlyWhenMissing() {
        let missing = VendorProvisioningStatus(
            vendorId: "upstash",
            cliStatus: .notInstalled,
            message: "CLI not installed."
        )
        let guide = VendorProvisioningOnboardingGuide.resolve(status: missing)

        XCTAssertEqual(guide.step, .installCLI)
        XCTAssertTrue(guide.showsInstall)
        XCTAssertFalse(guide.showsAuthenticate)
        XCTAssertEqual(guide.primaryActionKind, .install)
    }

    func testOnboardingGuideTreatsProbeErrorsAsAuthStep() {
        let timedOut = VendorProvisioningStatus(
            vendorId: "gcp",
            cliStatus: .error,
            installedBinary: "/opt/homebrew/bin/gcloud",
            message: "timedOut(after: 6.0)"
        )
        let guide = VendorProvisioningOnboardingGuide.resolve(status: timedOut)

        XCTAssertEqual(guide.step, .authenticate)
        XCTAssertFalse(guide.showsInstall)
        XCTAssertTrue(guide.showsAuthenticate)
        XCTAssertEqual(guide.statusLabel, "Needs Auth")
    }
}
