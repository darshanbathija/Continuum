import Foundation
import ClawdmeterShared

/// Resolved spawn configuration for a custom OpenAI/Anthropic-compatible
/// endpoint. Every spawn/respawn callsite routes through this choke point.
struct CustomProviderSpawnPlan: Sendable, Equatable {
    let argvExtras: [String]
    let envOverrides: [String: String]

    enum ResolveError: Error, Equatable, LocalizedError {
        case providerNotFound(String)
        case providerDisabled(String)
        case keyUnavailable(String)
        case runtimeMismatch(expected: AgentKind, actual: AgentKind)

        var errorDescription: String? {
            switch self {
            case .providerNotFound(let id):
                return "Custom provider \"\(id)\" not found."
            case .providerDisabled(let id):
                return "Custom provider \"\(id)\" is disabled."
            case .keyUnavailable(let detail):
                return detail
            case .runtimeMismatch(let expected, let actual):
                return "Custom provider requires \(expected.rawValue) runtime, not \(actual.rawValue)."
            }
        }
    }

    @MainActor
    static func resolve(
        customProviderId: String,
        agent: AgentKind,
        store: CustomProviderStore
    ) throws -> CustomProviderSpawnPlan {
        guard let record = store.record(id: customProviderId) else {
            throw ResolveError.providerNotFound(customProviderId)
        }
        guard record.isEnabled else {
            throw ResolveError.providerDisabled(customProviderId)
        }
        let apiKey: String
        do {
            apiKey = try store.resolveAPIKey(for: record)
        } catch let error as CustomProviderStoreError {
            throw ResolveError.keyUnavailable(error.localizedDescription ?? "key unavailable")
        }

        switch record.kind {
        case .anthropicCompatible:
            guard agent == .claude else {
                throw ResolveError.runtimeMismatch(expected: .claude, actual: agent)
            }
            return CustomProviderSpawnPlan(
                argvExtras: [],
                envOverrides: [
                    "ANTHROPIC_BASE_URL": record.baseURL,
                    "ANTHROPIC_AUTH_TOKEN": apiKey,
                ]
            )
        case .openAICompatible:
            guard agent == .codex else {
                throw ResolveError.runtimeMismatch(expected: .codex, actual: agent)
            }
            let envKey = record.codexEnvKeyName
            let codexBaseURL = record.baseURL + "/v1"
            return CustomProviderSpawnPlan(
                argvExtras: [
                    "-c", "model_providers.\(record.id).name=\(record.displayLabel)",
                    "-c", "model_providers.\(record.id).base_url=\(codexBaseURL)",
                    "-c", "model_providers.\(record.id).env_key=\(envKey)",
                    "-c", "model_providers.\(record.id).wire_api=chat",
                    "-c", "model_provider=\(record.id)",
                ],
                envOverrides: [envKey: apiKey]
            )
        }
    }

    @MainActor
    static func resolve(for session: AgentSession, store: CustomProviderStore) throws -> CustomProviderSpawnPlan? {
        guard let customProviderId = session.customProviderId else { return nil }
        return try resolve(customProviderId: customProviderId, agent: session.agent, store: store)
    }
}
