// swift-tools-version: 5.10
// Clawdmeter shared package — UsageData, AISource protocol, AnthropicSource,
// BurnRatePredictor, Theme, and MeterRenderer primitives.
//
// Per plan E6: primitives kit (Ring, Arc, BigNumeral, StaleBadge, AODStyle)
// Per plan E8: XCTest as test framework.

import PackageDescription

let package = Package(
    name: "ClawdmeterShared",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ClawdmeterShared", targets: ["ClawdmeterShared"]),
    ],
    dependencies: [
        // Snapshot testing for primitives (Pass 3 of eng review).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
        // Apple's CommonMark parser. Used by BrainPlanParser to walk the
        // checklist structure of `implementation_plan.md` so we render
        // nested steps, ignore prose between lists, and handle fenced
        // code blocks correctly (eng review 2C fix).
        .package(url: "https://github.com/apple/swift-markdown", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "ClawdmeterShared",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [
                // Embedded LiteLLM pricing snapshot (A3 + A20). Refreshed via
                // `tools/refresh-pricing.sh`; loaded at runtime by `Pricing`.
                .process("Analytics/pricing.json"),
            ]
        ),
        .testTarget(
            name: "ClawdmeterSharedTests",
            dependencies: [
                "ClawdmeterShared",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
