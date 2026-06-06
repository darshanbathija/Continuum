import Foundation

/// Client-side mirror for a Frontier broadcast group. It subscribes to
/// the daemon's aggregate `frontier-subscribe` WebSocket and replaces
/// the current snapshot wholesale, matching `iOSChatStore`'s full-snapshot
/// contract for solo chats.
@MainActor
public final class FrontierSnapshotStore: ObservableObject {
    @Published public private(set) var snapshot: FrontierGroupSnapshot
    @Published public private(set) var lastError: String?

    public let groupId: UUID
    private weak var client: AgentControlClient?
    private var subscribeTask: Task<Void, Never>?
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    private var wsTask: URLSessionWebSocketTask?
    #endif

    public init(groupId: UUID, client: AgentControlClient) {
        self.groupId = groupId
        self.client = client
        self.snapshot = FrontierGroupSnapshot(groupId: groupId, updateCounter: 0, children: [])
    }

    deinit {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        wsTask?.cancel(with: .normalClosure, reason: nil)
        #endif
    }

    public func start() {
        guard subscribeTask == nil else { return }
        subscribeTask = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        subscribeTask?.cancel()
        subscribeTask = nil
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        #endif
    }

    private func run() async {
        // Track B (B1): drive the aggregate frontier stream over the relay
        // multiplex when it's the default transport (reads the shared
        // `client.relayMux`). No URLSession needed; mux owns reconnect. nil ⇒
        // the legacy direct-WS loop below runs byte-identically.
        if let mux = client?.relayMux {
            await runViaRelay(mux)
            return
        }
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        while !Task.isCancelled {
            do {
                try await openAndStream()
            } catch {
                lastError = error.localizedDescription
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        #else
        lastError = "Frontier live subscription is unavailable on this platform."
        #endif
    }

    /// Track B (B1): subscribe to `frontier-subscribe` over the relay; each
    /// inbound snapshot replaces `snapshot` wholesale (same contract as the
    /// direct WS). Park until cancelled, then unsubscribe.
    private func runViaRelay(_ mux: RelayMuxClient) async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let spec = RelaySubscribeSpec(op: "frontier-subscribe", groupId: groupId.uuidString)
        let opId = await mux.subscribe(spec, handlers: .init(
            onFrame: { [weak self] data in
                guard let self,
                      let fetched = try? decoder.decode(FrontierGroupSnapshot.self, from: data) else { return }
                self.snapshot = fetched
                self.lastError = nil
            }
        ))
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { break }
        }
        await mux.unsubscribe(opId)
    }

    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    private func openAndStream() async throws {
        guard let client,
              let host = client.host,
              let token = client.token,
              let url = URL(string: "ws://\(AgentControlClient.urlHostLiteral(host)):\(client.wsPort)/")
        else { throw URLError(.badURL) }

        let task = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: 8))
        wsTask = task
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            if wsTask === task { wsTask = nil }
        }
        task.resume()

        let envelope: [String: Any] = [
            "op": "frontier-subscribe",
            "token": token,
            "groupId": groupId.uuidString
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        try await task.send(.data(body))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let d):
                data = d
            case .string(let s):
                data = Data(s.utf8)
            @unknown default:
                continue
            }
            if let fetched = try? decoder.decode(FrontierGroupSnapshot.self, from: data) {
                snapshot = fetched
                lastError = nil
            }
        }
    }
    #endif
}
