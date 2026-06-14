import Foundation
import Combine
import AppKit
import OSLog

#if canImport(Sparkle)
import Sparkle
#endif

private let updateLogger = Logger(subsystem: "com.clawdmeter.mac", category: "Updates")

// MARK: - Public update model

struct SparkleUpdateInfo: Equatable {
    let version: String
    let displayVersion: String
    let title: String?
    let releaseNotesURL: URL?
    let fullReleaseNotesURL: URL?
    let downloadURL: URL?
    let minimumSystemVersion: String?

    init(
        version: String,
        displayVersion: String? = nil,
        title: String? = nil,
        releaseNotesURL: URL? = nil,
        fullReleaseNotesURL: URL? = nil,
        downloadURL: URL? = nil,
        minimumSystemVersion: String? = nil
    ) {
        self.version = version
        self.displayVersion = displayVersion ?? version
        self.title = title
        self.releaseNotesURL = releaseNotesURL
        self.fullReleaseNotesURL = fullReleaseNotesURL
        self.downloadURL = downloadURL
        self.minimumSystemVersion = minimumSystemVersion
    }
}

/// Live download / extraction / install progress surfaced inside the top-right
/// updater popover. There is no separate Sparkle window — the popover is the
/// only update UI, so this drives its inline progress bar.
struct UpdateInstallProgress: Equatable {
    enum Phase: Equatable {
        case downloading
        case extracting
        case installing
    }

    var phase: Phase
    /// 0...1 when the total is known; nil renders an indeterminate bar.
    var fraction: Double?

    var label: String {
        switch phase {
        case .downloading: return "Downloading update"
        case .extracting: return "Preparing update"
        case .installing: return "Installing update"
        }
    }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(lastCheckedAt: Date?)
    case updateAvailable(SparkleUpdateInfo)
    case installing(SparkleUpdateInfo?)
    case installedRelaunchPending(version: String?)
    case userCancelled(version: String?)
    case failed(reason: String, fallbackURL: URL)
    case invalidAppcastSignature(reason: String, fallbackURL: URL)
    case corruptedDownload(reason: String, fallbackURL: URL)
    case translocated(bundleURL: URL)
    case nonApplicationsInstall(bundleURL: URL)
    case setupBlocked(reason: String, fallbackURL: URL)
    case automaticChecksDisabled

    var isActionable: Bool {
        switch self {
        case .checking, .installing:
            return false
        default:
            return true
        }
    }
}

// MARK: - Sparkle driver seam

@MainActor
protocol SparkleUpdateDriverDelegate: AnyObject {
    func updateDriverDidStartChecking()
    func updateDriverDidFindUpdate(_ update: SparkleUpdateInfo)
    func updateDriverDidNotFindUpdate()
    func updateDriverDidStartInstalling(_ update: SparkleUpdateInfo?)
    func updateDriverDidUpdateProgress(_ progress: UpdateInstallProgress)
    func updateDriverDidInstallAndAwaitRelaunch(version: String?)
    func updateDriverDidCancel(version: String?)
    func updateDriverDidFail(_ error: Error)
    func updateDriverPreferencesChanged()
}

@MainActor
protocol SparkleUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }

    func start() throws
    func checkForUpdates()
    func checkForUpdateInformation()
    func checkForUpdatesInBackground()
    /// Cancel an in-flight download, if one is cancellable. No-op otherwise.
    func cancelInstall()
}

// MARK: - Coordinator

@MainActor
final class UpdateCoordinator: ObservableObject {
    typealias DriverFactory = @MainActor (SparkleUpdateDriverDelegate) throws -> SparkleUpdateDriving

    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var automaticChecksEnabled: Bool = false
    @Published private(set) var automaticDownloadsEnabled: Bool = false
    @Published private(set) var isTranslocated: Bool = false
    @Published private(set) var isInstalledInApplications: Bool = false
    @Published private(set) var releaseNotes: String?
    @Published private(set) var releaseHistory: [ReleaseHistoryEntry] = []
    @Published private(set) var releaseMetadataError: String?
    @Published private(set) var isLoadingReleaseMetadata: Bool = false
    @Published private(set) var awaitingManualCheckPopover: Bool = false
    /// True while a manual check is refreshing an already-displayed status.
    @Published private(set) var isRefreshingUpdateStatus: Bool = false
    /// Download / extraction / install progress for the popover bar. Non-nil
    /// only while `state == .installing`.
    @Published private(set) var installProgress: UpdateInstallProgress?

    static let manualCheckDebounce: TimeInterval = 2

    private let session: URLSession
    private let bundleURLProvider: () -> URL
    private let currentVersionProvider: () -> String?
    private let buildProvider: () -> String?
    private let nowProvider: () -> Date
    private let opener: (URL) -> Void
    private let finderRevealer: (URL) -> Void
    private let driverFactory: DriverFactory

    private var driver: SparkleUpdateDriving?
    private var lastManualCheckAt: Date?
    private var releaseMetadataTask: Task<Void, Never>?
    private var currentUpdate: SparkleUpdateInfo?

    var currentVersion: String {
        currentVersionProvider() ?? "unknown"
    }

    var currentBuild: String {
        buildProvider() ?? "unknown"
    }

    var fallbackURL: URL {
        ReleaseUpdateConfig.releasesLatestURL
    }

    init(
        session: URLSession = .ephemeralWithTimeout(10),
        bundleURLProvider: @escaping () -> URL = { Bundle.main.bundleURL },
        currentVersionProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        },
        buildProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        },
        nowProvider: @escaping () -> Date = { Date() },
        opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        finderRevealer: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        driverFactory: @escaping DriverFactory = { delegate in
            #if canImport(Sparkle)
            return SparkleUpdateDriver(delegate: delegate)
            #else
            throw UpdateSetupError.sparkleUnavailable
            #endif
        }
    ) {
        self.session = session
        self.bundleURLProvider = bundleURLProvider
        self.currentVersionProvider = currentVersionProvider
        self.buildProvider = buildProvider
        self.nowProvider = nowProvider
        self.opener = opener
        self.finderRevealer = finderRevealer
        self.driverFactory = driverFactory

        evaluateInstallLocation()
        startSparkleIfPossible()
        restorePersistedStatusIfNeeded()
    }

    deinit {
        releaseMetadataTask?.cancel()
    }

    // MARK: - Actions

    func checkForUpdates() {
        startManualCheck(mode: .foreground)
    }

    func refreshUpdateStatus() {
        startManualCheck(mode: .informationOnly)
    }

    func checkForUpdatesInBackground() {
        guard canUseSparkle, let driver, automaticChecksEnabled else {
            if canUseSparkle { state = .automaticChecksDisabled }
            return
        }
        driver.checkForUpdatesInBackground()
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard let driver else {
            automaticChecksEnabled = false
            state = .setupBlocked(reason: "Sparkle is not configured.", fallbackURL: fallbackURL)
            return
        }
        driver.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = enabled
        if enabled {
            if case .automaticChecksDisabled = state { state = .idle }
        } else {
            state = .automaticChecksDisabled
        }
    }

    func setAutomaticDownloadsEnabled(_ enabled: Bool) {
        guard let driver else {
            automaticDownloadsEnabled = false
            return
        }
        driver.automaticallyDownloadsUpdates = enabled
        automaticDownloadsEnabled = enabled
    }

    func dismissUpdate() {
        let version = currentUpdate?.displayVersion
        currentUpdate = nil
        state = .userCancelled(version: version)
    }

    /// Cancel an in-flight download. Sparkle reports the cancellation back
    /// through the driver, which transitions the state to `.userCancelled`.
    func cancelInstall() {
        guard case .installing = state else { return }
        driver?.cancelInstall()
    }

    /// True only while a download is actively cancellable (not during the
    /// non-interruptible extraction/install phases).
    var canCancelInstall: Bool {
        guard case .installing = state else { return false }
        return installProgress?.phase == .downloading
    }

    func openReleasePageFallback() {
        opener(fallbackURL)
    }

    func openAppcast() {
        opener(ReleaseUpdateConfig.appcastURL)
    }

    func openReleaseNotes() {
        if let url = currentUpdate?.releaseNotesURL ?? currentUpdate?.fullReleaseNotesURL {
            opener(url)
        } else {
            opener(ReleaseUpdateConfig.releaseNotesURL(version: currentVersion))
        }
    }

    func showCurrentBundleInFinder() {
        finderRevealer(bundleURLProvider())
    }

    func refreshReleaseMetadata() {
        guard !isLoadingReleaseMetadata else { return }
        releaseMetadataTask?.cancel()
        releaseMetadataTask = Task { [weak self] in
            await self?.loadReleaseMetadata()
        }
    }

    func acknowledgeManualCheckPopover() {
        awaitingManualCheckPopover = false
    }

    // MARK: - Setup

    private var canUseSparkle: Bool {
        switch state {
        case .translocated, .nonApplicationsInstall, .setupBlocked:
            return false
        default:
            return true
        }
    }

    private func evaluateInstallLocation() {
        let bundleURL = bundleURLProvider().standardizedFileURL
        let bundlePath = bundleURL.path
        isTranslocated = bundlePath.hasPrefix("/private/var/folders/")
        isInstalledInApplications = bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix("/System/Applications/")

        if isTranslocated {
            state = .translocated(bundleURL: bundleURL)
            updateLogger.info("App is translocated at \(bundlePath, privacy: .public)")
        } else if !isInstalledInApplications {
            state = .nonApplicationsInstall(bundleURL: bundleURL)
            updateLogger.info("App is outside /Applications at \(bundlePath, privacy: .public)")
        }
    }

    private func startSparkleIfPossible() {
        guard canUseSparkle else { return }

        do {
            let driver = try driverFactory(self)
            self.driver = driver
            try driver.start()
            syncDriverPreferences()
            updateLogger.info("Sparkle updater started with feed \(ReleaseUpdateConfig.appcastURL.absoluteString, privacy: .public)")
        } catch {
            state = .setupBlocked(reason: error.localizedDescription, fallbackURL: fallbackURL)
            updateLogger.error("Sparkle setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func syncDriverPreferences() {
        guard let driver else { return }
        automaticChecksEnabled = driver.automaticallyChecksForUpdates
        automaticDownloadsEnabled = driver.automaticallyDownloadsUpdates
        lastCheckedAt = driver.lastUpdateCheckDate
        if !automaticChecksEnabled, case .idle = state {
            state = .automaticChecksDisabled
        }
    }

    private enum ManualCheckMode {
        case foreground
        case informationOnly
    }

    private func startManualCheck(mode: ManualCheckMode) {
        guard canUseSparkle else { return }

        let bypassDebounce: Bool = {
            if case .foreground = mode, case .updateAvailable = state { return true }
            return false
        }()

        if !bypassDebounce,
           let lastManualCheckAt,
           nowProvider().timeIntervalSince(lastManualCheckAt) < Self.manualCheckDebounce {
            awaitingManualCheckPopover = true
            updateLogger.debug("Skipping network update check inside debounce window; showing cached status")
            return
        }

        guard let driver else {
            state = .setupBlocked(reason: "Sparkle is not available in this build.", fallbackURL: fallbackURL)
            return
        }

        guard driver.canCheckForUpdates else {
            state = .setupBlocked(
                reason: "Sparkle cannot check for updates right now. Open the app from /Applications and try again.",
                fallbackURL: fallbackURL
            )
            return
        }

        lastManualCheckAt = nowProvider()
        awaitingManualCheckPopover = true

        if hasDisplayedUpdateStatus {
            isRefreshingUpdateStatus = true
        } else {
            state = .checking
        }

        scheduleSparkleCheck(mode: mode, driver: driver)
    }

    private var hasDisplayedUpdateStatus: Bool {
        switch state {
        case .upToDate, .updateAvailable:
            return true
        default:
            return false
        }
    }

    private func scheduleSparkleCheck(mode: ManualCheckMode, driver: SparkleUpdateDriving) {
        Task { @MainActor in
            // Yield so SwiftUI can paint "Checking" / the cached status
            // before Sparkle's synchronous appcast work on the main actor.
            await Task.yield()
            switch mode {
            case .foreground:
                driver.checkForUpdates()
            case .informationOnly:
                driver.checkForUpdateInformation()
            }
        }
    }

    private func restorePersistedStatusIfNeeded() {
        guard canUseSparkle else { return }
        switch state {
        case .idle, .automaticChecksDisabled: break
        default: return
        }
        guard let record = UpdateStatusPersistence.load() else { return }
        switch record {
        case .upToDate(let checkedAt):
            lastCheckedAt = checkedAt
            state = .upToDate(lastCheckedAt: checkedAt)
        case .updateAvailable(let update):
            // Don't restore if we're already at or past the advertised version.
            guard let current = currentVersionProvider() else { return }
            if update.version.compare(current, options: .numeric) != .orderedDescending {
                UpdateStatusPersistence.clear()
                return
            }
            currentUpdate = update
            state = .updateAvailable(update)
        }
    }

    private func persistCompletedStatus() {
        switch state {
        case .upToDate(let checkedAt):
            UpdateStatusPersistence.save(.upToDate(lastCheckedAt: checkedAt))
        case .updateAvailable(let update):
            UpdateStatusPersistence.save(.updateAvailable(update))
        default:
            break
        }
    }

    private func loadReleaseMetadata() async {
        isLoadingReleaseMetadata = true
        releaseMetadataError = nil
        defer { isLoadingReleaseMetadata = false }

        async let historyResult: Void = loadReleaseHistory()
        async let notesResult: Void = loadCurrentReleaseNotes()
        _ = await (historyResult, notesResult)
    }

    private func loadReleaseHistory() async {
        do {
            let (data, response) = try await session.data(from: ReleaseUpdateConfig.releaseHistoryURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            releaseHistory = try decoder.decode([ReleaseHistoryEntry].self, from: data)
        } catch {
            releaseMetadataError = error.localizedDescription
            updateLogger.debug("Release history unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadCurrentReleaseNotes() async {
        let url = currentUpdate?.releaseNotesURL
            ?? currentUpdate?.fullReleaseNotesURL
            ?? ReleaseUpdateConfig.releaseNotesURL(version: currentVersion)
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            releaseNotes = String(data: data, encoding: .utf8)
        } catch {
            // Release notes are a best-effort informational extra. A missing
            // per-version notes doc (404) — or any transient fetch failure —
            // must NOT surface a raw URLError ("NSURLErrorDomain error -1011")
            // in the updater popover. The genuine history/appcast failure path
            // owns releaseMetadataError; leave the notes panel in its calm empty
            // state and drop any stale notes from a prior load.
            releaseNotes = nil
            updateLogger.debug("Release notes unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Driver delegate

extension UpdateCoordinator: SparkleUpdateDriverDelegate {
    func updateDriverDidStartChecking() {
        guard !isRefreshingUpdateStatus else { return }
        state = .checking
    }

    func updateDriverDidFindUpdate(_ update: SparkleUpdateInfo) {
        isRefreshingUpdateStatus = false
        installProgress = nil
        currentUpdate = update
        state = .updateAvailable(update)
        persistCompletedStatus()
        refreshReleaseMetadata()
    }

    func updateDriverDidNotFindUpdate() {
        isRefreshingUpdateStatus = false
        installProgress = nil
        currentUpdate = nil
        lastCheckedAt = driver?.lastUpdateCheckDate ?? nowProvider()
        state = .upToDate(lastCheckedAt: lastCheckedAt)
        persistCompletedStatus()
        refreshReleaseMetadata()
    }

    func updateDriverDidStartInstalling(_ update: SparkleUpdateInfo?) {
        if let update { currentUpdate = update }
        if installProgress == nil { installProgress = UpdateInstallProgress(phase: .downloading, fraction: nil) }
        state = .installing(update ?? currentUpdate)
        UpdateStatusPersistence.clear()
    }

    func updateDriverDidUpdateProgress(_ progress: UpdateInstallProgress) {
        // Progress only makes sense while installing; flip the state if a
        // resumed (already-downloaded) update jumps straight to extraction.
        if case .installing = state {} else {
            state = .installing(currentUpdate)
            UpdateStatusPersistence.clear()
        }
        installProgress = progress
    }

    func updateDriverDidInstallAndAwaitRelaunch(version: String?) {
        installProgress = nil
        state = .installedRelaunchPending(version: version ?? currentUpdate?.displayVersion)
        UpdateStatusPersistence.clear()
    }

    func updateDriverDidCancel(version: String?) {
        isRefreshingUpdateStatus = false
        installProgress = nil
        state = .userCancelled(version: version ?? currentUpdate?.displayVersion)
    }

    func updateDriverDidFail(_ error: Error) {
        isRefreshingUpdateStatus = false
        installProgress = nil
        state = SparkleErrorClassifier.state(for: error, fallbackURL: fallbackURL)
    }

    func updateDriverPreferencesChanged() {
        isRefreshingUpdateStatus = false
        syncDriverPreferences()
    }
}

// MARK: - Error classification

enum SparkleErrorClassifier {
    static func isNoUpdate(_ error: Error) -> Bool {
        let nsError = error as NSError
        return isSparkleError(nsError, code: 1001)
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == NSUserCancelledError { return true }
        return isSparkleError(nsError, code: 4007)
            || isSparkleError(nsError, code: 4008)
    }

    static func state(for error: Error, fallbackURL: URL) -> AppUpdateState {
        let nsError = error as NSError
        let text = ([nsError.domain, nsError.localizedDescription, nsError.localizedFailureReason]
            + nsError.userInfo.values.map { "\($0)" })
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if text.contains("ed25519")
            || text.contains("signature")
            || text.contains("appcast")
            || text.contains("dsasignature") {
            return .invalidAppcastSignature(reason: nsError.localizedDescription, fallbackURL: fallbackURL)
        }

        if text.contains("corrupt")
            || text.contains("checksum")
            || text.contains("archive")
            || text.contains("extract") {
            return .corruptedDownload(reason: nsError.localizedDescription, fallbackURL: fallbackURL)
        }

        return .failed(reason: nsError.localizedDescription, fallbackURL: fallbackURL)
    }

    private static func isSparkleError(_ error: NSError, code: Int) -> Bool {
        guard error.code == code else { return false }
        if error.domain == "SUSparkleErrorDomain" { return true }
        return error.domain.localizedCaseInsensitiveContains("Sparkle")
    }
}

enum UpdateSetupError: LocalizedError {
    case sparkleUnavailable

    var errorDescription: String? {
        switch self {
        case .sparkleUnavailable:
            return "Sparkle is not linked into this build."
        }
    }
}

// MARK: - Sparkle adapter

#if canImport(Sparkle)
/// Drives Sparkle through a *headless* user driver so the entire update flow —
/// availability, download progress, extraction, install — renders inside the
/// top-right `UpdateAppControl` popover. We deliberately do NOT use
/// `SPUStandardUpdaterController` / `SPUStandardUserDriver`: those pop Sparkle's
/// own center-of-screen window, which is exactly the overlay we're replacing.
@MainActor
final class SparkleUpdateDriver: NSObject, SparkleUpdateDriving, SPUUpdaterDelegate {
    private weak var delegate: SparkleUpdateDriverDelegate?
    private let userDriver = ContinuumUserDriver()
    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: userDriver,
        delegate: self
    )
    private var installingUpdate: SparkleUpdateInfo?
    private var downloadExpectedLength: UInt64 = 0
    private var downloadReceivedLength: UInt64 = 0
    /// Guards the single `.installing` flip per session (a resumed background
    /// download can skip `showDownloadInitiated` and jump to extraction).
    private var installingSessionActive = false
    /// Latest in-flight cancellation block (download phase only).
    private var activeCancellation: (() -> Void)?

    init(delegate: SparkleUpdateDriverDelegate) {
        self.delegate = delegate
        super.init()
        userDriver.host = self
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            updater.automaticallyChecksForUpdates = newValue
            delegate?.updateDriverPreferencesChanged()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            updater.automaticallyDownloadsUpdates = newValue
            delegate?.updateDriverPreferencesChanged()
        }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func start() throws { try updater.start() }

    func checkForUpdates() {
        resetInstallSession()
        delegate?.updateDriverDidStartChecking()
        updater.checkForUpdates()
    }

    func checkForUpdateInformation() {
        resetInstallSession()
        delegate?.updateDriverDidStartChecking()
        updater.checkForUpdateInformation()
    }

    func checkForUpdatesInBackground() {
        updater.checkForUpdatesInBackground()
    }

    func cancelInstall() {
        cancelActiveDownload()
    }

    private func resetInstallSession() {
        installingSessionActive = false
        activeCancellation = nil
        downloadExpectedLength = 0
        downloadReceivedLength = 0
    }

    private func beginInstallSessionIfNeeded() {
        guard !installingSessionActive else { return }
        installingSessionActive = true
        delegate?.updateDriverDidStartInstalling(installingUpdate)
    }

    // MARK: - SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        ReleaseUpdateConfig.appcastURL.absoluteString
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = Self.info(from: item)
        installingUpdate = update
        delegate?.updateDriverDidFindUpdate(update)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        delegate?.updateDriverDidNotFindUpdate()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        if SparkleErrorClassifier.isUserCancellation(error) {
            delegate?.updateDriverDidCancel(version: nil)
        } else {
            delegate?.updateDriverDidNotFindUpdate()
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installingUpdate = Self.info(from: item)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        delegate?.updateDriverDidInstallAndAwaitRelaunch(version: installingUpdate?.displayVersion)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        if SparkleErrorClassifier.isNoUpdate(error) {
            delegate?.updateDriverDidNotFindUpdate()
        } else if SparkleErrorClassifier.isUserCancellation(error) {
            delegate?.updateDriverDidCancel(version: installingUpdate?.displayVersion)
        } else {
            delegate?.updateDriverDidFail(error)
        }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        delegate?.updateDriverDidFail(error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            if SparkleErrorClassifier.isNoUpdate(error) {
                delegate?.updateDriverDidNotFindUpdate()
            } else if SparkleErrorClassifier.isUserCancellation(error) {
                delegate?.updateDriverDidCancel(version: installingUpdate?.displayVersion)
            } else {
                delegate?.updateDriverDidFail(error)
            }
        } else {
            delegate?.updateDriverPreferencesChanged()
        }
    }

    // MARK: - Cancellation surfaced to the popover

    /// Called by the popover's Cancel affordance while a download is in flight.
    func cancelActiveDownload() {
        activeCancellation?()
        activeCancellation = nil
    }

    var canCancelActiveDownload: Bool { activeCancellation != nil }

    // MARK: - ContinuumUserDriver bridge (all on the main actor)

    func userDriverWillCheck(cancellation: @escaping () -> Void) {
        // The coordinator already painted "Checking"/cached status. Nothing to
        // show here — keep the in-flight cancellation only during download.
    }

    func userDriverFoundUpdate(
        _ item: SUAppcastItem,
        userInitiated: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        installingUpdate = Self.info(from: item)
        // `didFindValidUpdate` already surfaced `.updateAvailable` for the
        // popover. A user-initiated check means they pressed Update, so proceed
        // straight into download/install; a background-found update is parked
        // (kept, but not auto-installed) until they press Update themselves.
        reply(userInitiated ? .install : .dismiss)
    }

    func userDriverDownloadInitiated(cancellation: @escaping () -> Void) {
        activeCancellation = cancellation
        downloadExpectedLength = 0
        downloadReceivedLength = 0
        beginInstallSessionIfNeeded()
        delegate?.updateDriverDidUpdateProgress(UpdateInstallProgress(phase: .downloading, fraction: nil))
    }

    func userDriverDownloadExpectedLength(_ length: UInt64) {
        downloadExpectedLength = length
        downloadReceivedLength = 0
        emitDownloadProgress()
    }

    func userDriverDownloadReceived(_ length: UInt64) {
        downloadReceivedLength &+= length
        emitDownloadProgress()
    }

    private func emitDownloadProgress() {
        beginInstallSessionIfNeeded()
        let fraction: Double? = downloadExpectedLength > 0
            ? min(1, Double(downloadReceivedLength) / Double(downloadExpectedLength))
            : nil
        delegate?.updateDriverDidUpdateProgress(UpdateInstallProgress(phase: .downloading, fraction: fraction))
    }

    func userDriverExtractionStarted() {
        // Past the point of a clean download cancel.
        activeCancellation = nil
        beginInstallSessionIfNeeded()
        delegate?.updateDriverDidUpdateProgress(UpdateInstallProgress(phase: .extracting, fraction: nil))
    }

    func userDriverExtractionProgress(_ progress: Double) {
        beginInstallSessionIfNeeded()
        delegate?.updateDriverDidUpdateProgress(
            UpdateInstallProgress(phase: .extracting, fraction: min(1, max(0, progress)))
        )
    }

    func userDriverReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        activeCancellation = nil
        beginInstallSessionIfNeeded()
        delegate?.updateDriverDidUpdateProgress(UpdateInstallProgress(phase: .installing, fraction: nil))
        reply(.install)
    }

    func userDriverInstalling() {
        beginInstallSessionIfNeeded()
        delegate?.updateDriverDidUpdateProgress(UpdateInstallProgress(phase: .installing, fraction: nil))
    }

    func userDriverInstalledAndRelaunched() {
        delegate?.updateDriverDidInstallAndAwaitRelaunch(version: installingUpdate?.displayVersion)
    }

    func userDriverNotFound(error: Error?) {
        delegate?.updateDriverDidNotFindUpdate()
    }

    func userDriverError(_ error: Error) {
        activeCancellation = nil
        installingSessionActive = false
        if SparkleErrorClassifier.isUserCancellation(error) {
            delegate?.updateDriverDidCancel(version: installingUpdate?.displayVersion)
        } else {
            delegate?.updateDriverDidFail(error)
        }
    }

    func userDriverDismiss() {
        // Sparkle tore down its (headless) session. The coordinator owns the
        // visible state; nothing on-screen to dismiss here.
        activeCancellation = nil
        installingSessionActive = false
    }

    private static func info(from item: SUAppcastItem) -> SparkleUpdateInfo {
        SparkleUpdateInfo(
            version: item.versionString,
            displayVersion: item.displayVersionString,
            title: item.title,
            releaseNotesURL: item.releaseNotesURL,
            fullReleaseNotesURL: item.fullReleaseNotesURL,
            downloadURL: item.fileURL,
            minimumSystemVersion: item.minimumSystemVersion
        )
    }
}

/// Headless `SPUUserDriver`: every callback routes into `SparkleUpdateDriver`
/// (and thence the coordinator + popover). No windows, alerts, or panels are
/// ever shown — Sparkle's UI is entirely our top-right popover.
@MainActor
final class ContinuumUserDriver: NSObject, SPUUserDriver {
    weak var host: SparkleUpdateDriver?

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Never prompt with a dialog; honor the current automatic-check setting.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: host?.automaticallyChecksForUpdates ?? true,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        host?.userDriverWillCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        host?.userDriverFoundUpdate(appcastItem, userInitiated: state.userInitiated, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        host?.userDriverNotFound(error: error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        host?.userDriverError(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        host?.userDriverDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        host?.userDriverDownloadExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        host?.userDriverDownloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        host?.userDriverExtractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        host?.userDriverExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        host?.userDriverReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        host?.userDriverInstalling()
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        host?.userDriverInstalledAndRelaunched()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        host?.userDriverDismiss()
    }

    func showUpdateInFocus() {}
}
#endif

// MARK: - URLSession convenience

extension URLSession {
    static func ephemeralWithTimeout(_ timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: config)
    }
}
