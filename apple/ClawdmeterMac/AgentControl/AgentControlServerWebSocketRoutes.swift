import Foundation
import Network
import ClawdmeterShared

extension AgentControlServer {
    /// Spin up a WebSocket-enabled listener. The first message from the
    /// client must be a JSON subscription envelope identifying the channel
    /// (terminal vs events) + bearer token.
    func startWSListening(on port: UInt16, queue: DispatchQueue) -> Bool {
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: nwPort)
            self.wsListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewWSConnection(connection)
                }
            }
            listener.start(queue: queue)
            return true
        } catch {
            serverLogger.debug("WS bind \(port) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Accept a WebSocket connection. Apply the same peer filter as HTTP;
    /// the first WS message authenticates and subscribes to a channel.
    private func handleNewWSConnection(_ connection: NWConnection) {
        guard Self.isAllowedPeer(connection.endpoint) else {
            serverLogger.warning("WS: rejecting non-tailnet peer \(String(describing: connection.endpoint))")
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor in
                    await self?.routeWSSubscription(on: connection)
                }
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                    if let channel = self?.wsChannels.removeValue(forKey: ObjectIdentifier(connection)) {
                        channel.stop()
                    }
                }
            default: break
            }
        }
        connection.start(queue: listenerQueue ?? .global())
    }

    private func routeWSSubscription(on connection: NWConnection) async {
        // Read the first WebSocket message: a JSON envelope with op, token,
        // and channel-specific params.
        let firstMessage: Data
        do {
            firstMessage = try await receiveOne(on: connection)
        } catch {
            serverLogger.debug("WS: failed to receive subscription envelope: \(error.localizedDescription)")
            connection.cancel()
            return
        }
        let wsDecoder = JSONDecoder()
        // ComposeDraft carries an ISO-8601 `createdAt` field (X1 cross-Apple
        // handoff). iOS encodes with `.iso8601` via `encodedJSONObject()`;
        // without setting the strategy here, the default `.deferredToDate`
        // would expect a Double and the whole envelope would silently fail
        // to decode — X1 broken end-to-end (caught by review 2026-05-18).
        wsDecoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? wsDecoder.decode(WSSubscription.self, from: firstMessage) else {
            serverLogger.debug("WS: malformed subscription envelope")
            sendWSClose(on: connection, code: .protocolCode(.protocolError))
            return
        }
        // Auth — accept either the pairing token (iOS) or the per-launch
        // loopback token (Mac's in-process MacLoopbackClient, PR #24a).
        guard isAuthorized(token: envelope.token) else {
            serverLogger.warning("WS: bad bearer token")
            sendWSClose(on: connection, code: .protocolCode(.policyViolation))
            return
        }
        // Tailscale whois for non-loopback.
        if !isLoopback(connection.endpoint) {
            let peerString = Self.endpointString(connection.endpoint)
            if await whois.userLoginName(for: peerString) == nil {
                serverLogger.warning("WS: whois rejected \(peerString, privacy: .public)")
                sendWSClose(on: connection, code: .protocolCode(.policyViolation))
                return
            }
        }

        switch envelope.op {
        case "compose-draft":
            // X1 cross-Apple handoff. Phone POSTs a draft, daemon broadcasts
            // to any Mac /events subscriber. Here on the *server* side, the
            // initial WS message contains the draft itself (single-shot
            // post-as-WS) — fan it out via NotificationCenter to the local
            // Mac UI process. The connection is then closed; we don't keep
            // a long-lived state.
            if let payload = envelope.draft {
                // Cap inbound text length so a misbehaving / malicious paired
                // device can't push a multi-MB blob into the SwiftUI TextField
                // (review §3 finding 2026-05-18). 64KB ≈ ~10K tokens — far
                // larger than any plausible composer prompt.
                guard payload.text.count <= 64 * 1024 else {
                    serverLogger.warning("compose-draft rejected: text length \(payload.text.count) > 64KB cap")
                    sendWSClose(on: connection, code: .protocolCode(.policyViolation))
                    return
                }
                NotificationCenter.default.post(
                    name: .composeDraftIncoming,
                    object: nil,
                    userInfo: ["draft": payload]
                )
                let peer = Self.endpointString(connection.endpoint)
                await AuditLog.shared.recordSend(
                    sessionId: UUID(),  // synthetic — drafts don't belong to a session yet
                    sourcePeer: peer,
                    text: "[compose-draft] repo=\(payload.repoKey ?? "-") len=\(payload.text.count)"
                )
                serverLogger.info("compose-draft received: text length=\(payload.text.count, privacy: .public), repo=\(payload.repoKey ?? "-", privacy: .public), peer=\(peer, privacy: .public)")

                // Send a 1-byte application-layer ACK before closing so the
                // iOS caller can `task.receive()` instead of guessing a
                // sleep duration. Replaces the prior 200ms hope-it-flushed
                // race (review §10 finding 2026-05-18).
                sendWSText("ok", on: connection)
            }
            sendWSClose(on: connection, code: .protocolCode(.normalClosure))
        case "terminal":
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  let session = registry.session(id: sessionId)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            // G12: envelope can target a specific pane within the session
            // (multi-terminal tab strip). Only actual pane ids owned by the
            // session are accepted; tmux output is keyed by "%pane", not
            // "@window".
            let paneId: String? = {
                if let explicit = envelope.paneId, !explicit.isEmpty {
                    guard Self.isValidTmuxPaneId(explicit),
                          explicit == session.tmuxPaneId || session.terminalPanes.contains(where: { $0.paneId == explicit })
                    else { return nil }
                    return explicit
                }
                return session.tmuxPaneId
            }()
            guard let paneId else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let channel = TerminalWebSocketChannel(
                connection: connection,
                tmux: tmux,
                paneId: paneId,
                registry: registry,
                sessionId: sessionId
            )
            wsChannels[ObjectIdentifier(connection)] = channel
            channel.start()
        case "events":
            let since = envelope.since ?? 0
            let stream = AgentEventStream(
                connection: connection,
                registry: registry,
                sinceSeq: since
            )
            wsChannels[ObjectIdentifier(connection)] = stream
            stream.start()
        case "chat-subscribe":
            // Phase 2 of the WhatsApp-smooth Sessions pipeline. Replaces
            // iOS's 3-second `GET /chat-snapshot` HTTP polling with a
            // long-lived WS subscription. A10 (wire v21) layered the
            // shell/detail split on top:
            //   - Client reports `wireVersion`. v21+ receives shell +
            //     detail event pairs (one shell frame + one detail frame
            //     per 100ms coalesced commit); v20 and earlier keep
            //     receiving the legacy single `WireChatSnapshot` frame.
            //   - Branch is selected ONCE in the channel constructor and
            //     never re-evaluated mid-connection (clients that
            //     dynamically upgrade their wire shape would have to
            //     reconnect — which they already do across app launches).
            // No delta encoding in v1 — Codex's outside-voice review (D6)
            // explicitly cut that scope until measurements show it's
            // needed; the split lands first.
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  let session = registry.session(id: sessionId)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let chatChannel = ChatStreamWebSocketChannel(
                connection: connection,
                session: session,
                registry: chatStoreRegistry,
                clientWireVersion: envelope.wireVersion
            )
            wsChannels[ObjectIdentifier(connection)] = chatChannel
            chatChannel.start()
        case "lifecycle-subscribe":
            // v19 lifecycle spine: full session lifecycle snapshots over WS.
            // The first frame is immediate; subsequent frames coalesce
            // registry changes at 50ms so UI surfaces can bind directly to
            // phase/blocker/next-action changes.
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  registry.session(id: sessionId) != nil
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let lifecycleChannel = LifecycleWebSocketChannel(
                connection: connection,
                sessionId: sessionId,
                registry: registry,
                checkpointProvider: { [weak self] id in
                    guard let self else { return [] }
                    return self.storedCheckpoints(for: id).map(self.codeCheckpoint)
                }
            )
            wsChannels[ObjectIdentifier(connection)] = lifecycleChannel
            lifecycleChannel.start()
        case "frontier-subscribe":
            // v0.9.x — typed aggregator for the 3-pane Frontier UI.
            // Acquires every child's chat store, observes them in
            // parallel via Combine, emits one FrontierGroupSnapshot
            // envelope per debounced 100ms commit window. Same auth
            // gate as chat-subscribe; same idle-eviction lifecycle.
            guard let groupIdString = envelope.groupId,
                  let groupId = UUID(uuidString: groupIdString)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let frontierChannel = FrontierWebSocketChannel(
                connection: connection,
                groupId: groupId,
                registry: chatStoreRegistry,
                sessionRegistry: registry,
                turnWinnersProvider: { [weak self] in
                    self?.frontierTurnWinners[groupId]?.values.sorted { $0.decidedAt < $1.decidedAt } ?? []
                }
            )
            wsChannels[ObjectIdentifier(connection)] = frontierChannel
            frontierChannel.start()
        default:
            sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
        }
    }

    private func sendWSClose(on connection: NWConnection, code: NWProtocolWebSocket.CloseCode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = code
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        connection.send(content: nil, contentContext: ctx, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Send a single text frame on the WS connection. Used as a tiny
    /// application-layer ACK for one-shot ops like `compose-draft` so the
    /// iOS caller can await receipt instead of guessing a sleep duration.
    private func sendWSText(_ text: String, on connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws-text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: ctx,
                        isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receiveOne(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receiveMessage { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    /// Subscription envelope for WS connections.
    private struct WSSubscription: Codable {
        let op: String           // "terminal" | "events" | "compose-draft" | "chat-subscribe" | "lifecycle-subscribe" | "frontier-subscribe" | "codex-stream-subscribe"
        let token: String
        let sessionId: String?   // required for "terminal", "chat-subscribe", "lifecycle-subscribe", "codex-stream-subscribe"
        let since: UInt64?       // optional for "events"
        /// G12: target a specific pane (multi-terminal tab strip). When nil,
        /// the server falls back to the session's primary pane.
        let paneId: String?
        /// X1: compose-draft single-shot payload. Only populated when
        /// `op == "compose-draft"`. The Mac UI consumes via NotificationCenter.
        let draft: ComposeDraft?
        /// v0.9.x: required for `frontier-subscribe` — the group whose
        /// aggregate `FrontierGroupSnapshot` envelopes the client wants.
        let groupId: String?
        /// A10 (wire v21): client's reported wireVersion. The server picks
        /// the dispatch branch ONCE per connection: `wireVersion >= 21`
        /// receives shell + detail event pairs on `chat-subscribe`; older
        /// clients receive the legacy `WireChatSnapshot` frame on each
        /// commit (back-compat). Optional; absent on v20 and earlier
        /// clients that don't know to send it (the default-to-legacy path
        /// covers them).
        let wireVersion: Int?
    }
}
