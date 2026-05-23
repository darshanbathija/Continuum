import XCTest
@testable import Clawdmeter

/// v0.24.0 — locks the in-app update checker's behavior across version
/// comparison, dismissal cooldown, translocation detection, debug URL
/// override, GitHub API decoding, and the chipState pure function.
@MainActor
final class UpdateCoordinatorTests: XCTestCase {

    // MARK: - Defaults helpers

    /// Isolated UserDefaults suite per test — never touch
    /// `.standard` so tests can't bleed into each other or pollute
    /// the user's real preferences when run via Xcode.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "Clawdmeter.UpdateCoordinatorTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeCoordinator(
        session: URLSession = MockURLProtocol.makeSession(),
        defaults: UserDefaults? = nil,
        bundleURL: URL = URL(fileURLWithPath: "/Applications/Clawdmeter.app"),
        currentVersion: String? = "0.23.8",
        now: Date = Date(timeIntervalSince1970: 1_716_000_000)
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            session: session,
            defaults: defaults ?? makeDefaults(),
            bundleURLProvider: { bundleURL },
            currentVersionProvider: { currentVersion },
            nowProvider: { now },
            opener: { _ in },
            finderRevealer: { _ in },
            startBackgroundScheduling: false
        )
    }

    // MARK: - Version comparison + tag parsing (5 tests)

    func testCompareVersionsCanonicalCases() {
        XCTAssertEqual(GitHubReleaseConstants.compareVersions("0.23.10", "0.23.9"), .orderedDescending,
                       "0.23.10 must be > 0.23.9 — lexicographic order would give the opposite")
        XCTAssertEqual(GitHubReleaseConstants.compareVersions("1.0.0", "0.99.99"), .orderedDescending,
                       "1.0.0 must be > 0.99.99")
        XCTAssertEqual(GitHubReleaseConstants.compareVersions("0.24.0", "0.23.99"), .orderedDescending)
        XCTAssertEqual(GitHubReleaseConstants.compareVersions("0.23.8", "0.23.8"), .orderedSame)
        XCTAssertEqual(GitHubReleaseConstants.compareVersions("0.23.7", "0.23.8"), .orderedAscending)
    }

    func testParseVersionFromValidTag() {
        XCTAssertEqual(GitHubReleaseConstants.parseVersion(fromTag: "v0.23.8-mac"), "0.23.8")
        XCTAssertEqual(GitHubReleaseConstants.parseVersion(fromTag: "v1.0.0-mac"), "1.0.0")
    }

    func testParseVersionRejectsBetaTag() {
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: "v0.24.0-beta1-mac"),
                     "channel suffix should fail parse until channel support exists")
    }

    func testParseVersionRejectsLinuxTag() {
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: "v0.23.8-linux"))
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: "v0.23.8"))
    }

    func testParseVersionRejectsMalformed() {
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: ""))
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: "v"))
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: "0.23.8"))
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: "v0.23-mac"))
        XCTAssertNil(GitHubReleaseConstants.parseVersion(fromTag: "v0.23.x-mac"))
    }

    // MARK: - Dismissal cooldown (3 tests)

    func testDismissalCooldownSuppressesSameVersion() async {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        defaults.set("0.23.9", forKey: UpdateCoordinator.kDismissedVersion)
        defaults.set(now, forKey: UpdateCoordinator.kDismissedAt)

        MockURLProtocol.responder = { _ in
            MockURLProtocol.json(Self.release(tag: "v0.23.9-mac"))
        }

        let coord = makeCoordinator(defaults: defaults, now: now)
        coord.checkForUpdates()
        await Self.waitForNotChecking(coord)

        XCTAssertNil(coord.availableUpdate, "same-version dismissal within 24h should suppress")
    }

    func testDismissalCooldownExpiresAfter24h() async {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        defaults.set("0.23.9", forKey: UpdateCoordinator.kDismissedVersion)
        defaults.set(now.addingTimeInterval(-25 * 3_600), forKey: UpdateCoordinator.kDismissedAt)

        MockURLProtocol.responder = { _ in
            MockURLProtocol.json(Self.release(tag: "v0.23.9-mac"))
        }

        let coord = makeCoordinator(defaults: defaults, now: now)
        coord.checkForUpdates()
        await Self.waitForNotChecking(coord)

        XCTAssertNotNil(coord.availableUpdate, "after >24h, the chip must reappear")
    }

    func testDismissalCooldownAllowsDifferentVersion() async {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        defaults.set("0.23.9", forKey: UpdateCoordinator.kDismissedVersion)
        defaults.set(now, forKey: UpdateCoordinator.kDismissedAt)

        MockURLProtocol.responder = { _ in
            MockURLProtocol.json(Self.release(tag: "v0.24.0-mac"))
        }

        let coord = makeCoordinator(defaults: defaults, now: now)
        coord.checkForUpdates()
        await Self.waitForNotChecking(coord)

        XCTAssertNotNil(coord.availableUpdate, "a NEWER version than the dismissed one must surface immediately")
        XCTAssertEqual(coord.availableUpdate?.tagName, "v0.24.0-mac")
    }

    // MARK: - Coordinator boundary behavior (4 tests)

    func testDebugReleasesURLOverride() {
        let defaults = makeDefaults()
        let overrideString = "https://example.test/releases/latest.json"
        defaults.set(overrideString, forKey: UpdateCoordinator.kDebugReleasesURL)

        let coord = makeCoordinator(defaults: defaults)
        XCTAssertEqual(coord.effectiveAPIURL.absoluteString, overrideString)
    }

    func testTranslocationDetectionFromPrivateVarFolders() {
        let translocatedURL = URL(fileURLWithPath: "/private/var/folders/aa/bb/T/AppTranslocation/xxx/d/Clawdmeter.app")
        let coordT = makeCoordinator(bundleURL: translocatedURL)
        XCTAssertTrue(coordT.isTranslocated)

        let coordA = makeCoordinator(bundleURL: URL(fileURLWithPath: "/Applications/Clawdmeter.app"))
        XCTAssertFalse(coordA.isTranslocated)
    }

    func testManualCheckDebouncedWithin5Seconds() async {
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let counter = MockURLProtocol.Counter()
        MockURLProtocol.responder = { _ in
            counter.bump()
            return MockURLProtocol.json(Self.release(tag: "v0.23.7-mac"))  // older — won't set chip
        }

        let coord = makeCoordinator(now: now)
        coord.checkForUpdates()
        await Self.waitForNotChecking(coord)
        coord.checkForUpdates()  // immediate second call — should be debounced
        // small wait to give any second fetch a chance
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(counter.value, 1, "second manual check within 5s must be debounced")
    }

    func testAPIErrorPopulatesLastError() async {
        MockURLProtocol.responder = { _ in
            MockURLProtocol.status(500)
        }

        let coord = makeCoordinator()
        coord.checkForUpdates()
        await Self.waitForNotChecking(coord)

        XCTAssertNotNil(coord.lastError, "5xx must populate lastError")
        XCTAssertNil(coord.availableUpdate)
    }

    // MARK: - API decoding (2 tests)

    func testGitHubReleaseDecodesRealResponse() throws {
        // Captured from `gh release view v0.23.8-mac --json
        // tagName,name,body,htmlUrl,publishedAt` — minimal but real.
        let json = """
        {
          "tag_name": "v0.23.8-mac",
          "name": "Clawdmeter v0.23.8 (Mac) — README refresh + Linux compat shims",
          "body": "## Changed\\n\\n- Root README updated.",
          "html_url": "https://github.com/darshanbathija/concept-fake-clawdmeter/releases/tag/v0.23.8-mac",
          "published_at": "2026-05-23T01:47:06Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: json)

        XCTAssertEqual(release.tagName, "v0.23.8-mac")
        XCTAssertEqual(release.name, "Clawdmeter v0.23.8 (Mac) — README refresh + Linux compat shims")
        XCTAssertTrue(release.body?.contains("README updated") ?? false)
        XCTAssertEqual(release.htmlURL.absoluteString,
                       "https://github.com/darshanbathija/concept-fake-clawdmeter/releases/tag/v0.23.8-mac")
        XCTAssertNotNil(release.publishedAt)
    }

    func testGitHubReleaseDecodeFailsGracefully() {
        let json = "{}".data(using: .utf8)!
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(GitHubRelease.self, from: json),
                             "empty object must fail decode because tag_name + html_url are required")
    }

    // MARK: - chipState pure function (3 tests)

    func testChipStateNilCoordinatorIsHidden() {
        XCTAssertEqual(chipState(nil), .hidden)
    }

    func testChipStateNoUpdateAndNotTranslocatedIsHidden() {
        let coord = makeCoordinator()
        XCTAssertEqual(chipState(coord), .hidden,
                       "no update + /Applications path should hide the chip entirely")
    }

    func testChipStateTranslocationWinsOverUpdate() async {
        MockURLProtocol.responder = { _ in
            MockURLProtocol.json(Self.release(tag: "v0.99.0-mac"))
        }
        let translocatedURL = URL(fileURLWithPath: "/private/var/folders/aa/bb/T/AppTranslocation/xxx/d/Clawdmeter.app")
        let coord = makeCoordinator(bundleURL: translocatedURL)
        coord.checkForUpdates()
        await Self.waitForNotChecking(coord)

        XCTAssertTrue(coord.isTranslocated)
        XCTAssertNotNil(coord.availableUpdate, "update should be decoded even when translocated")
        XCTAssertEqual(chipState(coord), .translocated,
                       "translocation must win over update — install would fail anyway")
    }

    // MARK: - GitHubReleaseConstants URL assertions (3 tests)

    func testReleasesLatestURLMatchesExpectedPath() {
        XCTAssertEqual(GitHubReleaseConstants.releasesLatestURL.absoluteString,
                       "https://github.com/darshanbathija/Clawdmeter/releases/latest")
    }

    func testReleasesLatestAPIURLMatchesExpectedPath() {
        XCTAssertEqual(GitHubReleaseConstants.releasesLatestAPIURL.absoluteString,
                       "https://api.github.com/repos/darshanbathija/Clawdmeter/releases/latest")
    }

    func testReleaseTagURLFormatsCorrectly() {
        XCTAssertEqual(GitHubReleaseConstants.releaseTagURL(version: "0.23.9").absoluteString,
                       "https://github.com/darshanbathija/Clawdmeter/releases/tag/v0.23.9-mac")
    }

    // MARK: - Helpers

    private static func release(tag: String, body: String = "Test body") -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            name: "Test \(tag)",
            body: body,
            htmlURL: URL(string: "https://github.com/darshanbathija/Clawdmeter/releases/tag/\(tag)")!,
            publishedAt: nil
        )
    }

    /// Poll for `isCheckingForUpdates == false`. The coordinator
    /// uses an unstructured Task internally; XCTest's expectations
    /// don't trivially attach. 1-second cap is plenty for a mocked
    /// URLProtocol response.
    private static func waitForNotChecking(_ coord: UpdateCoordinator) async {
        for _ in 0..<100 {
            if !coord.isCheckingForUpdates { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - URLProtocol-based URLSession mock

/// Intercepts URLSession requests so tests can return canned responses
/// without a real network round-trip. Set `responder` before each test;
/// it runs synchronously inside `startLoading()`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// `nonisolated(unsafe)` because XCTest tests run serialized per
    /// class but URLProtocol's loaders dispatch on its own queue.
    /// The simple "set before each test, no concurrent mutation" usage
    /// here is fine; if a test ever fans out, swap for a lock.
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data?)) = { _ in
        (HTTPURLResponse(url: URL(string: "https://example.test/")!,
                         statusCode: 500, httpVersion: nil, headerFields: nil)!,
         nil)
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

    static func json(_ release: GitHubRelease) -> (HTTPURLResponse, Data?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(release)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/test/test/releases/latest")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    static func status(_ code: Int, headers: [String: String] = [:]) -> (HTTPURLResponse, Data?) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/test/test/releases/latest")!,
            statusCode: code, httpVersion: nil, headerFields: headers
        )!
        return (response, Data())
    }

    /// Thread-safe counter for tests that need to assert how many
    /// requests fired. Don't read until after `waitForNotChecking`
    /// has returned (the in-flight Task completed).
    final class Counter: @unchecked Sendable {
        private var _value: Int = 0
        private let lock = NSLock()
        func bump() { lock.lock(); _value += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    }
}

// MARK: - Fixed `json` helper that returns a HTTPURLResponse + Data
//
// The `Counter` lives outside `responder` so multiple tests can share
// instances without thread-bouncing. The mock keeps state minimal by
// design — each test sets `responder` fresh.
