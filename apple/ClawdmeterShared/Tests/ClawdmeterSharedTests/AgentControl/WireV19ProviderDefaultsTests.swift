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
}
