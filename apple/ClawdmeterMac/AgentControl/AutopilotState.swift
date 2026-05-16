import Foundation
import OSLog

private let autopilotLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AutopilotState")

/// Per-session autopilot toggle state with per-repo trust list + 15-min
/// inactivity timeout (E7 from CEO+Eng review).
///
/// Sessions v2 Phase 0 ships the wire shape and persistence; Phase 7
/// wires the full timeout timer + per-repo trust prompt + banner.
@MainActor
public final class AutopilotState {
    public static let shared = AutopilotState()

    /// Sessions currently in autopilot mode. Keyed by session id.
    private var enabledSessions: Set<UUID> = []

    /// Per-session timestamp of the last agent message. Drives the
    /// 15-minute inactivity auto-disable.
    private var lastActivity: [UUID: Date] = [:]

    /// Trusted-repo allowlist; persisted to
    /// `~/.clawdmeter/autopilot-trusted-repos.json`. First toggle in a repo
    /// prompts user; subsequent toggles in the same repo are 1-tap.
    public private(set) var trustedRepoKeys: Set<String> = []

    private let storeURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autopilot-trusted-repos.json")
    }()

    private static let inactivityTimeout: TimeInterval = 15 * 60  // 15 minutes

    public init() {
        loadTrustList()
    }

    public func isEnabled(sessionId: UUID) -> Bool {
        enabledSessions.contains(sessionId)
    }

    public func setEnabled(_ enabled: Bool, sessionId: UUID) {
        if enabled {
            enabledSessions.insert(sessionId)
            lastActivity[sessionId] = Date()
            autopilotLogger.info("autopilot ON for session \(sessionId.uuidString, privacy: .public)")
        } else {
            enabledSessions.remove(sessionId)
            lastActivity.removeValue(forKey: sessionId)
            autopilotLogger.info("autopilot OFF for session \(sessionId.uuidString, privacy: .public)")
        }
    }

    /// Called from JSONL tail or chat-snapshot publisher when an agent
    /// message arrives, resetting the inactivity timer.
    public func recordActivity(sessionId: UUID) {
        guard enabledSessions.contains(sessionId) else { return }
        lastActivity[sessionId] = Date()
    }

    /// Returns the set of session ids whose autopilot expired due to
    /// inactivity. The daemon should disable them and post a notification.
    public func expiredSessions(now: Date = Date()) -> [UUID] {
        var expired: [UUID] = []
        for id in enabledSessions {
            if let last = lastActivity[id], now.timeIntervalSince(last) > Self.inactivityTimeout {
                expired.append(id)
            }
        }
        return expired
    }

    // MARK: - Per-repo trust list

    public func isRepoTrusted(_ repoKey: String) -> Bool {
        trustedRepoKeys.contains(repoKey)
    }

    public func trustRepo(_ repoKey: String) {
        trustedRepoKeys.insert(repoKey)
        saveTrustList()
    }

    public func untrustRepo(_ repoKey: String) {
        trustedRepoKeys.remove(repoKey)
        saveTrustList()
    }

    // MARK: - Persistence

    private struct TrustListFile: Codable {
        var version: Int
        var repos: [String]
    }

    private func loadTrustList() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL),
              let file = try? JSONDecoder().decode(TrustListFile.self, from: data) else {
            autopilotLogger.warning("Failed to load autopilot trust list at \(self.storeURL.path)")
            return
        }
        self.trustedRepoKeys = Set(file.repos)
    }

    private func saveTrustList() {
        let file = TrustListFile(version: 1, repos: Array(trustedRepoKeys).sorted())
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }
}
