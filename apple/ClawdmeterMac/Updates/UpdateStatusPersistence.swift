import Foundation

/// Persists the last completed Sparkle probe so manual "Check for Updates"
/// can surface status immediately instead of waiting on the network.
enum UpdateStatusPersistence {
    private static let storageKey = "update.lastKnownStatus"

    enum Record: Codable, Equatable {
        case upToDate(lastCheckedAt: Date?)
        case updateAvailable(SparkleUpdateInfo)
    }

    static func load() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

extension SparkleUpdateInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case version, displayVersion, title, releaseNotesURL, fullReleaseNotesURL, downloadURL, minimumSystemVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        displayVersion = try container.decodeIfPresent(String.self, forKey: .displayVersion) ?? version
        title = try container.decodeIfPresent(String.self, forKey: .title)
        releaseNotesURL = try container.decodeIfPresent(URL.self, forKey: .releaseNotesURL)
        fullReleaseNotesURL = try container.decodeIfPresent(URL.self, forKey: .fullReleaseNotesURL)
        downloadURL = try container.decodeIfPresent(URL.self, forKey: .downloadURL)
        minimumSystemVersion = try container.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(displayVersion, forKey: .displayVersion)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(releaseNotesURL, forKey: .releaseNotesURL)
        try container.encodeIfPresent(fullReleaseNotesURL, forKey: .fullReleaseNotesURL)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(minimumSystemVersion, forKey: .minimumSystemVersion)
    }
}
