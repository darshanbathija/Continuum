#if os(macOS)
import Foundation

/// Reads the Codex CLI's OAuth bundle from `~/.codex/auth.json`.
///
/// Shape (observed on macOS, May 2026):
/// ```json
/// {
///   "auth_mode": "chatgpt",
///   "OPENAI_API_KEY": null,
///   "tokens": {
///     "id_token": "<jwt>",
///     "access_token": "<jwt — aud=https://api.openai.com/v1>",
///     "refresh_token": "rt_…",
///     "account_id": "<uuid>"
///   },
///   "last_refresh": "2026-05-12T12:41:02Z"
/// }
/// ```
///
/// V1 uses the `access_token`. ChatGPT-auth JWTs are accepted by ChatGPT's
/// backend (chatgpt.com/backend-api/*) but NOT api.openai.com/v1/* — so any
/// poller that reads from this provider should target the ChatGPT backend.
public final class CodexTokenProvider: TokenProvider, @unchecked Sendable {

    public struct AuthBundle: Codable, Sendable {
        public struct Tokens: Codable, Sendable {
            public let idToken: String?
            public let accessToken: String
            public let refreshToken: String?
            public let accountId: String?

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountId = "account_id"
            }
        }
        public let authMode: String?
        public let openaiApiKey: String?
        public let tokens: Tokens?
        public let lastRefresh: String?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openaiApiKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
        }
    }

    public let authPath: URL

    private let lock = NSLock()
    private var cached: AuthBundle?

    public init(authPath: URL = ClawdmeterRealHome.url().appendingPathComponent(".codex/auth.json")) {
        // v0.26.2: switched from NSHomeDirectory() to ClawdmeterRealHome
        // so sandboxed Release builds resolve to ~/.codex/auth.json in
        // the user's actual home (where the Codex CLI writes it) rather
        // than the empty container path. The Release entitlements grant
        // read-only access to /.codex/ — see ClawdmeterMac-Release.entitlements.
        self.authPath = authPath
    }

    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached, let token = cached.tokens?.accessToken { return token }
        do {
            let bundle = try loadFromDisk()
            cached = bundle
            // If user has a raw API key set, prefer that over the ChatGPT JWT —
            // the API key works against api.openai.com while the JWT does not.
            return bundle.openaiApiKey ?? bundle.tokens?.accessToken
        } catch {
            return nil
        }
    }

    /// Workspace / ChatGPT account UUID. The Codex backend's usage endpoint
    /// requires this in the `ChatGPT-Account-ID` header so it can scope the
    /// rate-limit lookup to the right workspace (users can be members of
    /// multiple). Returns `nil` when auth is on API-key mode (no account
    /// concept) or the file hasn't been loaded yet.
    public var currentAccountId: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached, let id = cached.tokens?.accountId { return id }
        do {
            let bundle = try loadFromDisk()
            cached = bundle
            return bundle.tokens?.accountId
        } catch {
            return nil
        }
    }

    public var hasToken: Bool { currentAccessToken != nil }

    /// Re-read the file so we pick up rotations the Codex CLI does on its own.
    @discardableResult
    public func refreshIfNeeded() async throws -> Bool {
        try refreshFromDisk()
    }

    private func refreshFromDisk() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let previous = cached?.tokens?.accessToken
        cached = nil
        do {
            cached = try loadFromDisk()
        } catch {
            throw AISourceError.authExpired
        }
        return cached?.tokens?.accessToken != previous
    }

    private func loadFromDisk() throws -> AuthBundle {
        let data = try Data(contentsOf: authPath)
        return try JSONDecoder().decode(AuthBundle.self, from: data)
    }
}
#endif
