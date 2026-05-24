import Foundation
import Combine
import ClawdmeterShared

struct SessionLauncherAvailability: Equatable {
    var opencodeReady: Bool
    var cursorReady: Bool

    init(opencodeReady: Bool = false, cursorReady: Bool = false) {
        self.opencodeReady = opencodeReady
        self.cursorReady = cursorReady
    }
}

@MainActor
final class SessionLauncherModel: ObservableObject {
    @Published private(set) var availability: SessionLauncherAvailability
    @Published private(set) var modelCatalog: ModelCatalog

    init(
        modelCatalog: ModelCatalog = .bundled,
        availability: SessionLauncherAvailability = SessionLauncherAvailability()
    ) {
        self.modelCatalog = modelCatalog
        self.availability = availability
    }

    var selectableAgents: [AgentKind] {
        Self.selectableAgents(for: availability)
    }

    static func selectableAgents(for availability: SessionLauncherAvailability) -> [AgentKind] {
        var agents: [AgentKind] = [.claude, .codex, .gemini]
        if availability.opencodeReady {
            agents.append(.opencode)
        }
        if availability.cursorReady {
            agents.append(.cursor)
        }
        return agents
    }

    func refreshProviderAvailability() async {
        await OpencodeProcessManager.shared.refreshAuthStatus()
        let opencodeReady = OpencodeProcessManager.shared.binaryPath != nil
            && !(OpencodeProcessManager.shared.authStatus ?? [:]).isEmpty

        let cursorState = await CursorModelProbe.shared.currentState()
        modelCatalog = ModelCatalog.bundled.replacingCursor(cursorState.models)
        availability = SessionLauncherAvailability(
            opencodeReady: opencodeReady,
            cursorReady: cursorState.binaryPath != nil && cursorState.authenticated
        )
    }

    func availableAgentOrDefault(_ agent: AgentKind) -> AgentKind {
        selectableAgents.contains(agent) ? agent : .claude
    }

    func defaultModelId(for agent: AgentKind) -> String? {
        modelCatalog.entries(for: agent).first?.id
    }

    func resolvedModelId(for agent: AgentKind, selectedModelId: String?) -> String? {
        let models = modelCatalog.entries(for: agent)
        guard !models.isEmpty else { return nil }
        if let selectedModelId,
           models.contains(where: { $0.id == selectedModelId || $0.cliAlias == selectedModelId }) {
            return selectedModelId
        }
        return models.first?.id
    }

    func supportsEffort(modelId: String?) -> Bool {
        guard let modelId,
              let entry = modelCatalog.entry(forId: modelId)
        else {
            return true
        }
        return entry.supportsEffort
    }

    func chipDefaults(for agent: AgentKind) -> ComposerStore.ChipDefaults {
        ComposerStore.ChipDefaults.for(agent: agent, catalog: modelCatalog)
    }

    func normalize(_ store: ComposerStore) {
        let normalizedAgent = availableAgentOrDefault(store.agent)
        if normalizedAgent != store.agent {
            store.resetChipsForAgent(normalizedAgent, catalog: modelCatalog)
        } else {
            let resolved = resolvedModelId(for: normalizedAgent, selectedModelId: store.modelId)
            store.modelId = resolved
            if !supportsEffort(modelId: resolved) {
                store.effort = nil
            } else if store.effort == nil {
                store.effort = .max
            }
        }
        if store.agent == .cursor, store.permissionMode == .plan {
            store.permissionMode = .ask
            store.planMode = false
        }
    }
}
