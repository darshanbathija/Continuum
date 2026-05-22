#if os(iOS) || os(macOS) || os(tvOS) || os(visionOS)
import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(OSLog)
import OSLog
#endif

/// Cross-device usage cache backed by `NSUbiquitousKeyValueStore` (iCloud KV).
///
/// The Mac app polls `~/.codex/sessions/*.jsonl` for Codex usage and mirrors
/// the resulting `UsageData` here. iOS (which has no Codex CLI to read from)
/// reads the same store and renders the Codex card next to the live-polled
/// Claude card. Both Mac and iOS apps just need:
///
///   - iCloud entitlement with `KeyValueStore` service enabled
///   - Same `com.apple.developer.ubiquity-kvstore-identifier` value
///   - User signed into iCloud on both devices (same Apple ID)
///
/// We never put the Anthropic OAuth token here — Keychain handles that with
/// `kSecAttrSynchronizable=true`. This mirror is just the polled snapshots,
/// which are safe to expose across the user's devices.
///
/// Storage: ~300 bytes per snapshot (a few hundred bytes of JSON). Well
/// under the 1KB-per-key and 1MB-total caps that iCloud KV imposes.
///
/// watchOS isn't supported — NSUbiquitousKeyValueStore is unavailable on
/// watchOS. The Watch will get Codex via WCSession-from-iPhone in a future
/// pass; for now it stays Claude-only.
public final class UsageCloudMirror: @unchecked Sendable {

    public static let shared = UsageCloudMirror()

    private let store = NSUbiquitousKeyValueStore.default
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "UsageCloudMirror")

    /// Combine subject that fires whenever a snapshot for ANY provider is
    /// updated externally (i.e., another device pushed via iCloud) or by a
    /// local `writeSnapshot`. iOS subscribes to refresh the Codex card.
    public let didUpdate = PassthroughSubject<String, Never>()

    private var changeObserver: NSObjectProtocol?

    public init() {
        // Pull whatever's currently in iCloud KV into our local mirror.
        store.synchronize()
        changeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            self?.handleExternalChange(note: note)
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    // MARK: - Keys

    private static func key(for providerID: String) -> String {
        "cloud.usage.\(providerID)"
    }

    private static let providerIDsKey = "cloud.usage.providerIDs"

    /// Analytics snapshot mirror — plan A19. Distinct key from the live-data
    /// mirrors so iOS reads them independently.
    private static let analyticsKey = "cloud.analytics.v1"

    /// Plan A18: detect whether iCloud is actually wired up on this build /
    /// device. Returns `false` for personal-team dev accounts (no iCloud
    /// entitlement) and for users not signed into iCloud.
    public var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }

    // MARK: - Write

    /// Persist a snapshot under `cloud.usage.<providerID>`. Encodes via the
    /// same `UsageStore.Envelope` shape used locally — single decode path on
    /// both sides.
    @discardableResult
    public func writeSnapshot(
        _ usage: UsageData,
        providerID: String,
        displayName: String
    ) -> Bool {
        let envelope = UsageStore.Envelope(
            version: 1,
            providerID: providerID,
            displayName: displayName,
            usage: usage,
            writtenAt: Int(Date().timeIntervalSince1970)
        )
        guard let data = try? JSONEncoder().encode(envelope) else {
            logger.error("UsageCloudMirror.write \(providerID, privacy: .public): encode failed")
            return false
        }
        store.set(data, forKey: Self.key(for: providerID))
        var ids = Set(store.array(forKey: Self.providerIDsKey) as? [String] ?? [])
        ids.insert(providerID)
        store.set(Array(ids).sorted(), forKey: Self.providerIDsKey)
        store.synchronize()
        didUpdate.send(providerID)
        return true
    }

    // MARK: - Read

    public func readSnapshot(providerID: String) -> UsageStore.Snapshot? {
        guard let data = store.data(forKey: Self.key(for: providerID)),
              let env = try? JSONDecoder().decode(UsageStore.Envelope.self, from: data)
        else { return nil }
        return UsageStore.Snapshot(
            providerID: env.providerID,
            displayName: env.displayName,
            usage: env.usage,
            writtenAt: Date(timeIntervalSince1970: TimeInterval(env.writtenAt))
        )
    }

    public func readAll() -> [UsageStore.Snapshot] {
        let ids = (store.array(forKey: Self.providerIDsKey) as? [String]) ?? []
        return ids
            .compactMap { readSnapshot(providerID: $0) }
            .sorted { $0.providerID < $1.providerID }
    }

    private func handleExternalChange(note: Notification) {
        // The notification's userInfo contains the changed keys, but we
        // re-publish a coarse "something changed for some provider" event.
        // Callers (iOS) re-read all providers they care about.
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        for key in changedKeys {
            if key.hasPrefix("cloud.usage.") {
                let providerID = String(key.dropFirst("cloud.usage.".count))
                if providerID != "providerIDs" {
                    didUpdate.send(providerID)
                }
            } else if key == Self.analyticsKey {
                didUpdate.send("analytics")
            }
        }
    }

    // MARK: - Analytics snapshot mirror (plan A19)

    /// Persist the aggregated analytics snapshot. Plan A19: enforces the
    /// KVS total-store budget by summing all of our keys before writing;
    /// rejects writes that would push past ~900 KB headroom. Monotonic
    /// ordering is preserved because the snapshot itself carries
    /// `(computedAt, sequenceNumber)` and readers compare those.
    @discardableResult
    public func writeAnalyticsSnapshot(_ snapshot: UsageHistorySnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            logger.error("UsageCloudMirror.writeAnalyticsSnapshot: encode failed")
            return false
        }
        let ourKeys = currentKeyByteUsage()
        let withoutAnalytics = ourKeys - (store.data(forKey: Self.analyticsKey)?.count ?? 0)
        let projected = withoutAnalytics + data.count
        let budget = 900 * 1024
        if projected > budget {
            logger.error("UsageCloudMirror.writeAnalyticsSnapshot: \(projected, privacy: .public)B would exceed \(budget, privacy: .public)B budget; skipping")
            return false
        }
        store.set(data, forKey: Self.analyticsKey)
        store.synchronize()
        didUpdate.send("analytics")
        return true
    }

    public func readAnalyticsSnapshot() -> UsageHistorySnapshot? {
        guard let data = store.data(forKey: Self.analyticsKey),
              let snap = try? JSONDecoder().decode(UsageHistorySnapshot.self, from: data)
        else { return nil }
        return snap
    }

    /// Sum of byte-length of all keys we own (analytics + live mirrors).
    /// Used to enforce the KVS total-store budget.
    private func currentKeyByteUsage() -> Int {
        var sum = 0
        if let analytics = store.data(forKey: Self.analyticsKey) {
            sum += analytics.count
        }
        let ids = (store.array(forKey: Self.providerIDsKey) as? [String]) ?? []
        for id in ids {
            if let blob = store.data(forKey: Self.key(for: id)) {
                sum += blob.count
            }
        }
        return sum
    }
}
#endif
