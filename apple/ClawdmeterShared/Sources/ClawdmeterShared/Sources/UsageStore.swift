import Foundation
#if canImport(OSLog)
import OSLog
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Cross-target cache of the latest `UsageData` snapshot per provider.
///
/// Lives in an App Group container so the menu bar app, the widget extension,
/// and (eventually) the watch + iPhone targets all see the same bytes. Schema:
///
/// ```
/// $appGroup/usage/{providerID}.json
/// ```
///
/// File-per-provider rather than a single dictionary so that one corrupt write
/// can't take out the other provider's last-known state. Writes are atomic
/// (`Data.write(to:options:.atomic)`); reads tolerate missing/garbled files.
public struct UsageStore: Sendable {

    /// App Group identifier — must match the entitlement on every target.
    ///
    /// Personal-team apps must prefix with their team ID; paid programs can
    /// drop the prefix. We try the prefixed form first, then unprefixed, then
    /// fall back to `~/Library/Application Support/Clawdmeter`. The Mac app
    /// and widget extension converge on whichever path actually resolves.
    public static let appGroups = [
        "group.LRL8MRH6B4.ai.continuum",
        "group.ai.continuum",
    ]

    private static let logger = Logger(subsystem: "com.clawdmeter.shared", category: "UsageStore")

    /// Serialised snapshot envelope. `version` lets us evolve the format
    /// without crashing older readers in the wild. Public so the XPC-vending
    /// `UsageQueryService` in the Mac app can encode the same shape.
    public struct Envelope: Codable {
        public let version: Int
        public let providerID: String
        public let displayName: String
        public let usage: UsageData
        /// When the snapshot was last written (epoch seconds, integer
        /// resolution). Kept for backward compat with v1 readers.
        public let writtenAt: Int
        /// Sub-second-precise version of `writtenAt` (added in v2).
        /// Optional so v1-only readers can still decode v1 envelopes.
        public let writtenAtPrecise: TimeInterval?

        public init(
            version: Int,
            providerID: String,
            displayName: String,
            usage: UsageData,
            writtenAt: Int,
            writtenAtPrecise: TimeInterval? = nil
        ) {
            self.version = version
            self.providerID = providerID
            self.displayName = displayName
            self.usage = usage
            self.writtenAt = writtenAt
            self.writtenAtPrecise = writtenAtPrecise
        }
    }

    /// Root of the shared usage cache. Resolves in priority order:
    ///   1. App Group container (sandboxed builds with the entitlement)
    ///   2. `~/Library/Application Support/Clawdmeter` (dev / non-sandboxed)
    public static var containerURL: URL? {
        let fm = FileManager.default
        #if canImport(Darwin)
        for group in appGroups {
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
                logger.debug("UsageStore.containerURL → \(url.path, privacy: .public) (group=\(group, privacy: .public))")
                return url
            }
        }
        #endif
        // Fall back to a fixed user-library path that both the menu bar app
        // and any sandbox-disabled extensions can read directly. Works on
        // macOS where sandbox can be turned off; on iOS this branch is dead
        // code (sandbox is mandatory, so App Group is required).
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            logger.warning("UsageStore.containerURL → no App Group AND no AppSupport")
            return nil
        }
        let url = appSupport.appendingPathComponent("Clawdmeter", isDirectory: true)
        logger.debug("UsageStore.containerURL → \(url.path) (AppSupport fallback)")
        return url
    }

    private static var usageDirectory: URL? {
        guard let root = containerURL else { return nil }
        let dir = root.appendingPathComponent("usage", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("UsageStore.usageDirectory create failed \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return dir
    }

    private static func fileURL(for providerID: String) -> URL? {
        usageDirectory?.appendingPathComponent("\(providerID).json")
    }

    // MARK: - Storage

    private static func decodeSnapshot(_ data: Data) -> Snapshot? {
        // Some legacy snapshots on disk used snake_case keys from the
        // pre-1.x daemon. `.convertFromSnakeCase` lets us decode those
        // alongside the camelCase ones the current encoder writes.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let env: Envelope
        do {
            env = try decoder.decode(Envelope.self, from: data)
        } catch {
            logger.error("UsageStore decodeSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Prefer sub-second precision when available; fall back to
        // integer-seconds writtenAt for v1 envelopes.
        let stamp = env.writtenAtPrecise ?? TimeInterval(env.writtenAt)
        return Snapshot(
            providerID: env.providerID,
            displayName: env.displayName,
            usage: env.usage,
            writtenAt: Date(timeIntervalSince1970: stamp)
        )
    }

#if os(macOS)
    // On macOS the Mac app vends `UsageWriterProtocol` over an XPC Mach
    // service. The widget extension connects via NSXPCConnection and queries
    // the Mac app's in-memory state directly — no files, no cfprefsd, no
    // sandbox-EPERM wall. See `UsageWriterProtocol.swift` for rationale.
    //
    // `UsageStore.write` is a no-op here: the Mac app's `AppModel` is the
    // source of truth, snapshots are pulled live on widget refresh.

    @discardableResult
    public static func write(
        _ usage: UsageData,
        providerID: String,
        displayName: String
    ) -> Bool {
        true
    }

    public static func read(providerID: String) -> Snapshot? {
        guard let data = querySync({ proxy, completion in
            proxy.readSnapshot(forProviderID: providerID) { data in
                completion(data)
            }
        }) else { return nil }
        return decodeSnapshot(data)
    }

    public static func readAll() -> [Snapshot] {
        guard let blobs: [Data] = querySync({ proxy, completion in
            proxy.readAllSnapshots { blobs in
                completion(blobs)
            }
        }) else { return [] }
        return blobs
            .compactMap { decodeSnapshot($0) }
            .sorted { $0.providerID < $1.providerID }
    }

    private static func querySync<T>(
        _ body: (UsageWriterProtocol, @escaping (T?) -> Void) -> Void
    ) -> T? {
        let conn = NSXPCConnection(machServiceName: UsageWriterMachServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: UsageWriterProtocol.self)
        conn.resume()
        defer { conn.invalidate() }

        let sem = DispatchSemaphore(value: 0)
        var result: T?
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            logger.error("UsageStore XPC error: \(String(describing: error), privacy: .public)")
            sem.signal()
        } as? UsageWriterProtocol

        guard let proxy else { return nil }

        body(proxy) { value in
            result = value
            sem.signal()
        }

        let outcome = sem.wait(timeout: .now() + 2.0)
        if outcome == .timedOut {
            logger.warning("UsageStore.querySync timed out waiting for XPC reply")
        }
        return result
    }
#else
    // iOS / watchOS: everything is sandboxed uniformly, so the standard
    // App Group `UserDefaults` flow works directly. Writes from the host
    // app are visible to the widget extension because both sides are
    // sandboxed members of the same App Group.

    private static let providerIDsKey = "UsageStore.providerIDs"

    private static func key(for providerID: String) -> String {
        "UsageStore.provider.\(providerID)"
    }

    private static var sharedDefaults: UserDefaults? {
        for group in appGroups {
            if let defaults = UserDefaults(suiteName: group) {
                return defaults
            }
        }
        return nil
    }

    @discardableResult
    public static func write(
        _ usage: UsageData,
        providerID: String,
        displayName: String
    ) -> Bool {
        guard let defaults = sharedDefaults else { return false }
        let now = Date().timeIntervalSince1970
        let envelope = Envelope(
            version: 2,
            providerID: providerID,
            displayName: displayName,
            usage: usage,
            writtenAt: Int(now),
            writtenAtPrecise: now
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            logger.error("UsageStore encode envelope failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        defaults.set(data, forKey: key(for: providerID))
        var index = Set(defaults.stringArray(forKey: providerIDsKey) ?? [])
        index.insert(providerID)
        defaults.set(Array(index).sorted(), forKey: providerIDsKey)
        return true
    }

    public static func read(providerID: String) -> Snapshot? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: key(for: providerID))
        else { return nil }
        return decodeSnapshot(data)
    }

    public static func readAll() -> [Snapshot] {
        guard let defaults = sharedDefaults else { return [] }
        let ids = defaults.stringArray(forKey: providerIDsKey) ?? []
        return ids
            .compactMap { read(providerID: $0) }
            .sorted { $0.providerID < $1.providerID }
    }
#endif

    /// Read-side view of a single provider's last snapshot.
    public struct Snapshot: Sendable, Equatable {
        public let providerID: String
        public let displayName: String
        public let usage: UsageData
        public let writtenAt: Date

        public init(
            providerID: String,
            displayName: String,
            usage: UsageData,
            writtenAt: Date
        ) {
            self.providerID = providerID
            self.displayName = displayName
            self.usage = usage
            self.writtenAt = writtenAt
        }
    }

    // MARK: - Widget refresh

    /// Notify the OS that widgets backed by this provider should reload.
    /// Safe to call from any target — no-op on platforms without WidgetKit.
    public static func reloadWidgets(providerID: String? = nil) {
#if canImport(WidgetKit)
        if let providerID {
            WidgetCenter.shared.reloadTimelines(ofKind: "ClawdmeterMeter.\(providerID)")
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
#endif
    }
}
