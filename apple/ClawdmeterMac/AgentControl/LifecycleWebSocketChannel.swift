import Foundation
import Network
import OSLog
import Combine
import ClawdmeterShared

private let lifecycleStreamLogger = Logger(subsystem: "com.clawdmeter.mac", category: "LifecycleStreamWS")

/// Server-push lifecycle snapshots for one session.
///
/// Wire envelope:
/// - Client subscribes with `{op:"lifecycle-subscribe", token, sessionId}`.
/// - Server pushes `SessionLifecycleSnapshotResponse` frames. The first
///   frame is immediate; later frames follow `AgentSessionRegistry` changes.
@MainActor
public final class LifecycleWebSocketChannel: WSChannel {
    private let connection: NWConnection
    private let sessionId: UUID
    private let registry: AgentSessionRegistry
    private let checkpointProvider: (UUID) -> [CodeCheckpointSnapshot]
    private let encoder: JSONEncoder

    private var cancellable: AnyCancellable?
    private var invalidationCancellable: AnyCancellable?
    private var lastDedupeIdentity: String?

    static let externalInvalidations = PassthroughSubject<UUID, Never>()

    public init(
        connection: NWConnection,
        sessionId: UUID,
        registry: AgentSessionRegistry,
        checkpointProvider: @escaping (UUID) -> [CodeCheckpointSnapshot]
    ) {
        self.connection = connection
        self.sessionId = sessionId
        self.registry = registry
        self.checkpointProvider = checkpointProvider
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    public static func notifyCheckpointStateChanged(sessionId: UUID) {
        externalInvalidations.send(sessionId)
    }

    static func dedupeIdentity(for snapshot: SessionLifecycleSnapshot) -> String {
        let blockersIdentity = snapshot.blockers
            .map { "\($0.kind.rawValue):\($0.summary):\($0.resolution ?? ""):\($0.canOverride)" }
            .sorted()
            .joined(separator: ",")
        let evidenceIdentity = snapshot.evidence
            .map(evidenceIdentity(for:))
            .joined(separator: ",")
        let provider = snapshot.providerCapabilities
        return [
            "seq=\(snapshot.seq)",
            "phase=\(snapshot.phase.rawValue)",
            "goal=\(snapshot.goal?.text ?? "")",
            "blockers=\(blockersIdentity)",
            "evidence=\(evidenceIdentity)",
            "next=\(snapshot.nextAction?.kind.rawValue ?? ""):\(snapshot.nextAction?.title ?? ""):\(snapshot.nextAction?.deeplink ?? "")",
            "branch=\(snapshot.branchInfo.repoKey ?? ""):\(snapshot.branchInfo.repoDisplayName):\(snapshot.branchInfo.mode.rawValue):\(snapshot.branchInfo.worktreePath ?? ""):\(snapshot.branchInfo.runtimeCwd ?? ""):\(snapshot.branchInfo.branchName ?? ""):\(snapshot.branchInfo.baseBranch ?? "")",
            "pr=\(snapshot.prInfo?.state?.rawValue ?? ""):\(snapshot.prInfo?.checksRollup.rawValue ?? ""):\(snapshot.prInfo?.reviewState.rawValue ?? ""):\(snapshot.prInfo?.mergeability.rawValue ?? "")",
            "validation=\(snapshot.validationStatus?.state.rawValue ?? ""):\(snapshot.validationStatus?.title ?? ""):\(snapshot.validationStatus?.summary ?? "")",
            "checkpoints=\(snapshot.checkpointStatus?.count ?? 0):\(snapshot.checkpointStatus?.latest?.id.uuidString ?? ""):\(snapshot.checkpointStatus?.latest?.summary ?? "")",
            "provider=\(provider.agent.rawValue):\(provider.supportsPlanApproval):\(provider.supportsResume):\(provider.supportsTranscriptImport):\(provider.supportsInterrupt):\(provider.supportsPRs):\(provider.supportsCheckpoints):\(provider.supportsProviderHandoff)",
        ].joined(separator: "|")
    }

    private static func evidenceIdentity(for evidence: LifecycleEvidence) -> String {
        let metadata = evidence.payload.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return [
            evidence.kind.rawValue,
            evidence.title,
            evidence.payload.text ?? "",
            evidence.payload.url ?? "",
            evidence.payload.refId ?? "",
            metadata,
        ].joined(separator: ":")
    }

    public func start() {
        guard registry.session(id: sessionId) != nil else {
            sendCloseAndCancel(.protocolCode(.unsupportedData))
            return
        }
        lifecycleStreamLogger.info("lifecycle-subscribe started for session \(self.sessionId.uuidString, privacy: .public)")
        Task { @MainActor [weak self] in
            await self?.pushCurrentSnapshot(force: true)
        }
        cancellable = registry.$sessions
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.pushCurrentSnapshot(force: false)
                }
            }
        invalidationCancellable = Self.externalInvalidations
            .filter { [sessionId] invalidatedId in invalidatedId == sessionId }
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.pushCurrentSnapshot(force: false)
                }
            }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
        invalidationCancellable?.cancel()
        invalidationCancellable = nil
        connection.cancel()
        lifecycleStreamLogger.info("lifecycle-subscribe stopped for session \(self.sessionId.uuidString, privacy: .public)")
    }

    private func pushCurrentSnapshot(force: Bool) async {
        guard let session = registry.session(id: sessionId) else {
            sendCloseAndCancel(.protocolCode(.unsupportedData))
            return
        }
        let snapshot = SessionLifecycleReducer.snapshot(
            for: session,
            checkpoints: checkpointProvider(session.id)
        )
        let dedupeIdentity = Self.dedupeIdentity(for: snapshot)
        guard force || dedupeIdentity != lastDedupeIdentity else {
            return
        }
        lastDedupeIdentity = dedupeIdentity
        await push(SessionLifecycleSnapshotResponse(snapshot: snapshot))
    }

    private func push(_ response: SessionLifecycleSnapshotResponse) async {
        guard let body = try? encoder.encode(response) else {
            lifecycleStreamLogger.error("lifecycle-subscribe: failed to encode snapshot for session \(self.sessionId.uuidString, privacy: .public)")
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "lifecycle-snapshot", metadata: [meta])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(
                content: body,
                contentContext: ctx,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        lifecycleStreamLogger.debug("lifecycle-subscribe send failed: \(error.localizedDescription)")
                    }
                    cont.resume()
                }
            )
        }
    }

    private func sendCloseAndCancel(_ code: NWProtocolWebSocket.CloseCode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = code
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        connection.send(
            content: nil,
            contentContext: ctx,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            }
        )
    }
}
