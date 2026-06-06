import ClawdmeterShared

enum AgentTransportPolicy: Equatable {
    case directPtyArgv
    case opencodeServe
    case acpHarness
    case codexAppServer
    case transportOwningHarness
    case unsupported

    static func codeSessionTransport(
        for agent: AgentKind,
        acpSupported: Bool
    ) -> AgentTransportPolicy {
        switch agent {
        case .claude:
            return .directPtyArgv
        case .opencode:
            return .opencodeServe
        case .cursor:
            return acpSupported ? .acpHarness : .unsupported
        case .codex:
            return .codexAppServer
        case .gemini, .grok:
            return .transportOwningHarness
        case .unknown:
            return .unsupported
        }
    }

    var requiresArgvPreflight: Bool {
        self == .directPtyArgv
    }

    var managedPreflightToken: String {
        switch self {
        case .directPtyArgv, .unsupported:
            return ""
        case .opencodeServe:
            return "opencode-managed-session"
        case .acpHarness:
            return "acp-managed-session"
        case .codexAppServer:
            return "codex-app-server-session"
        case .transportOwningHarness:
            return "transport-owning-harness-session"
        }
    }
}
