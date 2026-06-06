import Foundation
import Network
import ClawdmeterShared

private struct RegisterPushTokenBody: Codable {
    let token: String
    let bundleId: String
}

private struct UnregisterPushTokenBody: Codable {
    let token: String
}

private struct RegisterAPNSDeviceTokenBody: Codable {
    /// 64 hex chars (Apple's APNS token format).
    let deviceToken: String
    /// iPhone bundle id, used to derive the APNS topic.
    let bundleId: String
    /// Pairing session id used to scope the token under the current pairing.
    let sessionId: String
}

private struct UnregisterAPNSDeviceTokenBody: Codable {
    let sessionId: String
}

private struct SetAutoReviveBody: Codable {
    let enabled: Bool
}

extension AgentControlServer {
    /// D4 (v0.17): per-provider auto-revive toggle.
    func handleSetAutoRevive(
        providerId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let kind = AgentKind(rawValue: providerId),
              kind != .unknown else {
            sendResponse(.badRequest, on: connection)
            return
        }
        guard let body = try? JSONDecoder().decode(SetAutoReviveBody.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        guard let callback = setAutoReviveCallback else {
            sendResponse(.internalError, on: connection)
            return
        }
        await MainActor.run {
            callback(kind, body.enabled)
        }
        serverLogger.info("auto-revive toggle: \(providerId, privacy: .public) -> \(body.enabled, privacy: .public)")
        sendResponse(
            .ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8)),
            on: connection
        )
    }

    func handleRegisterPushToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(RegisterPushTokenBody.self, from: request.body),
              !req.token.isEmpty, !req.bundleId.isEmpty else {
            sendResponse(.badRequest, on: connection)
            return
        }
        await MacAPNSPusher.shared.register(token: req.token, bundleId: req.bundleId)
        sendJSON(["ok": true, "registered": true], on: connection)
    }

    func handleUnregisterPushToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(UnregisterPushTokenBody.self, from: request.body),
              !req.token.isEmpty else {
            sendResponse(.badRequest, on: connection)
            return
        }
        await MacAPNSPusher.shared.unregister(token: req.token)
        sendJSON(["ok": true], on: connection)
    }

    func handleRegisterAPNSDeviceToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(RegisterAPNSDeviceTokenBody.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let token = req.deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 64,
              token.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                  || ($0.value >= 0x41 && $0.value <= 0x46)
                  || ($0.value >= 0x61 && $0.value <= 0x66)
              }) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        guard !req.bundleId.isEmpty, !req.sessionId.isEmpty else {
            sendResponse(.badRequest, on: connection)
            return
        }
        APNSPushDeviceTokenStore.shared.register(
            sessionId: req.sessionId,
            deviceToken: token,
            bundleId: req.bundleId
        )
        sendJSON(["ok": true, "registered": true], on: connection)
    }

    func handleUnregisterAPNSDeviceToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(UnregisterAPNSDeviceTokenBody.self, from: request.body),
              !req.sessionId.isEmpty else {
            sendResponse(.badRequest, on: connection)
            return
        }
        APNSPushDeviceTokenStore.shared.purge(sessionId: req.sessionId)
        sendJSON(["ok": true], on: connection)
    }

    func handleGetNeedsAttention(connection: NWConnection) async {
        let response = NeedsAttentionResponse(events: await notifications.snapshotEvents(), serverTime: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(response) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    func handleAckNotifications(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(AckNotificationsRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        await notifications.ack(through: req.ackId)
        sendResponse(.ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8)), on: connection)
    }
}
