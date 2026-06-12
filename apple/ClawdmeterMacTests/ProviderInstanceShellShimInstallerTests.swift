import XCTest
@testable import Clawdmeter
@testable import ClawdmeterShared

final class ProviderInstanceShellShimInstallerTests: XCTestCase {

    private var tempRoot: URL!
    private var appSupport: URL!
    private var installDir: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderInstanceShellShimInstaller-\(UUID().uuidString)", isDirectory: true)
        appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        installDir = tempRoot.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func test_sync_installsAndRemovesShims() throws {
        let work = ProviderInstanceId(
            kind: .claude,
            name: "work",
            homePathOverride: appSupport
                .appendingPathComponent("Instances/claude/work", isDirectory: true)
                .path
        )
        ProviderInstanceShellShimInstaller.sync(
            instances: [.primary(kind: .claude), work],
            appSupportDirectory: appSupport,
            installDirectoryOverride: installDir
        )

        let shimURL = installDir.appendingPathComponent("claude-work")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shimURL.path))
        let body = try String(contentsOf: shimURL, encoding: .utf8)
        XCTAssertTrue(body.contains(ProviderInstanceShellShim.shimMarkerPrefix + "claude/work"))

        let attrs = try FileManager.default.attributesOfItem(atPath: shimURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(perms, 0o755)

        ProviderInstanceShellShimInstaller.sync(
            instances: [.primary(kind: .claude)],
            appSupportDirectory: appSupport,
            installDirectoryOverride: installDir
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: shimURL.path))
    }
}
