import Foundation
@testable import ClawdmeterShared

/// In-memory ACP agent for driving `AcpAgentDriver` end to end without a real
/// `grok`/`cursor` binary. It is the `AcpByteWriter` the connection writes to;
/// it parses driver→agent frames and delivers agent→driver frames back into the
/// connection via `setDeliver` (wired to `connection.feed`). Mirrors the real
/// turn shape: initialize → session/new → (stream session/update) → optional
/// session/request_permission → prompt response.
actor FakeAcpAgent: AcpByteWriter {
    enum Mode: Sendable { case normal, failInitialize, withPermission }
    let mode: Mode
    private var deliver: (@Sendable (Data) async -> Void)?
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    private(set) var sawCancel = false
    private var fakeRequestId: Int64 = 9000

    init(mode: Mode = .normal) { self.mode = mode }
    func setDeliver(_ d: @escaping @Sendable (Data) async -> Void) { deliver = d }

    // AcpByteWriter — receives driver → agent bytes.
    func write(_ data: Data) async throws {
        guard let v = try? JSONDecoder().decode(ACPJSONValue.self, from: data),
              case .object(let o) = v else { return }
        if let method = o["method"]?.stringValue {
            await handle(method: method, id: o["id"], params: o["params"] ?? .object([:]))
        } else if o["id"] != nil {
            // a response from the driver to our permission request
            permissionContinuation?.resume()
            permissionContinuation = nil
        }
    }

    private func handle(method: String, id: ACPJSONValue?, params: ACPJSONValue) async {
        switch method {
        case ACP.AgentMethod.initialize:
            if mode == .failInitialize {
                await respondError(id: id, code: ACP.ErrorCode.internalError, message: "boom")
            } else {
                await respond(id: id, result: Self.initializeResult)
            }
        case ACP.AgentMethod.authenticate:
            await respond(id: id, result: .object([:]))
        case ACP.AgentMethod.sessionNew:
            await respond(id: id, result: .object(["sessionId": .string("fake-session-1")]))
        case ACP.AgentMethod.sessionPrompt:
            await runPromptSequence(promptId: id)
        case ACP.AgentMethod.sessionCancel:
            sawCancel = true
        default:
            if let id { await respondError(id: id, code: ACP.ErrorCode.methodNotFound, message: method) }
        }
    }

    private func runPromptSequence(promptId: ACPJSONValue?) async {
        await note(update: .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Hello from fake")]),
        ]))
        await note(update: .object([
            "sessionUpdate": .string("plan"),
            "plan": .object(["entries": .array([
                .object(["content": .string("Step 1"), "status": .string("pending"), "priority": .string("high")]),
                .object(["content": .string("Step 2"), "status": .string("pending"), "priority": .string("medium")]),
            ])]),
        ]))
        await note(update: .object([
            "sessionUpdate": .string("tool_call"),
            "toolCall": .object(["toolCallId": .string("tc1"), "title": .string("run tests"),
                                 "kind": .string("execute"), "status": .string("in_progress")]),
        ]))

        if mode == .withPermission {
            await requestPermissionAndWait()
        }

        await note(update: .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCall": .object(["toolCallId": .string("tc1"), "status": .string("completed")]),
        ]))
        await respond(id: promptId, result: .object(["stopReason": .string("end_turn")]))
    }

    private func requestPermissionAndWait() async {
        fakeRequestId += 1
        let id = fakeRequestId
        let frame = ACPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(ACP.ClientMethod.sessionRequestPermission),
            "params": .object([
                "sessionId": .string("fake-session-1"),
                "toolCall": .object(["title": .string("write file foo.txt")]),
                "options": .array([
                    .object(["optionId": .string("allow_once"), "name": .string("Allow"), "kind": .string("allow_once")]),
                    .object(["optionId": .string("reject_once"), "name": .string("Reject"), "kind": .string("reject_once")]),
                ]),
            ]),
        ])
        await deliverFrame(frame)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            permissionContinuation = c
        }
    }

    // MARK: emit helpers

    private static var initializeResult: ACPJSONValue {
        .object([
            "protocolVersion": .int(1),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "_meta": .object(["x.ai/fs_notify": .bool(true)]),
            ]),
            "authMethods": .array([
                .object(["id": .string("grok.com"), "name": .string("Grok"), "description": .string("Sign in with Grok")]),
            ]),
            "_meta": .object(["grokShell": .bool(true)]),
        ])
    }

    private func note(update: ACPJSONValue) async {
        let frame = ACPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(ACP.ClientMethod.sessionUpdate),
            "params": .object(["sessionId": .string("fake-session-1"), "update": update]),
        ])
        await deliverFrame(frame)
    }

    private func respond(id: ACPJSONValue?, result: ACPJSONValue) async {
        guard let id else { return }
        await deliverFrame(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    private func respondError(id: ACPJSONValue?, code: Int, message: String) async {
        guard let id else { return }
        await deliverFrame(.object(["jsonrpc": .string("2.0"), "id": id,
                                    "error": .object(["code": .int(Int64(code)), "message": .string(message)])]))
    }

    private func deliverFrame(_ frame: ACPJSONValue) async {
        guard let deliver, var data = try? JSONEncoder().encode(frame) else { return }
        data.append(0x0A)
        await deliver(data)
    }
}
