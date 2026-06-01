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
    private let providerDefaults: ProviderDefaultsStore

    init(
        modelCatalog: ModelCatalog = .bundled,
        availability: SessionLauncherAvailability = SessionLauncherAvailability(),
        providerDefaults: ProviderDefaultsStore = ProviderDefaultsStore()
    ) {
        self.modelCatalog = modelCatalog
        self.availability = availability
        self.providerDefaults = providerDefaults
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
        let opencodeEnabled = ProviderEnablement.isEnabled("opencode")
        let cursorEnabled = ProviderEnablement.isEnabled("cursor")

        var opencodeReady = false
        var cursorReady = false
        var nextCatalog = ModelCatalog.bundled

        if opencodeEnabled {
            await OpencodeProcessManager.shared.refreshAuthStatus()
            opencodeReady = OpencodeProcessManager.shared.binaryPath != nil
                && !(OpencodeProcessManager.shared.authStatus ?? [:]).isEmpty
            nextCatalog = nextCatalog.replacingOpenRouter(await OpenRouterModelProbe.shared.currentModels())
        }

        if cursorEnabled {
            let cursorState = await CursorModelProbe.shared.currentState()
            nextCatalog = nextCatalog.replacingCursor(cursorState.models)
            cursorReady = cursorState.binaryPath != nil && cursorState.authenticated
        }

        modelCatalog = nextCatalog
        availability = SessionLauncherAvailability(
            opencodeReady: opencodeReady,
            cursorReady: cursorReady
        )
    }

    func availableAgentOrDefault(_ agent: AgentKind) -> AgentKind {
        selectableAgents.contains(agent) ? agent : .claude
    }

    func defaultModelId(for agent: AgentKind) -> String? {
        if let vendor = ChatVendor.migrated(from: agent),
           let model = providerDefaults.modelId(for: vendor, catalog: modelCatalog) {
            return model
        }
        return modelCatalog.entries(for: agent).first?.id
    }

    func resolvedModelId(for agent: AgentKind, selectedModelId: String?) -> String? {
        let models = modelCatalog.entries(for: agent)
        guard !models.isEmpty else { return nil }
        if let selectedModelId,
           models.contains(where: { $0.id == selectedModelId || $0.cliAlias == selectedModelId }) {
            return selectedModelId
        }
        return defaultModelId(for: agent)
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
        let base = ComposerStore.ChipDefaults.for(agent: agent, catalog: modelCatalog)
        guard let vendor = ChatVendor.migrated(from: agent) else { return base }
        let model = providerDefaults.modelId(for: vendor, catalog: modelCatalog) ?? base.modelId
        let effort = providerDefaults.effort(for: vendor, catalog: modelCatalog) ?? base.effort
        return ComposerStore.ChipDefaults(
            agent: agent,
            modelId: model,
            effort: supportsEffort(modelId: model) ? effort : nil,
            mode: base.mode,
            planMode: base.planMode
        )
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
