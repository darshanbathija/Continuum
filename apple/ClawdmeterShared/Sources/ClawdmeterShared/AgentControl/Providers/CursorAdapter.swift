import Foundation

/// Per-provider canonical-event adapter for Cursor (cursor-agent / Cursor IDE).
///
/// **F1d strangler-fig migration (D23).** Cursor is structurally
/// different from the other four providers: there's no JSONL session log
/// and no per-turn token stream. Cursor publishes **period-level usage**
/// via `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
/// — a polled HTTP endpoint returning the user's percent-used + reset
/// time for the current billing period.
///
/// For canonical-event uniformity, `CursorAdapter` translates each
/// observed `UsageData` snapshot into ONE `ProviderRuntimeEvent` carrying
/// the period state in extensions. This is intentionally simpler than
/// the other adapters — there are no chat turns, no token deltas, no
/// tool invocations at this layer.
///
/// **Why a thin adapter rather than no adapter:** downstream consumers
/// (orchestration store F2, push gateway E6, analytics) subscribe to one
/// canonical stream. A Cursor-shaped exception complicates the consumer
/// API. The adapter wraps Cursor's UsageData into the same shape so the
/// rest of the codebase stays uniform.
///
/// **Plan:** F1d (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
public enum CursorAdapter {

    /// Translate one observed Cursor period snapshot into a canonical
    /// event. The adapter emits a single `.sessionStarted` per call,
    /// carrying the period state in extensions — this is the most
    /// honest canonical mapping given Cursor doesn't have turn-level
    /// events to translate.
    ///
    /// Callers (the polling loop) typically call this once per poll
    /// (default 60s foreground / 300s background) — the canonical event
    /// stream then mirrors Cursor's actual update cadence.
    ///
    /// - Parameters:
    ///   - usage: The `UsageData` value the CursorSource poll just
    ///            produced.
    ///   - sessionId: Clawdmeter session identifier for this Cursor
    ///                period. Callers typically derive this from the
    ///                period start timestamp.
    ///   - sequenceNumber: Caller-managed sequence cursor.
    ///   - providerInstanceId: F3-ready instance id (e.g.
    ///                          "cursor_personal", "cursor_pro").
    ///   - rawBytes: Optional raw gRPC-Web body for
    ///               `rawProviderPayload` retention.
    public static func translate(
        usage: UsageData,
        sessionId: String,
        sequenceNumber: UInt64,
        providerInstanceId: String? = nil,
        rawBytes: Data? = nil
    ) -> [ProviderRuntimeEvent] {
        let extensions: [String: ProviderRuntimeEvent.ExtensionField] = [
            "cursor": .nested(cursorExtensions(from: usage))
        ]

        // `.sessionStarted` is the closest canonical case — Cursor's
        // "billing period" is the closest concept to a session. Settings
        // dict carries the percent + reset summary as readable strings.
        var settings: [String: String] = [:]
        settings["session_percent_used"] = String(usage.sessionPct)
        settings["session_reset_mins"] = String(usage.sessionResetMins)
        if let organizationID = usage.organizationID {
            settings["plan_badge"] = organizationID
        }
        settings["status"] = String(describing: usage.status)

        return [ProviderRuntimeEvent(
            id: "cursor-\(sessionId)-\(sequenceNumber)",
            providerKind: .cursor,
            providerInstanceId: providerInstanceId,
            sessionId: sessionId,
            sequenceNumber: sequenceNumber,
            emittedAt: usage.updatedAt,
            payload: .sessionStarted(model: "cursor", settings: settings),
            rawProviderPayload: rawBytes,
            providerExtensions: extensions
        )]
    }

    // MARK: - Extension fields

    private static func cursorExtensions(from usage: UsageData) -> [String: ProviderRuntimeEvent.ExtensionField] {
        var out: [String: ProviderRuntimeEvent.ExtensionField] = [
            "session_percent": .int(Int64(usage.sessionPct)),
            "session_reset_mins": .int(Int64(usage.sessionResetMins)),
            "weekly_percent": .int(Int64(usage.weeklyPct)),
            "weekly_reset_mins": .int(Int64(usage.weeklyResetMins)),
            "session_epoch": .int(Int64(usage.sessionEpoch)),
            "weekly_epoch": .int(Int64(usage.weeklyEpoch)),
            "status": .string(String(describing: usage.status)),
            "representative_claim": .string(String(describing: usage.representativeClaim)),
            "updated_at_epoch": .double(usage.updatedAt.timeIntervalSince1970)
        ]
        if let org = usage.organizationID {
            out["plan_badge"] = .string(org)
        }
        return out
    }
}
