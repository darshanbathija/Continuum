import XCTest
@testable import Clawdmeter

final class OpencodeSupportedProviderCatalogTests: XCTestCase {
    func test_splitSeparatesFeaturedAndMoreProviders() {
        let providers = [
            OpencodeSupportedProvider(id: "zeta", name: "Zeta"),
            OpencodeSupportedProvider(id: "anthropic", name: "Anthropic"),
            OpencodeSupportedProvider(id: "openrouter", name: "OpenRouter"),
            OpencodeSupportedProvider(id: "alpha", name: "Alpha"),
            OpencodeSupportedProvider(id: "openai", name: "OpenAI"),
        ]

        let snapshot = OpencodeSupportedProviderCatalog.split(providers)

        XCTAssertEqual(snapshot.featured.map(\.id), ["openai", "anthropic", "openrouter"])
        XCTAssertEqual(snapshot.more.map(\.id), ["alpha", "zeta"])
    }

    func test_bundledFallbackIncludesFeaturedProviders() {
        let ids = Set(OpencodeSupportedProviderCatalog.bundledFallback.map(\.id))
        XCTAssertTrue(OpencodeSupportedProviderCatalog.featuredProviderIDs.allSatisfy { ids.contains($0) })
    }

    func test_providerLogoURLUsesModelsDevPNG() {
        let provider = OpencodeSupportedProvider(id: "anthropic", name: "Anthropic")
        XCTAssertEqual(provider.logoURL.absoluteString, "https://models.dev/logos/anthropic.png")
    }
}
