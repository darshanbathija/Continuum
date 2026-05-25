import Foundation
#if canImport(Combine)
import Combine
#endif

public struct ViewedFileState: Codable, Hashable, Sendable {
    public var path: String
    public var contentHash: String
    public var viewedAt: Date

    public init(path: String, contentHash: String, viewedAt: Date = Date()) {
        self.path = path
        self.contentHash = contentHash
        self.viewedAt = viewedAt
    }
}

public struct SavedPromptState: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, body: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }
}

public struct RepoIdentityBadge: Codable, Hashable, Sendable {
    public var repoKey: String
    public var displayName: String
    public var symbol: String
    public var colorHex: String
    public var remoteHost: String?
    public var remoteSlug: String?
    public var iconURL: String?
    public var emoji: String?
    public var updatedAt: Date

    public init(
        repoKey: String,
        displayName: String,
        symbol: String,
        colorHex: String,
        remoteHost: String? = nil,
        remoteSlug: String? = nil,
        iconURL: String? = nil,
        emoji: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.repoKey = repoKey
        self.displayName = displayName
        self.symbol = symbol
        self.colorHex = colorHex
        self.remoteHost = remoteHost
        self.remoteSlug = remoteSlug
        self.iconURL = iconURL
        self.emoji = emoji
        self.updatedAt = updatedAt
    }
}

public enum DiffDisplayMode: String, Codable, CaseIterable, Hashable, Sendable {
    case unified
    case split

    public var label: String {
        switch self {
        case .unified: return "Unified"
        case .split: return "Split"
        }
    }
}

public enum CodeSyntaxTheme: String, Codable, CaseIterable, Hashable, Sendable {
    case tahoe
    case graphite
    case xcode

    public var label: String {
        switch self {
        case .tahoe: return "Tahoe"
        case .graphite: return "Graphite"
        case .xcode: return "Xcode"
        }
    }
}

public enum FileReviewDisposition: String, Codable, Hashable, Sendable {
    case approved
    case changesRequested

    public var label: String {
        switch self {
        case .approved: return "Reviewed"
        case .changesRequested: return "Needs changes"
        }
    }
}

public struct NotificationPresentationPreferences: Codable, Hashable, Sendable {
    public var dndEnabled: Bool
    public var batchBanners: Bool
    public var playChimes: Bool
    public var sensitivePreviews: Bool
    public var mutedEventIDs: Set<String>

    public init(
        dndEnabled: Bool = false,
        batchBanners: Bool = true,
        playChimes: Bool = true,
        sensitivePreviews: Bool = false,
        mutedEventIDs: Set<String> = []
    ) {
        self.dndEnabled = dndEnabled
        self.batchBanners = batchBanners
        self.playChimes = playChimes
        self.sensitivePreviews = sensitivePreviews
        self.mutedEventIDs = mutedEventIDs
    }
}

public struct SessionPresentationSnapshot: Codable, Hashable, Sendable {
    public var pinnedSessionIds: [UUID]
    public var unreadSessionIds: Set<UUID>
    public var titleOverrides: [UUID: String]
    public var snoozedUntil: [UUID: Date]
    public var mutedSessionIds: Set<UUID>
    public var colorTags: [UUID: String]
    public var messageBookmarks: [UUID: Set<String>]
    public var viewedFiles: [UUID: [ViewedFileState]]
    public var commandRecents: [String]
    public var promptHistory: [String]
    public var savedPrompts: [SavedPromptState]
    public var shortcutOverrides: [String: String]
    public var recentPathActions: [String]
    public var externalToolPreferences: [String: String]
    public var repoIdentityBadges: [String: RepoIdentityBadge]
    public var syntaxTheme: CodeSyntaxTheme
    public var diffDisplayMode: DiffDisplayMode
    public var collapsedDiffHunks: [UUID: Set<String>]
    public var fileReviewDispositions: [UUID: [String: FileReviewDisposition]]
    public var exportedSessionURLs: [String]
    public var notificationPreferences: NotificationPresentationPreferences
    public var externalEditorIdentifier: String?
    public var updatedAt: Date

    public init(
        pinnedSessionIds: [UUID] = [],
        unreadSessionIds: Set<UUID> = [],
        titleOverrides: [UUID: String] = [:],
        snoozedUntil: [UUID: Date] = [:],
        mutedSessionIds: Set<UUID> = [],
        colorTags: [UUID: String] = [:],
        messageBookmarks: [UUID: Set<String>] = [:],
        viewedFiles: [UUID: [ViewedFileState]] = [:],
        commandRecents: [String] = [],
        promptHistory: [String] = [],
        savedPrompts: [SavedPromptState] = [],
        shortcutOverrides: [String: String] = [:],
        recentPathActions: [String] = [],
        externalToolPreferences: [String: String] = [:],
        repoIdentityBadges: [String: RepoIdentityBadge] = [:],
        syntaxTheme: CodeSyntaxTheme = .tahoe,
        diffDisplayMode: DiffDisplayMode = .unified,
        collapsedDiffHunks: [UUID: Set<String>] = [:],
        fileReviewDispositions: [UUID: [String: FileReviewDisposition]] = [:],
        exportedSessionURLs: [String] = [],
        notificationPreferences: NotificationPresentationPreferences = NotificationPresentationPreferences(),
        externalEditorIdentifier: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.pinnedSessionIds = pinnedSessionIds
        self.unreadSessionIds = unreadSessionIds
        self.titleOverrides = titleOverrides
        self.snoozedUntil = snoozedUntil
        self.mutedSessionIds = mutedSessionIds
        self.colorTags = colorTags
        self.messageBookmarks = messageBookmarks
        self.viewedFiles = viewedFiles
        self.commandRecents = commandRecents
        self.promptHistory = promptHistory
        self.savedPrompts = savedPrompts
        self.shortcutOverrides = shortcutOverrides
        self.recentPathActions = recentPathActions
        self.externalToolPreferences = externalToolPreferences
        self.repoIdentityBadges = repoIdentityBadges
        self.syntaxTheme = syntaxTheme
        self.diffDisplayMode = diffDisplayMode
        self.collapsedDiffHunks = collapsedDiffHunks
        self.fileReviewDispositions = fileReviewDispositions
        self.exportedSessionURLs = exportedSessionURLs
        self.notificationPreferences = notificationPreferences
        self.externalEditorIdentifier = externalEditorIdentifier
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pinnedSessionIds = try c.decodeIfPresent([UUID].self, forKey: .pinnedSessionIds) ?? []
        self.unreadSessionIds = try c.decodeIfPresent(Set<UUID>.self, forKey: .unreadSessionIds) ?? []
        self.titleOverrides = try c.decodeIfPresent([UUID: String].self, forKey: .titleOverrides) ?? [:]
        self.snoozedUntil = try c.decodeIfPresent([UUID: Date].self, forKey: .snoozedUntil) ?? [:]
        self.mutedSessionIds = try c.decodeIfPresent(Set<UUID>.self, forKey: .mutedSessionIds) ?? []
        self.colorTags = try c.decodeIfPresent([UUID: String].self, forKey: .colorTags) ?? [:]
        self.messageBookmarks = try c.decodeIfPresent([UUID: Set<String>].self, forKey: .messageBookmarks) ?? [:]
        self.viewedFiles = try c.decodeIfPresent([UUID: [ViewedFileState]].self, forKey: .viewedFiles) ?? [:]
        self.commandRecents = try c.decodeIfPresent([String].self, forKey: .commandRecents) ?? []
        self.promptHistory = try c.decodeIfPresent([String].self, forKey: .promptHistory) ?? []
        self.savedPrompts = try c.decodeIfPresent([SavedPromptState].self, forKey: .savedPrompts) ?? []
        self.shortcutOverrides = try c.decodeIfPresent([String: String].self, forKey: .shortcutOverrides) ?? [:]
        self.recentPathActions = try c.decodeIfPresent([String].self, forKey: .recentPathActions) ?? []
        self.externalToolPreferences = try c.decodeIfPresent([String: String].self, forKey: .externalToolPreferences) ?? [:]
        self.repoIdentityBadges = try c.decodeIfPresent([String: RepoIdentityBadge].self, forKey: .repoIdentityBadges) ?? [:]
        self.syntaxTheme = try c.decodeIfPresent(CodeSyntaxTheme.self, forKey: .syntaxTheme) ?? .tahoe
        self.diffDisplayMode = try c.decodeIfPresent(DiffDisplayMode.self, forKey: .diffDisplayMode) ?? .unified
        self.collapsedDiffHunks = try c.decodeIfPresent([UUID: Set<String>].self, forKey: .collapsedDiffHunks) ?? [:]
        self.fileReviewDispositions = try c.decodeIfPresent([UUID: [String: FileReviewDisposition]].self, forKey: .fileReviewDispositions) ?? [:]
        self.exportedSessionURLs = try c.decodeIfPresent([String].self, forKey: .exportedSessionURLs) ?? []
        self.notificationPreferences = try c.decodeIfPresent(NotificationPresentationPreferences.self, forKey: .notificationPreferences) ?? NotificationPresentationPreferences()
        self.externalEditorIdentifier = try c.decodeIfPresent(String.self, forKey: .externalEditorIdentifier)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case pinnedSessionIds
        case unreadSessionIds
        case titleOverrides
        case snoozedUntil
        case mutedSessionIds
        case colorTags
        case messageBookmarks
        case viewedFiles
        case commandRecents
        case promptHistory
        case savedPrompts
        case shortcutOverrides
        case recentPathActions
        case externalToolPreferences
        case repoIdentityBadges
        case syntaxTheme
        case diffDisplayMode
        case collapsedDiffHunks
        case fileReviewDispositions
        case exportedSessionURLs
        case notificationPreferences
        case externalEditorIdentifier
        case updatedAt
    }
}

public final class SessionPresentationStore: ObservableObject, @unchecked Sendable {
    @Published public private(set) var snapshot: SessionPresentationSnapshot
    private let storeURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(storeURL: URL) {
        self.storeURL = storeURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? decoder.decode(SessionPresentationSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = SessionPresentationSnapshot()
        }
    }

    public static func defaultStoreURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent("session-presentation.json")
    }

    public func update(_ mutate: (inout SessionPresentationSnapshot) -> Void) throws {
        mutate(&snapshot)
        snapshot.updatedAt = Date()
        try save()
    }

    public func togglePin(_ id: UUID) throws {
        try update { snapshot in
            if snapshot.pinnedSessionIds.contains(id) {
                snapshot.pinnedSessionIds.removeAll { $0 == id }
            } else {
                snapshot.pinnedSessionIds.append(id)
            }
        }
    }

    public func movePinnedSession(_ id: UUID, offset: Int) throws {
        try update { snapshot in
            guard let index = snapshot.pinnedSessionIds.firstIndex(of: id) else { return }
            let target = min(max(index + offset, 0), max(snapshot.pinnedSessionIds.count - 1, 0))
            guard target != index else { return }
            snapshot.pinnedSessionIds.remove(at: index)
            snapshot.pinnedSessionIds.insert(id, at: target)
        }
    }

    public func markUnread(_ id: UUID, unread: Bool) throws {
        try update { snapshot in
            if unread { snapshot.unreadSessionIds.insert(id) }
            else { snapshot.unreadSessionIds.remove(id) }
        }
    }

    public func setTitleOverride(_ id: UUID, title: String?) throws {
        try update { snapshot in
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                snapshot.titleOverrides.removeValue(forKey: id)
            } else {
                snapshot.titleOverrides[id] = trimmed
            }
        }
    }

    public func snooze(_ id: UUID, until date: Date?) throws {
        try update { snapshot in
            if let date {
                snapshot.snoozedUntil[id] = date
            } else {
                snapshot.snoozedUntil.removeValue(forKey: id)
            }
        }
    }

    public func setMuted(_ id: UUID, muted: Bool) throws {
        try update { snapshot in
            if muted { snapshot.mutedSessionIds.insert(id) }
            else { snapshot.mutedSessionIds.remove(id) }
        }
    }

    public func setColorTag(_ id: UUID, tag: String?) throws {
        try update { snapshot in
            let trimmed = tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                snapshot.colorTags.removeValue(forKey: id)
            } else {
                snapshot.colorTags[id] = trimmed
            }
        }
    }

    public func toggleMessageBookmark(sessionId: UUID, messageId: String) throws {
        try update { snapshot in
            var set = snapshot.messageBookmarks[sessionId] ?? []
            if set.contains(messageId) {
                set.remove(messageId)
            } else {
                set.insert(messageId)
            }
            if set.isEmpty {
                snapshot.messageBookmarks.removeValue(forKey: sessionId)
            } else {
                snapshot.messageBookmarks[sessionId] = set
            }
        }
    }

    public func recordViewedFile(sessionId: UUID, path: String, contentHash: String, viewedAt: Date = Date()) throws {
        try update { snapshot in
            var files = snapshot.viewedFiles[sessionId] ?? []
            files.removeAll { $0.path == path }
            files.append(ViewedFileState(path: path, contentHash: contentHash, viewedAt: viewedAt))
            snapshot.viewedFiles[sessionId] = files
        }
    }

    public func recordCommand(_ id: String, limit: Int = 12) throws {
        try update { snapshot in
            snapshot.commandRecents.removeAll { $0 == id }
            snapshot.commandRecents.insert(id, at: 0)
            if snapshot.commandRecents.count > limit {
                snapshot.commandRecents = Array(snapshot.commandRecents.prefix(limit))
            }
        }
    }

    public func recordPathAction(_ path: String, limit: Int = 20) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update { snapshot in
            snapshot.recentPathActions.removeAll { $0 == trimmed }
            snapshot.recentPathActions.insert(trimmed, at: 0)
            if snapshot.recentPathActions.count > limit {
                snapshot.recentPathActions = Array(snapshot.recentPathActions.prefix(limit))
            }
        }
    }

    public func recordPrompt(_ prompt: String, limit: Int = 50) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update { snapshot in
            snapshot.promptHistory.removeAll { $0 == trimmed }
            snapshot.promptHistory.insert(trimmed, at: 0)
            if snapshot.promptHistory.count > limit {
                snapshot.promptHistory = Array(snapshot.promptHistory.prefix(limit))
            }
        }
    }

    public func savePrompt(title: String, body: String) throws {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try update { snapshot in
            let title = trimmedTitle.isEmpty ? String(trimmedBody.prefix(48)) : trimmedTitle
            snapshot.savedPrompts.removeAll { $0.body == trimmedBody || $0.title == title }
            snapshot.savedPrompts.insert(SavedPromptState(title: title, body: trimmedBody), at: 0)
            if snapshot.savedPrompts.count > 24 {
                snapshot.savedPrompts = Array(snapshot.savedPrompts.prefix(24))
            }
        }
    }

    public func deleteSavedPrompt(_ id: UUID) throws {
        try update { snapshot in
            snapshot.savedPrompts.removeAll { $0.id == id }
        }
    }

    public func setExternalEditorIdentifier(_ identifier: String?) throws {
        try update { snapshot in
            let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            snapshot.externalEditorIdentifier = trimmed.isEmpty ? nil : trimmed
        }
    }

    public func setShortcutOverride(id: String, chord: String?) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        try update { snapshot in
            let trimmed = chord?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                snapshot.shortcutOverrides.removeValue(forKey: trimmedID)
            } else {
                snapshot.shortcutOverrides[trimmedID] = trimmed
            }
        }
    }

    public func cacheRepoIdentity(_ badge: RepoIdentityBadge) throws {
        try update { snapshot in
            snapshot.repoIdentityBadges[badge.repoKey] = badge
        }
    }

    public func setSyntaxTheme(_ theme: CodeSyntaxTheme) throws {
        try update { snapshot in
            snapshot.syntaxTheme = theme
        }
    }

    public func setDiffDisplayMode(_ mode: DiffDisplayMode) throws {
        try update { snapshot in
            snapshot.diffDisplayMode = mode
        }
    }

    public func setDiffHunkCollapsed(sessionId: UUID, hunkId: String, collapsed: Bool) throws {
        try update { snapshot in
            var hunks = snapshot.collapsedDiffHunks[sessionId] ?? []
            if collapsed {
                hunks.insert(hunkId)
            } else {
                hunks.remove(hunkId)
            }
            if hunks.isEmpty {
                snapshot.collapsedDiffHunks.removeValue(forKey: sessionId)
            } else {
                snapshot.collapsedDiffHunks[sessionId] = hunks
            }
        }
    }

    public func setFileReviewDisposition(sessionId: UUID, path: String, disposition: FileReviewDisposition?) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update { snapshot in
            var dispositions = snapshot.fileReviewDispositions[sessionId] ?? [:]
            if let disposition {
                dispositions[trimmed] = disposition
            } else {
                dispositions.removeValue(forKey: trimmed)
            }
            if dispositions.isEmpty {
                snapshot.fileReviewDispositions.removeValue(forKey: sessionId)
            } else {
                snapshot.fileReviewDispositions[sessionId] = dispositions
            }
        }
    }

    public func recordExportedSessionURL(_ path: String, limit: Int = 10) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update { snapshot in
            snapshot.exportedSessionURLs.removeAll { $0 == trimmed }
            snapshot.exportedSessionURLs.insert(trimmed, at: 0)
            if snapshot.exportedSessionURLs.count > limit {
                snapshot.exportedSessionURLs = Array(snapshot.exportedSessionURLs.prefix(limit))
            }
        }
    }

    public func setNotificationPreferences(_ preferences: NotificationPresentationPreferences) throws {
        try update { snapshot in
            snapshot.notificationPreferences = preferences
        }
    }

    private func save() throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: storeURL, options: [.atomic])
    }
}
