import Foundation
import Network

/// Route-table for AgentControlServer. Replaces the growing `switch (method,
/// path)` dispatch with a registration-based router.
///
/// Pattern syntax: `/sessions/:id/model` — segments starting with `:` are
/// parameter captures returned in the `params` dictionary. Trailing `/*`
/// matches the rest of the path (reserved for future).
///
/// Match order: routes are evaluated in registration order; first match
/// wins. Declare specific routes (`/sessions/needs-attention`) BEFORE
/// parameterized ones (`/sessions/:id`) so the specific one wins.
struct RouteTable {

    typealias Params = [String: String]

    /// Concrete handler shape. Same as `AgentControlServer.RouteHandler`.
    /// Specified here so we avoid the "typealias points at a private
    /// underlying type" compiler complaint when registering closures.
    typealias Handler = @MainActor (HTTPRequest, NWConnection, Params) async -> Void

    struct Route {
        let method: String
        let pattern: Pattern
        let raw: String
    }

    struct Pattern {
        let segments: [Segment]
        let hasTrailingWildcard: Bool

        static func compile(_ pattern: String) -> Pattern {
            var raw = pattern
            if raw.hasPrefix("/") { raw.removeFirst() }
            var wildcard = false
            if raw.hasSuffix("/*") {
                wildcard = true
                raw.removeLast(2)
            }
            let segments: [Segment] = raw.isEmpty ? [] : raw.split(separator: "/").map { piece in
                let s = String(piece)
                if s.hasPrefix(":") { return .parameter(String(s.dropFirst())) }
                return .literal(s)
            }
            return Pattern(segments: segments, hasTrailingWildcard: wildcard)
        }

        func match(_ path: String) -> Params? {
            var raw = path
            if raw.hasPrefix("/") { raw.removeFirst() }
            if raw.hasSuffix("/") { raw.removeLast() }
            let pieces = raw.isEmpty ? [] : raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if !hasTrailingWildcard, pieces.count != segments.count {
                return nil
            }
            if hasTrailingWildcard, pieces.count < segments.count {
                return nil
            }
            var params: Params = [:]
            for (i, segment) in segments.enumerated() {
                let actual = pieces[i]
                switch segment {
                case .literal(let lit):
                    if lit != actual { return nil }
                case .parameter(let name):
                    if actual.isEmpty { return nil }
                    params[name] = actual
                }
            }
            return params
        }
    }

    enum Segment: Equatable {
        case literal(String)
        case parameter(String)
    }

    struct Entry {
        let route: Route
        let handler: Handler
    }

    private(set) var entries: [Entry] = []

    mutating func register(method: String, pattern: String, handler: @escaping Handler) {
        let compiled = Pattern.compile(pattern)
        let entry = Entry(
            route: Route(method: method.uppercased(), pattern: compiled, raw: pattern),
            handler: handler
        )
        entries.append(entry)
    }

    struct Match {
        let handler: Handler
        let params: Params
        let raw: String
    }

    func match(method: String, path: String) -> Match? {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        for entry in entries where entry.route.method == method.uppercased() {
            if let params = entry.route.pattern.match(pathOnly) {
                return Match(handler: entry.handler, params: params, raw: entry.route.raw)
            }
        }
        return nil
    }
}
