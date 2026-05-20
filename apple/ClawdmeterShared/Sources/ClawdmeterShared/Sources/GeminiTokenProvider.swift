#if os(macOS)
import Foundation

/// Reads the Gemini CLI's OAuth bundle from `~/.gemini/oauth_creds.json`.
///
/// Shape (observed on Gemini CLI 0.42.0, macOS 2026-05):
/// ```json
/// {
///   "access_token": "ya29.<…>",
///   "refresh_token": "1//…",
///   "scope": "https://www.googleapis.com/auth/cloud-platform …",
///   "token_type": "Bearer",
///   "id_token": "<jwt>",
///   "expiry_date": 1747353600000
/// }
/// ```
///
/// **Authentication target**: Antigravity's
/// `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` endpoint, which
/// is the same one Antigravity uses for its 5h-window quota display. Auth
/// is a plain `Authorization: Bearer <access_token>` header against an
/// OAuth token with `cloud-platform` scope — which `gemini auth login`
/// grants by default.
///
/// **TOS posture**: Same risk class as `CodexTokenProvider` reading
/// `~/.codex/auth.json` — we're using a user-granted OAuth token (granted
/// to the Gemini CLI) to hit an internal Google endpoint. Google may
/// rotate/revoke; rollback path is the AgentKind tolerant decoder + the
/// D7 cached-stale-badge fallback in `GeminiSource`.
public final class GeminiTokenProvider: TokenProvider, @unchecked Sendable {

    public struct AuthBundle: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let scope: String?
        public let tokenType: String?
        public let idToken: String?
        /// Expiry in milliseconds since epoch (Google CLI convention).
        public let expiryDate: Int64?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
            case idToken = "id_token"
            case expiryDate = "expiry_date"
        }
    }

    public let authPath: URL

    private let lock = NSLock()
    private var cached: AuthBundle?

    public init(authPath: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/oauth_creds.json")) {
        self.authPath = authPath
    }

    /// Always re-read on access so a rotation by `gemini auth login` is
    /// picked up on the next poll without restarting Clawdmeter (mirrors
    /// the Claude `KeychainTokenProvider` rotation-pickup behavior).
    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        do {
            let bundle = try loadFromDisk()
            cached = bundle
            return bundle.accessToken
        } catch {
            return nil
        }
    }

    /// Returns the cloud-platform scope when present, for diagnostics +
    /// the Providers Settings tab's "scope detected" line.
    public var currentScope: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached.scope }
        do {
            let bundle = try loadFromDisk()
            cached = bundle
            return bundle.scope
        } catch {
            return nil
        }
    }

    /// True when `expiry_date` is in the past. Drives the D4 stale-token UX
    /// banner in DashboardView's Gemini ProviderColumn.
    public var isTokenExpired: Bool {
        lock.lock(); defer { lock.unlock() }
        let bundle: AuthBundle
        if let cached { bundle = cached }
        else if let loaded = try? loadFromDisk() {
            cached = loaded
            bundle = loaded
        } else {
            return false
        }
        guard let expiryMs = bundle.expiryDate else { return false }
        let expirySec = TimeInterval(expiryMs) / 1000
        return Date().timeIntervalSince1970 > expirySec
    }

    public var hasToken: Bool { currentAccessToken != nil }

    /// Re-read the file so we pick up rotations the Gemini CLI does on its own.
    ///
    /// P1-Mac-10: when the loaded token has already expired by its
    /// `expiryDate`, refreshIfNeeded() returned the rotation-status bool
    /// (so callers couldn't tell expired-vs-fresh apart) and the UI only
    /// flipped to `needsReauth` when refresh THREW `.authExpired`. Now
    /// any load that surfaces an expired bundle throws `.authExpired`,
    /// so the AppModel's "did the refresh throw expired?" guard fires
    /// reliably whenever the user needs to re-sign-in to Gemini.
    @discardableResult
    public func refreshIfNeeded() async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let previous = cached?.accessToken
        cached = nil
        do {
            cached = try loadFromDisk()
        } catch {
            throw AISourceError.authExpired
        }
        if let expiryMs = cached?.expiryDate {
            let expirySec = TimeInterval(expiryMs) / 1000
            if Date().timeIntervalSince1970 > expirySec {
                throw AISourceError.authExpired
            }
        }
        return cached?.accessToken != previous
    }

    private func loadFromDisk() throws -> AuthBundle {
        let data = try Data(contentsOf: authPath)
        return try JSONDecoder().decode(AuthBundle.self, from: data)
    }
}
#endif
