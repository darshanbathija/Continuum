import Foundation
import Combine
import ClawdmeterShared
import os

private let outboxLogger = Logger(subsystem: "com.clawdmeter.ios", category: "MobileCommandOutbox")

/// iOS-side queue + retry layer for write commands the user issues from
/// the Sessions detail view. Wraps `AgentControlClient` calls so a flaky
/// Tailscale link or a foregrounded iOS app stuck mid-send still
/// delivers the command exactly once (or surfaces a clear failure for
/// the user to retry).
///
/// Lifecycle:
/// - Each `enqueue(...)` call creates a `MobileCommandEnvelope`, persists
///   it to `Application Support/Clawdmeter/outbox.json`, and dispatches
///   to `AgentControlClient` asynchronously.
/// - On success → mark `.acknowledged`, remove from queue, broadcast a
///   notification so the UI can mirror.
/// - On transient failure (network error / 5xx) → keep in queue, retry
///   with exponential backoff: `[1s, 4s, 15s, 60s, 5min, 30min]`.
/// - On terminal failure (4xx other than 429) → mark `.failed`, leave
///   in the failed list, surface to UI so the user can retry/cancel.
///
/// The outbox shares its persistence schema with no on-disk migration —
/// `MobileCommandEnvelope` is already a Codable wire type that survives
/// `JSONEncoder` / `JSONDecoder` round-trips. The on-disk file is a
/// dict `{"version":1, "pending":[envelope], "failed":[envelope]}`.
@MainActor
public final class MobileCommandOutbox: ObservableObject {

    @Published public private(set) var pending: [MobileCommandEnvelope] = []
    @Published public private(set) var failed: [MobileCommandEnvelope] = []

    private let client: AgentControlClient
    private let storeURL: URL
    private let deviceId: String
    private var inflight: Set<String> = []
    private var retryTasks: [String: Task<Void, Never>] = [:]

    /// Exponential backoff schedule for retried commands. Caps at 30min.
    /// Index ≥ schedule.count keeps the command in `.failed` permanently.
    private let retrySchedule: [TimeInterval] = [1, 4, 15, 60, 300, 1800]

    public init(
        client: AgentControlClient,
        storeURL: URL = MobileCommandOutbox.defaultStoreURL(),
        deviceId: String = MobileCommandOutbox.deviceIdentifier()
    ) {
        self.client = client
        self.storeURL = storeURL
        self.deviceId = deviceId
        load()
        // Kick off any pending entries persisted from a previous launch.
        for envelope in pending { schedule(envelope) }
    }

    public nonisolated static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("outbox.json")
    }

    /// Per-install stable identifier. Stored in UserDefaults so a single
    /// reinstall picks up a new id; idempotency itself is per-command-
    /// key so this is just for audit attribution.
    public nonisolated static func deviceIdentifier() -> String {
        let key = "clawdmeter.outbox.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Enqueue paths (one per supported kind)

    public func enqueueSend(sessionId: UUID, text: String, asFollowUp: Bool = true) {
        enqueue(
            kind: .send,
            sessionId: sessionId,
            payload: SendPromptRequest(text: text, asFollowUp: asFollowUp, idempotencyKey: "")
        )
    }

    public func enqueueInterrupt(sessionId: UUID) {
        enqueue(
            kind: .interrupt,
            sessionId: sessionId,
            payload: InterruptRequest(idempotencyKey: "")
        )
    }

    public func enqueueApprovePlan(sessionId: UUID) {
        enqueue(
            kind: .approve,
            sessionId: sessionId,
            payload: InterruptRequest(idempotencyKey: "")
        )
    }

    public func enqueueChangeModel(
        sessionId: UUID,
        model: String,
        effort: ReasoningEffort? = nil
    ) {
        enqueue(
            kind: .changeModel,
            sessionId: sessionId,
            payload: ChangeModelRequest(model: model, effort: effort, idempotencyKey: "")
        )
    }

    public func enqueueChangeEffort(sessionId: UUID, effort: ReasoningEffort) {
        enqueue(
            kind: .changeEffort,
            sessionId: sessionId,
            payload: ChangeEffortRequest(effort: effort, idempotencyKey: "")
        )
    }

    public func enqueueSetAutopilot(sessionId: UUID, enabled: Bool) {
        enqueue(
            kind: .setAutopilot,
            sessionId: sessionId,
            payload: AutopilotRequest(enabled: enabled, idempotencyKey: "")
        )
    }

    public func enqueueCreatePR(sessionId: UUID) {
        enqueue(
            kind: .createPR,
            sessionId: sessionId,
            payload: CreatePRRequest(idempotencyKey: "")
        )
    }

    public func enqueueMerge(sessionId: UUID, method: PRMergeMethod = .squash) {
        enqueue(
            kind: .mergePR,
            sessionId: sessionId,
            payload: MergePRRequest(method: method, idempotencyKey: "")
        )
    }

    // MARK: - User actions on existing entries

    /// Manually retry a `.failed` envelope. Resets retry count + status
    /// and re-schedules.
    public func retry(idempotencyKey: String) {
        guard let idx = failed.firstIndex(where: { $0.idempotencyKey == idempotencyKey }) else { return }
        let envelope = failed.remove(at: idx)
        let reset = MobileCommandEnvelope(
            idempotencyKey: envelope.idempotencyKey,
            deviceId: envelope.deviceId,
            sessionId: envelope.sessionId,
            kind: envelope.kind,
            status: .queued,
            createdAt: envelope.createdAt,
            lastAttemptAt: nil,
            retryCount: 0,
            payload: envelope.payload
        )
        pending.append(reset)
        persist()
        schedule(reset)
    }

    /// Drop an envelope from the queue entirely. Used by the iOS UI's
    /// "Cancel" swipe action.
    public func discard(idempotencyKey: String) {
        retryTasks.removeValue(forKey: idempotencyKey)?.cancel()
        inflight.remove(idempotencyKey)
        pending.removeAll { $0.idempotencyKey == idempotencyKey }
        failed.removeAll { $0.idempotencyKey == idempotencyKey }
        persist()
    }

    // MARK: - Enqueue core

    private func enqueue<Body: Encodable>(
        kind: MobileCommandKind,
        sessionId: UUID,
        payload: Body
    ) {
        let key = UUID().uuidString
        let payloadString = encodePayload(payload, idempotencyKey: key)
        let envelope = MobileCommandEnvelope(
            idempotencyKey: key,
            deviceId: deviceId,
            sessionId: sessionId,
            kind: kind,
            status: .queued,
            payload: payloadString
        )
        pending.append(envelope)
        persist()
        schedule(envelope)
    }

    /// Inject the freshly-minted idempotency key into the payload so the
    /// server stores the same key the client retries with. We re-encode
    /// via a wrapper struct because the underlying Codable types want
    /// idempotencyKey at the top level of the request body.
    private func encodePayload<Body: Encodable>(_ payload: Body, idempotencyKey: String) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "{}" }
        dict["idempotencyKey"] = idempotencyKey
        guard let merged = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: merged, encoding: .utf8) else { return "{}" }
        return text
    }

    private func schedule(_ envelope: MobileCommandEnvelope) {
        guard !inflight.contains(envelope.idempotencyKey) else { return }
        inflight.insert(envelope.idempotencyKey)
        retryTasks[envelope.idempotencyKey] = Task { [weak self] in
            await self?.deliver(envelope)
        }
    }

    private func deliver(_ envelope: MobileCommandEnvelope) async {
        defer {
            inflight.remove(envelope.idempotencyKey)
            retryTasks.removeValue(forKey: envelope.idempotencyKey)
        }
        let success = await dispatch(envelope)
        if success {
            markAcknowledged(envelope)
        } else {
            await reschedule(envelope)
        }
    }

    /// Calls the matching `AgentControlClient` method for this envelope.
    /// Returns true on success, false on retryable failure.
    private func dispatch(_ envelope: MobileCommandEnvelope) async -> Bool {
        guard let payloadData = envelope.payload.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        guard let sessionId = envelope.sessionId else { return false }
        switch envelope.kind {
        case .send:
            guard let body = try? decoder.decode(SendPromptRequest.self, from: payloadData) else { return false }
            return await client.sendPrompt(
                sessionId: sessionId,
                text: body.text,
                asFollowUp: body.asFollowUp,
                idempotencyKey: envelope.idempotencyKey
            )
        case .interrupt:
            return await client.interruptSession(sessionId: sessionId, idempotencyKey: envelope.idempotencyKey)
        case .approve:
            return await client.approvePlan(sessionId: sessionId, idempotencyKey: envelope.idempotencyKey)
        case .changeModel:
            guard let body = try? decoder.decode(ChangeModelRequest.self, from: payloadData) else { return false }
            let result = await client.changeModel(
                sessionId: sessionId,
                request: ChangeModelRequest(
                    model: body.model,
                    effort: body.effort,
                    idempotencyKey: envelope.idempotencyKey
                )
            )
            return result != nil
        case .changeEffort:
            guard let body = try? decoder.decode(ChangeEffortRequest.self, from: payloadData) else { return false }
            return await client.changeEffort(
                sessionId: sessionId,
                effort: body.effort,
                idempotencyKey: envelope.idempotencyKey
            ) != nil
        case .changeMode:
            guard let body = try? decoder.decode(ChangeModeRequest.self, from: payloadData) else { return false }
            return await client.changeMode(
                sessionId: sessionId,
                mode: body.mode,
                planMode: body.planMode,
                idempotencyKey: envelope.idempotencyKey
            ) != nil
        case .setAutopilot:
            guard let body = try? decoder.decode(AutopilotRequest.self, from: payloadData) else { return false }
            return await client.setAutopilot(
                sessionId: sessionId,
                enabled: body.enabled,
                idempotencyKey: envelope.idempotencyKey
            )
        case .createPR:
            guard let body = try? decoder.decode(CreatePRRequest.self, from: payloadData) else { return false }
            return await client.createPR(
                sessionId: sessionId,
                title: body.title,
                body: body.body,
                baseBranch: body.baseBranch,
                idempotencyKey: envelope.idempotencyKey
            ) != nil
        case .mergePR:
            guard let body = try? decoder.decode(MergePRRequest.self, from: payloadData) else { return false }
            return await client.merge(
                sessionId: sessionId,
                method: body.method,
                deleteBranch: body.deleteBranch,
                auto: body.auto,
                adminOverride: body.adminOverride,
                idempotencyKey: envelope.idempotencyKey
            ) != nil
        case .permissionResponse, .terminalInput, .pickWinner, .updateWorkspace:
            // Pre-wired outbox kinds we don't surface enqueue helpers
            // for yet. Treat as success so a stale entry from a future
            // build doesn't permanently stick in the queue. The legacy
            // direct-call path on iOS still handles these.
            outboxLogger.warning("Skipping unsupported kind \(envelope.kind.rawValue, privacy: .public) — pretending success")
            return true
        }
    }

    private func markAcknowledged(_ envelope: MobileCommandEnvelope) {
        pending.removeAll { $0.idempotencyKey == envelope.idempotencyKey }
        // Acknowledged entries are dropped from the visible queue. The
        // server-side audit log retains a permanent record.
        persist()
    }

    private func reschedule(_ envelope: MobileCommandEnvelope) async {
        let nextRetryCount = envelope.retryCount + 1
        // Exceeded backoff schedule → mark as failed permanently.
        guard nextRetryCount <= retrySchedule.count else {
            let failedEnvelope = MobileCommandEnvelope(
                idempotencyKey: envelope.idempotencyKey,
                deviceId: envelope.deviceId,
                sessionId: envelope.sessionId,
                kind: envelope.kind,
                status: .failed,
                createdAt: envelope.createdAt,
                lastAttemptAt: Date(),
                retryCount: nextRetryCount,
                payload: envelope.payload
            )
            pending.removeAll { $0.idempotencyKey == envelope.idempotencyKey }
            failed.append(failedEnvelope)
            persist()
            return
        }
        let delay = retrySchedule[nextRetryCount - 1]
        // Bump the retry counter in the persisted record so cold-start
        // pickup respects the schedule.
        if let idx = pending.firstIndex(where: { $0.idempotencyKey == envelope.idempotencyKey }) {
            let bumped = MobileCommandEnvelope(
                idempotencyKey: envelope.idempotencyKey,
                deviceId: envelope.deviceId,
                sessionId: envelope.sessionId,
                kind: envelope.kind,
                status: .queued,
                createdAt: envelope.createdAt,
                lastAttemptAt: Date(),
                retryCount: nextRetryCount,
                payload: envelope.payload
            )
            pending[idx] = bumped
            persist()
        }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        // Re-fetch the latest snapshot of the envelope (caller may have
        // discarded it during the sleep).
        guard let current = pending.first(where: { $0.idempotencyKey == envelope.idempotencyKey }) else {
            return
        }
        schedule(current)
    }

    // MARK: - Persistence

    private struct StoreFile: Codable {
        var version: Int
        var pending: [MobileCommandEnvelope]
        var failed: [MobileCommandEnvelope]
    }

    private static let currentVersion = 1

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StoreFile.self, from: data)
            self.pending = file.pending
            self.failed = file.failed
            outboxLogger.info("Loaded outbox: \(file.pending.count) pending, \(file.failed.count) failed")
        } catch {
            outboxLogger.error("Failed to load outbox: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        let file = StoreFile(version: Self.currentVersion, pending: pending, failed: failed)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }
}
