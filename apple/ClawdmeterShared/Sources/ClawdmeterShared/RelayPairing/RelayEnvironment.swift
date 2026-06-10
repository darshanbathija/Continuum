// E7: relay environment helper — single source of truth for the relay
// Worker URL across Mac + iOS code paths.
//
// Wrangler config (infra/relay/wrangler.toml) defines two production
// envs:
//   - staging: relay-staging.clawdmeter.dev
//   - production: relay.clawdmeter.dev
//
// Defaults to `.staging` until E3 (Mac relay client) flips the GA
// build-time switch. Mac users on a dev build override via
// `CLAWDMETER_RELAY_URL` env var (read by `AppDelegate` in
// `AppRuntime`) — gives us a knob to point at `ws://localhost:8787`
// when running `wrangler dev` without an app rebuild.

import Foundation

public enum RelayEnvironment: String, Codable, Sendable, CaseIterable {
    case staging
    case production

    /// `wss://...` base URL for this environment. The E2 relay accepts
    /// only WSS in production (TLS 1.3 minimum) — local dev paths flow
    /// through `RelayPairingBundle.isValidRelayURL` which also accepts
    /// `ws://localhost` for `wrangler dev` round-trips.
    public var baseURL: String {
        switch self {
        case .staging: return "wss://clawdmeter-relay-staging.continuumai.workers.dev"
        case .production: return "wss://clawdmeter-relay.continuumai.workers.dev"
        }
    }

    /// GA default: the production relay Worker
    /// (`clawdmeter-relay.continuumai.workers.dev`). Dev builds still override
    /// via `CLAWDMETER_RELAY_URL` for `wrangler dev` localhost round-trips.
    public static let `default`: RelayEnvironment = .production

    /// Resolve the relay URL the Mac should bake into a fresh QR. Order
    /// of precedence:
    ///   1. `CLAWDMETER_RELAY_URL` env var (dev override, including
    ///      `wrangler dev` localhost paths).
    ///   2. The explicit env's `baseURL`.
    public static func resolvedRelayURL(env: RelayEnvironment = .default,
                                        processEnv: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = processEnv["CLAWDMETER_RELAY_URL"], !override.isEmpty {
            return override
        }
        return env.baseURL
    }

    /// Cloudflare-hosted fallback hosts used before the custom
    /// `*.clawdmeter.dev` relay routes are available everywhere. Keep this
    /// intentionally exact; accepting arbitrary `workers.dev` hosts would let
    /// a malicious QR redirect iOS to an attacker-owned Worker.
    static func isKnownHostedWorkerHost(_ host: String) -> Bool {
        switch host {
        // The live relay Workers (account subdomain `continuumai`). These MUST
        // match `baseURL` exactly — a stale entry here silently rejects every
        // pairing QR the Mac mints (isValidRelayURL → nil → scanner refuses).
        // Verified live 2026-06-05: continuumai hosts answer; the prior
        // `darshan-1ba` hosts no longer resolve. Keep exact (no wildcard) so a
        // malicious QR can't redirect iOS to an attacker-owned Worker.
        case "clawdmeter-relay-staging.continuumai.workers.dev",
             "clawdmeter-relay.continuumai.workers.dev":
            return true
        default:
            return false
        }
    }
}
