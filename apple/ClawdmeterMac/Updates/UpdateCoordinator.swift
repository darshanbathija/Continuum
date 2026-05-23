import Foundation
import Combine
import AppKit
import OSLog

private let updateLogger = Logger(subsystem: "com.clawdmeter.mac", category: "UpdateChecker")

/// In-app update checker — polls GitHub Releases once per day, parses
/// `tag_name` against the running build's `CFBundleShortVersionString`,
/// and surfaces a chip in the titlebar when something newer ships.
///
/// Click-through is intentionally low-tech: the popover's primary CTA
/// opens the GitHub release page in the user's browser, where they
/// download the DMG and drag the new app into `/Applications` themselves.
/// Sparkle one-click install is parked in `TODOS.md` as a phase-2 ship.
///
/// The coordinator also detects app translocation — when macOS Gatekeeper
/// runs the bundle from a randomized `/private/var/folders/...` path,
/// the user cannot follow the drag-to-Applications flow without first
/// moving the current install. A separate yellow chip surfaces this.
@MainActor
final class UpdateCoordinator: ObservableObject {

    // MARK: - Published view state

    @Published private(set) var availableUpdate: GitHubRelease?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isCheckingForUpdates: Bool = false
    @Published private(set) var isTranslocated: Bool = false

    // MARK: - Configuration

    /// Background check cadence. 24 hours.
    static let backgroundCheckInterval: TimeInterval = 86_400
    /// Manual-check debounce window. Prevents UI button-mashing from
    /// burning the GitHub API rate-limit budget.
    static let manualCheckDebounce: TimeInterval = 5
    /// Dismissal cooldown — the chip stays hidden for this long after
    /// the user clicks "Later" on a given version. Per-version.
    static let dismissalCooldown: TimeInterval = 86_400
    /// Initial check delay after init. Lets app launch settle first.
    static let initialCheckDelay: TimeInterval = 8

    // MARK: - UserDefaults keys

    static let kDismissedVersion = "Update.dismissedVersion"
    static let kDismissedAt = "Update.dismissedAt"
    static let kDebugReleasesURL = "ClawdmeterDebugReleasesURL"

    // MARK: - Injection points (for tests + production wiring)

    private let session: URLSession
    private let defaults: UserDefaults
    private let bundleURLProvider: () -> URL
    private let currentVersionProvider: () -> String?
    private let nowProvider: () -> Date
    private let opener: (URL) -> Void
    private let finderRevealer: (URL) -> Void

    // MARK: - Internals

    private var backgroundTimerCancellable: AnyCancellable?
    private var inFlightTask: Task<Void, Never>?

    /// The effective releases API URL, accounting for the debug override.
    /// Read lazily so tests can mutate UserDefaults between init calls.
    var effectiveAPIURL: URL {
        if let override = defaults.string(forKey: Self.kDebugReleasesURL),
           let url = URL(string: override) {
            return url
        }
        return GitHubReleaseConstants.releasesLatestAPIURL
    }

    /// The currently-running app version (CFBundleShortVersionString).
    /// Coordinator skips updates if this returns nil — better to do
    /// nothing than to spam an upgrade prompt over an unknown baseline.
    var currentVersion: String? { currentVersionProvider() }

    // MARK: - Init

    init(
        session: URLSession = .ephemeralWithTimeout(10),
        defaults: UserDefaults = .standard,
        bundleURLProvider: @escaping () -> URL = { Bundle.main.bundleURL },
        currentVersionProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        },
        nowProvider: @escaping () -> Date = { Date() },
        opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        finderRevealer: @escaping (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        },
        startBackgroundScheduling: Bool = true
    ) {
        self.session = session
        self.defaults = defaults
        self.bundleURLProvider = bundleURLProvider
        self.currentVersionProvider = currentVersionProvider
        self.nowProvider = nowProvider
        self.opener = opener
        self.finderRevealer = finderRevealer

        let bundlePath = bundleURLProvider().path
        self.isTranslocated = bundlePath.hasPrefix("/private/var/folders/")
        if isTranslocated {
            updateLogger.info("App is translocated at \(bundlePath, privacy: .public) — surfacing 'Move to Applications' chip")
        }

        if startBackgroundScheduling {
            scheduleBackgroundChecks()
        }
    }

    deinit {
        backgroundTimerCancellable?.cancel()
    }

    // MARK: - Public API (called from popover buttons)

    /// User-initiated check (popover's "Check now" button). Debounced
    /// so rapid clicks don't fire multiple requests.
    func checkForUpdates() {
        if let last = lastCheckedAt,
           nowProvider().timeIntervalSince(last) < Self.manualCheckDebounce {
            updateLogger.debug("Skipping manual check — within debounce window")
            return
        }
        runCheck()
    }

    /// Persist the dismissed version and refuse to surface it again
    /// for `dismissalCooldown` seconds.
    func dismissUpdate() {
        guard let update = availableUpdate,
              let version = GitHubReleaseConstants.parseVersion(fromTag: update.tagName)
        else {
            availableUpdate = nil
            return
        }
        defaults.set(version, forKey: Self.kDismissedVersion)
        defaults.set(nowProvider(), forKey: Self.kDismissedAt)
        availableUpdate = nil
        updateLogger.info("User dismissed update \(version, privacy: .public)")
    }

    /// Open the GitHub releases page in the user's default browser.
    /// This is the primary action — the user downloads the new DMG
    /// from here.
    func openReleasePageFallback() {
        opener(GitHubReleaseConstants.releasesLatestURL)
    }

    /// Reveal the current bundle in Finder so a translocated user can
    /// drag it to /Applications.
    func showCurrentBundleInFinder() {
        finderRevealer(bundleURLProvider())
    }

    // MARK: - Background scheduling

    private func scheduleBackgroundChecks() {
        // Initial check 8s after launch — gives app time to finish
        // bringing up the rest of AppRuntime so logs don't interleave.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.initialCheckDelay * 1_000_000_000))
            self?.runCheckIfStale()
        }

        backgroundTimerCancellable = Timer.publish(
            every: Self.backgroundCheckInterval,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            self?.runCheckIfStale()
        }
    }

    private func runCheckIfStale() {
        if let last = lastCheckedAt,
           nowProvider().timeIntervalSince(last) < Self.backgroundCheckInterval {
            return
        }
        runCheck()
    }

    // MARK: - The actual check

    private func runCheck() {
        inFlightTask?.cancel()
        isCheckingForUpdates = true
        inFlightTask = Task { [weak self] in
            guard let self else { return }
            await self.performCheck()
        }
    }

    private func performCheck() async {
        defer { isCheckingForUpdates = false }
        lastCheckedAt = nowProvider()

        guard let current = currentVersion else {
            updateLogger.warning("currentVersion is nil — skipping check")
            lastError = "Current app version is unavailable"
            return
        }

        let url = effectiveAPIURL
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Clawdmeter/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let detail = http.statusCode == 403 ?
                    rateLimitDetail(from: http) :
                    "HTTP \(http.statusCode)"
                lastError = detail
                availableUpdate = nil
                updateLogger.error("GitHub releases API returned \(http.statusCode, privacy: .public) — \(detail, privacy: .public)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(GitHubRelease.self, from: data)

            guard let latestVersion = GitHubReleaseConstants.parseVersion(fromTag: release.tagName) else {
                updateLogger.info("Latest release tag \(release.tagName, privacy: .public) doesn't match v<n>.<n>.<n>-mac — skipping")
                lastError = nil
                availableUpdate = nil
                return
            }

            let cmp = GitHubReleaseConstants.compareVersions(latestVersion, current)
            guard cmp == .orderedDescending else {
                lastError = nil
                availableUpdate = nil
                updateLogger.debug("Latest \(latestVersion, privacy: .public) is not newer than current \(current, privacy: .public)")
                return
            }

            if isDismissedWithinCooldown(version: latestVersion) {
                updateLogger.debug("Latest \(latestVersion, privacy: .public) was recently dismissed — staying hidden")
                lastError = nil
                availableUpdate = nil
                return
            }

            lastError = nil
            availableUpdate = release
            updateLogger.info("Update available: \(latestVersion, privacy: .public) (current: \(current, privacy: .public))")

        } catch is CancellationError {
            updateLogger.debug("In-flight check cancelled by a newer one")
        } catch {
            lastError = error.localizedDescription
            availableUpdate = nil
            updateLogger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isDismissedWithinCooldown(version: String) -> Bool {
        guard let dismissedVersion = defaults.string(forKey: Self.kDismissedVersion),
              let dismissedAt = defaults.object(forKey: Self.kDismissedAt) as? Date
        else { return false }
        guard dismissedVersion == version else { return false }
        return nowProvider().timeIntervalSince(dismissedAt) < Self.dismissalCooldown
    }

    private func rateLimitDetail(from response: HTTPURLResponse) -> String {
        if let resetStr = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let resetEpoch = TimeInterval(resetStr) {
            let resetDate = Date(timeIntervalSince1970: resetEpoch)
            let fmt = ISO8601DateFormatter()
            return "Rate-limited until \(fmt.string(from: resetDate))"
        }
        return "Rate-limited (HTTP 403)"
    }
}

// MARK: - URLSession convenience

extension URLSession {
    /// Ephemeral session with a custom timeout — used by `UpdateCoordinator`
    /// so update checks don't share cookies/cache with other URLSession
    /// users and don't hang the app on a slow GitHub edge.
    static func ephemeralWithTimeout(_ timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: config)
    }
}
