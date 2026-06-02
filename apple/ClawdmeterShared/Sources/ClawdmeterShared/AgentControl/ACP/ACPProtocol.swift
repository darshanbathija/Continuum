import Foundation

/// Agent Client Protocol (ACP) constants. Pinned to the schema release we
/// re-implemented from. Verified live on 2026-06-02 against grok agent 0.2.11
/// (`grok agent --no-leader stdio`) and cursor-agent (`cursor-agent acp`):
/// both answer `initialize` with `protocolVersion: 1`. See
/// `docs/acp-harness/phase0-spike.md`.
public enum ACP {
    public static let protocolVersion = 1
    /// The upstream ACP schema release the typed models mirror.
    public static let schemaRelease = "v0.11.3"

    /// Methods the harness (client) calls ON the agent.
    public enum AgentMethod {
        public static let initialize = "initialize"
        public static let authenticate = "authenticate"
        public static let sessionNew = "session/new"
        public static let sessionLoad = "session/load"
        public static let sessionPrompt = "session/prompt"
        public static let sessionCancel = "session/cancel"
        public static let sessionSetMode = "session/set_mode"
        public static let sessionSetModel = "session/set_model"
        public static let sessionSetConfigOption = "session/set_config_option"
    }

    /// Methods the agent calls BACK on the harness (client). Implementing these
    /// is what makes us "the harness" rather than an observer.
    public enum ClientMethod {
        public static let fsReadTextFile = "fs/read_text_file"
        public static let fsWriteTextFile = "fs/write_text_file"
        public static let sessionRequestPermission = "session/request_permission"
        public static let sessionUpdate = "session/update"
        public static let terminalCreate = "terminal/create"
        public static let terminalOutput = "terminal/output"
        public static let terminalWaitForExit = "terminal/wait_for_exit"
        public static let terminalKill = "terminal/kill"
        public static let terminalRelease = "terminal/release"
    }

    /// JSON-RPC error codes (standard + ACP-specific).
    public enum ErrorCode {
        public static let parse = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
        public static let authRequired = -32000
        public static let resourceNotFound = -32002
    }
}

/// A JSON-RPC id. ACP agents send numeric ids; a request with `id: 0` must be
/// distinguished from a notification (no `id` field at all), so we model the id
/// explicitly rather than as an optional Int.
public enum RpcId: Sendable, Hashable, Codable {
    case number(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int64.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported RPC id")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

/// Errors surfaced by the ACP transport / driver.
public enum ACPError: Error, Sendable, Equatable {
    /// The agent returned a JSON-RPC error to one of our requests.
    case rpc(code: Int, message: String)
    /// Spawn / handshake / auth failed before a turn could start (two-phase
    /// failure contract: this is thrown synchronously from `start`).
    case startFailed(String)
    /// The agent process exited while requests were in flight.
    case processExited(code: Int32?)
    /// A frame could not be decoded.
    case decode(String)
    /// No auth method offered by the agent matched what we can satisfy.
    case noUsableAuthMethod(offered: [String])
}
