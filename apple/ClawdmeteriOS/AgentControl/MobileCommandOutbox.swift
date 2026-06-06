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
/// - On terminal failure (4xx other than 409/429) → mark `.failed`, leave
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
        holdPersistedProviderSendsForManualRetry()
        // Kick off persisted non-provider commands; provider sends need an
        // explicit retry after relaunch so old chat text cannot spend tokens.
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
            payload: SendPromptRequest(
                text: text,
                asFollowUp: asFollowUp,
                idempotencyKey: "",
                origin: .userComposer,
                clientIntentId: UUID().uuidString
            )
        )
    }

    public func enqueueInterrupt(sessionId: UUID) {
        enqueue(
            kind: .interrupt,
            sessionId: sessionId,
            payload: InterruptRequest(idempotencyKey: "")
        )
    }

    public func enqueueApprovePlan(sessionId: UUID, idempotencyKey: String? = nil) {
        enqueue(
            kind: .approve,
            sessionId: sessionId,
            payload: InterruptRequest(idempotencyKey: ""),
            idempotencyKey: idempotencyKey
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

    public func enqueueMerge(
        sessionId: UUID,
        method: PRMergeMethod = .squash,
        deleteBranch: Bool = false,
        auto: Bool = false,
        adminOverride: Bool = false
    ) {
        enqueue(
            kind: .mergePR,
            sessionId: sessionId,
            payload: MergePRRequest(
                method: method,
                deleteBranch: deleteBranch,
                auto: auto,
                adminOverride: adminOverride,
                idempotencyKey: ""
            )
        )
    }

    // MARK: - User actions on existing entries

    /// Manually retry a `.failed` envelope. Resets retry count + status
    /// and re-schedules.
    public func retry(idempotencyKey: String) {
        guard let idx = failed.firstIndex(where: { $0.idempotencyKey == idempotencyKey }) else { return }
        let envelope = failed.remove(at: idx)
        let payload = restampedPayloadForExplicitRetry(envelope)
        retryTasks.removeValue(forKey: envelope.idempotencyKey)?.cancel()
        inflight.remove(envelope.idempotencyKey)
        let reset = MobileCommandEnvelope(
            idempotencyKey: envelope.idempotencyKey,
            deviceId: envelope.deviceId,
            sessionId: envelope.sessionId,
            kind: envelope.kind,
            status: .queued,
            createdAt: envelope.createdAt,
            lastAttemptAt: nil,
            retryCount: 0,
            payload: payload
        )
        pending.append(reset)
        persist()
        schedule(reset)
    }

    private func restampedPayloadForExplicitRetry(_ envelope: MobileCommandEnvelope) -> String {
        guard envelope.kind == .send,
              let data = envelope.payload.data(using: .utf8)
        else {
            return envelope.payload
        }
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(SendPromptRequest.self, from: data) else {
            return envelope.payload
        }
        let request = SendPromptRequest(
            text: body.text,
            asFollowUp: body.asFollowUp,
            idempotencyKey: envelope.idempotencyKey,
            origin: .userComposer,
            clientIntentId: body.clientIntentId ?? UUID().uuidString
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(request),
              let string = String(data: encoded, encoding: .utf8)
        else {
            return envelope.payload
        }
        return string
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
        payload: Body,
        idempotencyKey requestedIdempotencyKey: String? = nil
    ) {
        let requestedKey = requestedIdempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if let requestedKey, !requestedKey.isEmpty {
            key = requestedKey
        } else {
            key = UUID().uuidString
        }
        guard !inflight.contains(key),
              !pending.contains(where: { $0.idempotencyKey == key }),
              !failed.contains(where: { $0.idempotencyKey == key })
        else { return }
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
        retryTasks[envelope.idempotencyKey] = Task {
            await self.deliver(envelope)
        }
    }

    private func deliver(_ envelope: MobileCommandEnvelope) async {
        let success = await dispatch(envelope)
        // v0.26.2 review: clear inflight BEFORE the retry path, not in
        // a defer. The previous defer kept the key in inflight while
        // `reschedule` slept + called `schedule(current)`. That
        // schedule() saw the key in inflight, early-returned at
        // line 223, and the retry never fired — offline composer
        // sends silently stuck in .queued forever.
        inflight.remove(envelope.idempotencyKey)
        retryTasks.removeValue(forKey: envelope.idempotencyKey)
        if success {
            markAcknowledged(envelope)
        } else if isTerminalClientFailure() {
            markFailed(envelope, retryCount: envelope.retryCount)
        } else {
            await reschedule(envelope)
        }
    }

    /// Calls the matching `AgentControlClient` method for this envelope.
    /// Returns true on success, false on retryable failure.
    private func dispatch(_ envelope: MobileCommandEnvelope) async -> Bool {
        client.clearLastHTTPStatusCode()
        guard let payloadData = envelope.payload.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        // Workspace-onboarding commands are workspace-level — no sessionId.
        // Handle them BEFORE the session-scoped guard so a queued entry
        // actually fires through the client instead of silently pretending
        // success (which would delete the pending entry without doing
        // any work). iOS sheets call client.* directly today; outbox
        // entries only exist if a future build wires the enqueue path.
        switch envelope.kind {
        case .openLocalFolder:
            let result = await client.openLocalFolderOnMac(idempotencyKey: envelope.idempotencyKey)
            return isDefinitive(result)
        case .cloneFromGitHub:
            guard let body = try? decoder.decode(CloneFromGitHubRequest.self, from: payloadData) else {
                return false
            }
            let result = await client.cloneFromGitHubOnMac(
                spec: body.spec,
                destinationParent: body.destinationParent,
                idempotencyKey: envelope.idempotencyKey
            )
            return isDefinitive(result)
        case .quickStartRepo:
            guard let body = try? decoder.decode(QuickStartRepoRequest.self, from: payloadData) else {
                return false
            }
            let result = await client.quickStartRepoOnMac(
                name: body.name,
                parent: body.parent,
                idempotencyKey: envelope.idempotencyKey
            )
            return isDefinitive(result)
        case .wakeMac:
            return await client.wakeMacForOpenLocal(idempotencyKey: envelope.idempotencyKey)
        default:
            break
        }
        guard let sessionId = envelope.sessionId else { return false }
        switch envelope.kind {
        case .send:
            guard let body = try? decoder.decode(SendPromptRequest.self, from: payloadData) else { return false }
            return await client.sendPrompt(
                sessionId: sessionId,
                text: body.text,
                asFollowUp: body.asFollowUp,
                idempotencyKey: envelope.idempotencyKey,
                origin: body.origin,
                clientIntentId: body.clientIntentId
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
        case .reviewPR:
            guard let body = try? decoder.decode(PRReviewRequest.self, from: payloadData) else { return false }
            return await client.reviewPR(
                sessionId: sessionId,
                action: body.action,
                body: body.body,
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
        case .revive:
            return await client.revive(
                sessionId: sessionId,
                idempotencyKey: envelope.idempotencyKey
            ) != nil
        case .permissionResponse:
            // Runtime permission prompts: a queued permission response dispatches
            // for real (the daemon's ACP request waits indefinitely, so a delayed
            // delivery still unblocks the agent).
            // Returns the real HTTP outcome so an offline response reschedules
            // instead of being silently acknowledged.
            guard let body = try? decoder.decode(PermissionRespondRequest.self, from: payloadData) else { return false }
            return await client.respondToPermissionPrompt(
                sessionId: sessionId,
                promptId: body.promptId,
                optionId: body.optionId,
                idempotencyKey: envelope.idempotencyKey
            )
        case .terminalInput, .pickWinner, .updateWorkspace:
            // Pre-wired outbox kinds we don't surface enqueue helpers
            // for yet. Treat as success so a stale entry from a future
            // build doesn't permanently stick in the queue.
            outboxLogger.warning("Skipping unsupported kind \(envelope.kind.rawValue, privacy: .public) — pretending success")
            return true
        case .openLocalFolder, .cloneFromGitHub, .quickStartRepo, .wakeMac:
            // Dispatched above the sessionId guard. Unreachable here but
            // Swift requires exhaustive cases.
            return true
        }
    }

    /// Treat a `WorkspaceOnboardingResult` as a definitive outcome iff the
    /// daemon returned either a record (success) or a structured
    /// `RepoOnboardingError` (final failure — auth-failed, path-not-
    /// allowed, etc.). `macLocked` and `unsupportedServer` are also
    /// definitive (no point retrying until the user wakes/updates the
    /// Mac). Empty results signal a transport-layer hiccup and should
    /// retry. This keeps queued entries off the persistent queue once
    /// the Mac has actually responded.
    private func isDefinitive(_ result: AgentControlClient.WorkspaceOnboardingResult) -> Bool {
        if result.record != nil { return true }
        if result.error != nil { return true }
        if result.macLocked { return true }
        if result.unsupportedServer { return true }
        return false
    }

    private func markAcknowledged(_ envelope: MobileCommandEnvelope) {
        pending.removeAll { $0.idempotencyKey == envelope.idempotencyKey }
        // Acknowledged entries are dropped from the visible queue. The
        // server-side audit log retains a permanent record.
        persist()
    }

    private func isTerminalClientFailure() -> Bool {
        guard let status = client.lastHTTPStatusCode else { return false }
        return (400..<500).contains(status) && status != 409 && status != 429
    }

    private func markFailed(_ envelope: MobileCommandEnvelope, retryCount: Int) {
        let failedEnvelope = MobileCommandEnvelope(
            idempotencyKey: envelope.idempotencyKey,
            deviceId: envelope.deviceId,
            sessionId: envelope.sessionId,
            kind: envelope.kind,
            status: .failed,
            createdAt: envelope.createdAt,
            lastAttemptAt: Date(),
            retryCount: retryCount,
            payload: envelope.payload
        )
        pending.removeAll { $0.idempotencyKey == envelope.idempotencyKey }
        if let idx = failed.firstIndex(where: { $0.idempotencyKey == envelope.idempotencyKey }) {
            failed[idx] = failedEnvelope
        } else {
            failed.append(failedEnvelope)
        }
        persist()
    }

    private func reschedule(_ envelope: MobileCommandEnvelope) async {
        let nextRetryCount = envelope.retryCount + 1
        // Exceeded backoff schedule → mark as failed permanently.
        guard nextRetryCount <= retrySchedule.count else {
            markFailed(envelope, retryCount: nextRetryCount)
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

    private func holdPersistedProviderSendsForManualRetry() {
        let replayable = pending.filter { $0.kind != .send }
        let held = pending.filter { $0.kind == .send }
        guard !held.isEmpty else { return }
        pending = replayable
        for envelope in held {
            retryTasks.removeValue(forKey: envelope.idempotencyKey)?.cancel()
            inflight.remove(envelope.idempotencyKey)
        }
        let heldFailures = held.map {
            MobileCommandEnvelope(
                idempotencyKey: $0.idempotencyKey,
                deviceId: $0.deviceId,
                sessionId: $0.sessionId,
                kind: $0.kind,
                status: .failed,
                createdAt: $0.createdAt,
                lastAttemptAt: $0.lastAttemptAt,
                retryCount: $0.retryCount,
                payload: $0.payload
            )
        }
        for envelope in heldFailures {
            if let idx = failed.firstIndex(where: { $0.idempotencyKey == envelope.idempotencyKey }) {
                failed[idx] = envelope
            } else {
                failed.append(envelope)
            }
        }
        persist()
        outboxLogger.info("Held \(held.count) persisted provider send(s) for manual retry")
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
