import Foundation

/// A permissive, lossless JSON value used for ACP fields whose shape we do not
/// model strictly: `_meta` blocks, tool-call `rawInput`/`rawOutput`, and the
/// payloads of `session/update` variants we have not added a typed case for.
///
/// Why: ACP agents (Grok especially) stuff arbitrary vendor data under `_meta`
/// (`x.ai/fs_notify`, `grokShell`, even the user's MCP env). A strict `Codable`
/// chokes on that; a permissive value round-trips it so nothing is lost and the
/// raw bytes can flow into `ProviderRuntimeEvent.rawProviderPayload`.
public enum ACPJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ACPJSONValue])
    case object([String: ACPJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([ACPJSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: ACPJSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Convenience accessors

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [ACPJSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: ACPJSONValue]? { if case .object(let o) = self { return o }; return nil }

    public subscript(_ key: String) -> ACPJSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Recursively strip every `_meta` key. ACP responses embed `_meta` blocks
    /// (agent-private data, sometimes secrets); we drop them at the decode edge
    /// so they never reach typed models, logs, or persisted state.
    public func strippingMeta() -> ACPJSONValue {
        switch self {
        case .object(let o):
            var out: [String: ACPJSONValue] = [:]
            for (k, v) in o where k != "_meta" {
                out[k] = v.strippingMeta()
            }
            return .object(out)
        case .array(let a):
            return .array(a.map { $0.strippingMeta() })
        default:
            return self
        }
    }
}
