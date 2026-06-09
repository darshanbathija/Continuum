import Foundation
import OSLog
import Combine
import ClawdmeterShared

private let relayPairingLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayPairing")

public struct RelayPairingCreationGrantRequest: Sendable {
    public let sessionId: String
    public let macTokenHash: String
    public let iosTokenHash: String
    public let ttlSeconds: UInt64
    public let relayURL: String
    public let senderMacFingerprint: String?

    public init(
        sessionId: String,
        macTokenHash: String,
        iosTokenHash: String,
        ttlSeconds: UInt64,
        relayURL: String,
        senderMacFingerprint: String?
    ) {
        self.sessionId = sessionId
        self.macTokenHash = macTokenHash
        self.iosTokenHash = iosTokenHash
        self.ttlSeconds = ttlSeconds
        self.relayURL = relayURL
        self.senderMacFingerprint = senderMacFingerprint
    }
}

public struct RelayPairingCreationGrant: Codable, Sendable, Equatable {
    public let creation: RelaySessionCreationProof
    public let apnsSigningKey: String?

    public init(creation: RelaySessionCreationProof, apnsSigningKey: String? = nil) {
        self.creation = creation
        self.apnsSigningKey = apnsSigningKey
    }
}

public enum RelayPairingCreationGrantError: Error, LocalizedError, Equatable {
    case malformedRelayURL
    case missingGrantAuthorization
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .malformedRelayURL:
            return "Relay URL is malformed."
        case .missingGrantAuthorization:
            return "Relay creation grant authorization is not configured."
        case .badStatus(let status, let body):
            if body.isEmpty { return "Relay returned HTTP \(status)." }
            return "Relay returned HTTP \(status): \(body)"
        }
    }
}

public typealias RelayPairingCreationGrantProvider = (RelayPairingCreationGrantRequest) async throws -> RelayPairingCreationGrant

public struct RelayPairingCreationGrantClient {
    private struct Body: Encodable {
        let macTokenHash: String
        let iosTokenHash: String
        let ttlSeconds: UInt64
        let senderMacFingerprint: String?
    }

    private let urlSession: URLSession
    private let authToken: String?

    public init(
        urlSession: URLSession = .shared,
        authToken: String? = ProcessInfo.processInfo.environment["CLAWDMETER_RELAY_CREATION_GRANT_TOKEN"]
    ) {
        self.urlSession = urlSession
        let trimmedToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.authToken = trimmedToken.isEmpty ? nil : trimmedToken
    }

    public func issueGrant(_ grantRequest: RelayPairingCreationGrantRequest) async throws -> RelayPairingCreationGrant {
        guard let url = Self.creationGrantURL(
            relayURL: grantRequest.relayURL,
            sessionId: grantRequest.sessionId
        ) else {
            throw RelayPairingCreationGrantError.malformedRelayURL
        }
        guard let authToken else {
            throw RelayPairingCreationGrantError.missingGrantAuthorization
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(
            macTokenHash: grantRequest.macTokenHash,
            iosTokenHash: grantRequest.iosTokenHash,
            ttlSeconds: grantRequest.ttlSeconds,
            senderMacFingerprint: grantRequest.senderMacFingerprint
        ))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RelayPairingCreationGrantError.badStatus(status, "body bytes=\(data.count)")
        }
        return try JSONDecoder().decode(RelayPairingCreationGrant.self, from: data)
    }

    static func creationGrantURL(relayURL: String, sessionId: String) -> URL? {
        let trimmed = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed) else { return nil }
        switch components.scheme {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            return nil
        }
        components.path = "/v1/relay/sessions/\(sessionId)/creation-grant"
        components.query = nil
        return components.url
    }
}

/// E7 Mac-side state machine + bundle factory for relay pairing.
///
/// Owns:
///   - the ephemeral X25519 keypair the Mac generates per pairing
///   - the (sid, macTok, iosTok) tuple the Mac mints at QR time
///   - the persisted-for-this-process record so the QR can be redisplayed
///     without re-minting (re-minting would invalidate the iPhone's
///     already-scanned bundle)
///
/// Per the E7 task spec ("but DOES NOT actually connect to the relay (E3
/// will)") this service just GENERATES the bundle + shows the QR. The
/// actual relay WebSocket open lives in E3.
///
/// Per design doc §5b: the Mac's X25519 private key is held in process
/// memory only; it is never written to Keychain or disk. Relaunching
/// Clawdmeter invalidates the previous QR — the user must regenerate.
@MainActor
public final class RelayPairingService: ObservableObject {

    // MARK: - Observable state

    @Published public private(set) var phase: RelayPairingPhase = .unpaired

    /// The currently-active bundle. The QR view reads `bundleURL` off of
    /// this; nil while in `.unpaired` / `.generatingBundle`.
    @Published public private(set) var bundle: RelayPairingBundle?

    /// Encoded `clawdmeter-pair://v1/<base64>` URL of the current bundle,
    /// for both the QR generator and the "Copy to clipboard" fallback.
    @Published public private(set) var bundleURL: String?

    /// Operator-facing summary derived from the current state. UI binds
    /// to this so secret material never accidentally leaks into views.
    @Published public private(set) var summary: RelayPairingSummary = .initial

    /// Last grant/encoding error surfaced to Settings. Nil after a successful
    /// generation or reset.
    @Published public private(set) var lastError: String?

    /// The relay env the Mac currently targets. The Mac UI can flip this
    /// (defaults to `.staging` for E7).
    @Published public var environment: RelayEnvironment = .default {
        didSet {
            // Bundle is stale once the env changes — drop it. Next "Pair"
            // tap mints a fresh one against the new env.
            if environment != oldValue { reset() }
        }
    }

    // MARK: - Internal state

    /// Mac's ephemeral X25519 keypair. NOT persisted; new pairing → new
    /// keypair. Held until `reset()` or the service is dealloc'd.
    private var keypair: RelayPairingKeyPair?

    /// Shared pairing-record store. Used so the Mac's APNS gateway path
    /// (E6) can find the active pairing without reaching back into this
    /// service. For E7 the Mac side did not write here; E6 adds the
    /// `recordPeerHandshake(...)` hook that persists once the iPhone's
    /// pubkey arrives (currently invoked by E6 tests + by E3 once it
    /// lands; the production path is E3's relay-client first-frame
    /// handler).
    private let pairingStore: RelayPairingStore
    private let processEnv: [String: String]
    private let creationGrantProvider: RelayPairingCreationGrantProvider
    private let apnsSigningKeyProvider: APNSGatewaySigningKeyProvider?

    public init(
        pairingStore: RelayPairingStore = .shared,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        creationGrantProvider: RelayPairingCreationGrantProvider? = nil,
        apnsSigningKeyProvider: APNSGatewaySigningKeyProvider? = .shared
    ) {
        self.pairingStore = pairingStore
        self.processEnv = processEnv
        let grantClient = RelayPairingCreationGrantClient(
            authToken: processEnv["CLAWDMETER_RELAY_CREATION_GRANT_TOKEN"]
        )
        self.creationGrantProvider = creationGrantProvider ?? { request in
            try await grantClient.issueGrant(request)
        }
        self.apnsSigningKeyProvider = apnsSigningKeyProvider
    }

    // MARK: - Public API

    /// User tapped "Pair iPhone" on the Mac. Generates the bundle and obtains
    /// the relay Worker grant needed for first-connect session creation.
    public func beginPairing() async {
        phase = .generatingBundle
        lastError = nil
        relayPairingLogger.info("Beginning relay pairing bundle generation")

        let pair = RelayPairingKeyPair()
        let sid = RelayPairingMint.randomBase64URLToken()
        let macTok = RelayPairingMint.randomBase64URLToken()
        let iosTok = RelayPairingMint.randomBase64URLToken()
        // CB-P0a (2026-06-05): durable session TTL. The original §5b 15-min
        // window forced a re-pair every 15 minutes, which makes the relay
        // unusable as a daily transport. The relay Worker accepts any
        // ttlSeconds > 0 (isValidAuthBundle), so durability is a client-side
        // bump: 30 days. Re-pairing rotates the X25519 keypair + tokens, so a
        // bounded window (vs forever) keeps a leaked Keychain bundle's blast
        // radius finite. Continuous in-band credential rotation is the deferred
        // hardening (CB-P0a-rotation); this is the pragmatic durable default.
        let relaySessionTTLSeconds: UInt64 = 30 * 24 * 60 * 60  // 30 days
        let ttl = UInt64(Date().timeIntervalSince1970) + relaySessionTTLSeconds
        let relayUrl = RelayEnvironment.resolvedRelayURL(env: environment, processEnv: processEnv)
        let macTokenHash = MacRelayClientConfig.sha256Hex(macTok)
        let iosTokenHash = MacRelayClientConfig.sha256Hex(iosTok)
        let senderFingerprint = APNSSenderFingerprint.compute(macPublicKeyBase64URL: pair.publicKeyBase64URL)
        let grant: RelayPairingCreationGrant
        do {
            grant = try await creationGrantProvider(RelayPairingCreationGrantRequest(
                sessionId: sid,
                macTokenHash: macTokenHash,
                iosTokenHash: iosTokenHash,
                ttlSeconds: ttl,
                relayURL: relayUrl,
                senderMacFingerprint: senderFingerprint
            ))
        } catch {
            guard let fallbackSigningKey = RelaySessionCreationSigningKeyProvider.shared.signingKey() else {
                relayPairingLogger.error("Failed to obtain relay creation grant: \(error.localizedDescription)")
                self.lastError = error.localizedDescription
                self.phase = .unpaired
                return
            }
            relayPairingLogger.warning("Using local relay creation signing key fallback after grant failure: \(error.localizedDescription)")
            grant = RelayPairingCreationGrant(creation: RelaySessionCreationProof.issue(
                signingKey: fallbackSigningKey,
                sessionId: sid,
                macTokenHash: macTokenHash,
                iosTokenHash: iosTokenHash,
                ttlSeconds: ttl
            ))
        }

        let bundle = RelayPairingBundle(
            sid: sid,
            macTok: macTok,
            iosTok: iosTok,
            ecdhPub: pair.publicKeyBase64URL,
            ttl: ttl,
            relayUrl: relayUrl,
            creationProof: grant.creation,
            apnsSigningKey: grant.apnsSigningKey
        )

        let urlString: String
        do {
            urlString = try bundle.encodeToURL()
        } catch {
            relayPairingLogger.error("Failed to encode bundle URL: \(error.localizedDescription)")
            self.phase = .unpaired
            self.lastError = error.localizedDescription
            return
        }

        persistAPNSSigningKeyFromGrant(grant)

        self.keypair = pair
        self.bundle = bundle
        self.bundleURL = urlString
        // §5b "forward secrecy by construction" — the Mac's commitment
        // happens the moment it displays the bundle. The iPhone's half
        // (its derived K) is observed-but-not-known to us until E3/E4
        // bring the relay frame through. For UI purposes we mark the
        // Mac side `keyExchanged` to signal "QR is live and ready for
        // the iPhone to scan", then `readyButNotConnected` since the
        // socket itself is E3's job.
        self.phase = .readyButNotConnected
        self.refreshSummary()

        relayPairingLogger.info("Bundle minted (sid=\(bundle.sid.prefix(8))…, ttl=\(ttl))")
    }

    /// E6 hook: the relay client (E3) calls this when it receives the
    /// iPhone's pubkey as the first relay frame. We derive the symmetric
    /// key, persist a `RelayPairingRecord` to the shared store, and stash
    /// the symmetric key in the Keychain so `APNSGatewayPushCoordinator`
    /// can find it on the next push trigger.
    ///
    /// Returns the derived key bytes on success, nil if the input was
    /// invalid. The Mac's symmetric-key value matches the iPhone's by
    /// construction (X25519 + HKDF — proved by the E7 handshake test).
    @discardableResult
    public func recordPeerHandshake(
        iPhoneEcdhPublicKeyBase64URL: String,
        now: Date = Date()
    ) -> Data? {
        guard let pair = keypair, let bundle else {
            relayPairingLogger.warning("recordPeerHandshake called with no active bundle")
            return nil
        }
        let derived: Data
        do {
            derived = try pair.deriveSharedKey(
                theirPublicKeyBase64URL: iPhoneEcdhPublicKeyBase64URL,
                sessionId: bundle.sid
            )
        } catch {
            relayPairingLogger.error("recordPeerHandshake derivation failed: \(error.localizedDescription)")
            return nil
        }
        let record = RelayPairingRecord(
            sid: bundle.sid,
            macTok: bundle.macTok,
            iosTok: bundle.iosTok,
            theirEcdhPublicKeyBase64URL: iPhoneEcdhPublicKeyBase64URL,
            ourEcdhPublicKeyBase64URL: pair.publicKeyBase64URL,
            derivedSymmetricKeyBase64URL: RelayPairingBase64URL.encode(derived),
            ttl: bundle.ttl,
            relayUrl: bundle.relayUrl,
            pairedAtUnixSeconds: UInt64(now.timeIntervalSince1970)
        )
        do {
            try pairingStore.save(record: record, symmetricKey: derived)
            relayPairingLogger.info("Recorded peer handshake (sid=\(bundle.sid.prefix(8))…) — derived APNS key persisted")
        } catch {
            relayPairingLogger.error("recordPeerHandshake persist failed: \(error.localizedDescription)")
            return nil
        }
        self.phase = .keyExchanged
        self.refreshSummary()
        return derived
    }

    /// User tapped "Forget" / "Cancel pairing" — wipes the in-memory
    /// keypair + bundle. The QR view falls back to the empty state.
    public func reset() {
        keypair = nil
        bundle = nil
        bundleURL = nil
        phase = .unpaired
        summary = .initial
        lastError = nil
        // Drop the persisted record + symmetric key so the APNS gateway
        // path stops finding a stale pairing. E3/E4 re-write on next
        // successful pairing.
        pairingStore.clear()
        relayPairingLogger.info("Relay pairing state reset to .unpaired")
    }

    // MARK: - Summary

    /// Refresh the operator-facing summary. Computes seconds-remaining
    /// from the bundle TTL.
    private func refreshSummary() {
        guard let bundle else {
            summary = .initial
            return
        }
        let now = UInt64(Date().timeIntervalSince1970)
        let remaining = bundle.ttl > now ? Int(bundle.ttl - now) : 0
        summary = RelayPairingSummary(
            phase: phase,
            sessionIdPrefix: String(bundle.sid.prefix(8)),
            keyFingerprintPrefix: nil, // requires iPhone's pubkey; unknown on Mac side in E7
            secondsRemaining: remaining
        )
    }

    // MARK: - Testing hooks

    /// For unit tests only: directly read the keypair to verify the
    /// derived key against the iPhone-side derivation.
    public var keypairForTesting: RelayPairingKeyPair? { keypair }

    private func persistAPNSSigningKeyFromGrant(_ grant: RelayPairingCreationGrant) {
        guard let apnsSigningKey = grant.apnsSigningKey,
              let decoded = RelayPairingBase64URL.decode(apnsSigningKey),
              decoded.count >= 32 else {
            return
        }
        do {
            try apnsSigningKeyProvider?.saveFromPairing(decoded)
            relayPairingLogger.info("APNS gateway signing key saved from pairing grant")
        } catch {
            relayPairingLogger.error("Failed to save APNS gateway signing key from pairing grant: \(error.localizedDescription)")
        }
    }
}
