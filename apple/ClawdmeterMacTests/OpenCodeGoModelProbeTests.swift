import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class OpenCodeGoModelProbeTests: XCTestCase {
    func test_parseModelsResponse_buildsGoCatalogEntries() throws {
        let json = """
        {
          "object": "list",
          "data": [
            { "id": "kimi-k2.6", "object": "model", "created": 1, "owned_by": "opencode" },
            { "id": "glm-5.1", "object": "model", "created": 1, "owned_by": "opencode" }
          ]
        }
        """.data(using: .utf8)!
        let models = try OpenCodeGoModelProbe.parseModelsResponse(json)
        XCTAssertEqual(models.map(\.id), ["kimi-k2.6", "glm-5.1"])
        XCTAssertEqual(models.first?.displayName, "OpenCode Go · Kimi K2.6")
        XCTAssertEqual(models.first?.cliAlias, "opencode-go/kimi-k2.6")
    }

    func test_parseModelsResponse_stripsGoPrefixForCatalogId() throws {
        let json = #"{ "data": [ { "id": "opencode-go/glm-5.1", "object": "model" } ] }"#.data(using: .utf8)!
        let models = try OpenCodeGoModelProbe.parseModelsResponse(json)
        XCTAssertEqual(models.first?.id, "glm-5.1")
        XCTAssertEqual(models.first?.cliAlias, "opencode-go/glm-5.1")
    }

    func test_parseModelsResponse_emptyData_returnsEmpty() throws {
        let json = #"{"data":[]}"#.data(using: .utf8)!
        XCTAssertEqual(try OpenCodeGoModelProbe.parseModelsResponse(json).count, 0)
    }
}
