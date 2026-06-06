import Foundation
import ClawdmeterShared
import OSLog
import Security
import CryptoKit

private let gatewayLogger = Logger(subsystem: "com.clawdmeter.mac", category: "APNSGatewayClient")

/// E6: HTTPS client targeting the operator-hosted APNS gateway Worker
/// (PR #147 / `infra/apns-gateway`).
///
/// Flow per Mac-side push trigger:
///
///   1. PlanModeWatcher / DoneDetector / surfacePermissionPrompt fires.
///   2. `APNSGatewayPushCoordinator.notify(...)` (in this file) is called.
///   3. We look up the iPhone APNS device token in `APNSPushDeviceTokenStore`.
///   4. We seal the `APNSPushBody` with the HKDF-derived per-pairing key
///      (info=`clawdmeter.apns.v1` per the design doc §4.4 sibling-key
///      derivation).
    ///   5. We sign a fresh per-peer bearer with issued-at + nonce, bound to
    ///      `(sid, senderFingerprint)`.
///   6. POST `<gateway>/push` with `{deviceToken, encryptedPayload, topic,
///      sessionId, senderMacFingerprint, priority, pushType, ...}`.
///   7. On 200, record SLO timestamps to OSLog. On 410, purge the token.
///      Other 4xx/5xx → audit-only retry (the next trigger will fire fresh;
///      we deliberately do NOT backoff/queue — push triggers are best-
///      effort, the daemon's WS reconnect path is the durable channel).
///
/// All sealing + bearer signing is done in `ClawdmeterShared` so the iOS
/// side (E7) can decrypt with the identical key derivation. The Worker
/// is opaque to the payload body.
public actor APNSGatewayClient {

    public static let shared = APNSGatewayClient()

    /// Configuration mirrors the deployment env. `staging` until the GA
    /// cut; production is flipped via the gateway environment override.
    public var environment: APNSGatewayEnvironment = .default

    /// The `URLSession` the client posts through. Pinned to TLS 1.3
    /// (URLSession honours `tlsMinimumSupportedProtocolVersion`). Tests
    /// inject a session with a `URLProtocol` stub.
    private var urlSession: URLSession

    /// Per-request timeout. Plan-approval/permission pushes need to land
    /// within 2 seconds end-to-end — we time-out earlier so the daemon
    /// doesn't dangle on a flaky gateway.
    public var requestTimeout: TimeInterval = 4.0

    /// Test seam — by default `Date()` but tests inject a deterministic
    /// time source so timing assertions are reproducible.
    public var nowProvider: @Sendable () -> Date = { Date() }

    public init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.tlsMinimumSupportedProtocolVersion = .TLSv13
            config.timeoutIntervalForRequest = 4.0
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Tests inject a custom `URLSession`. Not on the public API surface
    /// — call sites that need control reach in via `APNSGatewayClient.shared`
    /// and the test-only `_setURLSession` extension.
    public func _setURLSession(_ session: URLSession) {
        self.urlSession = session
    }

    public func _setRequestTimeout(_ timeout: TimeInterval) {
        self.requestTimeout = timeout
    }

    public func _setNowProvider(_ provider: @escaping @Sendable () -> Date) {
        self.nowProvider = provider
    }

    public func _setEnvironment(_ env: APNSGatewayEnvironment) {
        self.environment = env
    }

    // MARK: - Push API

    public struct PushInput: Sendable {
        public let body: APNSPushBody
        public let deviceToken: String
        public let topic: String
        public let sessionId: String
        public let senderMacFingerprint: String
        public let signingKey: Data
        public let payloadKey: Data
        public let priority: Int
        public let pushType: APNSGatewayPushRequest.PushType
        public let collapseId: String?

        public init(
            body: APNSPushBody,
            deviceToken: String,
            topic: String,
            sessionId: String,
            senderMacFingerprint: String,
            signingKey: Data,
            payloadKey: Data,
            priority: Int = 10,
            pushType: APNSGatewayPushRequest.PushType = .alert,
            collapseId: String? = nil
        ) {
            self.body = body
            self.deviceToken = deviceToken
            self.topic = topic
            self.sessionId = sessionId
            self.senderMacFingerprint = senderMacFingerprint
            self.signingKey = signingKey
            self.payloadKey = payloadKey
            self.priority = priority
            self.pushType = pushType
            self.collapseId = collapseId
        }
    }

    /// Outcome surfaced to the call site. Tests assert on this.
    public struct PushOutcome: Sendable, Equatable {
        /// Worker response classification.
        public let response: APNSGatewayPushResponseTag
        /// Wall-clock between trigger and the moment we got the response.
        public let elapsedSeconds: Double
        /// Optional APNS id from the Worker on 200. Audit-log key on the
        /// E5 side.
        public let apnsId: String?
        /// HTTP status the Worker returned (or -1 on transport error).
        public let httpStatus: Int

        public init(response: APNSGatewayPushResponseTag, elapsedSeconds: Double, apnsId: String?, httpStatus: Int) {
            self.response = response
            self.elapsedSeconds = elapsedSeconds
            self.apnsId = apnsId
            self.httpStatus = httpStatus
        }
    }

    /// Lightweight enum the call site can switch over without juggling
    /// associated values. Tests assert on this for the 4xx/410/200 paths.
    public enum APNSGatewayPushResponseTag: String, Sendable, Equatable {
        case delivered
        case unregistered
        case badToken
        case rateLimited
        case unauthorized
        case forbidden
        case schemaError
        case killSwitch
        case serverError
        case transportError
    }

    /// Post a single push. Returns the outcome — never throws to the call
    /// site; transport / parse errors map to `.transportError`.
    public func push(_ input: PushInput) async -> PushOutcome {
        let url = URL(string: APNSGatewayEnvironment.resolvedPushURL(env: environment))!
        return await postPush(input: input, url: url)
    }

    /// Public entry point used by the test harness — passes the URL in
    /// directly so the mock gateway can run on `http://localhost:<port>`.
    public func push(_ input: PushInput, gatewayURL: URL) async -> PushOutcome {
        return await postPush(input: input, url: gatewayURL)
    }

    // MARK: - DELETE /device-token (opt-out)

    public struct OptOutInput: Sendable {
        public let deviceToken: String
        public let sessionId: String
        public let signingKey: Data

        public init(deviceToken: String, sessionId: String, signingKey: Data) {
            self.deviceToken = deviceToken
            self.sessionId = sessionId
            self.signingKey = signingKey
        }
    }

    public func optOut(_ input: OptOutInput) async -> Int {
        let url = URL(string: APNSGatewayEnvironment.resolvedDeviceTokenURL(env: environment))!
        return await deleteOptOut(input: input, url: url)
    }

    public func optOut(_ input: OptOutInput, gatewayURL: URL) async -> Int {
        return await deleteOptOut(input: input, url: gatewayURL)
    }

    // MARK: - Internals

    private func postPush(input: PushInput, url: URL) async -> PushOutcome {
        let started = nowProvider()

        // 1. Seal the cleartext body.
        let encryptedPayload: String
        do {
            encryptedPayload = try APNSPayloadSealer.sealJSON(
                body: input.body,
                keyBytes: input.payloadKey
            )
        } catch {
            gatewayLogger.error("Seal failed: \(error.localizedDescription, privacy: .public)")
            let elapsed = nowProvider().timeIntervalSince(started)
            return PushOutcome(response: .transportError, elapsedSeconds: elapsed, apnsId: nil, httpStatus: -1)
        }

        // 2. Sign the bearer.
        let bearer = APNSGatewayBearer.issueBearer(
            signingKey: input.signingKey,
            sessionId: input.sessionId,
            senderMacFingerprint: input.senderMacFingerprint,
            issuedAtSeconds: UInt64(started.timeIntervalSince1970)
        )

        // 3. Encode the request body.
        let requestBody = APNSGatewayPushRequest(
            deviceToken: input.deviceToken,
            encryptedPayload: encryptedPayload,
            topic: input.topic,
            sessionId: input.sessionId,
            senderMacFingerprint: input.senderMacFingerprint,
            priority: input.priority,
            pushType: input.pushType,
            collapseId: input.collapseId,
            expiration: UInt64(started.timeIntervalSince1970) + 60
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedBody: Data
        do {
            encodedBody = try encoder.encode(requestBody)
        } catch {
            gatewayLogger.error("Encode failed: \(error.localizedDescription, privacy: .public)")
            let elapsed = nowProvider().timeIntervalSince(started)
            return PushOutcome(response: .transportError, elapsedSeconds: elapsed, apnsId: nil, httpStatus: -1)
        }

        // 4. POST.
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = encodedBody
        req.timeoutInterval = requestTimeout
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            let elapsed = nowProvider().timeIntervalSince(started)
            gatewayLogger.error("Push transport error after \(elapsed, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
            return PushOutcome(response: .transportError, elapsedSeconds: elapsed, apnsId: nil, httpStatus: -1)
        }

        let elapsed = nowProvider().timeIntervalSince(started)
        guard let http = response as? HTTPURLResponse else {
            gatewayLogger.error("Push non-HTTP response after \(elapsed, privacy: .public)s")
            return PushOutcome(response: .transportError, elapsedSeconds: elapsed, apnsId: nil, httpStatus: -1)
        }

        // 5. Classify + side-effect on 410.
        let outcome = classify(status: http.statusCode, body: data)
        switch outcome {
        case .delivered:
            // SLO: ≤2s from trigger to response.
            gatewayLogger.info("Push delivered in \(elapsed, privacy: .public)s session=\(String(input.sessionId.prefix(8)), privacy: .public) kind=\(input.body.kind, privacy: .public)")
        case .unregistered:
            // 410 — APNS says the device is no longer reachable. Purge.
            APNSPushDeviceTokenStore.shared.purgeByDeviceToken(input.deviceToken)
            gatewayLogger.info("Push 410 unregistered in \(elapsed, privacy: .public)s; purged token prefix=\(String(input.deviceToken.prefix(8)), privacy: .public)")
        case .killSwitch:
            gatewayLogger.warning("Push 503 kill-switch active on gateway")
        case .rateLimited:
            gatewayLogger.warning("Push 429 rate-limited; dropping (best-effort)")
        case .unauthorized:
            gatewayLogger.error("Push 401 unauthorized — bearer mismatch (signing key drift?)")
        case .forbidden:
            gatewayLogger.error("Push 403 forbidden — likely cross-tenant binding failure")
        case .schemaError:
            gatewayLogger.error("Push 400 schema error — daemon and Worker schemas diverged?")
        case .badToken:
            gatewayLogger.error("Push 400 bad-token — APNS rejected the device token")
        case .serverError:
            gatewayLogger.error("Push 5xx server-error after \(elapsed, privacy: .public)s")
        case .transportError:
            break  // already logged
        }

        let apnsId = extractApnsId(from: data)
        return PushOutcome(response: outcome, elapsedSeconds: elapsed, apnsId: apnsId, httpStatus: http.statusCode)
    }

    private func deleteOptOut(input: OptOutInput, url: URL) async -> Int {
        let signature = APNSGatewayBearer.issueOptOutSignature(
            signingKey: input.signingKey,
            sessionId: input.sessionId,
            deviceToken: input.deviceToken
        )
        let body = APNSGatewayOptOutRequest(
            deviceToken: input.deviceToken,
            signature: signature,
            sessionId: input.sessionId
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(body) else {
            return -1
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.httpBody = encoded
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await urlSession.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            gatewayLogger.error("Opt-out transport error: \(error.localizedDescription, privacy: .public)")
            return -1
        }
    }

    private func classify(status: Int, body: Data) -> APNSGatewayPushResponseTag {
        switch status {
        case 200:                  return .delivered
        case 410:                  return .unregistered
        case 401:                  return .unauthorized
        case 403:                  return .forbidden
        case 400:
            // Disambiguate schema-error vs bad-token via the error body.
            if let s = String(data: body, encoding: .utf8), s.contains("bad-token") {
                return .badToken
            }
            return .schemaError
        case 429:                  return .rateLimited
        case 503:                  return .killSwitch
        case 500..<600:            return .serverError
        default:                   return .serverError
        }
    }

    private func extractApnsId(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["apnsId"] as? String
    }
}

// MARK: - PushCoordinator

/// Central call site for push triggers. Wraps the `APNSGatewayClient` with
/// the lookup logic that joins:
///   - the iPhone's APNS device token (`APNSPushDeviceTokenStore`)
///   - the active pairing's symmetric key (`RelayPairingStore`)
///   - the operator's bearer signing key (`APNSGatewaySigningKeyProvider`)
///   - the user-facing settings (`APNSGatewaySettings`)
///
/// Mac-side trigger sites call `notify(...)` — they don't have to know
/// about sealing, bearer signing, or HTTP plumbing.
public actor APNSGatewayPushCoordinator {

    public static let shared = APNSGatewayPushCoordinator()

    private let client: APNSGatewayClient
    private let deviceTokenStore: APNSPushDeviceTokenStore
    private let settings: APNSGatewaySettings
    private let pairingStore: RelayPairingStore
    private let signingKeyProvider: APNSGatewaySigningKeyProvider
    private var environment: APNSGatewayEnvironment

    public init(
        client: APNSGatewayClient = .shared,
        deviceTokenStore: APNSPushDeviceTokenStore = .shared,
        settings: APNSGatewaySettings = .shared,
        pairingStore: RelayPairingStore = .shared,
        signingKeyProvider: APNSGatewaySigningKeyProvider = .shared,
        environment: APNSGatewayEnvironment = .default
    ) {
        self.client = client
        self.deviceTokenStore = deviceTokenStore
        self.settings = settings
        self.pairingStore = pairingStore
        self.signingKeyProvider = signingKeyProvider
        self.environment = environment
    }

    public func setEnvironment(_ env: APNSGatewayEnvironment) async {
        environment = env
        await client._setEnvironment(env)
    }

    /// Returns true iff the coordinator could fire a push right now: the
    /// surface is enabled, an iPhone has registered a token, and the
    /// active pairing has a derived key.
    public func canFire(forSurface surface: APNSGatewaySettings.Surface) -> Bool {
        guard settings.isEnabled(surface: surface) else { return false }
        guard !deviceTokenStore.entries.isEmpty else { return false }
        guard signingKeyProvider.signingKey() != nil else { return false }
        return true
    }

    /// Main entry point. Returns nil when the surface is disabled / no
    /// pairing exists; otherwise returns the `PushOutcome` so callers can
    /// observe SLO timing.
    @discardableResult
    public func notify(
        surface: APNSGatewaySettings.Surface,
        body: APNSPushBody
    ) async -> APNSGatewayClient.PushOutcome? {
        guard settings.isEnabled(surface: surface) else {
            gatewayLogger.debug("Skipping APNS push: \(surface.rawValue, privacy: .public) disabled in settings")
            return nil
        }
        guard let pairingRecord = pairingStore.loadRecord() else {
            gatewayLogger.debug("Skipping APNS push: no relay pairing recorded")
            return nil
        }
        guard let signingKey = signingKeyProvider.signingKey() else {
            gatewayLogger.debug("Skipping APNS push: no operator signing key available")
            return nil
        }
        guard let entry = deviceTokenStore.entry(forSessionId: pairingRecord.sid) else {
            gatewayLogger.debug("Skipping APNS push: no iPhone device token registered for session prefix=\(String(pairingRecord.sid.prefix(8)), privacy: .public)")
            return nil
        }
        // Derive the APNS sibling key from the relay pair's HKDF info=
        // "clawdmeter.apns.v1" so the iPhone can decrypt with the same key.
        // The relay derivation was already done at pairing; we re-derive
        // here with the APNS info so the symmetric keys diverge by domain
        // (relay vs APNS) per design doc §4.4.
        guard let payloadKey = derivedAPNSKey(forPairingRecord: pairingRecord) else {
            gatewayLogger.error("Skipping APNS push: could not derive APNS payload key from pairing record")
            return nil
        }
        guard let senderFingerprint = APNSSenderFingerprint.compute(
            macPublicKeyBase64URL: pairingRecord.ourEcdhPublicKeyBase64URL
        ) else {
            gatewayLogger.error("Skipping APNS push: could not compute sender fingerprint")
            return nil
        }

        let input = APNSGatewayClient.PushInput(
            body: body,
            deviceToken: entry.deviceToken,
            topic: APNSGatewayTopics.topic(forIPhoneOn: environment),
            sessionId: pairingRecord.sid,
            senderMacFingerprint: senderFingerprint,
            signingKey: signingKey,
            payloadKey: payloadKey,
            priority: 10,
            pushType: .alert,
            collapseId: collapseId(forSurface: surface, sessionId: body.sessionId)
        )
        return await client.push(input)
    }

    /// HKDF-SHA256 of the pairing's stored symmetric key with `info =
    /// "clawdmeter.apns.v1"` per design doc §4.4. This gives us a sibling
    /// key for the APNS path so a relay-derived key can never decrypt an
    /// APNS payload (defense against threat #14 protocol-confusion).
    ///
    /// Source of the relay K (in order):
    ///   1. `RelayPairingStore.loadSymmetricKey()` — Keychain on Apple
    ///      platforms. This is the production source.
    ///   2. The record's `derivedSymmetricKeyBase64URL` — present when the
    ///      caller wrote the record via `save(record:symmetricKey:)`. We
    ///      use this as a fallback for the SPM-host test target where the
    ///      Keychain ACL can reject reads from non-Application-Group
    ///      callers.
    private func derivedAPNSKey(forPairingRecord record: RelayPairingRecord) -> Data? {
        let relayKey: Data
        if let fromKeychain = pairingStore.loadSymmetricKey(), fromKeychain.count == 32 {
            relayKey = fromKeychain
        } else if let encoded = record.derivedSymmetricKeyBase64URL,
                  let fromRecord = RelayPairingBase64URL.decode(encoded),
                  fromRecord.count == 32 {
            relayKey = fromRecord
        } else {
            return nil
        }
        // The pairing record holds the relay-derived K (info=
        // "clawdmeter.relay.v1"). For APNS we re-HKDF with the APNS info
        // string, using the relay K itself as the input keying material.
        // The Worker doesn't see either key — it forwards the opaque blob.
        return APNSGatewayKey.derivePayloadKey(
            relaySymmetricKey: relayKey,
            sessionId: record.sid
        )
    }

    /// Apple's `apns-collapse-id` lets us fold multiple back-to-back
    /// notifications about the same session into a single banner.
    private func collapseId(forSurface surface: APNSGatewaySettings.Surface, sessionId: String) -> String {
        // 64-char limit per E5 schema.ts:60. Keep it short.
        let prefix: String
        switch surface {
        case .planApproval:     prefix = "plan"
        case .sessionDone:      prefix = "done"
        case .permissionPrompt: prefix = "perm"
        case .statusChanged:    prefix = "stat"
        }
        let shortSession = String(sessionId.prefix(16))
        return "\(prefix)-\(shortSession)"
    }
}

// MARK: - Signing key provider

/// Wraps the operator's `RELAY_BEARER_SIGNING_KEY`. In production this is
/// learned at pairing time over the secure relay; for development it can
/// be set via the `CLAWDMETER_RELAY_BEARER_SIGNING_KEY` env var (raw base64
/// or hex). Tests inject a fixed key via `setForTesting(_:)`.
public final class APNSGatewaySigningKeyProvider: @unchecked Sendable {

    public static let shared = APNSGatewaySigningKeyProvider()
    public static let defaultKeychainService = "ai.continuum.apns.gateway.signing-key"
    private static let keychainAccount = "default"

    private let lock = NSLock()
    private let keychainService: String
    private let processEnv: [String: String]
    private var stored: Data?

    public enum StoreError: Error, LocalizedError {
        case invalidKeyLength
        case keychainError(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidKeyLength:
                return "APNS gateway signing key must be at least 32 bytes."
            case .keychainError(let status):
                return "Keychain error \(status)."
            }
        }
    }

    public init(
        keychainService: String = APNSGatewaySigningKeyProvider.defaultKeychainService,
        processEnv: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.keychainService = keychainService
        self.processEnv = processEnv
        // Production persistence wins; the env-var override is a dev fallback.
        loadFromKeychainIfNeeded()
        loadFromEnvironmentIfNeeded()
    }

    public func signingKey() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Test-only seeding hook.
    public func setForTesting(_ key: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored = key
    }

    /// Production writer: called when pairing learns the shared gateway bearer
    /// key from the relay. Persists to Keychain so APNS pushes survive app
    /// relaunch without relying on `launchctl setenv`.
    public func saveFromPairing(_ key: Data) throws {
        guard key.count >= 32 else { throw StoreError.invalidKeyLength }
        try storeInKeychain(key)
        lock.lock()
        stored = key
        lock.unlock()
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }

    /// Persistence: the Mac learns the key over the relay during pairing
    /// (E3). For E6 we accept it via env var so the dev-mac path can fire
    /// pushes against `wrangler dev` without waiting for E3.
    private func loadFromKeychainIfNeeded() {
        lock.lock()
        if stored != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let data = loadFromKeychain() else { return }

        lock.lock()
        if stored == nil {
            stored = data
        }
        lock.unlock()
    }

    private func loadFromEnvironmentIfNeeded() {
        lock.lock()
        if stored != nil {
            lock.unlock()
            return
        }
        if let raw = processEnv["CLAWDMETER_RELAY_BEARER_SIGNING_KEY"], !raw.isEmpty {
            // Try base64 first, then hex.
            if let data = Data(base64Encoded: raw) {
                stored = data
            } else {
                stored = Data(hexString: raw)
            }
        }
        lock.unlock()
    }

    private func storeInKeychain(_ key: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainError(status)
        }
    }

    private func loadFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }
}

// MARK: - Hex decode helper

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
