import Foundation

public struct ClawdmeterShortcut: Identifiable, Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Hashable, Sendable {
        case command
        case shift
        case option
        case control
    }

    public var id: String
    public var label: String
    public var key: String
    public var modifiers: [Modifier]
    public var scope: ClawdmeterCommandScope
    public var commandID: ClawdmeterCommandID?
    public var isEnabled: Bool

    public init(
        id: String,
        label: String,
        key: String,
        modifiers: [Modifier],
        scope: ClawdmeterCommandScope,
        commandID: ClawdmeterCommandID? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
        self.commandID = commandID
        self.isEnabled = isEnabled
    }

    public var displayChord: String {
        let prefix = modifiers.map(\.symbol).joined()
        return prefix + key
    }
}

public struct ClawdmeterShortcutRegistry: Codable, Hashable, Sendable {
    public private(set) var shortcuts: [ClawdmeterShortcut]

    public init(shortcuts: [ClawdmeterShortcut] = Self.defaults) {
        self.shortcuts = shortcuts
    }

    public func grouped(query: String = "") -> [ClawdmeterCommandScope: [ClawdmeterShortcut]] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = shortcuts.filter { shortcut in
            guard !needle.isEmpty else { return true }
            return shortcut.label.lowercased().contains(needle)
                || shortcut.displayChord.lowercased().contains(needle)
                || shortcut.scope.rawValue.lowercased().contains(needle)
        }
        return Dictionary(grouping: filtered.sorted { $0.label < $1.label }, by: \.scope)
    }

    public func displayChord(for shortcut: ClawdmeterShortcut, overrides: [String: String]) -> String {
        let override = overrides[shortcut.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return override?.isEmpty == false ? override! : shortcut.displayChord
    }

    public static let defaults: [ClawdmeterShortcut] = [
        .init(id: "global.palette", label: "Open command palette", key: "K", modifiers: [.command], scope: .global, commandID: "global.palette"),
        .init(id: "global.shortcuts", label: "Show keyboard shortcuts", key: "/", modifiers: [.command], scope: .global, commandID: "global.shortcuts"),
        .init(id: "global.filePicker", label: "Open repo file picker", key: "P", modifiers: [.command], scope: .global, commandID: "global.filePicker"),
        .init(id: "nav.chat", label: "Open Chat", key: "1", modifiers: [.command], scope: .global, commandID: "nav.chat"),
        .init(id: "nav.usage", label: "Open Usage", key: "2", modifiers: [.command], scope: .global, commandID: "nav.usage"),
        .init(id: "nav.code", label: "Open Code", key: "3", modifiers: [.command], scope: .global, commandID: "nav.code"),
        .init(id: "nav.settings", label: "Open Settings", key: "4", modifiers: [.command], scope: .global, commandID: "nav.settings"),
        .init(id: "code.search", label: "Focus Code search", key: "F", modifiers: [.command, .shift], scope: .code, commandID: "code.search"),
        .init(id: "code.workspaceSwitcher", label: "Open workspace switcher", key: "O", modifiers: [.command], scope: .code, commandID: "code.workspaceSwitcher"),
        .init(id: "code.reviewPane", label: "Toggle review pane", key: "B", modifiers: [.command], scope: .code, commandID: "code.reviewPane"),
        .init(id: "session.subchat", label: "Create sub-chat", key: ";", modifiers: [.command], scope: .session, commandID: "session.subchat"),
        .init(id: "session.nextAttention", label: "Open next session needing attention", key: "'", modifiers: [.command], scope: .session, commandID: "session.nextAttention"),
        .init(id: "transcript.find", label: "Find in transcript", key: "F", modifiers: [.command], scope: .chat, commandID: "transcript.find"),
        .init(id: "transcript.nextMatch", label: "Next transcript match", key: "G", modifiers: [.command], scope: .chat, commandID: "transcript.nextMatch"),
        .init(id: "transcript.previousMatch", label: "Previous transcript match", key: "G", modifiers: [.command, .shift], scope: .chat, commandID: "transcript.previousMatch"),
        .init(id: "transcript.latest", label: "Jump to latest message", key: "Down", modifiers: [.command], scope: .chat, commandID: "transcript.latest"),
        .init(id: "transcript.lastUser", label: "Jump to last user message", key: "Up", modifiers: [.command, .shift], scope: .chat, commandID: "transcript.lastUser"),
        .init(id: "composer.send", label: "Send prompt", key: "Return", modifiers: [.command], scope: .composer, commandID: "composer.send"),
        .init(id: "composer.queue", label: "Queue follow-up", key: "Return", modifiers: [.option], scope: .composer, commandID: "composer.queue"),
        .init(id: "composer.history", label: "Open prompt history", key: "Up", modifiers: [.option], scope: .composer, commandID: "composer.history"),
        .init(id: "composer.dictation", label: "Toggle dictation", key: "M", modifiers: [.control], scope: .composer, commandID: "composer.dictation"),
        .init(id: "session.export", label: "Export open session", key: "E", modifiers: [.command, .shift], scope: .session, commandID: "session.export"),
    ]
}

public extension ClawdmeterShortcut.Modifier {
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
}
