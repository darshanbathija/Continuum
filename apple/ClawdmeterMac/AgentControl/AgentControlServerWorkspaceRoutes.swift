import Foundation
import Network
import ClawdmeterShared

extension AgentControlServer {
    func handleGetRepos(connection: NWConnection) async {
        let repos = await repoIndex.snapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(repos) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    func handleGetSessions(connection: NWConnection) {
        let sessions = registry.sessions
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(sessions) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    func handleListWorkspaces(connection: NWConnection) {
        let response = WorkspaceListResponse(workspaces: workspaceStore.all())
        sendCodable(response, on: connection)
    }

    func handleUpdateWorkspaceDefaults(
        workspaceId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: workspaceId) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(UpdateWorkspaceDefaultsRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        guard let updated = workspaceStore.updateDefaults(
            id: uuid,
            providerDefaults: req.providerDefaults,
            filesToCopy: req.filesToCopy
        ) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let recordData = try? encoder.encode(updated),
              var dict = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any]
        else {
            sendResponse(.internalError, on: connection)
            return
        }
        if let key = req.idempotencyKey {
            let receipt = MobileCommandReceipt(
                idempotencyKey: key,
                status: .acknowledged,
                processedAt: Date()
            )
            dict["receipt"] = receipt.jsonDictionary
        }
        sendJSON(dict, on: connection)
    }

    func handleGetOneSession(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    func handleGetLifecycle(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = SessionLifecycleReducer.snapshot(
            for: session,
            checkpoints: storedCheckpoints(for: uuid).map(codeCheckpoint)
        )
        sendCodable(SessionLifecycleSnapshotResponse(snapshot: snapshot), on: connection)
    }

    func handleGetRunProfile(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.snapshot(
            session: session,
            messages: chatMessages(for: session)
        )
        sendCodable(CodeRunProfileResponse(profile: snapshot), on: connection)
    }

    func handleStartRunProfile(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let body = request.body.isEmpty
            ? CodeRunProfileStartRequest()
            : (try? decoder.decode(CodeRunProfileStartRequest.self, from: request.body))
        guard let body else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.start(
            session: session,
            command: body.command,
            messages: chatMessages(for: session)
        )
        sendCodable(CodeRunProfileResponse(profile: snapshot), on: connection)
    }

    func handleStopRunProfile(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.stop(
            session: session,
            messages: chatMessages(for: session)
        )
        sendCodable(CodeRunProfileResponse(profile: snapshot), on: connection)
    }

    func handleRunProfileProxy(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.snapshot(
            session: session,
            messages: chatMessages(for: session)
        )
        guard let target = proxiedRunProfileURL(
            from: request.path,
            sessionId: sessionId,
            detectedURL: snapshot.detectedURL
        ) else {
            sendResponse(.badRequest(detail: "no detected preview URL for run-profile proxy"), on: connection)
            return
        }
        do {
            var upstream = URLRequest(url: target)
            upstream.httpMethod = request.method
            upstream.httpBody = request.body.isEmpty ? nil : request.body
            if let accept = request.headers["accept"] {
                upstream.setValue(accept, forHTTPHeaderField: "Accept")
            }
            if let contentType = request.headers["content-type"] {
                upstream.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            if let userAgent = request.headers["user-agent"] {
                upstream.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            let (data, response) = try await URLSession.shared.data(for: upstream)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            sendResponse(
                HTTPResponse(
                    status: status,
                    reason: HTTPURLResponse.localizedString(forStatusCode: status),
                    contentType: contentType,
                    body: request.method.uppercased() == "HEAD" ? Data() : data
                ),
                on: connection
            )
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 502)
        }
    }

    func handleListCheckpoints(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId),
              registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection)
            return
        }
        sendCodable(
            CodeCheckpointListResponse(checkpoints: storedCheckpoints(for: uuid).map(codeCheckpoint)),
            on: connection
        )
    }

    func handleCreateCheckpoint(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let body = request.body.isEmpty
            ? CodeCheckpointCreateRequest()
            : (try? decoder.decode(CodeCheckpointCreateRequest.self, from: request.body))
        guard let body else {
            sendResponse(.badRequest, on: connection)
            return
        }
        do {
            let trimmedSummary = body.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let checkpoint = try await CheckpointService().createCheckpoint(
                session: session,
                summary: (trimmedSummary?.isEmpty == false) ? trimmedSummary : "Manual checkpoint"
            )
            recordCheckpoint(checkpoint)
            sendCodable(CodeCheckpointCreateResponse(checkpoint: codeCheckpoint(checkpoint)), on: connection)
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 409)
        }
    }

    func handlePrepareCheckpointRestore(
        sessionId: String,
        checkpointId: String,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let checkpointUUID = UUID(uuidString: checkpointId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        guard let checkpoint = storedCheckpoint(sessionId: uuid, checkpointId: checkpointUUID) else {
            sendResponse(.notFound, on: connection)
            return
        }
        do {
            let plan = try await CheckpointService().prepareRestore(checkpoint, session: session)
            recordCheckpoint(plan.safety)
            checkpointRestorePlans[plan.id] = plan
            sendCodable(
                CodeCheckpointRestorePreviewResponse(preview: codeRestorePreview(plan)),
                on: connection
            )
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 409)
        }
    }

    func handleRestoreCheckpoint(
        sessionId: String,
        checkpointId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let checkpointUUID = UUID(uuidString: checkpointId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let body = try? decoder.decode(CodeCheckpointRestoreRequest.self, from: request.body),
              let plan = checkpointRestorePlans[body.previewId],
              plan.target.id == checkpointUUID,
              plan.target.sessionId == uuid else {
            sendResponse(.badRequest(detail: "restore requires a current previewId for this checkpoint"), on: connection)
            return
        }
        do {
            try await CheckpointService().restore(plan, in: session.effectiveCwd)
            checkpointRestorePlans.removeValue(forKey: body.previewId)
            sendCodable(
                CodeCheckpointRestoreResponse(
                    restored: true,
                    checkpoint: codeCheckpoint(plan.target),
                    safety: codeCheckpoint(plan.safety)
                ),
                on: connection
            )
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 409)
        }
    }

    private func chatMessages(for session: AgentSession) -> [ChatMessage] {
        chatStoreRegistry.snapshotStore(for: session)?.snapshot.messages ?? []
    }

    func storedCheckpoints(for sessionId: UUID) -> [CheckpointStateSnapshot] {
        WorkbenchStateStore().load().checkpoints[sessionId] ?? []
    }

    private func storedCheckpoint(sessionId: UUID, checkpointId: UUID) -> CheckpointStateSnapshot? {
        storedCheckpoints(for: sessionId).first { $0.id == checkpointId }
    }

    private func recordCheckpoint(_ checkpoint: CheckpointStateSnapshot) {
        let store = WorkbenchStateStore()
        var snapshot = store.load()
        var checkpoints = snapshot.checkpoints[checkpoint.sessionId] ?? []
        checkpoints.removeAll { $0.id == checkpoint.id }
        checkpoints.append(checkpoint)
        snapshot.checkpoints[checkpoint.sessionId] = checkpoints
        store.save(snapshot)
        LifecycleWebSocketChannel.notifyCheckpointStateChanged(sessionId: checkpoint.sessionId)
    }

    func codeCheckpoint(_ checkpoint: CheckpointStateSnapshot) -> CodeCheckpointSnapshot {
        CodeCheckpointSnapshot(
            id: checkpoint.id,
            sessionId: checkpoint.sessionId,
            refName: checkpoint.refName,
            turnId: checkpoint.turnId,
            createdAt: checkpoint.createdAt,
            summary: checkpoint.summary
        )
    }

    private func codeRestorePreview(_ plan: CheckpointRestorePlan) -> CodeCheckpointRestorePreview {
        CodeCheckpointRestorePreview(
            id: plan.id,
            target: codeCheckpoint(plan.target),
            safety: codeCheckpoint(plan.safety),
            diffStat: plan.diffStat,
            diffPatch: plan.diffPatch,
            patchTruncated: plan.patchTruncated,
            dirtyStatusLines: plan.dirtyStatusLines,
            untrackedOverwritePaths: plan.untrackedOverwritePaths,
            untrackedSnapshotPaths: plan.untrackedSnapshotPaths,
            blockingReasons: plan.blockingReasons
        )
    }

    private func proxiedRunProfileURL(
        from requestPath: String,
        sessionId: String,
        detectedURL: String?
    ) -> URL? {
        guard let detectedURL,
              var target = URLComponents(string: detectedURL) else {
            return nil
        }
        let pieces = requestPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathOnly = pieces.first.map(String.init) ?? requestPath
        let query = pieces.count > 1 ? String(pieces[1]) : nil
        let prefix = "/sessions/\(sessionId)/run-profile/proxy"
        guard pathOnly.hasPrefix(prefix) else { return target.url }
        var suffix = String(pathOnly.dropFirst(prefix.count))
        if suffix.isEmpty || suffix == "/" {
            if target.percentEncodedPath.isEmpty {
                target.percentEncodedPath = "/"
            }
            if query != nil {
                target.percentEncodedQuery = query
            }
        } else {
            if !suffix.hasPrefix("/") {
                suffix = "/" + suffix
            }
            target.percentEncodedPath = suffix
            target.percentEncodedQuery = query
        }
        return target.url
    }
}
