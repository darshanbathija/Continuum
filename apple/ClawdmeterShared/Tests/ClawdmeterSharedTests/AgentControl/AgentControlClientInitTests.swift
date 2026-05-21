import XCTest
@testable import ClawdmeterShared

/// PR #24a Step 1 regression tests: AgentControlClient now lives in
/// ClawdmeterShared with two construction modes — UserDefaults-backed
/// (existing iOS path) and explicit-arg (new Mac loopback path). Both
/// modes must coexist without leaking state across instances.
final class AgentControlClientInitTests: XCTestCase {

    // Standard UserDefaults keys the client checks. Tests stomp them
    // to set up scenarios; teardown removes them.
    private let keys = [
        AgentControlClient.hostKey,
        AgentControlClient.httpPortKey,
        AgentControlClient.wsPortKey,
        AgentControlClient.tokenKey,
    ]

    override func tearDown() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        super.tearDown()
    }

    func test_userDefaultsBackedInit_readsFromUserDefaults() {
        UserDefaults.standard.set("10.0.0.42", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set(31000, forKey: AgentControlClient.httpPortKey)
        UserDefaults.standard.set(31001, forKey: AgentControlClient.wsPortKey)
        UserDefaults.standard.set("user-defaults-token", forKey: AgentControlClient.tokenKey)

        let client = AgentControlClient()

        XCTAssertEqual(client.host, "10.0.0.42")
        XCTAssertEqual(client.httpPort, 31000)
        XCTAssertEqual(client.wsPort, 31001)
        XCTAssertEqual(client.token, "user-defaults-token")
        XCTAssertTrue(client.isConfigured)
    }

    func test_userDefaultsBackedInit_unconfiguredWhenNoDefaults() {
        let client = AgentControlClient()
        XCTAssertNil(client.host)
        XCTAssertNil(client.token)
        XCTAssertFalse(client.isConfigured)
        // Port defaults still kick in via nonZeroOrDefault.
        XCTAssertEqual(client.httpPort, 21731)
        XCTAssertEqual(client.wsPort, 21732)
    }

    func test_explicitInit_overridesUserDefaults() {
        // Set UserDefaults to one host, construct with another.
        UserDefaults.standard.set("dont.use.me", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("dont-use-token", forKey: AgentControlClient.tokenKey)

        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback-token-abc"
        )

        // Explicit values win.
        XCTAssertEqual(client.host, "127.0.0.1")
        XCTAssertEqual(client.httpPort, 21731)
        XCTAssertEqual(client.wsPort, 21732)
        XCTAssertEqual(client.token, "loopback-token-abc")
        XCTAssertTrue(client.isConfigured)
    }

    func test_explicitInit_setPairingDoesNotCorruptUserDefaults() {
        // UserDefaults previously paired with iOS — don't let a Mac
        // loopback client wipe these.
        UserDefaults.standard.set("paired-iphone.example", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("paired-iphone-token", forKey: AgentControlClient.tokenKey)

        let loopback = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback"
        )
        // setPairing on an explicit-config instance is a no-op (logs a
        // warning); UserDefaults must remain intact.
        loopback.setPairing(host: "evil.example", httpPort: 1, wsPort: 2, token: "stolen")

        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.hostKey),
                       "paired-iphone.example",
                       "Explicit-config setPairing must not overwrite UserDefaults")
        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey),
                       "paired-iphone-token")
        // The loopback client's own values stay the explicit ones.
        XCTAssertEqual(loopback.host, "127.0.0.1")
        XCTAssertEqual(loopback.token, "loopback")
    }

    func test_explicitInit_clearPairingIsNoOp() {
        UserDefaults.standard.set("paired-iphone.example", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("paired-iphone-token", forKey: AgentControlClient.tokenKey)

        let loopback = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback"
        )
        loopback.clearPairing()

        // UserDefaults preserved.
        XCTAssertNotNil(UserDefaults.standard.string(forKey: AgentControlClient.hostKey))
        XCTAssertNotNil(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey))
    }

    func test_userDefaultsInit_setPairingDoesUpdate() {
        let client = AgentControlClient()
        client.setPairing(host: "newhost.example", httpPort: 22222, wsPort: 22223, token: "new-token")

        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.hostKey), "newhost.example")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AgentControlClient.httpPortKey), 22222)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AgentControlClient.wsPortKey), 22223)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey), "new-token")
    }

    func test_userDefaultsInit_clearPairingClears() {
        UserDefaults.standard.set("h.example", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("t", forKey: AgentControlClient.tokenKey)
        let client = AgentControlClient()
        client.clearPairing()
        XCTAssertNil(UserDefaults.standard.string(forKey: AgentControlClient.hostKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey))
    }

    func test_explicitInit_handlesIPv6Host() {
        // url-host literal helper brackets bare IPv6.
        let client = AgentControlClient(
            host: "::1",
            httpPort: 21731,
            wsPort: 21732,
            token: "v6"
        )
        XCTAssertEqual(client.host, "::1")
        // The literal helper itself is tested separately; just ensure
        // we don't crash on IPv6 hosts during init.
        XCTAssertEqual(AgentControlClient.urlHostLiteral("::1"), "[::1]")
        XCTAssertEqual(AgentControlClient.urlHostLiteral("[::1]"), "[::1]")
        XCTAssertEqual(AgentControlClient.urlHostLiteral("127.0.0.1"), "127.0.0.1")
    }
}
