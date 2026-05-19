import Foundation

/// Cross-platform attributes / content state for the Gemini quota Live
/// Activity (plan D5 cherry-pick). Distinct from `SessionLiveActivityAttributes`
/// — that one tracks an *aggregate* "N active sessions" pill; this one
/// surfaces Gemini's 5h-window quota burn on the Lock Screen + Dynamic
/// Island so the user notices saturation without unlocking.
///
/// Why a separate activity type instead of multiplexing into the existing
/// one: the existing aggregate activity changes shape (active count, agent
/// emoji, attention state) — quota is a steady-state percent + reset time
/// that wants its own widget. ActivityKit can run both simultaneously when
/// the user has both surfaces installed.
///
/// ActivityKit is iOS-only (16.1+). Mac / watchOS targets compile the
/// content-state struct only — the `ActivityAttributes` conformance lives
/// under `#if os(iOS)` so non-iOS callers can still construct + decode the
/// state shape (used by the Mac daemon's APNS pusher to encode payloads
/// without compiling ActivityKit).
#if os(iOS)
import ActivityKit

@available(iOS 16.1, *)
public struct GeminiQuotaLiveActivityAttributes: ActivityAttributes {
    public typealias ContentState = GeminiQuotaLiveActivityContentState

    /// Bundle id we report when registering a push token — apns-topic
    /// derivative.
    public let bundleIdentifier: String

    public init(bundleIdentifier: String = "com.clawdmeter") {
        self.bundleIdentifier = bundleIdentifier
    }
}
#endif

public struct GeminiQuotaLiveActivityContentState: Codable, Hashable, Sendable {
    /// Session-window usage percent (0…100).
    public let sessionPct: Int
    /// Epoch-seconds of the next quota refresh. Drives the "Resets in 3h"
    /// label on the lock screen + the always-on dimmed glyph.
    public let resetEpoch: Int
    /// `true` when the most recent Mac→iPhone snapshot is stale (cached
    /// fallback rendered the value, not a fresh poll). Drives a small
    /// caution dot in the Dynamic Island.
    public let stale: Bool

    public init(sessionPct: Int, resetEpoch: Int, stale: Bool = false) {
        self.sessionPct = sessionPct
        self.resetEpoch = resetEpoch
        self.stale = stale
    }

    public var resetDate: Date {
        Date(timeIntervalSince1970: TimeInterval(resetEpoch))
    }

    public var headlineText: String {
        "Gemini · \(sessionPct)%"
    }
}
