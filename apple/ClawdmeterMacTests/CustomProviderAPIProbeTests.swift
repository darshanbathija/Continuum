import XCTest
@testable import Clawdmeter

final class CustomProviderAPIProbeTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeProbe() -> CustomProviderAPIProbe {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CustomProviderAPIProbe(sessionConfiguration: config)
    }

    func testOpenAIAuthHeaderAndParseShape() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            let body = #"{"data":[{"id":"gpt-5.5","name":"GPT 5.5"}]}"#.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        let probe = makeProbe()
        let result = await probe.fetchModels(
            kind: .openAICompatible,
            baseURL: "https://api.example.com",
            apiKey: "test-key"
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.models.map(\.id), ["gpt-5.5"])
    }

    func testAnthropicAuthHeaderAndArrayParseShape() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let body = #"[{"id":"claude-opus","display_name":"Opus"}]"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let probe = makeProbe()
        let result = await probe.fetchModels(
            kind: .anthropicCompatible,
            baseURL: "https://gateway.example",
            apiKey: "anthropic-key"
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.models.first?.id, "claude-opus")
    }

    func testHTTP401And500ReturnErrorDetail() async {
        MockURLProtocol.handler = { request in
            let body = #"{"error":{"message":"invalid api key"}}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let probe = makeProbe()
        let unauthorized = await probe.fetchModels(
            kind: .openAICompatible,
            baseURL: "https://api.example.com",
            apiKey: "bad"
        )
        XCTAssertFalse(unauthorized.success)
        XCTAssertEqual(unauthorized.httpStatus, 401)
        XCTAssertEqual(unauthorized.errorDetail, "invalid api key")

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let serverError = await probe.testConnection(
            kind: .openAICompatible,
            baseURL: "https://api.example.com",
            apiKey: "key"
        )
        XCTAssertFalse(serverError.success)
        XCTAssertEqual(serverError.httpStatus, 500)
    }

    func testMalformedJSONReturnsFailure() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not-json".utf8))
        }
        let probe = makeProbe()
        let result = await probe.fetchModels(
            kind: .openAICompatible,
            baseURL: "https://api.example.com",
            apiKey: "key"
        )
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.errorDetail)
    }

    func testModelsURLAppendsV1Models() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/models")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"data":[{"id":"m1"}]}"#.data(using: .utf8)!)
        }
        let probe = makeProbe()
        let result = await probe.fetchModels(
            kind: .openAICompatible,
            baseURL: "https://gateway.example",
            apiKey: "key"
        )
        XCTAssertTrue(result.success)
    }
}
