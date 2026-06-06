import Foundation

/// One snapshot of Claude Code usage across the session (5h) and weekly (7d) windows.
///
/// Carries `sessionEpoch` and `weeklyEpoch` per plan E14 (reset-boundary integrity).
/// Newer epoch always beats older epoch, regardless of `updatedAt` — this prevents
/// stale-pre-reset payloads from overriding fresh-post-reset payloads under clock drift.
public struct UsageData: Codable, Equatable, Sendable {
    public struct CursorQuota: Codable, Equatable, Sendable {
        public let totalPct: Int
        public let autoPct: Int?
        public let apiPct: Int?
        public let resetMins: Int
        public let resetEpoch: Int
        public let includedUsageLabel: String?
        public let extraUsageLabel: String?

        public init(
            totalPct: Int,
            autoPct: Int?,
            apiPct: Int?,
            resetMins: Int,
            resetEpoch: Int,
            includedUsageLabel: String? = nil,
            extraUsageLabel: String? = nil
        ) {
            self.totalPct = UsageData.clampPercent(totalPct)
            self.autoPct = autoPct.map(UsageData.clampPercent)
            self.apiPct = apiPct.map(UsageData.clampPercent)
            self.resetMins = resetMins
            self.resetEpoch = resetEpoch
            self.includedUsageLabel = includedUsageLabel
            self.extraUsageLabel = extraUsageLabel
        }
    }

    public enum Status: String, Codable, Sendable {
        case allowed
        case limited
        case unknown
        /// No active session window — either the source hasn't been used
        /// recently, or the most recent recorded window has already reset
        /// without a fresh use to start a new one. Surfaced primarily for
        /// Codex, which can only observe state from CLI rollout files.
        case notStarted
    }

    public enum BindingWindow: String, Codable, Sendable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case unknown
    }

    public let sessionPct: Int           // 0...100
    public let sessionResetMins: Int     // minutes until session window reset
    public let sessionEpoch: Int         // epoch seconds of the current session-window reset (E14)
    public let weeklyPct: Int            // 0...100
    public let weeklyResetMins: Int
    public let weeklyEpoch: Int          // epoch seconds of the current weekly-window reset (E14)
    public let status: Status            // composite: "limited" if either window limited
    public let representativeClaim: BindingWindow
    public let updatedAt: Date           // server-time, parsed from API response `date:` header
    public let organizationID: String?   // surfaced for V2 multi-account (see plan roadmap)
    /// Wire v7: display name of the currently-selected Antigravity 2 model
    /// (e.g. "gemini-3.5-flash"). Resolved by the Mac from
    /// `antigravity_state.pbtxt`'s `last_selected_agent_model` token.
    /// Nil for non-Gemini providers and for older wire versions.
    /// decodeIfPresent — back-compat with v6 readers.
    public let antigravityModel: String?
    /// Wire v7: true when the daemon is running with SDK mode toggle ON
    /// (Python sidecar provisioned + observer.py active). Drives the
    /// "· SDK mode" vs "· disk mode" subtitle on the analytics row.
    /// Nil for older wire versions; treat nil as `false` (Disk mode).
    /// decodeIfPresent — back-compat with v6 readers.
    public let sdkModeActive: Bool?
    /// Wire v8: true when the Codex SDK observation mode toggle is ON
    /// (Node sidecar provisioned + observer active). Drives the
    /// "· SDK mode" subtitle on the Codex analytics column. Nil for
    /// older wire versions; treat nil as `false` (Codex Disk mode).
    /// decodeIfPresent — back-compat with v7 readers.
    public let codexSDKModeActive: Bool?
    /// Cursor's billing period is monthly and exposes Total / Auto / API
    /// buckets. Optional so older provider payloads decode unchanged.
    public let cursorQuota: CursorQuota?

    public init(
        sessionPct: Int,
        sessionResetMins: Int,
        sessionEpoch: Int,
        weeklyPct: Int,
        weeklyResetMins: Int,
        weeklyEpoch: Int,
        status: Status,
        representativeClaim: BindingWindow,
        updatedAt: Date,
        organizationID: String? = nil,
        antigravityModel: String? = nil,
        sdkModeActive: Bool? = nil,
        codexSDKModeActive: Bool? = nil,
        cursorQuota: CursorQuota? = nil
    ) {
        self.sessionPct = Self.clampPercent(sessionPct)
        self.sessionResetMins = sessionResetMins
        self.sessionEpoch = sessionEpoch
        self.weeklyPct = Self.clampPercent(weeklyPct)
        self.weeklyResetMins = weeklyResetMins
        self.weeklyEpoch = weeklyEpoch
        self.status = status
        self.representativeClaim = representativeClaim
        self.updatedAt = updatedAt
        self.organizationID = organizationID
        self.antigravityModel = antigravityModel
        self.sdkModeActive = sdkModeActive
        self.codexSDKModeActive = codexSDKModeActive
        self.cursorQuota = cursorQuota
    }

    // MARK: - Custom Codable (back-compat with v6/v7)

    enum CodingKeys: String, CodingKey {
        case sessionPct, sessionResetMins, sessionEpoch
        case weeklyPct, weeklyResetMins, weeklyEpoch
        case status, representativeClaim, updatedAt
        case organizationID
        case antigravityModel, sdkModeActive
        case codexSDKModeActive
        case cursorQuota
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionPct = Self.clampPercent(try c.decode(Int.self, forKey: .sessionPct))
        self.sessionResetMins = try c.decode(Int.self, forKey: .sessionResetMins)
        self.sessionEpoch = try c.decode(Int.self, forKey: .sessionEpoch)
        self.weeklyPct = Self.clampPercent(try c.decode(Int.self, forKey: .weeklyPct))
        self.weeklyResetMins = try c.decode(Int.self, forKey: .weeklyResetMins)
        self.weeklyEpoch = try c.decode(Int.self, forKey: .weeklyEpoch)
        self.status = try c.decode(Status.self, forKey: .status)
        self.representativeClaim = try c.decode(BindingWindow.self, forKey: .representativeClaim)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.organizationID = try c.decodeIfPresent(String.self, forKey: .organizationID)
        // v7 fields — decodeIfPresent so older wire payloads still decode
        // cleanly. Newer clients reading older payloads get nil here,
        // which renders the same as Disk mode (subtitle = "· disk mode").
        self.antigravityModel = try c.decodeIfPresent(String.self, forKey: .antigravityModel)
        self.sdkModeActive = try c.decodeIfPresent(Bool.self, forKey: .sdkModeActive)
        // v8 field — decodeIfPresent so v6/v7 payloads still parse.
        self.codexSDKModeActive = try c.decodeIfPresent(Bool.self, forKey: .codexSDKModeActive)
        self.cursorQuota = try c.decodeIfPresent(CursorQuota.self, forKey: .cursorQuota)
    }

    private static func clampPercent(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionPct, forKey: .sessionPct)
        try c.encode(sessionResetMins, forKey: .sessionResetMins)
        try c.encode(sessionEpoch, forKey: .sessionEpoch)
        try c.encode(weeklyPct, forKey: .weeklyPct)
        try c.encode(weeklyResetMins, forKey: .weeklyResetMins)
        try c.encode(weeklyEpoch, forKey: .weeklyEpoch)
        try c.encode(status, forKey: .status)
        try c.encode(representativeClaim, forKey: .representativeClaim)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(organizationID, forKey: .organizationID)
        try c.encodeIfPresent(antigravityModel, forKey: .antigravityModel)
        try c.encodeIfPresent(sdkModeActive, forKey: .sdkModeActive)
        try c.encodeIfPresent(codexSDKModeActive, forKey: .codexSDKModeActive)
        try c.encodeIfPresent(cursorQuota, forKey: .cursorQuota)
    }

    /// Mood derived from session usage. Drives gauge color and animation cadence.
    /// Mirrors firmware's idle/active/red-line mapping (plan: mood-state mapping).
    public enum Mood: String, Sendable {
        case idle
        case active
        case redLine
    }

    public var mood: Mood {
        switch sessionPct {
        case ..<30: return .idle
        case ..<75: return .active
        default: return .redLine
        }
    }

    /// Whether this snapshot is considered stale based on a wall-clock reference.
    /// Plan: stale when older than 90 seconds (visible-indicator threshold).
    public func isStale(referenceTime: Date, thresholdSeconds: TimeInterval = 90) -> Bool {
        referenceTime.timeIntervalSince(updatedAt) > thresholdSeconds
    }

    /// Plan E3 + E14: ordering uses `(epoch, updatedAt)` tuple.
    /// Returns true if `incoming` should replace `self`.
    public func shouldReplace(with incoming: UsageData) -> Bool {
        // New session window wins regardless of timestamp.
        if incoming.sessionEpoch != self.sessionEpoch {
            return incoming.sessionEpoch > self.sessionEpoch
        }
        // Same window: newer `updatedAt` wins.
        return incoming.updatedAt > self.updatedAt
    }
}
