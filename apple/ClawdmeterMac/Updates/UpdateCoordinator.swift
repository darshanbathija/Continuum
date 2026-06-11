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
}

// MARK: - Coordinator

@MainActor
final class UpdateCoordinator: ObservableObject {
    typealias DriverFactory = @MainActor (SparkleUpdateDriverDelegate) throws -> SparkleUpdateDriving

    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var automaticChecksEnabled: Bool = true
    @Published private(set) var automaticDownloadsEnabled: Bool = true
    @Published private(set) var isTranslocated: Bool = false
    @Published private(set) var isInstalledInApplications: Bool = false
    @Published private(set) var releaseNotes: String?
    @Published private(set) var releaseHistory: [ReleaseHistoryEntry] = []
    @Published private(set) var releaseMetadataError: String?
    @Published private(set) var isLoadingReleaseMetadata: Bool = false

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
            applyDefaultUpdatePreferences()
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

    /// The Settings toggles for automatic checks/downloads were removed, so
    /// every launch re-enables Sparkle's background check + download path.
    private func applyDefaultUpdatePreferences() {
        setAutomaticChecksEnabled(true)
        setAutomaticDownloadsEnabled(true)
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
            updateLogger.debug("Skipping update check because it is inside the manual debounce window")
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
        state = .checking
        switch mode {
        case .foreground:
            driver.checkForUpdates()
        case .informationOnly:
            driver.checkForUpdateInformation()
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
        state = .checking
    }

    func updateDriverDidFindUpdate(_ update: SparkleUpdateInfo) {
        currentUpdate = update
        state = .updateAvailable(update)
        refreshReleaseMetadata()
    }

    func updateDriverDidNotFindUpdate() {
        currentUpdate = nil
        lastCheckedAt = driver?.lastUpdateCheckDate ?? nowProvider()
        state = .upToDate(lastCheckedAt: lastCheckedAt)
        refreshReleaseMetadata()
    }

    func updateDriverDidStartInstalling(_ update: SparkleUpdateInfo?) {
        if let update { currentUpdate = update }
        state = .installing(update ?? currentUpdate)
    }

    func updateDriverDidInstallAndAwaitRelaunch(version: String?) {
        state = .installedRelaunchPending(version: version ?? currentUpdate?.displayVersion)
    }

    func updateDriverDidCancel(version: String?) {
        state = .userCancelled(version: version ?? currentUpdate?.displayVersion)
    }

    func updateDriverDidFail(_ error: Error) {
        state = SparkleErrorClassifier.state(for: error, fallbackURL: fallbackURL)
    }

    func updateDriverPreferencesChanged() {
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
@MainActor
final class SparkleUpdateDriver: NSObject, SparkleUpdateDriving, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private weak var delegate: SparkleUpdateDriverDelegate?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var installingUpdate: SparkleUpdateInfo?

    init(delegate: SparkleUpdateDriverDelegate) {
        self.delegate = delegate
        super.init()
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
            delegate?.updateDriverPreferencesChanged()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set {
            updaterController.updater.automaticallyDownloadsUpdates = newValue
            delegate?.updateDriverPreferencesChanged()
        }
    }

    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }

    func start() throws {
        try updaterController.updater.start()
    }

    func checkForUpdates() {
        delegate?.updateDriverDidStartChecking()
        updaterController.updater.checkForUpdates()
    }

    func checkForUpdateInformation() {
        delegate?.updateDriverDidStartChecking()
        updaterController.updater.checkForUpdateInformation()
    }

    func checkForUpdatesInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }

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
        let update = Self.info(from: item)
        installingUpdate = update
        delegate?.updateDriverDidStartInstalling(update)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        delegate?.updateDriverDidFail(error)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        delegate?.updateDriverDidFail(error)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        delegate?.updateDriverDidCancel(version: installingUpdate?.displayVersion)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        delegate?.updateDriverDidInstallAndAwaitRelaunch(version: installingUpdate?.displayVersion)
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
