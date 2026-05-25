import Foundation

public enum ClawdmeterCommandScope: String, Codable, CaseIterable, Hashable, Sendable {
    case global
    case chat
    case code
    case session
    case composer
    case diff
    case terminal
    case settings
    case diagnostics
}
public enum ClawdmeterCommandKind: String, Codable, CaseIterable, Hashable, Sendable {
    case action
    case navigation
    case session
    case setting
    case skill
    case external
}

public struct ClawdmeterCommandID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

public struct ClawdmeterCommandDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: ClawdmeterCommandID
    public var title: String
    public var subtitle: String?
    public var keywords: [String]
    public var scope: ClawdmeterCommandScope
    public var kind: ClawdmeterCommandKind
    public var shortcutID: String?
    public var isEnabled: Bool
    public var disabledReason: String?

    public init(
        id: ClawdmeterCommandID,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        scope: ClawdmeterCommandScope = .global,
        kind: ClawdmeterCommandKind = .action,
        shortcutID: String? = nil,
        isEnabled: Bool = true,
        disabledReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.scope = scope
        self.kind = kind
        self.shortcutID = shortcutID
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

public struct ClawdmeterCommandRegistry: Codable, Hashable, Sendable {
    public private(set) var commands: [ClawdmeterCommandDescriptor]

    public init(commands: [ClawdmeterCommandDescriptor] = []) {
        self.commands = []
        for command in commands {
            upsert(command)
        }
    }

    public mutating func upsert(_ command: ClawdmeterCommandDescriptor) {
        if let idx = commands.firstIndex(where: { $0.id == command.id }) {
            commands[idx] = command
        } else {
            commands.append(command)
        }
    }

    public func command(id: ClawdmeterCommandID) -> ClawdmeterCommandDescriptor? {
        commands.first { $0.id == id }
    }

    public func filtered(
        query: String,
        scopes: Set<ClawdmeterCommandScope>? = nil,
        includeDisabled: Bool = true
    ) -> [ClawdmeterCommandDescriptor] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return commands
            .filter { command in
                if !includeDisabled && !command.isEnabled { return false }
                if let scopes, !scopes.contains(command.scope), command.scope != .global { return false }
                guard !needle.isEmpty else { return true }
                if command.title.lowercased().contains(needle) { return true }
                if command.subtitle?.lowercased().contains(needle) == true { return true }
                if command.id.rawValue.lowercased().contains(needle) { return true }
                return command.keywords.contains { $0.lowercased().contains(needle) }
            }
            .sorted { lhs, rhs in
                let lhsEnabled = lhs.isEnabled ? 0 : 1
                let rhsEnabled = rhs.isEnabled ? 0 : 1
                if lhsEnabled != rhsEnabled { return lhsEnabled < rhsEnabled }
                if lhs.scope != rhs.scope { return lhs.scope.rawValue < rhs.scope.rawValue }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}
