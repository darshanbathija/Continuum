import ClawdmeterShared
import Foundation

/// Persists the last few dictation transcripts for quick copy from Voice settings.
public struct DictationHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

@MainActor
public final class DictationHistoryStore: ObservableObject {
    public static let maximumEntries = 20

    @Published public private(set) var entries: [DictationHistoryEntry] = []

    private let storeURL: URL

    public init(appSupportDirectory: URL) {
        self.storeURL = appSupportDirectory.appendingPathComponent("dictation-history.json")
        load()
    }

    public func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(DictationHistoryEntry(text: trimmed), at: 0)
        if entries.count > Self.maximumEntries {
            entries = Array(entries.prefix(Self.maximumEntries))
        }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
