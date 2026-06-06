import Foundation
import CryptoKit
import ClawdmeterShared
import OSLog

private let outboxLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MobileCommandOutbox")

/// Server-side dedup + receipt cache for iOS-originated write commands.
///
/// Every write endpoint (`/sessions/:id/send`, `/approve-plan`,
/// `/interrupt`, `/model`, `/effort`, `/mode`, `/autopilot`,
/// `/ab-pair/pick-winner`, `/create-pr`, `/review-pr`, `/merge`) routes through this
/// actor when the request carries a `MobileCommandEnvelope.idempotencyKey`.
///
/// Behavior:
/// - First request with a fresh key processes normally; we cache the
///   response bytes + receipt under `key` so a replayed request with
///   the same key returns the identical response without re-executing
///   the side effect (no double-send, no double-merge).
/// - Bounded LRU at 256 entries with a 24-hour TTL — flushes anything
///   older than 24h on every access. The 24h window matches the
///   `~/.clawdmeter/audit/mobile-commands.jsonl` rotation cadence so
///   the in-memory cache and the on-disk audit trail are roughly
///   coterminous.
/// - On startup, the daemon replays the last 256 audit entries to
///   re-seed the receipt cache. The replayed entries only carry the
///   receipt (no cached response body — the response shape is endpoint-
///   specific and we don't want to leak content across rotations). A
///   replay-hit is reported with status `.acknowledged` and serves as
///   "we already saw this; the side effect already happened" — clients
///   that want full body fidelity should retry within the daemon's
///   lifetime.
public actor MobileCommandOutbox {

    public struct CachedEntry: Sendable {
        public let receipt: MobileCommandReceipt
        public let kind: MobileCommandKind
        public let responseBody: Data?
        public let responseContentType: String
        public let responseStatus: Int
        public let cachedAt: Date
        /// Hex SHA-256 of the original request payload. On replay,
        /// `tryReplayIdempotent` compares against the incoming envelope's
        /// payloadHash so a key reused with edited payload (e.g. user
        /// tapped Clone, edited the spec, tapped Clone again with the
        /// SAME persisted key) is rejected instead of silently replaying
        /// the wrong response. nil for receipts replayed from the audit
        /// log on daemon restart (we don't carry the original payload
        /// through the JSONL).
        public let payloadHash: String?

        public init(
            receipt: MobileCommandReceipt,
            kind: MobileCommandKind,
            responseBody: Data?,
            responseContentType: String = "application/json",
            responseStatus: Int = 200,
            cachedAt: Date = Date(),
            payloadHash: String? = nil
        ) {
            self.receipt = receipt
            self.kind = kind
            self.responseBody = responseBody
            self.responseContentType = responseContentType
            self.responseStatus = responseStatus
            self.cachedAt = cachedAt
            self.payloadHash = payloadHash
        }
    }

    private var cache: [String: CachedEntry] = [:]
    private var insertionOrder: [String] = []
    /// Keys currently being processed by a request handler. Used to gate
    /// concurrent same-key requests so two simultaneous clones with the
    /// same idempotency key don't both pass the nil-cache check + run
    /// twice. Cleared in `releaseInFlight(_:)` from a defer block.
    private var inFlight: Set<String> = []

    /// Upper bound on resident entries before LRU eviction kicks in.
    /// At 256 entries x ~1KB cached response = ~256KB worst case, well
    /// under any sane RSS pressure.
    public let capacity: Int

    /// Soft expiry. Entries older than `ttl` are evicted on lookup so
    /// a quiet client can't pin a stale receipt forever.
    public let ttl: TimeInterval

    public init(capacity: Int = 256, ttl: TimeInterval = 24 * 3600) {
        self.capacity = capacity
        self.ttl = ttl
    }

    // MARK: - Lookup

    /// Returns the cached entry under `key`, or nil if absent / expired.
    /// Side-effecting: evicts expired entries it walks past.
    public func entry(forKey key: String) -> CachedEntry? {
        guard let cached = cache[key] else { return nil }
        if Date().timeIntervalSince(cached.cachedAt) > ttl {
            cache.removeValue(forKey: key)
            if let idx = insertionOrder.firstIndex(of: key) {
                insertionOrder.remove(at: idx)
            }
            return nil
        }
        return cached
    }

    public enum ReservationResult: Sendable {
        case noKey
        case cached(CachedEntry)
        case inFlight
        case reserved
    }

    /// Atomically checks for a cached receipt and reserves a fresh key.
    /// Callers that receive `.reserved` must release the key from a defer
    /// after recording or abandoning the command.
    public func entryOrReserve(key: String?) -> ReservationResult {
        guard let key, !key.isEmpty else { return .noKey }
        if let cached = entry(forKey: key) { return .cached(cached) }
        if inFlight.contains(key) { return .inFlight }
        inFlight.insert(key)
        return .reserved
    }

    // MARK: - Record

    /// Cache a freshly-processed command's receipt + response. Subsequent
    /// retries of the same `key` return the cached entry verbatim.
    @discardableResult
    public func record(
        key: String,
        kind: MobileCommandKind,
        responseBody: Data?,
        responseContentType: String = "application/json",
        responseStatus: Int = 200,
        processedAt: Date = Date(),
        serverReceiptId: String = UUID().uuidString,
        payloadHash: String? = nil
    ) -> CachedEntry {
        let receipt = MobileCommandReceipt(
            idempotencyKey: key,
            status: .acknowledged,
            receivedAt: processedAt,
            processedAt: processedAt,
            serverReceiptId: serverReceiptId
        )
        let entry = CachedEntry(
            receipt: receipt,
            kind: kind,
            responseBody: responseBody,
            responseContentType: responseContentType,
            responseStatus: responseStatus,
            cachedAt: processedAt,
            payloadHash: payloadHash
        )
        upsert(key: key, entry: entry)
        return entry
    }

    // MARK: - In-flight reservation

    /// Try to mark `key` as currently being processed. Returns `true` if
    /// reserved (caller proceeds with work + must release in defer);
    /// returns `false` if another concurrent request is already
    /// processing this key (caller should return 409 Conflict).
    /// Idempotency-key collisions across different handlers (e.g. the
    /// same key submitted for clone + open-local) collide here too,
    /// which is the correct behavior — the daemon's audit log records
    /// the first one's outcome, and the second is genuinely ambiguous.
    public func tryReserveInFlight(_ key: String) -> Bool {
        if inFlight.contains(key) { return false }
        inFlight.insert(key)
        return true
    }

    /// Pair with `tryReserveInFlight`. Always call in a defer so a
    /// thrown error from the handler doesn't pin the slot forever.
    public func releaseInFlight(_ key: String) {
        inFlight.remove(key)
    }

    /// Cache a failed command so the next retry sees the failure
    /// instead of silently re-attempting. Clients should resend with
    /// a NEW idempotency key after fixing whatever caused the
    /// failure; this entry is here so a dumb-retry doesn't repeat the
    /// same broken request.
    @discardableResult
    public func recordFailure(
        key: String,
        kind: MobileCommandKind,
        error: String,
        responseStatus: Int,
        responseBody: Data? = nil,
        processedAt: Date = Date(),
        serverReceiptId: String = UUID().uuidString,
        payloadHash: String? = nil
    ) -> CachedEntry {
        let receipt = MobileCommandReceipt(
            idempotencyKey: key,
            status: .failed,
            receivedAt: processedAt,
            processedAt: processedAt,
            serverReceiptId: serverReceiptId,
            error: error
        )
        let entry = CachedEntry(
            receipt: receipt,
            kind: kind,
            responseBody: responseBody,
            responseContentType: "application/json",
            responseStatus: responseStatus,
            cachedAt: processedAt,
            payloadHash: payloadHash
        )
        upsert(key: key, entry: entry)
        return entry
    }

    private func upsert(key: String, entry: CachedEntry) {
        if cache[key] != nil, let idx = insertionOrder.firstIndex(of: key) {
            insertionOrder.remove(at: idx)
        }
        cache[key] = entry
        insertionOrder.append(key)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while insertionOrder.count > capacity {
            let oldest = insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    // MARK: - Replay

    /// On startup, walk the last `capacity` entries from the JSONL audit
    /// stream and seed the cache with receipt-only entries (no response
    /// body). The receipts are flagged with status `.acknowledged` so
    /// post-restart retries from iOS see "already processed" and stop
    /// retrying. Response bodies are not replayed because the daemon
    /// can't reconstruct the endpoint-specific shape; iOS gracefully
    /// degrades to "we don't know what the response said, but the
    /// server claims it processed."
    public func replayFromAuditLog(_ log: AuditLog = .shared) async {
        let lines = await log.recentEntries(kind: "mobile-commands", limit: capacity)
        var seeded = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let key = dict["idempotencyKey"] as? String,
                  let kindRaw = dict["command"] as? String,
                  let statusRaw = dict["status"] as? String
            else { continue }
            let kind = MobileCommandKind(rawValue: kindRaw) ?? .send
            let status = MobileCommandStatus(rawValue: statusRaw) ?? .acknowledged
            let serverReceiptId = (dict["serverReceiptId"] as? String) ?? UUID().uuidString
            // Pull payloadHash out of the audit row so the 422 mismatch
            // gate works against post-restart replayed entries too
            // (Codex R4 #1 fix). Without this, a retry with edited
            // payload after daemon restart would silently replay the
            // wrong response.
            let payloadHash = dict["payloadHash"] as? String
            let receipt = MobileCommandReceipt(
                idempotencyKey: key,
                status: status,
                receivedAt: Date(),
                processedAt: Date(),
                serverReceiptId: serverReceiptId
            )
            let entry = CachedEntry(
                receipt: receipt,
                kind: kind,
                responseBody: nil,
                responseStatus: status == .failed ? 500 : 200,
                cachedAt: Date(),
                payloadHash: payloadHash
            )
            upsert(key: key, entry: entry)
            seeded += 1
        }
        outboxLogger.info("Replayed \(seeded) entries from mobile-commands.jsonl")
    }

    // MARK: - Inspection (tests + diagnostics)

    public func count() -> Int { cache.count }
}

/// Convenience: SHA-256 hex of an arbitrary request body, used by the
/// audit log to record a non-PII fingerprint. The same input produces
/// the same hash so duplicate-detection still works across restarts.
public enum MobileCommandPayloadHasher {
    public static func hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
