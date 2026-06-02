import Foundation

/// Per-agent ACP spawn + auth/config policy. Each agent speaks ACP but differs
/// in spawn argv, which `authMethods` it offers, and whether it supports
/// in-session `set_config_option` (vs respawn-to-change-model). Verified live
/// 2026-06-02 (see docs/acp-harness/phase0-spike.md).
public protocol AcpAgentSupport: Sendable {
    /// Binary to spawn (resolved via PATH/locateBinary by the caller).
    var binaryName: String { get }
    /// argv after the binary. `model`/`effort` only apply when the agent takes
    /// them at launch (Grok); ignored otherwise.
    func spawnArgv(model: String?, effort: String?, alwaysApprove: Bool) -> [String]
    /// Pick the auth method id to use from what the agent advertised in
    /// `initialize`. Returns nil if none are usable.
    func resolveAuthMethod(offered: [ACPAuthMethod]) -> String?
    /// Whether mid-session model change is supported via `session/set_config_option`.
    /// When false, the driver must respawn to change model/effort.
    var supportsInSessionModelChange: Bool { get }
}

/// Grok (xAI) — `grok agent --no-leader [--always-approve] [-m M] [--reasoning-effort E] stdio`.
/// Auth id observed live is `grok.com` (NOT the older reference's `xai.api_key`),
/// which is exactly why auth is resolved from `initialize.authMethods`, never
/// hardcoded. Grok does not implement `set_config_option`, so model/effort are
/// launch-time only.
public struct GrokAcpSupport: AcpAgentSupport {
    public init() {}
    public var binaryName: String { "grok" }
    public var supportsInSessionModelChange: Bool { false }

    public func spawnArgv(model: String?, effort: String?, alwaysApprove: Bool) -> [String] {
        var argv = ["agent", "--no-leader"]
        if alwaysApprove { argv.append("--always-approve") }
        if let model, !model.isEmpty { argv += ["-m", model] }
        if let effort, !effort.isEmpty { argv += ["--reasoning-effort", effort] }
        argv.append("stdio")
        return argv
    }

    public func resolveAuthMethod(offered: [ACPAuthMethod]) -> String? {
        let ids = offered.map(\.id)
        // Prefer the interactive Grok sign-in id seen live; fall back to any
        // offered method so a future build that renames it still works.
        for preferred in ["grok.com", "xai.api_key", "cached_token"] where ids.contains(preferred) {
            return preferred
        }
        return ids.first
    }
}

/// Cursor — `cursor-agent acp`. Auth id `cursor_login`. Cursor advertises
/// `sessionCapabilities.list` and supports in-session config (parameterized
/// model picker), so model changes go via `set_config_option`, not respawn.
public struct CursorAcpSupport: AcpAgentSupport {
    public init() {}
    public var binaryName: String { "cursor-agent" }
    public var supportsInSessionModelChange: Bool { true }

    public func spawnArgv(model: String?, effort: String?, alwaysApprove: Bool) -> [String] {
        // Cursor takes model/effort via set_config_option after init, not argv.
        return ["acp"]
    }

    public func resolveAuthMethod(offered: [ACPAuthMethod]) -> String? {
        let ids = offered.map(\.id)
        if ids.contains("cursor_login") { return "cursor_login" }
        return ids.first
    }
}
