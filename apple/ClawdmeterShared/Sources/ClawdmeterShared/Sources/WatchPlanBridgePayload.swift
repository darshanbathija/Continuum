// Typed Codable payload for WatchPlanBridge (eng review 2D fix).
//
// v0.5.11 grew WatchPlanBridge via loose-keyed dict access:
//   context["planWaitingCount"] = N
//   context["latestGoal"] = goal
//   context["sessionsSummaryJSON"] = json
//   ...
// v0.6.0 would add a third loose key (currentTaskHeadline). Each new
// field is a coordination point between iOS sender + Watch receiver,
// fragile to typos.
//
// This file introduces a Codable struct that defines the schema. The
// runtime context dict shape is preserved so v5/v6 watch installs keep
// reading via their existing dict-keyed access. New v0.6.0 receivers
// can decode the same JSON payload as a `WatchPlanBridge.Payload`
// struct for compile-time safety.
//
// Diff-before-send guard (eng review 4B fix): the sender hashes the
// encoded JSON and skips the WCSession.updateApplicationContext call
// when the payload is unchanged. Saves Watch wake-ups during agent
// streaming when only the timestamp changes.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum WatchPlanBridge {
    /// Typed schema for the WCSession context. Encoded fields use the
    /// same JSON keys that v0.5.11's loose-dict access reads — so a
    /// v5 receiver decoding via `context["planWaitingCount"] as? Int`
    /// still works against a v7 payload.
    public struct Payload: Codable, Sendable, Equatable {
        // v0.5+ — plan-waiting badge (D10).
        public var planWaitingCount: Int?
        public var latestGoal: String?
        public var latestPlanSummary: String?
        public var latestSessionId: String?
        // v0.5+ — Sessions v2 phase 6 (Watch session list).
        public var sessionsSummaryJSON: String?
        // v0.6.0 — Antigravity 2 task complication. First 18 chars of
        // task.md headline. Receiver writes to App Group UserDefaults
        // and the .accessoryCorner complication reads from there.
        public var currentTaskHeadline: String?
        // v0.7.8 — Codex SDK task complication. First 18 chars of the
        // active Codex SDK session's in-progress todo (falls back to
        // first pending). Same pattern as currentTaskHeadline:
        // receiver writes to App Group UserDefaults and the watch
        // CodexTaskComplication reads from there.
        public var codexCurrentTodo: String?
        /// Server-time of payload send. Lets the watch detect stale
        /// payloads (>30s old) and pull a fresh context.
        public var sentAt: Date

        public init(
            planWaitingCount: Int? = nil,
            latestGoal: String? = nil,
            latestPlanSummary: String? = nil,
            latestSessionId: String? = nil,
            sessionsSummaryJSON: String? = nil,
            currentTaskHeadline: String? = nil,
            codexCurrentTodo: String? = nil,
            sentAt: Date = Date()
        ) {
            self.planWaitingCount = planWaitingCount
            self.latestGoal = latestGoal
            self.latestPlanSummary = latestPlanSummary
            self.latestSessionId = latestSessionId
            self.sessionsSummaryJSON = sessionsSummaryJSON
            self.currentTaskHeadline = currentTaskHeadline
            self.codexCurrentTodo = codexCurrentTodo
            self.sentAt = sentAt
        }

        /// Encodes the payload as a `[String: Any]` dict matching the
        /// shape the legacy receivers expect. Nil fields are omitted so
        /// older receivers don't see surprise keys.
        public func encodedAsDict() -> [String: Any] {
            var dict: [String: Any] = [:]
            if let v = planWaitingCount { dict["planWaitingCount"] = v }
            if let v = latestGoal { dict["latestGoal"] = v }
            if let v = latestPlanSummary { dict["latestPlanSummary"] = v }
            if let v = latestSessionId { dict["latestSessionId"] = v }
            if let v = sessionsSummaryJSON { dict["sessionsSummaryJSON"] = v }
            if let v = currentTaskHeadline { dict["currentTaskHeadline"] = v }
            if let v = codexCurrentTodo { dict["codexCurrentTodo"] = v }
            dict["sentAt"] = ISO8601DateFormatter().string(from: sentAt)
            return dict
        }

        /// Decodes from a `[String: Any]` dict (the runtime shape Watch
        /// receivers see from WCSession). Missing keys → nil fields.
        public static func decode(from dict: [String: Any]) -> Payload {
            var payload = Payload()
            payload.planWaitingCount = dict["planWaitingCount"] as? Int
            payload.latestGoal = dict["latestGoal"] as? String
            payload.latestPlanSummary = dict["latestPlanSummary"] as? String
            payload.latestSessionId = dict["latestSessionId"] as? String
            payload.sessionsSummaryJSON = dict["sessionsSummaryJSON"] as? String
            payload.currentTaskHeadline = dict["currentTaskHeadline"] as? String
            payload.codexCurrentTodo = dict["codexCurrentTodo"] as? String
            if let raw = dict["sentAt"] as? String, let date = ISO8601DateFormatter().date(from: raw) {
                payload.sentAt = date
            }
            return payload
        }

        /// SHA256 of the encoded JSON. Used by the diff-before-send
        /// guard — same hash twice in a row means skip the WCSession
        /// call. Excludes `sentAt` from the hash so timestamp-only
        /// changes don't wake the Watch.
        public func contentHash() -> String {
            // Build the hash from a stable string concatenation rather
            // than JSON-encoded bytes. JSONEncoder's output order isn't
            // contractually deterministic across runs for synthesized
            // Codable, but a hand-built string is. Order: every field
            // in struct order, separated by `|`.
            let parts: [String] = [
                planWaitingCount.map(String.init) ?? "-",
                latestGoal ?? "-",
                latestPlanSummary ?? "-",
                latestSessionId ?? "-",
                sessionsSummaryJSON ?? "-",
                currentTaskHeadline ?? "-",
                codexCurrentTodo ?? "-",
            ]
            let canonical = parts.joined(separator: "|")
            let data = Data(canonical.utf8)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Diff-before-send accumulator. Threadsafe via NSLock. Sender calls
    /// `shouldSend(_:)` with the encoded payload; returns true the first
    /// time AND every time the content (excluding sentAt) changes.
    public final class SendGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastHash: String?

        public init() {}

        /// Returns true if this payload should be sent (content changed
        /// since last accepted send). Returns false when content is
        /// identical — skipping the WCSession round-trip.
        public func shouldSend(_ payload: Payload) -> Bool {
            let hash = payload.contentHash()
            lock.lock()
            defer { lock.unlock() }
            if hash == lastHash { return false }
            lastHash = hash
            return true
        }

        /// Clears the cached hash so the next call always sends. Use
        /// when the Watch reconnects (WCSession.activationState changed)
        /// and we want to flush a full payload.
        public func reset() {
            lock.lock()
            lastHash = nil
            lock.unlock()
        }
    }
}
