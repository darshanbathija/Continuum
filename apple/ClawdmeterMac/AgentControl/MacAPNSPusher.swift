import Foundation
import CryptoKit
import ClawdmeterShared
import OSLog

private let apnsLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MacAPNSPusher")

/// Sessions v2 Phase 10 — sends ActivityKit content-state updates from
/// the Mac daemon to Apple's APNS gateway. The aggregate iOS Live
/// Activity registers a per-activity push token; the iOS app POSTs that
/// token to the Mac (`POST /live-activities/push-token`), and this
/// pusher consumes the token + signs a fresh JWT + POSTs to
/// `api.push.apple.com/3/device/{token}` whenever a session's status
/// changes.
///
/// JWT signing is ES256 (ECDSA over P-256). CryptoKit decodes the
/// `.p8` PEM directly via `P256.Signing.PrivateKey(pemRepresentation:)`,
/// so there's no third-party dep.
///
/// JWTs are valid for 1 hour per Apple's guidance; we cache the signed
/// token in-process and re-sign when it ages past 45 minutes (small
/// safety margin against clock drift).
public actor MacAPNSPusher {
    public static let shared = MacAPNSPusher()

    public init() {}

    private var cachedJWT: (token: String, issuedAt: Date, credentialsFingerprint: String)?
    /// Per-activity push tokens registered by paired iOS clients. Key
    /// is the hex push token from ActivityKit. Value is metadata used
    /// for the apns-topic header + bookkeeping.
    private var registeredTokens: [String: RegisteredToken] = [:]

    public struct RegisteredToken: Sendable {
        public let token: String
        /// The iOS app's bundle id (e.g. `ai.continuum.ios`). Used to
        /// build the `apns-topic` header (`<bundle>.push-type.liveactivity`).
        public let bundleId: String
        /// When the token was first registered. Tokens that go more
        /// than 12 hours without a refresh are stale and pruned.
        public let registeredAt: Date

        public init(token: String, bundleId: String, registeredAt: Date) {
            self.token = token
            self.bundleId = bundleId
            self.registeredAt = registeredAt
        }
    }

    // MARK: - Token registry

    /// Register a push token coming from the iOS app via the daemon
    /// endpoint. If the token already exists, the registeredAt
    /// timestamp gets bumped so stale-token pruning leaves it alone.
    public func register(token: String, bundleId: String) {
        registeredTokens[token] = RegisteredToken(
            token: token, bundleId: bundleId, registeredAt: Date()
        )
        apnsLogger.info("APNS token registered (count=\(self.registeredTokens.count))")
    }

    /// Drop a token explicitly. iOS calls this when ActivityKit
    /// invalidates the token (activity ended, system revoked, etc.).
    public func unregister(token: String) {
        registeredTokens.removeValue(forKey: token)
        apnsLogger.info("APNS token unregistered (count=\(self.registeredTokens.count))")
    }

    public func registeredCount() -> Int { registeredTokens.count }

    /// Drop tokens older than 12 hours. Idempotent — safe to call from
    /// any change trigger.
    public func pruneStale() {
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        let before = registeredTokens.count
        registeredTokens = registeredTokens.filter { $0.value.registeredAt >= cutoff }
        let dropped = before - registeredTokens.count
        if dropped > 0 {
            apnsLogger.info("Pruned \(dropped) stale APNS tokens")
        }
    }

    // MARK: - Push

    /// Push a Live Activity content-state update to every registered
    /// token. Best-effort: any single token's failure logs + continues;
    /// 410-gone responses unregister the token automatically.
    public func push(contentState: APNSContentStatePayload) async {
        guard !registeredTokens.isEmpty else {
            apnsLogger.debug("No APNS tokens registered — push skipped")
            return
        }
        let creds: APNSCredentialStore.Credentials
        do {
            creds = try APNSCredentialStore.shared.load()
        } catch {
            apnsLogger.debug("APNS not configured — push skipped: \(error.localizedDescription, privacy: .public)")
            return
        }
        let jwt: String
        do {
            jwt = try await signedJWT(creds: creds)
        } catch {
            apnsLogger.error("JWT signing failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(contentState)
        } catch {
            apnsLogger.error("Body encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let snapshot = registeredTokens
        for (_, registration) in snapshot {
            await send(
                jwt: jwt, body: bodyData,
                token: registration.token, bundleId: registration.bundleId,
                environment: creds.environment
            )
        }
    }

    private func send(
        jwt: String, body: Data,
        token: String, bundleId: String, environment: APNSCredentialStore.Environment
    ) async {
        let host = (environment == .sandbox)
            ? "api.sandbox.push.apple.com"
            : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue("\(bundleId).push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        req.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.setValue(
            String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            forHTTPHeaderField: "apns-expiration"
        )
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                break  // ok
            case 410:
                // BadDeviceToken / Unregistered — drop the token.
                apnsLogger.info("APNS 410 (unregistered); removing APNS token")
                registeredTokens.removeValue(forKey: token)
            default:
                apnsLogger.error("APNS HTTP \(http.statusCode) while sending live-activity push")
            }
        } catch {
            apnsLogger.error("APNS POST failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - JWT signing

    /// Returns a freshly signed JWT — or the cached one if it's less
    /// than 45 minutes old. Apple rejects JWTs older than 1 hour.
    private func signedJWT(creds: APNSCredentialStore.Credentials) async throws -> String {
        let fingerprint = "\(creds.keyId)|\(creds.teamId)"
        if let cached = cachedJWT,
           cached.credentialsFingerprint == fingerprint,
           Date().timeIntervalSince(cached.issuedAt) < 45 * 60 {
            return cached.token
        }
        let now = Date()
        let header: [String: String] = ["alg": "ES256", "kid": creds.keyId]
        let claims: [String: Any] = [
            "iss": creds.teamId,
            "iat": Int(now.timeIntervalSince1970),
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys)
        let headerB64 = base64URL(headerData)
        let claimsB64 = base64URL(claimsData)
        let signingInput = "\(headerB64).\(claimsB64)"

        guard let signingBytes = signingInput.data(using: .ascii) else {
            throw APNSCredentialStore.StoreError.invalidPEM
        }
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: creds.p8Pem)
        let signature = try privateKey.signature(for: signingBytes)
        // JWT ES256 wants the raw r||s representation, which is what
        // `rawRepresentation` already gives us (64 bytes for P-256).
        let signatureB64 = base64URL(signature.rawRepresentation)
        let token = "\(signingInput).\(signatureB64)"
        cachedJWT = (token, now, fingerprint)
        return token
    }

    private nonisolated func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Wire shape for the APNS payload that delivers a Live Activity
/// content-state update. Apple expects a top-level `aps` object with
/// `event: "update"` (or `"start"` / `"end"`) and a `content-state`
/// matching the activity's `ContentState` codable.
///
/// We keep this in the daemon module (Mac-only) instead of Shared
/// because Shared can't import ActivityKit-coupled types, and the
/// shape only matters at the APNS encode boundary anyway.
public struct APNSContentStatePayload: Codable, Sendable {
    public let aps: APS

    public struct APS: Codable, Sendable {
        public let timestamp: Int
        public let event: String
        public let contentState: WireSessionLiveActivityContentState

        enum CodingKeys: String, CodingKey {
            case timestamp
            case event
            case contentState = "content-state"
        }
    }

    public init(event: String, content: WireSessionLiveActivityContentState, at: Date = Date()) {
        self.aps = APS(
            timestamp: Int(at.timeIntervalSince1970),
            event: event,
            contentState: content
        )
    }
}

/// Shared shape for the content state that crosses the wire to ActivityKit.
/// Mirrors `SessionLiveActivityContentState` from ClawdmeterShared (iOS
/// owns the canonical ActivityAttributes definition; the daemon only
/// needs a Codable that decodes to the same key-set).
public struct WireSessionLiveActivityContentState: Codable, Sendable {
    public let activeSessionCount: Int
    public let latestCity: String
    public let latestAgentKind: AgentKind
    public let latestState: String
    public let needsAttention: Bool

    public init(
        activeSessionCount: Int,
        latestCity: String,
        latestAgentKind: AgentKind,
        latestState: String,
        needsAttention: Bool
    ) {
        self.activeSessionCount = activeSessionCount
        self.latestCity = latestCity
        self.latestAgentKind = latestAgentKind
        self.latestState = latestState
        self.needsAttention = needsAttention
    }
}
