import Foundation
import ClawdmeterShared
import OSLog

private let senderLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MacComposerSender")

/// Loopback HTTP client that the Mac composer uses instead of poking
/// `tmuxClient.pasteBytes` directly. Going through the daemon gives us
/// rate-limit + audit-log + `sendKeys`/`paste-buffer` heuristics for free
/// (Codex P0 finding: Mac send was bypassing all of these).
///
/// All calls hit `http://127.0.0.1:<boundPort>/...` with `Authorization:
/// Bearer <token>` — same auth as iOS but local-only.
@MainActor
final class MacComposerSender {

    let host: String
    let port: Int
    let token: String

    init(host: String = "127.0.0.1", port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    enum Error: Swift.Error, LocalizedError {
        case badURL
        case http(status: Int, retryAfter: Int?, detail: String?)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad daemon URL"
            case .http(let s, _, let detail):
                if let detail, !detail.isEmpty {
                    return "Daemon HTTP \(s): \(detail)"
                }
                return "Daemon HTTP \(s)"
            case .transport(let m): return m
            }
        }
    }

    func send(sessionId: UUID, body: String, asFollowUp: Bool = false) async throws {
        let req = try makeRequest(
            path: "/sessions/\(sessionId.uuidString)/send",
            jsonBody: SendPromptRequest(text: body, asFollowUp: asFollowUp)
        )
        _ = try await execute(req)
    }

    func interrupt(sessionId: UUID) async throws {
        let req = try makeRequest(
            path: "/sessions/\(sessionId.uuidString)/interrupt",
            method: "POST"
        )
        _ = try await execute(req)
    }

    func setAutopilot(sessionId: UUID, enabled: Bool) async throws {
        let req = try makeRequest(
            path: "/sessions/\(sessionId.uuidString)/autopilot",
            jsonBody: AutopilotRequest(enabled: enabled)
        )
        _ = try await execute(req)
    }

    /// v0.9 — fan out a prompt to every child of a Frontier group.
    func frontierSend(groupId: UUID, text: String) async throws {
        let req = try makeRequest(
            path: "/chat-sessions/frontier/\(groupId.uuidString)/send",
            jsonBody: SendPromptRequest(text: text, asFollowUp: false)
        )
        _ = try await execute(req)
    }

    /// v0.9 — archive losing children + return winner.
    func frontierPickWinner(groupId: UUID, childIndex: Int) async throws {
        let req = try makeRequest(
            path: "/chat-sessions/frontier/\(groupId.uuidString)/pick-winner",
            jsonBody: PickFrontierWinnerRequest(childIndex: childIndex)
        )
        _ = try await execute(req)
    }

    /// v0.9 — re-spawn one failed child slot with the same provider/model.
    func frontierRetrySlot(groupId: UUID, index: Int) async throws {
        let req = try makeRequest(
            path: "/chat-sessions/frontier/\(groupId.uuidString)/retry-slot",
            jsonBody: RetryFrontierSlotRequest(index: index)
        )
        _ = try await execute(req)
    }

    /// v0.9 — spawn a Frontier group with 2-3 model slots.
    func createFrontier(clientRequestId: UUID, slots: [FrontierModelSlot]) async throws -> CreateFrontierResponse {
        let req = try makeRequest(
            path: "/chat-sessions/frontier",
            jsonBody: CreateFrontierRequest(clientRequestId: clientRequestId, models: slots)
        )
        let data = try await execute(req)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CreateFrontierResponse.self, from: data)
    }

    /// v27 Code-tab harness migration: create a session via the daemon's
    /// `POST /sessions` harness spawn (paneless codex/cursor/gemini) and return
    /// the registered `AgentSession`. Mirrors the Mac→daemon loopback the Code
    /// tab already uses for send/interrupt, so Mac + iOS share one create path.
    /// Uses the 30s timeout (daemon-side worktree provisioning can take a few
    /// seconds) — harness bridges are live by the time this returns.
    func createSession(_ request: NewSessionRequest) async throws -> AgentSession {
        let req = try makeRequest(path: "/sessions", jsonBody: request)
        let data = try await execute(req)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentSession.self, from: data)
    }

    // MARK: - HTTP

    private func makeRequest<Body: Encodable>(path: String, jsonBody: Body) throws -> URLRequest {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { throw Error.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 30s, not 8s: the FIRST send to a Claude (tmux) chat blocks server-side
        // on the CLI warmup (boot + trust-dismiss), which can take ~10-14s with a
        // heavy MCP/plugin config. Harness providers (codex/grok/cursor) are ready
        // at create so they return fast either way; Claude is the one that needs
        // the headroom. Without it the first "hi" hit "The request timed out."
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        req.httpBody = try enc.encode(jsonBody)
        return req
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { throw Error.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func execute(_ req: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                throw Error.http(status: http.statusCode, retryAfter: retry, detail: Self.errorDetail(from: data))
            }
            return data
        } catch let urlError as URLError {
            throw Error.transport(urlError.localizedDescription)
        }
    }

    private static func errorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "cta", "reason", "error", "hint"] {
                if let value = object[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}
