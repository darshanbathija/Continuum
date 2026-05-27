// E6: APNS gateway environment URLs — sibling of `RelayEnvironment`.
//
// Wrangler config (infra/apns-gateway/wrangler.toml) defines two production
// envs:
//   - staging:    apns-gateway-staging.clawdmeter.dev
//   - production: apns-gateway.clawdmeter.dev
// (plus a `canary` route which routes a percentage of prod traffic; the
//  Mac client doesn't need to know about canary — Cloudflare load-balances
//  the prod hostname into it.)
//
// Default is `.staging` until the GA cut. Mac users on a dev build override
// via the `CLAWDMETER_APNS_GATEWAY_URL` env var, the same shape as the
// relay env override knob.

import Foundation

public enum APNSGatewayEnvironment: String, Codable, Sendable, CaseIterable {
    case staging
    case production

    /// `https://...` base URL for this environment. The Worker enforces
    /// custom_domain TLS; the Mac MUST pin TLS 1.3 on the URLSession
    /// configuration when targeting these hosts.
    public var baseURL: String {
        switch self {
        case .staging: return "https://apns-gateway-staging.clawdmeter.dev"
        case .production: return "https://apns-gateway.clawdmeter.dev"
        }
    }

    /// Convenience: `<baseURL>/push` — the only authenticated POST endpoint.
    public var pushURL: String { baseURL + "/push" }

    /// Convenience: `<baseURL>/device-token` — DELETE for opt-out.
    public var deviceTokenURL: String { baseURL + "/device-token" }

    /// Convenience: `<baseURL>/health` — GET probe used by the rotation
    /// drill + Mac startup wiring sanity-check.
    public var healthURL: String { baseURL + "/health" }

    /// Default for E6. Flip to `.production` in the GA cut.
    public static let `default`: APNSGatewayEnvironment = .staging

    /// Resolve the gateway URL. Order of precedence:
    ///   1. `CLAWDMETER_APNS_GATEWAY_URL` env var (dev override, including
    ///      `wrangler dev` localhost paths).
    ///   2. The explicit env's `baseURL`.
    public static func resolvedBaseURL(
        env: APNSGatewayEnvironment = .default,
        processEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = processEnv["CLAWDMETER_APNS_GATEWAY_URL"], !override.isEmpty {
            return override
        }
        return env.baseURL
    }

    /// Resolve the `/push` URL with the same override semantics.
    public static func resolvedPushURL(
        env: APNSGatewayEnvironment = .default,
        processEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolvedBaseURL(env: env, processEnv: processEnv) + "/push"
    }

    /// Resolve the `/device-token` URL.
    public static func resolvedDeviceTokenURL(
        env: APNSGatewayEnvironment = .default,
        processEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolvedBaseURL(env: env, processEnv: processEnv) + "/device-token"
    }
}

// MARK: - Topic helpers

/// The Worker validates the `topic` field against operator-configured
/// production/sandbox bundle ids. For E6 the Mac knows which env it's
/// targeting and ships the bundle id accordingly. We keep the topic
/// strings here so a future Watch-target or extension-target shipped from
/// the same Mac process can fan out to the right APNS topic.
public enum APNSGatewayTopics {

    /// Production iPhone bundle id. Mirrors the operator's `APNS_TOPIC_PRODUCTION`
    /// secret (E5 ROTATION.md). The default here matches what the Worker
    /// validates against in `infra/apns-gateway/src/schema.ts:115`.
    public static let iPhoneProduction = "com.clawdmeter.iphone"

    /// Sandbox iPhone bundle id. APNS sandbox accepts this against the
    /// `api.sandbox.push.apple.com` endpoint.
    public static let iPhoneSandbox = "com.clawdmeter.iphone"

    /// Resolve the topic for a given gateway environment. iPhone-only for
    /// now; Watch is on the roadmap.
    public static func topic(forIPhoneOn env: APNSGatewayEnvironment) -> String {
        switch env {
        case .staging:    return iPhoneSandbox
        case .production: return iPhoneProduction
        }
    }
}
