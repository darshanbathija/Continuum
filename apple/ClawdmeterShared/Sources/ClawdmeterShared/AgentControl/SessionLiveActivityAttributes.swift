import Foundation

/// Cross-platform attributes / content state for the aggregate iOS Live
/// Activity that surfaces "N active sessions" + the most-urgent item on
/// the Lock Screen + Dynamic Island.
///
/// Sessions v2 Phase 10 / E6 (aggregate, not per-session). Defined in
/// `ClawdmeterShared` so both the iOS app target (where we start activities)
/// and the iOS widget extension (where we render them) share the shape.
///
/// ActivityKit is iOS-only (16.1+). Mac and watchOS targets compile this
/// file as a no-op via `#if os(iOS)` — the shared content state struct
/// is always available so iOS callers can reference the shape from typed
/// code. macOS technically has ActivityKit imports but the
/// `ActivityAttributes` protocol is marked unavailable, so a typecheck
/// fails there.
#if os(iOS)
import ActivityKit

@available(iOS 16.1, *)
public struct SessionLiveActivityAttributes: ActivityAttributes {
    public typealias ContentState = SessionLiveActivityContentState

    /// Stable across the activity's lifetime. There's only ever one of
    /// these at a time (aggregate model).
    public let bundleIdentifier: String

    public init(bundleIdentifier: String = "com.clawdmeter") {
        self.bundleIdentifier = bundleIdentifier
    }
}
#endif

public struct SessionLiveActivityContentState: Codable, Hashable, Sendable {
    /// Total active sessions (not counting archived / done).
    public let activeSessionCount: Int
    /// City display label for the latest-event session.
    public let latestCity: String
    /// Latest session's agent (Claude or Codex) — drives the agent emoji.
    public let latestAgentKind: AgentKind
    /// Latest session's state ("running" / "planning" / "paused" / "done").
    public let latestState: String
    /// True when ANY session is in `needs-attention` (plan ready, etc.).
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

    public var agentEmoji: String {
        latestAgentKind == .claude ? "✻" : "◇"
    }

    public var headlineText: String {
        if activeSessionCount == 0 { return "No active sessions" }
        if activeSessionCount == 1 { return "\(latestCity) · \(latestAgentKind.rawValue.capitalized)" }
        return "\(activeSessionCount) active sessions"
    }
}
