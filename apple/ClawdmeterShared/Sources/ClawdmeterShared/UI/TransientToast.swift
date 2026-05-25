import Foundation

public struct TransientToast: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String?
    public var actionTitle: String?
    public var actionID: String?
    public var duration: TimeInterval
    public var createdAt: Date
    public var isDestructiveRecovery: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        actionID: String? = nil,
        duration: TimeInterval = 5,
        createdAt: Date = Date(),
        isDestructiveRecovery: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.actionID = actionID
        self.duration = duration
        self.createdAt = createdAt
        self.isDestructiveRecovery = isDestructiveRecovery
    }
}
