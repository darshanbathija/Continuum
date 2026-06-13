import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Network)
import Network
#endif

/// Probes whether the client can reach a Tailscale MagicDNS host (R1 1B-TS).
public enum TailnetReachability: Sendable {

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedOnTailnet: Bool?
    private nonisolated(unsafe) static var cacheExpiresAt: Date = .distantPast

    /// True when the host appears to be on an active tailnet.
    public static func isOnTailnet(now: Date = Date()) -> Bool {
        cacheLock.lock()
        if let cached = cachedOnTailnet, now < cacheExpiresAt {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let reachable = probeTailnetInterface() || hostNameOnTailnet()
        cacheLock.lock()
        cachedOnTailnet = reachable
        cacheExpiresAt = now.addingTimeInterval(30)
        cacheLock.unlock()
        return reachable
    }

    /// TCP probe a specific MagicDNS hostname (used when pairing a device).
    public static func canReach(hostname: String, port: Int, timeout: TimeInterval = 2) async -> Bool {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
#if canImport(Network)
        return await withCheckedContinuation { continuation in
            let conn = NWConnection(
                host: NWEndpoint.Host(trimmed),
                port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 21731,
                using: .tcp
            )
            let lock = NSLock()
            var resumed = false
            func finish(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                continuation.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
#else
        return false
#endif
    }

    public static func invalidateCache() {
        cacheLock.lock()
        cachedOnTailnet = nil
        cacheExpiresAt = .distantPast
        cacheLock.unlock()
    }

    private static func hostNameOnTailnet() -> Bool {
        ProcessInfo.processInfo.hostName.contains(".ts.net")
    }

    private static func probeTailnetInterface() -> Bool {
#if canImport(Darwin)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == AF_INET else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("utun") || name.hasPrefix("tailscale") else { continue }
            var storage = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var ip = in_addr(s_addr: storage.sin_addr.s_addr)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            if String(cString: buffer).hasPrefix("100.") { return true }
        }
#endif
        return false
    }
}
