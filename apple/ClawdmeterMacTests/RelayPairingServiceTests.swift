import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// E7 Mac-side state-machine + bundle-gen tests for the relay pairing
/// service. Validates that:
///   1. Initial phase is `.unpaired`
///   2. `beginPairing()` transitions to `.readyButNotConnected` and
///      surfaces a valid bundle + URL
///   3. The URL round-trips through `RelayPairingBundle.decode(fromURL:)`
///   4. The iOS-side derivation against the Mac's keypair yields the
///      same symmetric key as the Mac-side derivation (cross-platform
///      acceptance — same invariant as RelayPairingHandshakeTests but
///      driven through the Mac service)
///   5. `reset()` returns to `.unpaired` + drops the keypair
@MainActor
final class RelayPairingServiceTests: XCTestCase {

    func testInitialPhaseIsUnpaired() {
        let service = makeService()
        XCTAssertEqual(service.phase, .unpaired)
        XCTAssertNil(service.bundle)
        XCTAssertNil(service.bundleURL)
    }

    func testBeginPairingProducesValidBundle() async throws {
        let service = makeService()
        await service.beginPairing()

        XCTAssertEqual(service.phase, .readyButNotConnected)
        let bundle = try XCTUnwrap(service.bundle)
        let urlString = try XCTUnwrap(service.bundleURL)

        // Bundle fields validate.
        XCTAssertNotNil(bundle.validated())
        XCTAssertTrue(urlString.hasPrefix("clawdmeter-pair://v1/"))

        // The URL parses cleanly back into an equal bundle.
        let decoded = try XCTUnwrap(RelayPairingBundle.decode(fromURL: urlString))
        XCTAssertEqual(decoded, bundle)

        // The session ID + tokens are 32-byte base64url (43 chars).
        XCTAssertEqual(bundle.sid.count, 43)
        XCTAssertEqual(bundle.macTok.count, 43)
        XCTAssertEqual(bundle.iosTok.count, 43)
        XCTAssertNotEqual(bundle.macTok, bundle.iosTok)
        XCTAssertEqual(bundle.creationProof, Self.creationProof)

        // The TTL is in the future and within the relay's 31-day QR cap.
        let now = UInt64(Date().timeIntervalSince1970)
        XCTAssertGreaterThan(bundle.ttl, now)
        XCTAssertLessThanOrEqual(bundle.ttl, now + 31 * 24 * 60 * 60)

        // The relay URL defaults to staging (no env override).
        XCTAssertEqual(bundle.relayUrl, RelayEnvironment.staging.baseURL)
    }

    func testIPhoneCanDeriveMatchingSymmetricKey() async throws {
        let service = makeService()
        await service.beginPairing()

        let macKeypair = try XCTUnwrap(service.keypairForTesting)
        let bundle = try XCTUnwrap(service.bundle)

        // Simulate the iPhone side: parse the bundle from URL, generate
        // an iPhone keypair, derive K, then compute the Mac-side K
        // independently and verify byte equality.
        let urlString = try XCTUnwrap(service.bundleURL)
        let parsed = try XCTUnwrap(RelayPairingBundle.decode(fromURL: urlString))
        XCTAssertEqual(parsed.sid, bundle.sid)
        XCTAssertEqual(parsed.ecdhPub, bundle.ecdhPub)

        let phoneKeypair = RelayPairingKeyPair()
        let phoneK = try phoneKeypair.deriveSharedKey(
            theirPublicKeyBase64URL: parsed.ecdhPub,
            sessionId: parsed.sid
        )
        let macK = try macKeypair.deriveSharedKey(
            theirPublicKeyBase64URL: phoneKeypair.publicKeyBase64URL,
            sessionId: parsed.sid
        )
        XCTAssertEqual(macK, phoneK)
        XCTAssertEqual(macK.count, 32)
    }

    func testResetReturnsToUnpaired() async throws {
        let service = makeService()
        await service.beginPairing()
        XCTAssertEqual(service.phase, .readyButNotConnected)

        service.reset()
        XCTAssertEqual(service.phase, .unpaired)
        XCTAssertNil(service.bundle)
        XCTAssertNil(service.bundleURL)
        XCTAssertNil(service.keypairForTesting)
    }

    func testRegeneratingProducesFreshBundle() async throws {
        let service = makeService()
        await service.beginPairing()
        let first = try XCTUnwrap(service.bundle)
        let firstKey = try XCTUnwrap(service.keypairForTesting).publicKeyBase64URL

        await service.beginPairing()
        let second = try XCTUnwrap(service.bundle)
        let secondKey = try XCTUnwrap(service.keypairForTesting).publicKeyBase64URL

        // Fresh sid, fresh tokens, fresh keypair.
        XCTAssertNotEqual(first.sid, second.sid)
        XCTAssertNotEqual(first.macTok, second.macTok)
        XCTAssertNotEqual(first.iosTok, second.iosTok)
        XCTAssertNotEqual(firstKey, secondKey)
    }

    func testBeginPairingPersistsAPNSSigningKeyFromGrant() async throws {
        let serviceName = "ai.continuum.test.apns.gateway.signing-key-\(UUID().uuidString)"
        let provider = APNSGatewaySigningKeyProvider(keychainService: serviceName, processEnv: [:])
        defer { provider.clear() }
        let key = Data(repeating: 0x7a, count: 32)
        let service = makeService(
            grant: RelayPairingCreationGrant(
                creation: Self.creationProof,
                apnsSigningKey: RelayPairingBase64URL.encode(key)
            ),
            apnsSigningKeyProvider: provider
        )

        await service.beginPairing()

        XCTAssertEqual(provider.signingKey(), key)
        XCTAssertEqual(service.bundle?.apnsSigningKey, RelayPairingBase64URL.encode(key))
    }

    private func makeService(
        grant: RelayPairingCreationGrant = RelayPairingCreationGrant(creation: RelayPairingServiceTests.creationProof),
        apnsSigningKeyProvider: APNSGatewaySigningKeyProvider? = nil
    ) -> RelayPairingService {
        RelayPairingService(
            processEnv: [:],
            creationGrantProvider: { _ in grant },
            apnsSigningKeyProvider: apnsSigningKeyProvider
        )
    }

    nonisolated private static let creationProof = RelaySessionCreationProof(
        issuedAtSeconds: 1_700_000_000,
        nonce: "creation_nonce_123",
        signature: "signature-placeholder"
    )
}

final class CredentialLoggingRedactionTests: XCTestCase {

    func testProviderAndRelaySourcesDoNotLogTokenDerivedMaterial() throws {
        let sourceFiles = [
            "ClawdmeterShared/Sources/ClawdmeterShared/Sources/AnthropicSource.swift",
            "ClawdmeterShared/Sources/ClawdmeterShared/Sources/WatchTokenBridge.swift",
            "ClawdmeterMac/AppRuntime.swift",
            "ClawdmeterMac/AgentControl/MacAPNSPusher.swift",
            "ClawdmeterMac/AgentControl/APNSGatewayClient.swift",
            "ClawdmeterMac/AgentControl/APNSPushDeviceTokenStore.swift"
        ]
        let forbiddenSnippets = [
            "token len=",
            "token prefix=",
            "fp=\\(",
            "token.count, privacy: .public",
            "token.prefix(8)",
            "deviceToken.prefix"
        ]

        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for relativePath in sourceFiles {
            let url = appleRoot.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: url, encoding: .utf8)
            for snippet in forbiddenSnippets {
                XCTAssertFalse(
                    contents.contains(snippet),
                    "\(relativePath) must not log credential-derived material matching \(snippet)"
                )
            }
        }
    }

    func testProviderAndCodeSourcesDoNotExposePromptOrResponseBodiesInPublicDiagnostics() throws {
        let sourceFiles = [
            "ClawdmeterShared/Sources/ClawdmeterShared/Sources/AnthropicSource.swift",
            "ClawdmeterShared/Sources/ClawdmeterShared/Sources/AntigravitySource.swift",
            "ClawdmeterShared/Sources/ClawdmeterShared/Sources/CodexSource.swift",
            "ClawdmeterShared/Sources/ClawdmeterShared/Sources/CursorSource.swift",
            "ClawdmeterMac/AgentControl/RelayPairingService.swift",
            "ClawdmeterMac/AgentControl/SidecarAskCoordinator.swift",
            "ClawdmeterMac/AgentControl/TailscaleWhois.swift",
            "ClawdmeterMac/Workspace/GitDiffPane.swift"
        ]
        let forbiddenSnippets = [
            "body preview",
            "first 200B",
            "String(data: data.prefix",
            "question=\\(question",
            "question, privacy: .public",
            "stderrString, privacy: .public",
            "stdoutString, privacy: .public",
            "trailerText.prefix",
            "preview, privacy: .public"
        ]

        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for relativePath in sourceFiles {
            let url = appleRoot.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: url, encoding: .utf8)
            for snippet in forbiddenSnippets {
                XCTAssertFalse(
                    contents.contains(snippet),
                    "\(relativePath) must not expose prompt or provider response bodies via \(snippet)"
                )
            }
        }
    }

    func testAppRuntimeDefersProviderSideEffectsUnderNoSpendXCTest() throws {
        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = appleRoot.appendingPathComponent("ClawdmeterMac/AppRuntime.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            contents.contains("deferProviderSideEffectsForTesting"),
            "AppRuntime must centralize provider launch side-effect gating."
        )
        XCTAssertTrue(
            contents.contains("XCTestConfigurationFilePath")
                && contents.contains("CLAWDMETER_LIVE_VERIFY")
                && contents.contains("CLAWDMETER_ALLOW_PROVIDER_SPEND")
                && contents.contains(".continuum-live-verify"),
            "Ordinary XCTest must defer provider pollers/warmers unless live-provider spend is explicitly opted in."
        )
        XCTAssertTrue(
            contents.contains("guard !Self.deferProviderSideEffectsForTesting else"),
            "Provider model/probe warmers must return before touching network or provider credentials under no-spend XCTest."
        )
        XCTAssertTrue(
            contents.contains("Provider pollers deferred under test/no-spend gate"),
            "Usage pollers must be visibly skipped under the same no-spend XCTest gate."
        )
        XCTAssertTrue(
            contents.contains("Claude auto-import deferred under test/no-spend gate"),
            "Claude Code token auto-import must not read third-party keychain state during ordinary XCTest."
        )
        XCTAssertTrue(
            contents.contains("testingAppSupportOverride")
                && contents.contains("ClawdmeterMacTests-\\(ProcessInfo.processInfo.processIdentifier)")
                && contents.contains("CLAWDMETER_TEST_APP_SUPPORT_DIR"),
            "Ordinary XCTest must isolate session/workspace/repo-env stores away from the user's real Application Support data."
        )
        XCTAssertTrue(
            contents.contains("mobileCommandOutboxForAppBootstrap")
                && contents.contains("MobileCommandOutbox(replaysAuditLogOnStart: false)"),
            "Ordinary XCTest must not replay the user's real mobile command audit log during AppRuntime bootstrap."
        )
    }
}
