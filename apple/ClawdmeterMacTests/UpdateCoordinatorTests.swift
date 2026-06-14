import XCTest
@testable import Clawdmeter

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        driver providedDriver: FakeSparkleUpdateDriver? = nil,
        session: URLSession = MockURLProtocol.makeSession(),
        bundleURL: URL = URL(fileURLWithPath: "/Applications/Continuum.app"),
        currentVersion: String? = "0.29.16",
        build: String? = "155",
        now: Date = Date(timeIntervalSince1970: 1_779_840_000),
        opener: @escaping (URL) -> Void = { _ in },
        finderRevealer: @escaping (URL) -> Void = { _ in },
        clearPersistence: Bool = true
    ) -> (UpdateCoordinator, FakeSparkleUpdateDriver) {
        if clearPersistence {
            UpdateStatusPersistence.clear()
        }
        let driver = providedDriver ?? FakeSparkleUpdateDriver()
        let coordinator = UpdateCoordinator(
            session: session,
            bundleURLProvider: { bundleURL },
            currentVersionProvider: { currentVersion },
            buildProvider: { build },
            nowProvider: { now },
            opener: opener,
            finderRevealer: finderRevealer,
            driverFactory: { delegate in
                driver.delegate = delegate
                return driver
            }
        )
        return (coordinator, driver)
    }

    func testCompareVersionsCanonicalCases() {
        XCTAssertEqual(ReleaseUpdateConfig.compareVersions("0.23.10", "0.23.9"), .orderedDescending)
        XCTAssertEqual(ReleaseUpdateConfig.compareVersions("1.0.0", "0.99.99"), .orderedDescending)
        XCTAssertEqual(ReleaseUpdateConfig.compareVersions("0.24.0", "0.23.99"), .orderedDescending)
        XCTAssertEqual(ReleaseUpdateConfig.compareVersions("0.23.8", "0.23.8"), .orderedSame)
        XCTAssertEqual(ReleaseUpdateConfig.compareVersions("0.23.7", "0.23.8"), .orderedAscending)
    }

    func testParseVersionFromMacTagOnly() {
        XCTAssertEqual(ReleaseUpdateConfig.parseVersion(fromTag: "v0.29.16-mac"), "0.29.16")
        XCTAssertNil(ReleaseUpdateConfig.parseVersion(fromTag: "v0.29.16-beta1-mac"))
        XCTAssertNil(ReleaseUpdateConfig.parseVersion(fromTag: "v0.29.16-ios"))
        XCTAssertNil(ReleaseUpdateConfig.parseVersion(fromTag: "v0.29"))
    }

    func testReleaseURLsMatchExpectedHosts() {
        XCTAssertEqual(ReleaseUpdateConfig.releasesLatestURL.absoluteString,
                       "https://github.com/darshanbathija/Continuum/releases/latest")
        XCTAssertEqual(ReleaseUpdateConfig.appcastURL.absoluteString,
                       "https://darshanbathija.github.io/Continuum/updates/appcast.xml")
        XCTAssertEqual(ReleaseUpdateConfig.releaseTagURL(version: "0.29.16").absoluteString,
                       "https://github.com/darshanbathija/Continuum/releases/tag/v0.29.16-mac")
    }

    func testStartsSparkleDriverOnApplicationsInstall() {
        let (coordinator, driver) = makeCoordinator()
        XCTAssertTrue(driver.didStart)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.automaticChecksEnabled)
    }

    func testAutomaticChecksDisabledInitialState() {
        let driver = FakeSparkleUpdateDriver()
        driver.automaticallyChecksForUpdates = false
        let (coordinator, _) = makeCoordinator(driver: driver)
        XCTAssertEqual(coordinator.state, .automaticChecksDisabled)
    }

    func testTranslocationBlocksSparkle() {
        let driver = FakeSparkleUpdateDriver()
        let url = URL(fileURLWithPath: "/private/var/folders/x/y/T/AppTranslocation/Continuum.app")
        let (coordinator, _) = makeCoordinator(driver: driver, bundleURL: url)
        XCTAssertEqual(coordinator.state, .translocated(bundleURL: url.standardizedFileURL))
        XCTAssertFalse(driver.didStart)
        coordinator.checkForUpdates()
        XCTAssertEqual(driver.manualChecks, 0)
    }

    func testNonApplicationsInstallBlocksSparkle() {
        let driver = FakeSparkleUpdateDriver()
        let url = URL(fileURLWithPath: "/Users/me/Downloads/Continuum.app")
        let (coordinator, _) = makeCoordinator(driver: driver, bundleURL: url)
        XCTAssertEqual(coordinator.state, .nonApplicationsInstall(bundleURL: url.standardizedFileURL))
        XCTAssertFalse(driver.didStart)
    }

    func testSetupBlockedWhenSparkleCannotStart() {
        let driver = FakeSparkleUpdateDriver()
        driver.startError = NSError(domain: "Sparkle", code: 42, userInfo: [NSLocalizedDescriptionKey: "bad public key"])
        let (coordinator, _) = makeCoordinator(driver: driver)
        XCTAssertEqual(coordinator.state, .setupBlocked(reason: "bad public key", fallbackURL: ReleaseUpdateConfig.releasesLatestURL))
    }

    func testManualCheckUsesSparkleDriver() async {
        let (coordinator, driver) = makeCoordinator()
        coordinator.checkForUpdates()
        XCTAssertEqual(coordinator.state, .checking)
        await drainScheduledSparkleChecks()
        XCTAssertEqual(driver.manualChecks, 1)
        XCTAssertEqual(driver.informationChecks, 0)
    }

    func testRefreshUpdateStatusUsesInformationOnlyProbe() async {
        let (coordinator, driver) = makeCoordinator()
        coordinator.refreshUpdateStatus()
        XCTAssertEqual(coordinator.state, .checking)
        XCTAssertTrue(coordinator.awaitingManualCheckPopover)
        await drainScheduledSparkleChecks()
        XCTAssertEqual(driver.manualChecks, 0)
        XCTAssertEqual(driver.informationChecks, 1)
    }

    func testManualCheckAwaitingPopoverClearedAfterAcknowledgement() {
        let (coordinator, _) = makeCoordinator()
        coordinator.refreshUpdateStatus()
        coordinator.acknowledgeManualCheckPopover()
        XCTAssertFalse(coordinator.awaitingManualCheckPopover)
    }

    func testUpdateAvailableForegroundCheckBypassesProbeDebounce() async {
        let (coordinator, driver) = makeCoordinator()
        let update = SparkleUpdateInfo(version: "156", displayVersion: "0.29.17")
        coordinator.refreshUpdateStatus()
        await drainScheduledSparkleChecks()
        driver.emitFound(update)

        coordinator.checkForUpdates()
        XCTAssertEqual(coordinator.state, .updateAvailable(update))
        XCTAssertTrue(coordinator.isRefreshingUpdateStatus)
        await drainScheduledSparkleChecks()

        XCTAssertEqual(driver.informationChecks, 1)
        XCTAssertEqual(driver.manualChecks, 1)
    }

    func testManualCheckWhenDriverCannotCheckShowsSetupBlocked() {
        let driver = FakeSparkleUpdateDriver()
        driver.canCheckForUpdates = false
        let (coordinator, _) = makeCoordinator(driver: driver)

        coordinator.checkForUpdates()

        XCTAssertEqual(driver.manualChecks, 0)
        XCTAssertEqual(
            coordinator.state,
            .setupBlocked(
                reason: "Sparkle cannot check for updates right now. Open the app from /Applications and try again.",
                fallbackURL: ReleaseUpdateConfig.releasesLatestURL
            )
        )
    }

    func testManualCheckDebouncesRapidClicks() async {
        let (coordinator, driver) = makeCoordinator()
        coordinator.checkForUpdates()
        await drainScheduledSparkleChecks()
        coordinator.checkForUpdates()
        XCTAssertEqual(driver.manualChecks, 1)
        XCTAssertTrue(coordinator.awaitingManualCheckPopover)
    }

    func testBackgroundCheckRespectsAutomaticToggle() {
        let (coordinator, driver) = makeCoordinator()
        coordinator.setAutomaticChecksEnabled(false)
        coordinator.checkForUpdatesInBackground()
        XCTAssertEqual(driver.backgroundChecks, 0)
        XCTAssertEqual(coordinator.state, .automaticChecksDisabled)

        coordinator.setAutomaticChecksEnabled(true)
        coordinator.checkForUpdatesInBackground()
        XCTAssertEqual(driver.backgroundChecks, 1)
    }

    func testAutomaticDownloadToggleWritesDriver() {
        let (coordinator, driver) = makeCoordinator()
        coordinator.setAutomaticDownloadsEnabled(true)
        XCTAssertTrue(driver.automaticallyDownloadsUpdates)
        XCTAssertTrue(coordinator.automaticDownloadsEnabled)
    }

    func testUpdateAvailableState() {
        let (coordinator, driver) = makeCoordinator()
        let update = SparkleUpdateInfo(version: "156", displayVersion: "0.29.17", title: "Fixes")
        driver.emitFound(update)
        XCTAssertEqual(coordinator.state, .updateAvailable(update))
        XCTAssertEqual(updateControlSnapshot(coordinator), .available("0.29.17"))
    }

    func testUpToDateState() {
        let (coordinator, driver) = makeCoordinator()
        driver.lastUpdateCheckDate = Date(timeIntervalSince1970: 10)
        driver.emitNoUpdate()
        XCTAssertEqual(coordinator.state, .upToDate(lastCheckedAt: Date(timeIntervalSince1970: 10)))
    }

    func testInstallingAndRelaunchStates() {
        let (coordinator, driver) = makeCoordinator()
        let update = SparkleUpdateInfo(version: "156", displayVersion: "0.29.17")
        driver.emitInstalling(update)
        XCTAssertEqual(coordinator.state, .installing(update))
        driver.emitRelaunch(version: "0.29.17")
        XCTAssertEqual(coordinator.state, .installedRelaunchPending(version: "0.29.17"))
    }

    func testUserCancelledState() {
        let (coordinator, driver) = makeCoordinator()
        driver.emitCancelled(version: "0.29.17")
        XCTAssertEqual(coordinator.state, .userCancelled(version: "0.29.17"))
    }

    func testInstallProgressFlowsToCoordinator() {
        let (coordinator, driver) = makeCoordinator()
        let update = SparkleUpdateInfo(version: "156", displayVersion: "0.29.17")
        driver.emitInstalling(update)
        XCTAssertEqual(coordinator.installProgress, UpdateInstallProgress(phase: .downloading, fraction: nil))

        driver.emitProgress(UpdateInstallProgress(phase: .downloading, fraction: 0.5))
        XCTAssertEqual(coordinator.installProgress, UpdateInstallProgress(phase: .downloading, fraction: 0.5))
        XCTAssertEqual(coordinator.state, .installing(update))
        XCTAssertTrue(coordinator.canCancelInstall)

        driver.emitProgress(UpdateInstallProgress(phase: .extracting, fraction: nil))
        XCTAssertFalse(coordinator.canCancelInstall, "Extraction phase is not cancellable")
    }

    func testProgressBeforeInstallingFlipsState() {
        // A resumed background download can deliver progress without a prior
        // `didStartInstalling` — the coordinator must still enter `.installing`.
        let (coordinator, driver) = makeCoordinator()
        driver.emitProgress(UpdateInstallProgress(phase: .extracting, fraction: 0.2))
        XCTAssertEqual(coordinator.state, .installing(nil))
        XCTAssertEqual(coordinator.installProgress, UpdateInstallProgress(phase: .extracting, fraction: 0.2))
    }

    func testInstallProgressClearsOnTerminalStates() {
        let (coordinator, driver) = makeCoordinator()
        driver.emitInstalling(SparkleUpdateInfo(version: "156", displayVersion: "0.29.17"))
        XCTAssertNotNil(coordinator.installProgress)
        driver.emitRelaunch(version: "0.29.17")
        XCTAssertNil(coordinator.installProgress)

        driver.emitInstalling(SparkleUpdateInfo(version: "157", displayVersion: "0.29.18"))
        XCTAssertNotNil(coordinator.installProgress)
        driver.emitCancelled(version: "0.29.18")
        XCTAssertNil(coordinator.installProgress)
    }

    func testCancelInstallForwardsToDriverOnlyWhileInstalling() {
        let (coordinator, driver) = makeCoordinator()
        coordinator.cancelInstall()
        XCTAssertEqual(driver.cancelInstalls, 0, "No-op when not installing")

        driver.emitInstalling(SparkleUpdateInfo(version: "156", displayVersion: "0.29.17"))
        coordinator.cancelInstall()
        XCTAssertEqual(driver.cancelInstalls, 1)
    }

    func testCancelInstallRevertsToUpdateAvailableSynchronously() {
        let (coordinator, driver) = makeCoordinator()
        let update = SparkleUpdateInfo(version: "156", displayVersion: "0.29.17")
        driver.emitFound(update)
        driver.emitInstalling(update)
        driver.emitProgress(UpdateInstallProgress(phase: .downloading, fraction: 0.5))
        XCTAssertTrue(coordinator.canCancelInstall)

        coordinator.cancelInstall()
        // Popover snaps back to the pre-download state immediately — no waiting
        // on Sparkle's async abort callback.
        XCTAssertEqual(coordinator.state, .updateAvailable(update))
        XCTAssertNil(coordinator.installProgress)
        XCTAssertFalse(coordinator.canCancelInstall)
        XCTAssertEqual(driver.cancelInstalls, 1, "Driver still tears down the live download")
    }

    func testLateCancelCallbackDoesNotClobberRevertedState() {
        let (coordinator, driver) = makeCoordinator()
        let update = SparkleUpdateInfo(version: "156", displayVersion: "0.29.17")
        driver.emitFound(update)
        driver.emitInstalling(update)
        coordinator.cancelInstall()
        XCTAssertEqual(coordinator.state, .updateAvailable(update))

        // A stale progress frame already queued from the aborted download must
        // be ignored rather than flipping the popover back to `.installing`.
        driver.emitProgress(UpdateInstallProgress(phase: .downloading, fraction: 0.9))
        XCTAssertEqual(coordinator.state, .updateAvailable(update))
        XCTAssertNil(coordinator.installProgress)

        // Sparkle's delayed abort callback is then swallowed, not painted as a
        // generic `.userCancelled` screen.
        driver.emitCancelled(version: "0.29.17")
        XCTAssertEqual(coordinator.state, .updateAvailable(update))
        XCTAssertNil(coordinator.installProgress)
    }

    func testReDownloadAfterCancelStillFlowsProgress() {
        let (coordinator, driver) = makeCoordinator()
        let update = SparkleUpdateInfo(version: "156", displayVersion: "0.29.17")
        driver.emitFound(update)
        driver.emitInstalling(update)
        coordinator.cancelInstall()

        // User presses Update again: a fresh check clears the suppression and
        // the new download's progress drives the popover normally...
        coordinator.checkForUpdates()
        driver.emitFound(update)
        driver.emitInstalling(update)
        driver.emitProgress(UpdateInstallProgress(phase: .downloading, fraction: 0.25))
        XCTAssertEqual(coordinator.state, .installing(update))
        XCTAssertEqual(coordinator.installProgress, UpdateInstallProgress(phase: .downloading, fraction: 0.25))

        // ...even if the *first* download's abort callback only lands now, it is
        // swallowed and the in-flight re-download is left untouched.
        driver.emitCancelled(version: "0.29.17")
        XCTAssertEqual(coordinator.state, .installing(update))
    }

    func testSparkleInitiatedCancelStillShowsUserCancelled() {
        // A cancellation that did NOT come from our Cancel button (e.g. a
        // superseded background download) keeps the explicit cancelled screen.
        let (coordinator, driver) = makeCoordinator()
        driver.emitInstalling(SparkleUpdateInfo(version: "156", displayVersion: "0.29.17"))
        driver.emitCancelled(version: "0.29.17")
        XCTAssertEqual(coordinator.state, .userCancelled(version: "0.29.17"))
    }

    func testInvalidAppcastErrorClassification() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 100, userInfo: [
            NSLocalizedDescriptionKey: "The appcast signature is invalid"
        ])
        XCTAssertEqual(
            SparkleErrorClassifier.state(for: error, fallbackURL: ReleaseUpdateConfig.releasesLatestURL),
            .invalidAppcastSignature(reason: "The appcast signature is invalid", fallbackURL: ReleaseUpdateConfig.releasesLatestURL)
        )
    }

    func testSparkleNoUpdateErrorIsNotFailure() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 1001, userInfo: [
            NSLocalizedDescriptionKey: "No update is available"
        ])
        XCTAssertTrue(SparkleErrorClassifier.isNoUpdate(error))
        XCTAssertFalse(SparkleErrorClassifier.isUserCancellation(error))
    }

    func testSparkleCancellationErrorsAreUserCancelled() {
        let cancelled = NSError(domain: "SUSparkleErrorDomain", code: 4007, userInfo: [
            NSLocalizedDescriptionKey: "Installation was cancelled"
        ])
        let authorizeLater = NSError(domain: "SUSparkleErrorDomain", code: 4008, userInfo: [
            NSLocalizedDescriptionKey: "Installation was authorized for later"
        ])
        XCTAssertTrue(SparkleErrorClassifier.isUserCancellation(cancelled))
        XCTAssertTrue(SparkleErrorClassifier.isUserCancellation(authorizeLater))
    }

    func testCorruptedDownloadErrorClassification() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 101, userInfo: [
            NSLocalizedDescriptionKey: "The downloaded archive is corrupt"
        ])
        XCTAssertEqual(
            SparkleErrorClassifier.state(for: error, fallbackURL: ReleaseUpdateConfig.releasesLatestURL),
            .corruptedDownload(reason: "The downloaded archive is corrupt", fallbackURL: ReleaseUpdateConfig.releasesLatestURL)
        )
    }

    func testGenericFailureClassification() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 102, userInfo: [
            NSLocalizedDescriptionKey: "Network unavailable"
        ])
        XCTAssertEqual(
            SparkleErrorClassifier.state(for: error, fallbackURL: ReleaseUpdateConfig.releasesLatestURL),
            .failed(reason: "Network unavailable", fallbackURL: ReleaseUpdateConfig.releasesLatestURL)
        )
    }

    func testFallbackAndFinderActionsUseInjectedClosures() {
        var opened: URL?
        var revealed: URL?
        let bundleURL = URL(fileURLWithPath: "/Applications/Continuum.app")
        let (coordinator, _) = makeCoordinator(
            bundleURL: bundleURL,
            opener: { opened = $0 },
            finderRevealer: { revealed = $0 }
        )
        coordinator.openReleasePageFallback()
        coordinator.showCurrentBundleInFinder()
        XCTAssertEqual(opened, ReleaseUpdateConfig.releasesLatestURL)
        XCTAssertEqual(revealed, bundleURL)
    }

    func testReleaseMetadataLoadsThroughCoordinator() async {
        MockURLProtocol.responder = { request in
            if request.url?.path == "/Continuum/updates/history.json" {
                let data = """
                [{"version":"0.29.16","build":"155","title":"Sparkle","publishedAt":null,"notesURL":"https://example.test/notes.md"}]
                """.data(using: .utf8)!
                return MockURLProtocol.response(url: request.url!, status: 200, data: data)
            }
            let notes = "# Notes\n\n- Sparkle update"
            return MockURLProtocol.response(url: request.url!, status: 200, data: notes.data(using: .utf8)!)
        }

        let (coordinator, _) = makeCoordinator()
        coordinator.refreshReleaseMetadata()
        await Self.waitForMetadata(coordinator)

        XCTAssertEqual(coordinator.releaseHistory.first?.version, "0.29.16")
        XCTAssertTrue(coordinator.releaseNotes?.contains("Sparkle update") == true)
    }

    func testReleaseMetadataFailureSurfacesCoordinatorError() async {
        MockURLProtocol.responder = { request in
            MockURLProtocol.response(url: request.url!, status: 500, data: nil)
        }

        let (coordinator, _) = makeCoordinator()
        coordinator.refreshReleaseMetadata()
        await Self.waitForMetadata(coordinator)

        XCTAssertTrue(coordinator.releaseHistory.isEmpty)
        XCTAssertNotNil(coordinator.releaseMetadataError)
    }

    func testCurrentVersionReleaseNotes404DoesNotSurfaceError() async {
        // Regression: when the app is up to date, the current version's notes
        // markdown is frequently absent on GitHub Pages (404). That must degrade
        // to a calm empty state, NOT a user-facing "Release notes unavailable:
        // NSURLErrorDomain error -1011". History.json still loads fine, so its
        // own error path must stay clean too.
        MockURLProtocol.responder = { request in
            if request.url?.path == "/Continuum/updates/history.json" {
                let data = """
                [{"version":"0.29.16","build":"155","title":"Sparkle","publishedAt":null,"notesURL":null}]
                """.data(using: .utf8)!
                return MockURLProtocol.response(url: request.url!, status: 200, data: data)
            }
            // Per-version release-notes doc is not published for this build.
            return MockURLProtocol.response(url: request.url!, status: 404, data: Data())
        }

        let (coordinator, _) = makeCoordinator()
        coordinator.refreshReleaseMetadata()
        await Self.waitForMetadata(coordinator)

        XCTAssertEqual(coordinator.releaseHistory.first?.version, "0.29.16")
        XCTAssertNil(coordinator.releaseNotes)
        XCTAssertNil(
            coordinator.releaseMetadataError,
            "A 404 on the current version's release notes must not surface a user-facing updater error"
        )
    }

    func testOpenReleaseNotesPrefersAvailableUpdateURL() {
        var opened: URL?
        let notesURL = URL(string: "https://example.test/Continuum-0.29.17.md")!
        let (coordinator, driver) = makeCoordinator(opener: { opened = $0 })
        driver.emitFound(SparkleUpdateInfo(version: "156", displayVersion: "0.29.17", releaseNotesURL: notesURL))

        coordinator.openReleaseNotes()

        XCTAssertEqual(opened, notesURL)
    }

    func testUpdateControlSnapshotsCoverBlockedStates() {
        let missing = updateControlSnapshot(nil)
        XCTAssertEqual(missing, .unavailable)

        let translocatedURL = URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/Continuum.app")
        let (coordinator, _) = makeCoordinator(bundleURL: translocatedURL)
        XCTAssertEqual(updateControlSnapshot(coordinator), .translocated)
    }

    func testUpdateControlOnlyPersistsWhenUpdateNeedsAttention() {
        XCTAssertTrue(updateControlShouldRender(.available("0.31.0"), showsInactiveStates: false))
        XCTAssertTrue(updateControlShouldRender(.installing, showsInactiveStates: false))
        XCTAssertTrue(updateControlShouldRender(.relaunchPending("0.31.0"), showsInactiveStates: false))

        XCTAssertFalse(updateControlShouldRender(.idle, showsInactiveStates: false))
        XCTAssertFalse(updateControlShouldRender(.checking, showsInactiveStates: false))
        XCTAssertFalse(updateControlShouldRender(.upToDate, showsInactiveStates: false))
        XCTAssertFalse(updateControlShouldRender(.automaticChecksDisabled, showsInactiveStates: false))
        XCTAssertFalse(updateControlShouldRender(.failed("Network unavailable"), showsInactiveStates: false))

        XCTAssertTrue(updateControlShouldRender(.upToDate, showsInactiveStates: true))
    }

    func testUpdateControlRendersForManualUpToDateCheck() {
        XCTAssertTrue(
            updateControlShouldRender(.upToDate, showsInactiveStates: false, awaitingManualCheckPopover: true)
        )
        XCTAssertTrue(
            updateControlShouldRender(.checking, showsInactiveStates: false, awaitingManualCheckPopover: true)
        )
        XCTAssertFalse(
            updateControlShouldRender(.upToDate, showsInactiveStates: false, awaitingManualCheckPopover: false)
        )
    }

    func testPersistedUpToDateStatusRestoresImmediately() {
        let checkedAt = Date(timeIntervalSince1970: 42)
        UpdateStatusPersistence.save(.upToDate(lastCheckedAt: checkedAt))

        let (coordinator, _) = makeCoordinator(clearPersistence: false)
        XCTAssertEqual(coordinator.state, .upToDate(lastCheckedAt: checkedAt))
        XCTAssertEqual(coordinator.lastCheckedAt, checkedAt)
    }

    func testManualCheckKeepsPersistedStatusWhileRefreshing() async {
        let checkedAt = Date(timeIntervalSince1970: 42)
        UpdateStatusPersistence.save(.upToDate(lastCheckedAt: checkedAt))

        let (coordinator, driver) = makeCoordinator(clearPersistence: false)
        coordinator.refreshUpdateStatus()

        XCTAssertEqual(coordinator.state, .upToDate(lastCheckedAt: checkedAt))
        XCTAssertTrue(coordinator.isRefreshingUpdateStatus)
        XCTAssertTrue(coordinator.awaitingManualCheckPopover)
        await drainScheduledSparkleChecks()
        XCTAssertEqual(driver.informationChecks, 1)
    }

    private func drainScheduledSparkleChecks() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static func waitForMetadata(_ coordinator: UpdateCoordinator) async {
        for _ in 0..<100 {
            if !coordinator.isLoadingReleaseMetadata,
               !coordinator.releaseHistory.isEmpty || coordinator.releaseNotes != nil || coordinator.releaseMetadataError != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class FakeSparkleUpdateDriver: SparkleUpdateDriving {
    weak var delegate: SparkleUpdateDriverDelegate?
    var canCheckForUpdates: Bool = true
    var automaticallyChecksForUpdates: Bool = true
    var automaticallyDownloadsUpdates: Bool = false
    var lastUpdateCheckDate: Date?
    var didStart = false
    var manualChecks = 0
    var informationChecks = 0
    var backgroundChecks = 0
    var cancelInstalls = 0
    var startError: Error?

    func start() throws {
        if let startError { throw startError }
        didStart = true
    }

    func checkForUpdates() {
        manualChecks += 1
        delegate?.updateDriverDidStartChecking()
    }

    func checkForUpdateInformation() {
        informationChecks += 1
        delegate?.updateDriverDidStartChecking()
    }

    func checkForUpdatesInBackground() {
        backgroundChecks += 1
        delegate?.updateDriverDidStartChecking()
    }

    func cancelInstall() {
        cancelInstalls += 1
    }

    func emitFound(_ update: SparkleUpdateInfo) {
        delegate?.updateDriverDidFindUpdate(update)
    }

    func emitProgress(_ progress: UpdateInstallProgress) {
        delegate?.updateDriverDidUpdateProgress(progress)
    }

    func emitNoUpdate() {
        delegate?.updateDriverDidNotFindUpdate()
    }

    func emitInstalling(_ update: SparkleUpdateInfo?) {
        delegate?.updateDriverDidStartInstalling(update)
    }

    func emitRelaunch(version: String?) {
        delegate?.updateDriverDidInstallAndAwaitRelaunch(version: version)
    }

    func emitCancelled(version: String?) {
        delegate?.updateDriverDidCancel(version: version)
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data?)) = { request in
        response(url: request.url ?? URL(string: "https://example.test")!, status: 500, data: nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, data) = Self.responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func response(url: URL, status: Int, data: Data?) -> (HTTPURLResponse, Data?) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, data)
    }
}
