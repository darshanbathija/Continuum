import XCTest
@testable import ClawdmeterShared

final class TechStackIconCatalogTests: XCTestCase {

    func test_slugForCommonExtensions() {
        XCTAssertEqual(TechStackIconCatalog.slug(for: "App.swift"), "swift")
        XCTAssertEqual(TechStackIconCatalog.slug(for: "index.tsx"), "typescript")
        XCTAssertEqual(TechStackIconCatalog.slug(for: "main.py"), "python")
        XCTAssertEqual(TechStackIconCatalog.slug(for: "server.go"), "go")
        XCTAssertEqual(TechStackIconCatalog.slug(for: "lib.rs"), "rust")
        XCTAssertEqual(TechStackIconCatalog.slug(for: "Dockerfile"), "docker")
        XCTAssertEqual(TechStackIconCatalog.slug(for: "package.json"), "nodedotjs")
        XCTAssertEqual(TechStackIconCatalog.slug(for: "Cargo.toml"), "rust")
    }

    func test_assetNameWrapsSlug() {
        XCTAssertEqual(TechStackIconCatalog.assetName(for: "swift"), "stack-swift")
        XCTAssertEqual(TechStackIconCatalog.assetName(forPath: "App.swift"), "stack-swift")
    }

    func test_filePathHintExtractsFromToolBody() {
        let path = TechStackIconCatalog.filePathHint(
            toolTitle: "Read",
            body: "/repo/Sources/App.swift"
        )
        XCTAssertEqual(path, "/repo/Sources/App.swift")
    }

    func test_unknownExtensionReturnsNilSlug() {
        XCTAssertNil(TechStackIconCatalog.slug(for: "README"))
    }
}
