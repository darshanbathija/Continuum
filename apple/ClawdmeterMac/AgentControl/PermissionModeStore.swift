import Foundation
import Combine
import ClawdmeterShared

/// Per-session permission-mode state. Mirrors the AutopilotState pattern —
/// pure Mac local state, NOT persisted in `sessions.json` and NOT on the
/// wire, since the daemon only needs the resolved CLI flags at spawn time.
///
/// Bypass mode (`.bypass`) goes through `AutopilotState` for the
/// per-repo trust gate; this store treats it as a derived view: the
/// chip's "current mode" is the union of:
///   1. AutopilotState.isEnabled(session.id) → .bypass
///   2. session.status == .planning           → .plan
///   3. PermissionModeStore.acceptEdits(id)   → .acceptEdits
///   4. otherwise                             → .ask
@MainActor
public final class PermissionModeStore: ObservableObject {
    public static let shared = PermissionModeStore()

    /// Session ids whose CLI is currently spawned with
    /// `--permission-mode acceptEdits`.
    @Published public private(set) var acceptEditsSessionIds: Set<UUID> = []

    private let defaults = UserDefaults.standard
    private let storageKey = "clawdmeter.permission.acceptEdits.v1"

    public init() {
        if let raw = defaults.array(forKey: storageKey) as? [String] {
            acceptEditsSessionIds = Set(raw.compactMap(UUID.init(uuidString:)))
        }
    }

    public func acceptEdits(sessionId: UUID) -> Bool {
        acceptEditsSessionIds.contains(sessionId)
    }

    /// Set or clear the acceptEdits flag for a session. Caller is
    /// responsible for triggering the CLI respawn (the flag only takes
    /// effect when the agent is re-spawned with new argv).
    public func setAcceptEdits(_ enabled: Bool, sessionId: UUID) {
        if enabled {
            acceptEditsSessionIds.insert(sessionId)
        } else {
            acceptEditsSessionIds.remove(sessionId)
        }
        defaults.set(
            acceptEditsSessionIds.map(\.uuidString),
            forKey: storageKey
        )
    }

    /// Flip the bypass (autopilot) flag for a session. Forwards to
    /// `AutopilotState.shared` (the authoritative store) and bumps the
    /// observed `@Published` set so SwiftUI views re-render. Caller is
    /// still responsible for triggering the CLI respawn — only the
    /// argv changes between modes.
    public func setBypass(_ enabled: Bool, sessionId: UUID) {
        AutopilotState.shared.setEnabled(enabled, sessionId: sessionId)
        // Touch the @Published set with an idempotent insert/remove so
        // SwiftUI sees a publish event. Avoids needing to add
        // ObservableObject conformance to AutopilotState.
        let placeholder = UUID()
        acceptEditsSessionIds.insert(placeholder)
        acceptEditsSessionIds.remove(placeholder)
    }

    /// Resolved permission mode for a session — the union of autopilot
    /// state, planMode status, and acceptEdits flag. Used by the chip to
    /// display the current selection.
    public func currentMode(for session: AgentSession) -> PermissionMode {
        if AutopilotState.shared.isEnabled(sessionId: session.id) {
            return .bypass
        }
        if session.status == .planning {
            return .plan
        }
        if acceptEdits(sessionId: session.id) {
            return .acceptEdits
        }
        return .ask
    }
}
