import Foundation
import OSLog
import ClawdmeterShared

private let deviceTokenLogger = Logger(subsystem: "com.clawdmeter.mac", category: "APNSPushDeviceTokenStore")

/// E6: per-pairing iPhone APNS device-token registry on the Mac side.
///
/// The iPhone (E4) registers its remote-push device token with the Mac
/// over the relay (`RegisterDeviceToken` envelope) once it's been
/// successfully fetched from `UNUserNotificationCenter`. The Mac stores
/// the token here, scoped to the pairing session id, so the
/// `APNSGatewayClient` can look up the right destination when a push
/// trigger fires.
///
/// Storage: in-memory only. Per the design doc §5b the pairing is
/// ephemeral — re-pairing generates fresh ephemeral keys, and the iPhone
/// re-registers its device token after every re-pair. We DO persist the
/// token-to-pairing mapping to disk (`Application Support`) so a Mac
/// restart doesn't drop the pairing.
///
/// The token itself is treated as sensitive: we never log the full token
/// (only an 8-char prefix), and 410-Gone responses from the Worker drop
/// the token row immediately so a stale token doesn't keep retrying.
public final class APNSPushDeviceTokenStore: @unchecked Sendable {

    public static let shared = APNSPushDeviceTokenStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var entriesBacking: [String: Entry] = [:]

    public struct Entry: Codable, Sendable, Equatable {
        /// Raw APNS device token (64 hex chars).
        public let deviceToken: String
        /// Pairing session id this token is bound to. The Worker enforces
        /// the same tenant binding via `device-tokens.ts`.
        public let sessionId: String
        /// Bundle id of the iPhone app. Determines which APNS topic the
        /// Worker forwards to.
        public let bundleId: String
        /// When the token was last refreshed. Tokens older than 30 days
        /// without a refresh are considered stale and pruned.
        public let registeredAt: Date

        public init(deviceToken: String, sessionId: String, bundleId: String, registeredAt: Date) {
            self.deviceToken = deviceToken
            self.sessionId = sessionId
            self.bundleId = bundleId
            self.registeredAt = registeredAt
        }
    }

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("Clawdmeter", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("apns-device-tokens.json", isDirectory: false)
        }
        loadFromDisk()
    }

    // MARK: - Read

    /// Return the entry currently bound to `sessionId`, or nil if no
    /// iPhone has registered against this pairing yet.
    public func entry(forSessionId sessionId: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entriesBacking[sessionId]
    }

    /// Snapshot of every registered entry. Used by the settings UI to
    /// show "N iPhone(s) paired for push".
    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entriesBacking.values)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesBacking.count
    }

    // MARK: - Write

    /// Register or refresh a token. Idempotent — repeated calls with the
    /// same `(sessionId, deviceToken)` simply bump `registeredAt`.
    public func register(sessionId: String, deviceToken: String, bundleId: String) {
        lock.lock()
        let entry = Entry(
            deviceToken: deviceToken,
            sessionId: sessionId,
            bundleId: bundleId,
            registeredAt: Date()
        )
        entriesBacking[sessionId] = entry
        let count = entriesBacking.count
        let tokenPrefix = String(deviceToken.prefix(8))
        lock.unlock()
        deviceTokenLogger.info("Registered APNS token prefix=\(tokenPrefix, privacy: .public) session=\(String(sessionId.prefix(8)), privacy: .public) (now \(count) total)")
        persistToDisk()
    }

    /// Drop the entry for `sessionId`. Called when the user re-pairs (the
    /// old pairing's token can never reach the new iPhone) or when the
    /// Worker returns 410 Gone for that token.
    public func purge(sessionId: String) {
        lock.lock()
        let removed = entriesBacking.removeValue(forKey: sessionId)
        let count = entriesBacking.count
        lock.unlock()
        if removed != nil {
            deviceTokenLogger.info("Purged APNS token for session=\(String(sessionId.prefix(8)), privacy: .public) (now \(count) total)")
            persistToDisk()
        }
    }

    /// 410-Gone cleanup path. Locates the entry by raw device token (the
    /// HTTP response from the Worker doesn't echo the sessionId) and
    /// removes it.
    public func purgeByDeviceToken(_ deviceToken: String) {
        lock.lock()
        let toRemove = entriesBacking.first { $0.value.deviceToken == deviceToken }?.key
        if let key = toRemove {
            entriesBacking.removeValue(forKey: key)
        }
        let count = entriesBacking.count
        lock.unlock()
        if let key = toRemove {
            deviceTokenLogger.info("Purged APNS token by deviceToken for session=\(String(key.prefix(8)), privacy: .public) (now \(count) total)")
            persistToDisk()
        }
    }

    /// Drop every registered token. Used by the "Forget all pairings"
    /// destructive affordance.
    public func purgeAll() {
        lock.lock()
        entriesBacking.removeAll()
        lock.unlock()
        deviceTokenLogger.warning("Purged every APNS device-token registration")
        persistToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        entriesBacking = decoded
        deviceTokenLogger.info("Loaded \(decoded.count) APNS token(s) from disk")
    }

    private func persistToDisk() {
        lock.lock()
        let snapshot = entriesBacking
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            deviceTokenLogger.error("Failed to persist APNS token store: \(error.localizedDescription, privacy: .public)")
        }
    }
}
