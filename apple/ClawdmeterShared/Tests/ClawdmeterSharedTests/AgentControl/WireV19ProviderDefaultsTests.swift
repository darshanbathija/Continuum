import XCTest
@testable import ClawdmeterShared

final class WireV19ProviderDefaultsTests: XCTestCase {

    func test_providerDefaultsResponseRoundTripsModelAndEffortMaps() throws {
        let snapshot = ProviderDefaultsSnapshot(
            modelByVendor: [
                ChatVendor.openrouter.rawValue: "anthropic/claude-sonnet-4.6",
                ChatVendor.cursor.rawValue: CursorModelCatalog.autoModelId,
            ],
            effortByVendor: [
                ChatVendor.openrouter.rawValue: ReasoningEffort.high.rawValue,
            ],
            updatedAt: Date(timeIntervalSince1970: 1_777_100_000)
        )
        let response = ProviderDefaultsResponse(defaults: snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProviderDefaultsResponse.self, from: data)

        XCTAssertEqual(decoded.defaults.modelByVendor[ChatVendor.openrouter.rawValue], "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(decoded.defaults.modelByVendor[ChatVendor.cursor.rawValue], CursorModelCatalog.autoModelId)
        XCTAssertEqual(decoded.defaults.effort(for: .openrouter), .high)
        XCTAssertNil(decoded.defaults.effort(for: .cursor))
    }

    func test_updateProviderDefaultRequestRoundTripsClearFlags() throws {
        let request = UpdateProviderDefaultRequest(
            model: "google/gemini-3-pro",
            effort: nil,
            clearModel: false,
            clearEffort: true
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(UpdateProviderDefaultRequest.self, from: data)

        XCTAssertEqual(decoded.model, "google/gemini-3-pro")
        XCTAssertNil(decoded.effort)
        XCTAssertFalse(decoded.clearModel)
        XCTAssertTrue(decoded.clearEffort)
    }

    @MainActor
    func test_explicitLoopbackUpdateProviderDefaultSkipsHTTP() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoopbackHTTPTrapURLProtocol.self]
        LoopbackHTTPTrapURLProtocol.reset()

        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback-token",
            urlSession: URLSession(configuration: config)
        )
        let modelId = try XCTUnwrap(ModelCatalog.bundled.claude.first?.id)

        let start = ContinuousClock.now
        let updated = await client.updateProviderDefault(
            vendor: .claude,
            model: modelId,
            effort: .high
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertEqual(updated?.modelByVendor[ChatVendor.claude.rawValue], modelId)
        XCTAssertEqual(client.providerDefaults.modelByVendor[ChatVendor.claude.rawValue], modelId)
        XCTAssertTrue(LoopbackHTTPTrapURLProtocol.requests.isEmpty)
        XCTAssertLessThan(elapsed, .milliseconds(250))
    }
}

private final class LoopbackHTTPTrapURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock()
        storedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}
