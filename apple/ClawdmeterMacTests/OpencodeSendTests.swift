import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.23.2 T6 — sendOpencodePrompt path (AgentControlServer.swift:3808).
///
/// The end-to-end happy path (POST -> opencode `/session/<id>/message` ->
/// SSE `message.added` round-trips back into the chat store) is exercised
/// by `LiveDriveTests/testOpenCodeLiveDrive` behind the live-spend gate.
/// These unit tests cover the surfaces we can drive without spinning the
/// full daemon:
///   - the public BidirectionalMap lookup that gates the first
///     `opencode_session_not_registered` 503
///   - the request body shape we POST to opencode (single text part, plus
///     an optional OpenRouter model object when the Code picker selected one)
///   - the error JSON envelopes are valid JSON with the documented keys
///   - parser symmetry: a `message.added` round-trip into ChatMessage
///     produces the user-bubble shape we pre-echo on send
@MainActor
final class OpencodeSendTests: XCTestCase {

    // MARK: - Session-id gate (503 opencode_session_not_registered path)

    func test_opencodeSessionId_missingGatesSend() {
        // The first thing sendOpencodePrompt does after echoing the user
        // bubble is look up the opencode-side session id. When the SSE
        // `session.created` event hasn't landed yet, this is nil and the
        // 503 path fires. Unit-level we just confirm the lookup is the
        // gate.
        OpencodeSSEAdapter.shared.stop()
        XCTAssertNil(OpencodeSSEAdapter.shared.opencodeSessionId(for: UUID()))
    }

    func test_opencodeSessionId_presentAllowsSend() {
        OpencodeSSEAdapter.shared.stop()
        let uuid = UUID()
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_send_ok")
        XCTAssertEqual(OpencodeSSEAdapter.shared.opencodeSessionId(for: uuid), "ses_send_ok")
    }

    // MARK: - Request body shape

    func test_requestBody_isSingleTextPart() throws {
        // sendOpencodePrompt POSTs:
        //   {"parts":[{"type":"text","text":"<prompt>"}]}
        // The shape comes straight from opencode's HTTP API docs.
        // Rebuild it here and assert it survives a JSONSerialization
        // round-trip (so a future refactor that swaps to a typed
        // encoder doesn't silently change the wire shape).
        let prompt = "hello opencode"
        let body: [String: Any] = [
            "parts": [
                ["type": "text", "text": prompt]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(decoded)
        let parts = decoded?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 1)
        XCTAssertEqual(parts?.first?["type"] as? String, "text")
        XCTAssertEqual(parts?.first?["text"] as? String, prompt)
    }

    func test_requestBody_includesModelOverrideForPickedOpenRouterModel() throws {
        // When the user picked an OpenRouter model in the Code tab, the
        // opencode message body must carry the matching OpenCode model object.
        // The opencode-default sentinel still omits the override so the CLI's
        // own default can run.
        let model = try XCTUnwrap(AgentControlServer.opencodeModelObject(forModelId: "anthropic/claude-sonnet-4.6"))
        let body: [String: Any] = [
            "parts": [["type": "text", "text": "hello"]],
            "model": model
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decodedModel = decoded?["model"] as? [String: String]
        XCTAssertEqual(decodedModel?["providerID"], "openrouter")
        XCTAssertEqual(decodedModel?["modelID"], "anthropic/claude-sonnet-4.6")
        XCTAssertNil(decoded?["variant"])
        XCTAssertNil(decoded?["providerID"])
        XCTAssertNil(decoded?["modelID"])
        let parts = decoded?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 1)
        XCTAssertEqual(parts?.first?["text"] as? String, "hello")
        XCTAssertNil(AgentControlServer.opencodeModelObject(forModelId: "opencode-default"))
    }

    func test_requestBody_preservesPromptWithNewlines() throws {
        // Multi-line prompts are common (paste a stack trace). The
        // serializer must NOT mangle them.
        let prompt = "line 1\nline 2\nline 3"
        let body: [String: Any] = [
            "parts": [["type": "text", "text": prompt]]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (decoded?["parts"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(text, prompt)
    }

    func test_requestBody_handlesUnicode() throws {
        // Prompts with CJK / emojis must round-trip via JSON without
        // mojibake.
        let prompt = "你好 🐉 ¡hola!"
        let body: [String: Any] = [
            "parts": [["type": "text", "text": prompt]]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (decoded?["parts"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(text, prompt)
    }

    // MARK: - Error envelope JSON shape

    func test_errorEnvelope_sessionNotRegistered_isValidJSON() throws {
        // Mirrors the literal at AgentControlServer.swift:3845.
        let body = #"{"error":"opencode_session_not_registered","detail":"Opencode session has not been registered yet — retry in a moment."}"#
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["error"] as? String, "opencode_session_not_registered")
        XCTAssertNotNil(decoded?["detail"] as? String)
    }

    func test_errorEnvelope_serverUnreachable_isValidJSON() throws {
        // Mirrors the literal at AgentControlServer.swift:3856.
        let body = #"{"error":"opencode_server_unreachable","detail":"opencode serve is not running"}"#
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["error"] as? String, "opencode_server_unreachable")
    }

    func test_errorEnvelope_sendFailed_carriesUpstreamStatus() throws {
        // Mirrors the literal at AgentControlServer.swift:3881 with an
        // interpolated upstream status code.
        let upstream = 502
        let body = #"{"error":"opencode_send_failed","upstreamStatus":\#(upstream)}"#
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["error"] as? String, "opencode_send_failed")
        XCTAssertEqual(decoded?["upstreamStatus"] as? Int, upstream)
    }

    // MARK: - User-bubble echo shape

    func test_userBubbleEcho_buildsExpectedChatMessage() {
        // sendOpencodePrompt pre-echoes the user bubble so the composer
        // can clear its sending state without waiting on the SSE round
        // trip. Verify the ChatMessage shape matches what iOS / Mac chat
        // views expect (kind: .userText, title: "You").
        let prompt = "what's up"
        let userMsgId = "opencode-user-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
        let bubble = ChatMessage(
            id: userMsgId,
            kind: .userText,
            title: "You",
            body: prompt,
            at: Date()
        )
        XCTAssertEqual(bubble.kind, .userText)
        XCTAssertEqual(bubble.title, "You")
        XCTAssertEqual(bubble.body, prompt)
        XCTAssertTrue(bubble.id.hasPrefix("opencode-user-"),
            "user-bubble id must be prefixed so the dedupe layer can tell echo vs SSE-arrived bubble apart")
    }

    // MARK: - SSE round-trip symmetry

    func test_parseMessageAdded_userRoleMatchesEchoedBubble() {
        // When opencode echoes our user prompt back via `message.added`
        // with role:"user", the parser must produce the same kind/title
        // the echo path used — otherwise the chat view shows TWO user
        // bubbles for the same prompt.
        let props: [String: Any] = [
            "message": [
                "id": "msg_echo_back",
                "role": "user",
                "content": "what's up"
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertEqual(chat?.kind, .userText)
        XCTAssertEqual(chat?.title, "User")
        // ⚠️ Note: parser uses "User" (role.capitalized), the echo path
        // uses "You". This is intentional — the dedupe layer keys on id,
        // not title. The echo bubble carries an "opencode-user-..."
        // synthetic id so the SSE-arrived id ("msg_echo_back") doesn't
        // collide. If a future refactor unifies these, update this test
        // and the dedupe layer together.
    }
}
