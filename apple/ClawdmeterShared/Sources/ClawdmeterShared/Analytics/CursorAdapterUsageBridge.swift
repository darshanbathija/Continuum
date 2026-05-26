import Foundation

/// F1d-wire (strangler-fig per D23): adapter-routed equivalent of the
/// direct `UsageData` read for Cursor.
///
/// Cursor is structurally different from the other four providers: it
/// has **no JSONL session log** and no per-turn token stream. Cursor
/// publishes period-level usage via `api2.cursor.sh` and the polling
/// loop in `UsagePoller` produces one `UsageData` snapshot per poll.
/// `CursorAdapter` translates each snapshot into one canonical
/// `.sessionStarted` `ProviderRuntimeEvent` carrying the period state
/// in extensions.
///
/// This bridge is the consumer-side projection: it runs the adapter
/// over the polled `UsageData`, picks the canonical event, and
/// reconstructs the `UsageData` shape from the canonical extension
/// envelope. With the feature flag on, the analytics consumer calls
/// this bridge; with the flag off, it uses the polled `UsageData`
/// directly. The bridge MUST be a behavioral identity over the polled
/// `UsageData` — `F1dParityTests` enforces this.
///
/// **Why a separate type?** The legacy "consumer" is the implicit
/// `model.usage = freshPolledUsageData` assignment. The adapter is a
/// pure function from `UsageData` → `[ProviderRuntimeEvent]`. To wire
/// the analytics layer through the canonical pipeline without changing
/// downstream rendering, this bridge owns the
/// "translate-then-reproject" round-trip in one place, separate from
/// the adapter which stays general-purpose.
///
/// **Dedup contract.** Cursor emits one `.sessionStarted` per poll
/// with id `cursor-{sessionId}-{seq}`. Downstream consumers that
/// subscribe to the canonical event stream (orchestration store F2,
/// push gateway E6) dedup by event id — the bridge respects this
/// invariant by passing the caller's session id + sequence number
/// straight through to `CursorAdapter.translate`. The wire never
/// generates duplicate canonical events for the same `UsageData`
/// because the caller (the polling loop) owns the (sessionId,
/// sequence) cursor.
///
/// **Parity contract.** For every polled Cursor `UsageData`, this
/// MUST return a value that round-trips losslessly through the
/// canonical event stream: same `sessionPct`, `sessionResetMins`,
/// `sessionEpoch`, `weeklyPct`, `weeklyResetMins`, `weeklyEpoch`,
/// `status`, `representativeClaim`, `updatedAt`, `organizationID`.
/// Cases where the adapter would emit no events (none today — Cursor
/// always emits exactly one `.sessionStarted`) return nil here too.
///
/// **Plan reference:** F1d-wire (Phase 1; D23 strangler-fig).
public enum CursorAdapterUsageBridge {

    /// Project one polled `UsageData` through the canonical adapter and
    /// back into the legacy `UsageData` shape. Returns nil when the
    /// adapter emits no events (defensive — current `CursorAdapter`
    /// always emits exactly one `.sessionStarted`).
    ///
    /// Callers pass through the same `sessionId` / `sequenceNumber` they
    /// would use for the orchestration store so the canonical event id
    /// (`cursor-{sessionId}-{seq}`) is stable across the strangler-fig
    /// boundary. Downstream consumers that dedup by event id (F2 store,
    /// E6 push gateway) see the same id regardless of flag state.
    ///
    /// - Parameters:
    ///   - usage: The polled `UsageData` value from `CursorSource.poll()`.
    ///   - sessionId: Clawdmeter session identifier for this Cursor
    ///                period. Callers typically derive this from the
    ///                period start timestamp.
    ///   - sequenceNumber: Caller-managed sequence cursor.
    ///   - providerInstanceId: F3-ready instance id (e.g.
    ///                          "cursor_personal", "cursor_pro").
    ///   - rawBytes: Optional raw gRPC-Web body for retention.
    public static func project(
        usage: UsageData,
        sessionId: String,
        sequenceNumber: UInt64,
        providerInstanceId: String? = nil,
        rawBytes: Data? = nil
    ) -> UsageData? {
        let events = CursorAdapter.translate(
            usage: usage,
            sessionId: sessionId,
            sequenceNumber: sequenceNumber,
            providerInstanceId: providerInstanceId,
            rawBytes: rawBytes
        )

        // CursorAdapter is contract-bound to emit exactly one
        // `.sessionStarted` event per call. Pick the first such event;
        // defensively return nil if no event materializes (e.g. future
        // adapter change that drops a malformed UsageData).
        guard let event = events.first(where: { ev in
            if case .sessionStarted = ev.payload { return true }
            return false
        }) else {
            return nil
        }

        // Pull the period state back off the canonical extension
        // envelope. `CursorAdapter.translate` stashes every Cursor-
        // specific field under `providerExtensions["cursor"]` as a
        // nested map; we reconstruct `UsageData` from those keyed
        // scalars so the round-trip is lossless.
        guard let outer = event.providerExtensions?["cursor"],
              case let .nested(ext) = outer else {
            // No cursor extension envelope — would only happen if the
            // adapter contract changed. Defensive nil rather than a
            // partial reconstruction with default values.
            return nil
        }

        let sessionPct = extensionInt(ext["session_percent"])
        let sessionResetMins = extensionInt(ext["session_reset_mins"])
        let sessionEpoch = extensionInt(ext["session_epoch"])
        let weeklyPct = extensionInt(ext["weekly_percent"])
        let weeklyResetMins = extensionInt(ext["weekly_reset_mins"])
        let weeklyEpoch = extensionInt(ext["weekly_epoch"])

        // Status + representativeClaim are emitted as the raw
        // `String(describing:)` form of the enum (the adapter side
        // does this for parity with the t3code mirror, where each
        // enum case stringifies to its case name).
        //
        // `Status` raw values match `String(describing:)` directly
        // (no custom raw values declared). `BindingWindow` is the
        // exception — its raw values are snake_case ("five_hour" vs
        // describing's "fiveHour") so we look up by case-name first
        // and fall back to rawValue. This matches what the adapter
        // would produce for any future case added to either enum.
        let statusRaw = extensionString(ext["status"]) ?? String(describing: UsageData.Status.unknown)
        let status = decodeStatus(describing: statusRaw) ?? usage.status

        let claimRaw = extensionString(ext["representative_claim"]) ?? String(describing: usage.representativeClaim)
        let representativeClaim = decodeBindingWindow(describing: claimRaw) ?? usage.representativeClaim

        // updated_at_epoch is emitted as a double — convert back.
        let updatedAtEpoch = extensionDouble(ext["updated_at_epoch"]) ?? usage.updatedAt.timeIntervalSince1970
        let updatedAt = Date(timeIntervalSince1970: updatedAtEpoch)

        // organizationID is the only optional string — adapter omits
        // the key when nil, so we read it as optional here too. Mirror
        // legacy: nil → nil (not empty string).
        let organizationID = extensionString(ext["plan_badge"])

        return UsageData(
            sessionPct: sessionPct,
            sessionResetMins: sessionResetMins,
            sessionEpoch: sessionEpoch,
            weeklyPct: weeklyPct,
            weeklyResetMins: weeklyResetMins,
            weeklyEpoch: weeklyEpoch,
            status: status,
            representativeClaim: representativeClaim,
            updatedAt: updatedAt,
            organizationID: organizationID,
            // The Cursor adapter doesn't carry the Antigravity-only
            // fields. Pass through the input's values so the wire is
            // a behavioral identity even for `UsageData` values that
            // happen to carry these set (defensive — Cursor source
            // never sets them today, but the round-trip must preserve
            // input shape).
            antigravityModel: usage.antigravityModel,
            sdkModeActive: usage.sdkModeActive,
            codexSDKModeActive: usage.codexSDKModeActive
        )
    }

    // MARK: - Stable session id derivation

    /// Derive a stable Cursor session id from the period reset epoch.
    /// The polling loop calls `project(usage:sessionId:...)` once per
    /// poll; the session id must be stable across polls of the same
    /// billing period so the canonical event id
    /// (`cursor-{sessionId}-{seq}`) only varies on the sequence
    /// cursor. Returns `cursor-period-<epoch>`.
    ///
    /// Exposed so callers wiring the strangler-fig branch in
    /// `AppModel.consume(_:)` can derive the same id the polling loop
    /// would and the F2 orchestration store expects.
    public static func sessionId(forPeriodEpoch epoch: Int) -> String {
        "cursor-period-\(epoch)"
    }

    // MARK: - String(describing:) decoders

    /// Map the `String(describing:)` form of `UsageData.Status` (e.g.
    /// "allowed", "notStarted") back to the enum case. The status
    /// raw values happen to match `String(describing:)`, but we
    /// switch on the case name explicitly so a future case added with
    /// an explicit `rawValue` (e.g. `case rateLimited = "rate_limited"`)
    /// still round-trips correctly.
    private static func decodeStatus(describing name: String) -> UsageData.Status? {
        switch name {
        case "allowed":    return .allowed
        case "limited":    return .limited
        case "unknown":    return .unknown
        case "notStarted": return .notStarted
        default:           return UsageData.Status(rawValue: name)
        }
    }

    /// Map the `String(describing:)` form of `UsageData.BindingWindow`
    /// (e.g. "fiveHour", "sevenDay") back to the enum case. The raw
    /// values are snake_case ("five_hour", "seven_day") so a direct
    /// `init(rawValue:)` on the case-name string fails — we switch
    /// on the case name explicitly, then fall back to rawValue for
    /// any case whose name happens to equal its raw value.
    private static func decodeBindingWindow(describing name: String) -> UsageData.BindingWindow? {
        switch name {
        case "fiveHour": return .fiveHour
        case "sevenDay": return .sevenDay
        case "unknown":  return .unknown
        default:         return UsageData.BindingWindow(rawValue: name)
        }
    }

    // MARK: - Extension scalar helpers

    private static func extensionString(_ field: ProviderRuntimeEvent.ExtensionField?) -> String? {
        guard case let .string(v) = field else { return nil }
        return v
    }

    private static func extensionInt(_ field: ProviderRuntimeEvent.ExtensionField?) -> Int {
        guard case let .int(v) = field else { return 0 }
        return Int(v)
    }

    private static func extensionDouble(_ field: ProviderRuntimeEvent.ExtensionField?) -> Double? {
        guard case let .double(v) = field else { return nil }
        return v
    }
}
