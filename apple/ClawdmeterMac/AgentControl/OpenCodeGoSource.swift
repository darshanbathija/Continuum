import Foundation
import ClawdmeterShared

public struct OpenCodeGoTokenProvider: TokenProvider {
    public var hasToken: Bool {
        OpenCodeGoCredentials.hasGoAuthFromDisk()
            || OpenCodeGoCredentials.dashboardQuotaConfig() != nil
    }

    public var currentAccessToken: String? { nil }

    public init() {}

    public func refreshIfNeeded() async throws -> Bool {
        await OpenCodeGoCredentials.hasGoAuth()
            || OpenCodeGoCredentials.dashboardQuotaConfig() != nil
    }
}

public final class OpenCodeGoSource: AISource, @unchecked Sendable {
    public let providerID = "opencode"
    public let displayName = "OpenCode"

    private let quotaClient: OpenCodeGoQuotaClient
    private let nowProvider: @Sendable () -> Date

    public init(
        quotaClient: OpenCodeGoQuotaClient = OpenCodeGoQuotaClient(),
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.quotaClient = quotaClient
        self.nowProvider = nowProvider
    }

    public var isAuthenticated: Bool {
        OpenCodeGoTokenProvider().hasToken
    }

    public func refreshCredentialsIfNeeded() async throws -> Bool {
        isAuthenticated
    }

    public func dataChangedSince(_ date: Date?) -> Bool {
        guard let date else { return true }
        return nowProvider().timeIntervalSince(date) >= 60
    }

    public func poll() async throws -> UsageData {
        let apiKey = await OpenCodeGoCredentials.apiKey()
        let dashboard = OpenCodeGoCredentials.dashboardQuotaConfig()
        guard apiKey != nil || dashboard != nil else {
            throw AISourceError.unauthenticated
        }
        do {
            let snapshot = try await quotaClient.fetch(apiKey: apiKey, dashboard: dashboard)
            return snapshot.asUsageData(now: nowProvider())
        } catch let error as OpenCodeGoQuotaClient.Error {
            switch error {
            case .missingCredentials:
                // A Go API key alone can't produce quota numbers until the
                // usage API ships (it 404s today) and no dashboard creds are
                // configured. The user IS authenticated for chat/code — surface
                // a no-data error, NOT `.unauthenticated` (which would wrongly
                // tell an authed user to sign in again).
                if apiKey != nil {
                    throw AISourceError.malformedResponse(
                        detail: "OpenCode Go quota unavailable — add workspace + auth cookie in Settings for meters"
                    )
                }
                throw AISourceError.unauthenticated
            case .malformedResponse(let detail), .transport(let detail):
                throw AISourceError.malformedResponse(detail: detail)
            }
        }
    }
}
