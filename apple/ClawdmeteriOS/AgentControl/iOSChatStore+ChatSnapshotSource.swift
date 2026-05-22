import Foundation
import ClawdmeterShared

/// Bridges iOS's `iOSChatStore` (LRU-2 mirror of the Mac daemon's chat
/// state, pushed over the `chat-subscribe` WebSocket) to the
/// cross-platform `ChatSnapshotSource` protocol. iOS's store already
/// holds a `WireChatSnapshot` field directly, so the conformance is a
/// pass-through.
///
/// Read-only — mutations come from the WS frame stream; the V2
/// composer dispatches sends through `AgentControlClient` directly.
@MainActor
extension iOSChatStore: ChatSnapshotSource {
    public var items: [ChatItem] { snapshot.items }
    public var planSteps: [PlanStep] { snapshot.planSteps }
    public var sourceEntries: [SourceEntry] { snapshot.sourceEntries }
    public var pendingPermissionPrompt: PendingPermissionPrompt? { snapshot.pendingPermissionPrompt }
    public var currentTurnState: TurnState { snapshot.currentTurnState }
    public var lastEventAt: Date? { snapshot.lastEventAt }
    public var updateCounter: UInt64 { snapshot.updateCounter }
}
