import Foundation
#if canImport(OSLog)
import OSLog
#endif

private let cityLogger = Logger(subsystem: "com.clawdmeter.shared", category: "CityNamer")

/// City-namer helper. Sessions v2 Phase 9. Maintains assigned-city state
/// so the UI shows stable, unique labels across sessions.
///
/// Backed by `~/Library/Application Support/Clawdmeter/city-assignments.json`
/// on macOS so cities survive app restarts; iOS uses UserDefaults under
/// `clawdmeter.cityAssignments` for the same purpose.
@MainActor
public final class CityNamer: ObservableObject {

    public static let shared = CityNamer()

    /// Session id → assigned city. Stable across runs.
    @Published public private(set) var assignments: [UUID: String] = [:]

    private let storeURL: URL?

    public init() {
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("Clawdmeter", isDirectory: true) {
            do {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            } catch {
                cityLogger.error("createDirectory(\(support.path, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
            self.storeURL = support.appendingPathComponent("city-assignments.json")
        } else {
            cityLogger.error("applicationSupportDirectory unavailable — city assignments will not persist this run")
            self.storeURL = nil
        }
        load()
    }

    public func cityName(for sessionId: UUID) -> String {
        if let existing = assignments[sessionId] {
            return existing
        }
        let taken = Set(assignments.values)
        let picked = CityPool.uniqueCityName(for: sessionId, taken: taken)
        assignments[sessionId] = picked
        save()
        return picked
    }

    public func release(_ sessionId: UUID) {
        if assignments.removeValue(forKey: sessionId) != nil {
            save()
        }
    }

    // MARK: - Persistence

    private struct StoreFile: Codable {
        var version: Int
        var assignments: [String: String]  // UUID.uuidString → city
    }

    private func load() {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            cityLogger.error("read \(storeURL.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let file: StoreFile
        do {
            file = try JSONDecoder().decode(StoreFile.self, from: data)
        } catch {
            cityLogger.error("decode \(storeURL.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var loaded: [UUID: String] = [:]
        for (key, value) in file.assignments {
            if let uuid = UUID(uuidString: key) {
                loaded[uuid] = value
            }
        }
        self.assignments = loaded
    }

    private func save() {
        guard let storeURL else { return }
        let raw: [String: String] = assignments.reduce(into: [:]) { acc, pair in
            acc[pair.key.uuidString] = pair.value
        }
        let file = StoreFile(version: 1, assignments: raw)
        let data: Data
        do {
            data = try JSONEncoder().encode(file)
        } catch {
            cityLogger.error("encode city-assignments failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            cityLogger.error("write \(storeURL.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
