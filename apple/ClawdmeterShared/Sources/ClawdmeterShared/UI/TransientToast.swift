import Foundation

public struct TransientToast: Identifiable, Codable, Hashable, Sendable {
    /// Visual severity — drives the leading glyph + tint in the toast host so a
    /// failure never looks identical to a success. Defaults to `.info` for
    /// back-compat with existing callers (e.g. the archive-undo toast).
    public enum Severity: String, Codable, Hashable, Sendable {
        case info, success, failure
    }

    public var id: UUID
    public var title: String
    public var detail: String?
    public var actionTitle: String?
    public var actionID: String?
    public var duration: TimeInterval
    public var createdAt: Date
    public var isDestructiveRecovery: Bool
    public var severity: Severity

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        actionID: String? = nil,
        duration: TimeInterval = 5,
        createdAt: Date = Date(),
        isDestructiveRecovery: Bool = false,
        severity: Severity = .info
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.actionID = actionID
        self.duration = duration
        self.createdAt = createdAt
        self.isDestructiveRecovery = isDestructiveRecovery
        self.severity = severity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        actionTitle = try c.decodeIfPresent(String.self, forKey: .actionTitle)
        actionID = try c.decodeIfPresent(String.self, forKey: .actionID)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isDestructiveRecovery = try c.decodeIfPresent(Bool.self, forKey: .isDestructiveRecovery) ?? false
        // Tolerate payloads written before severity existed.
        severity = try c.decodeIfPresent(Severity.self, forKey: .severity) ?? .info
    }
}
