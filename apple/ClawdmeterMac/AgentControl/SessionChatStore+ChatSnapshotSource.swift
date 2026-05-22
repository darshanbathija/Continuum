import Foundation
import ClawdmeterShared

/// Bridges the Mac daemon's `SessionChatStore` to the cross-platform
/// `ChatSnapshotSource` protocol the new V2 chat UI binds to. Mac's
/// store wraps each session's state in a richer local `ChatSnapshot`
/// struct (carries token totals, model hint, cache breakdowns); the
/// protocol normalizes the read-shape so the same SwiftUI hierarchy
/// can target this store and iOS's `iOSChatStore` interchangeably.
///
/// Read-only — mutations stay on `SessionChatStore`'s own API (the
/// daemon's ingestors are the only writers).
@MainActor
extension SessionChatStore: ChatSnapshotSource {
    public var items: [ChatItem] { snapshot.items }
    public var planSteps: [PlanStep] { snapshot.planSteps }
    public var sourceEntries: [SourceEntry] { snapshot.sourceEntries }
    public var lastEventAt: Date? { snapshot.lastEventAt }
    public var updateCounter: UInt64 { snapshot.updateCounter }
    public var currentTurnState: TurnState { snapshot.currentTurnState }
    // `pendingPermissionPrompt` is already a stored `@Published` property
    // on `SessionChatStore` itself; no shim needed.
}
